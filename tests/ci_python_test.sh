#!/usr/bin/env bash
# SCRIPT: ci_python_test.sh
# DESCRIPTION: Tests the command scripts/ci_python.sh hands to docker.
# USAGE: bash tests/ci_python_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_python_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[ci_python_test] $*"; }
error() { echo "[ci_python_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A docker stand-in that records the command string it was asked to run.
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/proj"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
for last in "\$@"; do :; done
printf '%s' "\$last" > "$tmp/cmd"
EOF
chmod +x "$tmp/bin/docker"
printf 'pytest\n' > "$tmp/proj/requirements.txt"

rc=0
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh \
  --workdir "$tmp/proj" --extra-install "pytest-cov" --test-cmd "pytest -q" >/dev/null 2>&1 || rc=$?
got="$(cat "$tmp/cmd" 2>/dev/null)"
# shellcheck disable=SC2016 # $PATH is literal text in the expected command
want='python -m pip install --user --upgrade pip && python -m pip install --user -r "requirements.txt" && python -m pip install --user pytest-cov && export PATH="/tmp/.local/bin:$PATH" && pytest -q'
if [[ $rc -eq 0 && "$got" == "$want" ]]; then
  note "docker mode joins every step with ' && '"
else
  error "docker command: rc=$rc"
  error "  want: $want"
  error "  got:  $got"
fi

rc=0
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh \
  --workdir "$tmp/proj" --no-install --test-cmd "pytest -q" >/dev/null 2>&1 || rc=$?
got="$(cat "$tmp/cmd" 2>/dev/null)"
# shellcheck disable=SC2016 # $PATH is literal text in the expected command
want='export PATH="/tmp/.local/bin:$PATH" && pytest -q'
if [[ $rc -eq 0 && "$got" == "$want" ]]; then
  note "a single step is passed unchanged"
else
  error "single step: rc=$rc got: $got"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
