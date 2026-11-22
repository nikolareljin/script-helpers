#!/usr/bin/env bash
# SCRIPT: lint_shell.sh
# DESCRIPTION: Run ShellCheck over every tracked shell file and fail on a finding.
# USAGE: bash scripts/lint_shell.sh [--list]
# PARAMETERS:
#   --list   Print the files that would be checked and exit.
#   SHELLCHECK_SEVERITY  Minimum severity that fails (error|warning|info|style). Default: error.
# EXAMPLE: SHELLCHECK_SEVERITY=warning bash scripts/lint_shell.sh
# ----------------------------------------------------
set -euo pipefail

severity="${SHELLCHECK_SEVERITY:-error}"
case "$severity" in
  error|warning|info|style) ;;
  *) echo "lint_shell: SHELLCHECK_SEVERITY must be error, warning, info or style (got '$severity')" >&2; exit 2 ;;
esac

# Tracked *.sh files, plus tracked files without the suffix whose first line
# is a sh/bash shebang (git hooks, bin/ tools, the dev shim template).
files=()
while IFS= read -r -d '' f; do
  [[ -f "$f" ]] || continue
  if [[ "$f" == *.sh ]]; then
    files+=("$f")
    continue
  fi
  first=""
  IFS= read -r first < "$f" || true
  if [[ "$first" =~ ^#!.*(/|[[:space:]])(ba)?sh([[:space:]]|$) ]]; then
    files+=("$f")
  fi
done < <(git ls-files -z)

# Checked before any "${files[@]}": bash 3.2 treats an empty array as unset.
if [[ ${#files[@]} -eq 0 ]]; then
  [[ "${1:-}" == "--list" ]] || echo "lint_shell: no shell files found."
  exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
  printf '%s\n' "${files[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "lint_shell: shellcheck is not installed." >&2
  exit 2
fi

echo "lint_shell: checking ${#files[@]} file(s) at severity '$severity'."
shellcheck -S "$severity" -- "${files[@]}"
