#!/usr/bin/env bash
# SCRIPT: local_test_python_requirements_test.sh
# DESCRIPTION: Tests that local_test_python.sh installs requirements-dev.txt after requirements.txt, so a project that keeps pytest there is tested, not skipped.
# USAGE: bash tests/local_test_python_requirements_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/local_test_python_requirements_test.sh
# ----------------------------------------------------
#
# A stub .venv/bin/python logs each pip install and answers the pytest probes,
# so nothing is downloaded. Without the fix a project with pytest only in
# requirements-dev.txt reported SKIP and preflight passed without the suite.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[local_test_python_requirements_test] $*"; }
error() { echo "[local_test_python_requirements_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# project <name> <files...>: a git repo with a stub venv and the named files.
project() {
  local p="$tmp/$1"; shift
  mkdir -p "$p/.venv/bin"
  git init -q "$p"
  cat > "$p/.venv/bin/python" <<'STUB'
#!/usr/bin/env bash
log="$(dirname "$0")/../../pip.log"
case "$*" in
  "-m pip --version") exit 0 ;;
  "-m pip install -r "*) args="$*"; args="${args#-m pip install }"; echo "${args% --quiet}" >> "$log"; exit 0 ;;
  "-m pytest --version") exit 0 ;;
  "-m pytest "*) echo pytest >> "$log"; exit 0 ;;
esac
exit 1
STUB
  chmod +x "$p/.venv/bin/python"
  local f; for f in "$@"; do : > "$p/$f"; done
  : > "$p/pip.log"
  printf '%s\n' "$p"
}

# expect <label> <dir> <want log, lines joined by |>
expect() {
  local label="$1" p="$2" want="$3" rc=0 got
  bash scripts/local_test_python.sh --dir "$p" >/dev/null 2>"$tmp/err" || rc=$?
  got="$(tr '\n' '|' < "$p/pip.log")"; got="${got%|}"
  if [[ $rc -eq 0 && "$got" == "$want" ]]; then
    note "ok  $label"
  else
    error "$label: exit $rc, want '$want', got '$got': $(head -1 "$tmp/err")"
  fi
}

p="$(project both requirements.txt requirements-dev.txt)"
expect "requirements-dev.txt installs after requirements.txt" "$p" "-r requirements.txt|-r requirements-dev.txt|pytest"
p="$(project devonly requirements-dev.txt)"
expect "requirements-dev.txt alone installs" "$p" "-r requirements-dev.txt|pytest"
p="$(project runtime requirements.txt)"
expect "requirements.txt alone, unchanged" "$p" "-r requirements.txt|pytest"

# preflight finds the stack from requirements-dev.txt alone, or never runs it.
# CI is cleared: preflight refuses to run under CI=true.
p="$(project detect requirements-dev.txt)"
if [[ "$(CI='' bash scripts/preflight.sh --list --dir "$p" 2>/dev/null)" == *"python"* ]]; then
  note "ok  preflight detects a project with only requirements-dev.txt"
else
  error "preflight does not detect a project with only requirements-dev.txt"
fi

exit "$failures"
