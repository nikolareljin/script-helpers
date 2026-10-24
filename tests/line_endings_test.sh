#!/usr/bin/env bash
# SCRIPT: line_endings_test.sh
# DESCRIPTION: Tests that a clone with core.autocrlf=true, the Git for Windows default, checks every text file out with LF and its scripts still run.
# USAGE: ./tests/line_endings_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/line_endings_test.sh
# ----------------------------------------------------
#
# Without .gitattributes such a clone checks scripts out with CRLF and bash
# fails on them with $'\r': command not found. autocrlf=true converts on Linux
# and macOS too, so this runs everywhere, not only on Windows. It clones the
# committed HEAD: an uncommitted .gitattributes change is not tested.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
error() { echo "[line_endings_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[line_endings_test]   ok  $*"; }

if ! git rev-parse --verify -q HEAD >/dev/null; then
  echo "[line_endings_test] SKIP: not a git checkout"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# No global or system config, so a developer's own autocrlf or attributes
# cannot decide the result.
if ! GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -c core.autocrlf=true clone -q --no-local "$root_dir" "$tmp/clone" 2>"$tmp/clone.err"; then
  error "clone failed: $(head -1 "$tmp/clone.err")"
  exit 1
fi

crlf="$(git -C "$tmp/clone" ls-files --eol | grep 'w/crlf' || true)"
if [ -n "$crlf" ]; then
  error "checked out with CRLF under autocrlf=true ($(printf '%s\n' "$crlf" | wc -l | tr -d ' ') files):"
  sed -n '1,5p' <<<"$crlf" >&2
else
  ok "no file checks out with CRLF under autocrlf=true"
fi

# A script with no extension, which a *.sh rule alone would miss. It runs in
# the clone, with HOME and XDG_CONFIG_HOME in the temporary directory, so this
# checkout's .githooks and the developer's name list play no part. Only a CR
# in its error counts: without a name list the hook may refuse for other reasons.
mkdir -p "$tmp/home"
if (cd "$tmp/clone" && HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" \
      bash scripts/git-hooks/commit-msg /dev/null) >/dev/null 2>"$tmp/hook.err" \
    || ! grep -q $'\r' "$tmp/hook.err"; then
  ok "scripts/git-hooks/commit-msg runs from the clone with no CR error"
else
  error "scripts/git-hooks/commit-msg failed on a CR: $(head -1 "$tmp/hook.err")"
fi

exit "$failures"
