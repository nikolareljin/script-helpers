#!/usr/bin/env bash
# SCRIPT: release_notes_test.sh
# DESCRIPTION: Tests for scripts/release_notes.sh and scripts/check_changelog_section.sh.
# USAGE: ./tests/release_notes_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/release_notes_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[release_notes_test] $*"; }
error() { echo "[release_notes_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

notes="$root_dir/scripts/release_notes.sh"
gate="$root_dir/scripts/check_changelog_section.sh"

# Same shape as git_branches_test.sh: identity per invocation with -c, so the
# fixture never writes a user into any config.
git_t() { git -c user.name='script-helpers tests' -c user.email='tests@localhost' "$@"; }

# A repository with two releases. 0.1.0 is tagged at the first commit, then two
# more commits land, then 0.2.0 is tagged at the tip -- which is the state the
# release workflows actually run in, and the state the old generator got wrong.
build_repo() {
  local dir="$1"
  mkdir -p "$dir"
  ( cd "$dir"
    git init --quiet -b main .
    echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: the first thing"
    git_t tag 0.1.0
    echo two > b.txt; git_t add b.txt; git_t commit --quiet -m "fix: the second thing"
    echo three > c.txt; git_t add c.txt; git_t commit --quiet -m "fix: the third thing"
    git_t tag 0.2.0
  )
}

# ---------------------------------------------------------------------------
# 1) The regression. HEAD carries the tag being released, so
#    `git describe --tags --abbrev=0` returns that tag and the range is empty.
#    The notes must still be the commits since the PREVIOUS tag.
# ---------------------------------------------------------------------------
build_repo "$tmp/r1"
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"

grep -q "the second thing" <<<"$out" || error "notes lost a commit from the range (0.1.0..0.2.0)"
grep -q "the third thing"  <<<"$out" || error "notes lost the tip commit"
grep -q "the first thing"  <<<"$out" && error "notes reached back past the previous tag"
grep -qi "No changes"      <<<"$out" && error "notes fell through to the placeholder on a range with commits"
note "a tag on HEAD still yields the previous tag's range"

# The same call must not be fooled when asked before the tag exists either.
( cd "$tmp/r1" && git_t tag -d 0.2.0 >/dev/null )
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "the third thing" <<<"$out" || error "notes are wrong when the tag does not exist yet"
note "notes are the same before the tag is created"
( cd "$tmp/r1" && git_t tag 0.2.0 )

# ---------------------------------------------------------------------------
# 2) A CHANGELOG section wins over the commit range.
# ---------------------------------------------------------------------------
cat > "$tmp/r1/CHANGELOG.md" <<'EOF'
# Changelog

## 2026-09-12 — v0.2.0

### Added
- Something a person wrote.

## 2026-01-01 — v0.1.0

- The older one.
EOF
out="$("$notes" --version 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "Something a person wrote." <<<"$out" || error "the CHANGELOG section was not preferred"
grep -q "the third thing"           <<<"$out" && error "the commit range leaked in alongside the changelog"
grep -q "The older one."            <<<"$out" && error "the next section leaked in"
note "a CHANGELOG section is preferred over the commit range"

# ...and a version the changelog does not mention still falls back to commits,
# rather than reporting the wrong section or nothing at all.
out="$("$notes" --version 0.3.0 --tag 0.2.0 --repo "$tmp/r1" 2>/dev/null)"
grep -q "the third thing" <<<"$out" || error "a version absent from the CHANGELOG did not fall back to commits"
note "a version absent from the CHANGELOG falls back to the range"

# ---------------------------------------------------------------------------
# 3) Prefix collision. Asking for 0.2.0 must not match a v10.2.0 header.
#    This is why changelog_extract matches on boundaries rather than substrings.
# ---------------------------------------------------------------------------
cat > "$tmp/r1/COLLIDE.md" <<'EOF'
# Changelog

## 2026-09-10 — v10.2.0

- ten point two.

## 2026-01-01 — v0.2.0

- zero point two.
EOF
out="$("$notes" --version 0.2.0 --changelog "$tmp/r1/COLLIDE.md" --repo "$tmp/r1" 2>/dev/null)"
grep -q "zero point two." <<<"$out" || error "0.2.0 did not select its own section"
grep -q "ten point two."  <<<"$out" && error "0.2.0 matched the v10.2.0 section"
out="$("$notes" --version 10.2.0 --changelog "$tmp/r1/COLLIDE.md" --repo "$tmp/r1" 2>/dev/null)"
grep -q "ten point two." <<<"$out" || error "10.2.0 did not select its own section"
note "a version matches its own section, not one it is a substring of"

# ---------------------------------------------------------------------------
# 4) A first release has no previous tag: every commit, and no placeholder.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/r2"
( cd "$tmp/r2"
  git init --quiet -b main .
  echo one > a.txt; git_t add a.txt; git_t commit --quiet -m "feat: the only thing"
  git_t tag 0.1.0
)
out="$("$notes" --version 0.1.0 --repo "$tmp/r2" 2>/dev/null)"
grep -q "the only thing" <<<"$out" || error "a first release did not list its commits"
grep -qi "No changes"    <<<"$out" && error "a first release produced the placeholder"
note "a first release lists every commit"

# ---------------------------------------------------------------------------
# 5) When there genuinely is nothing, say what was looked at. The old
#    `* No changes listed.` could not be told apart from a broken range.
# ---------------------------------------------------------------------------
( cd "$tmp/r2" && git_t tag 0.2.0 )   # a second tag on the same commit
out="$("$notes" --version 0.2.0 --repo "$tmp/r2" 2>/dev/null)"
grep -q "0.2.0" <<<"$out" || error "an empty result did not name the version"
grep -qi "looked at" <<<"$out" || error "an empty result did not say what it looked at"
[[ "$out" == "* No changes listed." ]] && error "the bare placeholder came back"
note "an empty result says which version and which source"

# ---------------------------------------------------------------------------
# 6) --output writes the body to a file, so notes reach actions by body_path
#    rather than through an interpolated string.
# ---------------------------------------------------------------------------
"$notes" --version 0.2.0 --repo "$tmp/r1" --output "$tmp/body.md" >/dev/null 2>&1
[[ -s "$tmp/body.md" ]] || error "--output wrote nothing"
grep -q "Something a person wrote." "$tmp/body.md" || error "--output wrote the wrong body"
note "--output writes the body to a file"

# ---------------------------------------------------------------------------
# 7) The gate: missing section fails, present section passes, and it is a no-op
#    away from a release branch.
# ---------------------------------------------------------------------------
"$gate" --version 0.2.0 --changelog "$tmp/r1/CHANGELOG.md" --repo "$tmp/r1" >/dev/null 2>&1 \
  || error "the gate rejected a version that has a section"
"$gate" --branch feat/something --repo "$tmp/r1" >/dev/null 2>&1 \
  || error "the gate did not skip a non-release branch"
set +e
"$gate" --version 9.9.9 --changelog "$tmp/r1/CHANGELOG.md" --repo "$tmp/r1" >/dev/null 2>&1
status=$?
"$gate" --version 0.2.0 --changelog "$tmp/r1/ABSENT.md" --repo "$tmp/r1" >/dev/null 2>&1
status_absent=$?
set -e
[[ "$status" -eq 1 ]] || error "the gate accepted a version with no section (returned $status)"
[[ "$status_absent" -eq 1 ]] || error "the gate accepted a missing CHANGELOG (returned $status_absent)"
note "the gate fails on a missing section and skips off a release branch"

# ---------------------------------------------------------------------------
# 8) Bad arguments are refused rather than assumed.
# ---------------------------------------------------------------------------
set +e
"$notes" >/dev/null 2>&1;                              no_version=$?
"$notes" --version 1.0.0 --repo /nope >/dev/null 2>&1; bad_repo=$?
"$notes" --bogus >/dev/null 2>&1;                      bad_flag=$?
set -e
[[ "$no_version" -eq 2 ]] || error "no --version returned $no_version (expected 2)"
[[ "$bad_repo"   -eq 2 ]] || error "a missing --repo returned $bad_repo (expected 2)"
[[ "$bad_flag"   -eq 2 ]] || error "an unknown flag returned $bad_flag (expected 2)"
note "bad arguments return 2"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
