#!/usr/bin/env bash
# SCRIPT: rust_test.sh
# DESCRIPTION: Tests for lib/rust.sh -- resolving the Rust toolchain CI uses rather than PATH's first cargo.
# USAGE: ./tests/rust_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/rust_test.sh
# ----------------------------------------------------
#
# rustup and both cargos are stubs in a temporary directory. Nothing here
# installs a toolchain, reaches the network, or compiles anything.
#
# The behaviour worth pinning is the one that looks fine until it does not: a
# gate claiming "this is what CI would have run" while running an older
# distribution cargo. Its symptom is a lockfile error, so the failure points
# away from the cause.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[rust_test] $*"; }
error() { echo "[rust_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[rust_test]   ok  $*"; }

tmp="$(mktemp -d)"
# shellcheck disable=SC2317
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import rust

mkdir -p "$tmp/distro" "$tmp/rustup-toolchain" "$tmp/bin"

cat > "$tmp/distro/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.75.0 (distribution)"
EOF
cat > "$tmp/rustup-toolchain/cargo" <<'EOF'
#!/usr/bin/env bash
echo "cargo 1.96.0 (rustup)"
EOF
cat > "$tmp/bin/rustup" <<EOF
#!/usr/bin/env bash
[ "\$1" = "which" ] && echo "$tmp/rustup-toolchain/cargo"
EOF
chmod +x "$tmp/distro/cargo" "$tmp/rustup-toolchain/cargo" "$tmp/bin/rustup"

original_path="$PATH"

note "a shadowing distribution cargo is stepped over"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  resolved="$(command -v cargo)"
  [[ "$resolved" == "$tmp/rustup-toolchain/cargo" ]]
); then
  ok "cargo resolves to rustup's, not PATH's first"
else
  error "expected rustup's cargo to win, got: $(cat "$tmp/out" 2>/dev/null)"
fi

note "it says so, rather than switching silently"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "1.96.0" "$tmp/out" && grep -q "1.75.0" "$tmp/out"
); then
  ok "both versions named, so the switch is visible"
else
  error "expected both cargo versions in the message: $(cat "$tmp/out" 2>/dev/null)"
fi

note "no message when PATH already offers the right one"
if (
  PATH="$tmp/rustup-toolchain:$tmp/bin:/usr/bin:/bin"
  rust_toolchain_ci_uses >"$tmp/out" 2>&1
  [[ ! -s "$tmp/out" ]]
); then
  ok "quiet when there is nothing to report"
else
  error "expected no output, got: $(cat "$tmp/out" 2>/dev/null)"
fi

note "no rustup is an actionable refusal, not a silent fallback"
if (
  PATH="$tmp/distro:/usr/bin:/bin"
  ! rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "rustup" "$tmp/out"
); then
  ok "returns non-zero and names rustup"
else
  error "expected a non-zero return naming rustup: $(cat "$tmp/out" 2>/dev/null)"
fi

note "rustup present but with no usable cargo is also refused"
cat > "$tmp/bin/rustup" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$tmp/bin/rustup"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin"
  ! rust_toolchain_ci_uses >"$tmp/out" 2>&1
  grep -q "toolchain install stable" "$tmp/out"
); then
  ok "says how to fix it"
else
  error "expected install instructions: $(cat "$tmp/out" 2>/dev/null)"
fi

note "the report does not change PATH"
cat > "$tmp/bin/rustup" <<EOF
#!/usr/bin/env bash
[ "\$1" = "which" ] && echo "$tmp/rustup-toolchain/cargo"
EOF
chmod +x "$tmp/bin/rustup"
if (
  PATH="$tmp/distro:$tmp/bin:/usr/bin:/bin"
  rust_toolchain_report >"$tmp/out" 2>&1
  [[ "$(command -v cargo)" == "$tmp/distro/cargo" ]]
); then
  ok "report is read-only"
else
  error "rust_toolchain_report must not modify PATH"
fi

PATH="$original_path"

if [[ $failures -gt 0 ]]; then
  echo "[rust_test] $failures failure(s)" >&2
  exit 1
fi
echo "[rust_test] all checks passed"
