#!/usr/bin/env bash
# SCRIPT: svg_test.sh
# DESCRIPTION: Smoke tests for lib/svg.sh (svg_rasterize).
# USAGE: ./tests/svg_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/svg_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[svg_test] $*"; }
error() { echo "[svg_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import svg

# 1) functions defined after import
for fn in svg_rasterizer svg_rasterize svg_rasterize_sizes; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return 2
svg_rasterize >/dev/null 2>&1 && error "expected non-zero on missing args" || note "missing-args guarded"

# 3) if a rasterizer is available, render a real PNG
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/in.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"><rect width="64" height="64" fill="#1D3A5F"/></svg>
EOF

if svg_rasterizer >/dev/null 2>&1; then
  if svg_rasterize "$tmp/in.svg" "$tmp/out.png" 64 >/dev/null 2>&1 && [[ -s "$tmp/out.png" ]]; then
    note "svg_rasterize produced a non-empty PNG"
  else
    error "svg_rasterize failed to produce a PNG"
  fi
else
  note "no rasterizer installed — skipping render assertion (not a failure)"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
