#!/usr/bin/env bash
# SCRIPT: install_dev_cli_test.sh
# DESCRIPTION: Smoke tests for scripts/install_dev_cli.sh shim backup behaviour.
# USAGE: ./tests/install_dev_cli_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/install_dev_cli_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[install_dev_cli_test] $*"; }
error() { echo "[install_dev_cli_test][ERROR] $*" >&2; failures=$((failures+1)); }

ORIGINAL='echo "original script"'

# A throwaway git repo with one root script to shim.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q .
  printf '#!/usr/bin/env bash\n%s\n' "$ORIGINAL" > "$dir/start"
  chmod +x "$dir/start"
}

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# 1) First install backs the original up and leaves a shim behind.
repo="$tmp_root/once"
make_repo "$repo"
bash scripts/install_dev_cli.sh --repo "$repo" --shims start >/dev/null 2>&1 || true

if grep -q "$ORIGINAL" "$repo/start.pre-dev-cli" 2>/dev/null; then
  note "first run backs the original up to start.pre-dev-cli"
else
  error "first run did not preserve the original in start.pre-dev-cli"
fi
if grep -q 'cli.sh' "$repo/start" 2>/dev/null; then
  note "first run installs the shim"
else
  error "first run did not install the shim"
fi

# 2) Re-running must not overwrite that backup with the shim it just wrote.
#    Regression: `mv "$dest" "$dest.pre-dev-cli"` ran unconditionally, so a
#    second install replaced the only copy of the caller's script.
bash scripts/install_dev_cli.sh --repo "$repo" --shims start >/dev/null 2>&1 || true

if grep -q "$ORIGINAL" "$repo/start.pre-dev-cli" 2>/dev/null; then
  note "second run preserves the original backup"
else
  error "second run destroyed the original backup (it now holds the shim)"
fi
if grep -q 'cli.sh' "$repo/start" 2>/dev/null; then
  note "second run leaves the shim in place"
else
  error "second run did not leave a shim at start"
fi

# 3) --dry-run must not touch anything.
dry="$tmp_root/dry"
make_repo "$dry"
bash scripts/install_dev_cli.sh --repo "$dry" --shims start --dry-run >/dev/null 2>&1 || true

if [[ ! -e "$dry/start.pre-dev-cli" ]] && grep -q "$ORIGINAL" "$dry/start"; then
  note "--dry-run leaves the tree untouched"
else
  error "--dry-run modified the tree"
fi

if [[ $failures -gt 0 ]]; then
  echo "[install_dev_cli_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[install_dev_cli_test] all checks passed"
