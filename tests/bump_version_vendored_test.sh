#!/usr/bin/env bash
# SCRIPT: bump_version_vendored_test.sh
# DESCRIPTION: bump_version.sh run from a project that vendors script-helpers bumps the project's VERSION, never the vendored copy's.
# USAGE: bash tests/bump_version_vendored_test.sh
# ----------------------------------------------------
# The default target used to be the parent of the script-helpers directory, so
# `scripts/script-helpers/scripts/bump_version.sh patch` from a project root
# bumped scripts/script-helpers/VERSION and left the project's alone.
# Collect every failure, not just the first: no -e.
set -uo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
# A hook sets GIT_DIR and friends; they would beat the cwd of every git call.
# shellcheck disable=SC2046
unset $(git rev-parse --local-env-vars 2>/dev/null) GIT_DIR GIT_WORK_TREE 2>/dev/null || true
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 CI=true

fail=0
check() { # check <label> <file> <want>
  local got; got="$(tr -d '[:space:]' < "$2" 2>/dev/null)"
  if [[ "$got" == "$3" ]]; then echo "[bump_version_vendored_test] PASS: $1"
  else echo "[bump_version_vendored_test][ERROR] $1: $2 is '$got', want '$3'" >&2; fail=1; fi
}

# A script-helpers repository, vendored into a project as a submodule.
mkdir -p "$tmp/helpers"
(cd "$root_dir" && tar -cf - helpers.sh lib scripts) | (cd "$tmp/helpers" && tar -xf -)
echo "0.55.0" > "$tmp/helpers/VERSION"
git -C "$tmp/helpers" init -q && git -C "$tmp/helpers" add -A && git -C "$tmp/helpers" commit -qm helpers
mkdir -p "$tmp/proj/sub"
git -C "$tmp/proj" init -q
echo "1.0.0" > "$tmp/proj/VERSION"
git -C "$tmp/proj" -c protocol.file.allow=always submodule add -q "$tmp/helpers" scripts/script-helpers >/dev/null 2>&1 \
  || { echo "[bump_version_vendored_test][ERROR] could not vendor the copy as a submodule" >&2; exit 1; }
vend="$tmp/proj/scripts/script-helpers"
bump="$vend/scripts/bump_version.sh"

(cd "$tmp/proj" && bash "$bump" patch >/dev/null 2>&1)
check "from the project root, the project VERSION is bumped" "$tmp/proj/VERSION" "1.0.1"
check "from the project root, the vendored VERSION is untouched" "$vend/VERSION" "0.55.0"

(cd "$tmp/proj/sub" && bash "$bump" minor >/dev/null 2>&1)
check "from a subdirectory, the project root VERSION is bumped" "$tmp/proj/VERSION" "1.1.0"

(cd "$vend" && bash "$bump" patch >/dev/null 2>&1)
check "from inside the vendored copy, the project VERSION is bumped" "$tmp/proj/VERSION" "1.1.1"
check "from inside the vendored copy, its own VERSION is untouched" "$vend/VERSION" "0.55.0"

echo "2.0.0" > "$tmp/proj/sub/V"
(cd "$tmp/proj/sub" && bash "$bump" major -f V >/dev/null 2>&1)
check "a relative -f is relative to the cwd" "$tmp/proj/sub/V" "3.0.0"

mkdir -p "$tmp/plain" && echo "0.1.0" > "$tmp/plain/VERSION"
(cd "$tmp/plain" && bash "$bump" patch >/dev/null 2>&1)
check "outside a git repository, VERSION in the cwd is bumped" "$tmp/plain/VERSION" "0.1.1"

if [[ $fail -ne 0 ]]; then exit 1; fi
