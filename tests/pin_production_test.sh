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
  export HOME="$fixture/home" GIT_CONFIG_GLOBAL="$fixture/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1
  mkdir -p "$HOME"
  : > "$GIT_CONFIG_GLOBAL"
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

cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ -n "${fixture:-}" ]]; then
    rm -rf "$fixture"
  fi
  return 0
}
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
note "5. re-pinning to the tag it already points at says so, and is a no-op"
make_fixture
out="$( cd "$work" && bash scripts/pin_production.sh 1.1.0 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  ok "exit 0"
else
  error "no-op re-pin exited $rc"
fi
# Assert the message, not just the ref: asserting only that production is where
# it already was passes against a script that does nothing at all.
case "$out" in
  *"Nothing to do"*) ok "reported it as a no-op" ;;
  *) error "expected a 'Nothing to do' message, got: $out" ;;
esac
case "$out" in
  *"Moving production"*) error "claimed to move production when it was already there" ;;
  *) ok "did not claim to move anything" ;;
esac
cleanup

# ---------------------------------------------------------------------------
note "6. a missing tag is refused, by name"
make_fixture
out="$( cd "$work" && bash scripts/pin_production.sh 9.9.9 2>&1 )" && rc=0 || rc=$?
if [[ "$rc" -ne 0 ]]; then ok "non-zero exit"; else error "a nonexistent tag was accepted"; fi
case "$out" in
  *"Tag not found: 9.9.9"*) ok "said which tag was missing" ;;
  *) error "expected 'Tag not found: 9.9.9', got: $out" ;;
esac
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
note "8. protected branch names are refused, by name"
make_fixture
for b in main master HEAD; do
  out="$( cd "$work" && bash scripts/pin_production.sh 1.2.0 --branch "$b" 2>&1 )" && rc=0 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    error "--branch $b was accepted"
  else
    case "$out" in
      *"Refusing to move branch '$b'"*) ok "--branch $b refused, with a reason" ;;
      *) error "--branch $b exited $rc but not with the refusal message: $out" ;;
    esac
  fi
done
cleanup

# --branch must actually work, or the assertions above pass for a flag that
# does nothing.
note "9. --branch moves the named branch and leaves production alone"
make_fixture
before="$(remote_production)"
if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 --branch staging >/dev/null 2>&1 ); then
  got="$(git -C "$work" ls-remote origin refs/heads/staging | awk '{print $1}')"
  [[ "$got" == "$(tag_commit 1.2.0)" ]] && ok "staging created at 1.2.0" || error "staging is at ${got:-<missing>}"
  [[ "$(remote_production)" == "$before" ]] && ok "production untouched" || error "production moved too"
else
  error "--branch staging failed"
fi
cleanup

note "10. an option given without a value is a usage error, not a silent exit"
make_fixture
for opt in --remote --branch --repo; do
  out="$( cd "$work" && bash scripts/pin_production.sh 1.2.0 "$opt" 2>&1 )" && rc=0 || rc=$?
  case "$out" in
    *"requires a value"*) ok "$opt without a value explains itself" ;;
    *) error "$opt without a value produced: '${out}' (rc=$rc)" ;;
  esac
done
cleanup

note "11. --remote is honoured"
make_fixture
( cd "$work" && git remote rename origin upstream >/dev/null 2>&1 )
if ( cd "$work" && bash scripts/pin_production.sh 1.2.0 --remote upstream >/dev/null 2>&1 ); then
  got="$(git -C "$work" ls-remote upstream refs/heads/production | awk '{print $1}')"
  [[ "$got" == "$(tag_commit 1.2.0)" ]] && ok "moved via --remote upstream" || error "production is at ${got:-<missing>}"
else
  error "--remote upstream failed"
fi
cleanup

note "12. a refused move exits 3, distinctly from an error"
make_fixture
( cd "$work" && bash scripts/pin_production.sh 1.0.0 >/dev/null 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -eq 3 ]] && ok "refusal exits 3" || error "refusal exited $rc, expected 3"
( cd "$work" && bash scripts/pin_production.sh 9.9.9 >/dev/null 2>&1 ) && rc=0 || rc=$?
[[ "$rc" -eq 1 ]] && ok "a missing tag exits 1" || error "missing tag exited $rc, expected 1"
cleanup

note "13. it acts on the repository the caller stands in, not the script's own"
make_fixture
# Run the copy vendored inside the fixture from a DIFFERENT repo, and confirm it
# targets that other repo. Before this was fixed the script resolved its target
# from its own path, so a vendored copy moved the library's own production.
other="$(mktemp -d)"
( cd "$other"
  git init -q --bare remote.git
  git init -q w && cd w
  git config user.email t@example.com && git config user.name T
  git remote add origin ../remote.git
  git commit -q --allow-empty -m one && git tag 5.0.0
  git push -q origin HEAD:main --tags
)
if ( cd "$other/w" && bash "$work/scripts/pin_production.sh" 5.0.0 >/dev/null 2>&1 ); then
  got="$(git -C "$other/w" ls-remote origin refs/heads/production | awk '{print $1}')"
  want="$(git -C "$other/w" rev-parse '5.0.0^{commit}')"
  [[ "$got" == "$want" ]] && ok "moved the caller's repo" || error "caller's production is at ${got:-<missing>}"
  [[ "$(remote_production)" == "$(tag_commit 1.1.0)" ]] && ok "the script's own repo was untouched" \
    || error "it moved the repo the script lives in"
else
  error "running the vendored copy from another repo failed"
fi
rm -rf "$other"
cleanup

# ---------------------------------------------------------------------------
if [[ "$failures" -gt 0 ]]; then
  echo "[pin_production_test] FAILED: $failures assertion(s)" >&2
  exit 1
fi
note "ALL PASSED"
