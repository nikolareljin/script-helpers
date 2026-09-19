#!/usr/bin/env bash
# SCRIPT: pin_production_test.sh
# DESCRIPTION: Tests for scripts/pin_production.sh.
# USAGE: ./tests/pin_production_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/pin_production_test.sh
# ----------------------------------------------------
#
# The case worth a fixture is the rollback: pinning production BACK to an
# earlier tag. `git merge --ff-only <ancestor>` answers "Already up to date"
# and exits 0, so the old implementation pushed nothing and printed success
# while production stayed put. A test that only checks the forward move — the
# obvious one to write — passes against that bug, so the assertions below are
# on the ref's actual value after the run, never on the exit code alone.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"

failures=0
note()  { echo "[pin_production_test] $*"; }
error() { echo "[pin_production_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

script="$root_dir/scripts/pin_production.sh"

# A throwaway consumer repo with a bare remote, three tags, and `production`
# sitting on the middle one.
make_fixture() {
  fixture="$(mktemp -d)"
  ( cd "$fixture"
    git init -q --bare remote.git
    git init -q work
    cd work
    git config user.email test@example.com
    git config user.name "Test"
    git remote add origin ../remote.git
    for v in 1.0.0 1.1.0 1.2.0; do
      git commit -q --allow-empty -m "v$v"
      git tag "$v"
    done
    git push -q origin HEAD:main --tags
    git push -q origin "1.1.0:refs/heads/production"
    # Copy the script under test in, so it runs against this repo's root, and
    # COMMIT it: left untracked, it would make the tree dirty, and a dirty tree
    # is itself a refusal in some implementations — which would make every
    # assertion below pass or fail for the wrong reason.
    mkdir -p scripts
    cp "$script" scripts/pin_production.sh
    chmod +x scripts/pin_production.sh
    git add scripts/pin_production.sh
    git commit -q -m "fixture: script under test"
    git push -q origin HEAD:main
  )
  work="$fixture/work"
}

remote_production() {
  git -C "$work" ls-remote origin refs/heads/production | awk '{print $1}'
}
tag_commit() {
  git -C "$work" rev-parse "$1^{commit}"
}

cleanup() { [[ -n "${fixture:-}" ]] && rm -rf "$fixture"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
note "1. forward move fast-forwards production"
make_fixture
if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 >/dev/null 2>&1 ); then
  if [[ "$(remote_production)" == "$(tag_commit 1.2.0)" ]]; then
    ok "production advanced to 1.2.0"
  else
    error "exit 0 but production is at $(remote_production), wanted $(tag_commit 1.2.0)"
  fi
else
  error "forward move failed"
fi
cleanup

# ---------------------------------------------------------------------------
note "2. rollback is REFUSED without --allow-rewind, and changes nothing"
make_fixture
before="$(remote_production)"
if ( cd "$work" && bash scripts/pin_production.sh 1.0.0 >/dev/null 2>&1 ); then
  error "rollback without --allow-rewind exited 0; it must refuse"
else
  ok "refused"
fi
if [[ "$(remote_production)" == "$before" ]]; then
  ok "production unchanged after the refusal"
else
  error "refused but production moved to $(remote_production)"
fi
cleanup

# ---------------------------------------------------------------------------
# This is the assertion the old implementation fails: it exits 0 and prints
# success, but production is still on 1.1.0.
note "3. rollback WITH --allow-rewind actually moves production back"
make_fixture
if ( cd "$work" && bash scripts/pin_production.sh 1.0.0 --allow-rewind >/dev/null 2>&1 ); then
  if [[ "$(remote_production)" == "$(tag_commit 1.0.0)" ]]; then
    ok "production rolled back to 1.0.0"
  else
    error "exit 0 but production is at $(remote_production), wanted $(tag_commit 1.0.0) — the silent no-op"
  fi
else
  error "rollback with --allow-rewind failed"
fi
cleanup

# ---------------------------------------------------------------------------
note "4. --dry-run reports and pushes nothing"
make_fixture
before="$(remote_production)"
if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 --dry-run >/dev/null 2>&1 ); then
  if [[ "$(remote_production)" == "$before" ]]; then
    ok "dry run left production alone"
  else
    error "dry run moved production to $(remote_production)"
  fi
else
  error "dry run exited non-zero"
fi
cleanup

# ---------------------------------------------------------------------------
note "5. re-pinning to the tag it already points at is a truthful no-op"
make_fixture
if ( cd "$work" && bash scripts/pin_production.sh 1.1.0 >/dev/null 2>&1 ); then
  if [[ "$(remote_production)" == "$(tag_commit 1.1.0)" ]]; then
    ok "still on 1.1.0, exit 0"
  else
    error "production is at $(remote_production)"
  fi
else
  error "no-op re-pin exited non-zero"
fi
cleanup

# ---------------------------------------------------------------------------
note "6. a missing tag is refused"
make_fixture
if ( cd "$work" && bash scripts/pin_production.sh 9.9.9 >/dev/null 2>&1 ); then
  error "a nonexistent tag was accepted"
else
  ok "refused"
fi
cleanup

# ---------------------------------------------------------------------------
note "7. production is created on first pin when the branch does not exist"
make_fixture
git -C "$work" push -q origin --delete production
if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 >/dev/null 2>&1 ); then
  if [[ "$(remote_production)" == "$(tag_commit 1.2.0)" ]]; then
    ok "created at 1.2.0"
  else
    error "production is at $(remote_production), wanted $(tag_commit 1.2.0)"
  fi
else
  error "first pin failed"
fi
cleanup

# ---------------------------------------------------------------------------
note "8. protected branch names are refused"
make_fixture
for b in main master HEAD; do
  if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 --branch "$b" >/dev/null 2>&1 ); then
    error "--branch $b was accepted"
  else
    ok "--branch $b refused"
  fi
done
cleanup

# ---------------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
  echo "[pin_production_test] FAILED: $failures assertion(s)" >&2
  exit 1
fi
note "ALL PASSED"
