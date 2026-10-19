#!/usr/bin/env bash
# SCRIPT: rust_resolver_check.sh
# DESCRIPTION: Real-machine check of rust_toolchain_ci_uses on Linux or macOS: asks the installed rustup for its cargo, checks PATH order and the PATH-cargo-differs warning, and runs preflight on a throwaway cargo project. No toolchain is installed or changed.
# USAGE: bash tests/machine/rust_resolver_check.sh [--keep] [-h]
# PARAMETERS:
#   --keep      Leave the throwaway directory for inspection (its path is printed).
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  every case passed
#   1  a case failed
#   2  bad arguments, or this machine cannot run the check (no rustup)
# EXAMPLE:
#   bash tests/machine/rust_resolver_check.sh
# ----------------------------------------------------
# Not part of `make test`: it runs the real rustup and cargo. It never runs
# `rustup toolchain install`, `rustup default` or `rustup override`; a toolchain
# that is not installed is reported, not fetched. The fake cargo and the cargo
# project live in a directory made here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keep=false
for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v rustup >/dev/null 2>&1 || { echo "SKIP: rustup is not installed"; exit 2; }

passed=0
failed=0
case_() { # case_ <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"; passed=$((passed + 1))
  else
    printf 'FAIL  %s\n      expected [%s]\n      got      [%s]\n' "$1" "$2" "$3"; failed=$((failed + 1))
  fi
}

work="$(mktemp -d)"
cleanup() {
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  if [[ "$keep" == true ]]; then echo "kept: $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

echo "machine: $(uname -s) $(uname -m), bash $BASH_VERSION; $(rustup --version 2>/dev/null | sed -n 1p)"
echo "PATH cargo: $(command -v cargo 2>/dev/null || echo none); RUST_TOOLCHAIN=${RUST_TOOLCHAIN:-unset}"

# resolve <toolchain or ""> <extra PATH dir or "">: rust_toolchain_ci_uses in a
# fresh shell; prints "rc|first cargo on PATH|first PATH segment", stderr in $work/err.
resolve() {
  PATH="${2:+$2:}$PATH" bash -c '
    source "$1/helpers.sh"; shlib_import rust
    rc=0; rust_toolchain_ci_uses ${2:+"$2"} 2>"$3" || rc=$?
    printf "%s|%s|%s\n" "$rc" "$(command -v cargo || true)" "${PATH%%:*}"' _ "$ROOT" "$1" "$work/err"
}

toolchains=(stable)
[[ -n "${RUST_TOOLCHAIN:-}" && "$RUST_TOOLCHAIN" != stable ]] && toolchains+=("$RUST_TOOLCHAIN")

n=1
for tc in "${toolchains[@]}"; do
  echo
  echo "$n. rust_toolchain_ci_uses $tc"; n=$((n + 1))
  want="$(rustup which --toolchain "$tc" cargo 2>/dev/null || true)"
  if [[ -z "$want" ]]; then
    case_ "$tc: rustup has a cargo for it (rustup toolchain install $tc; not done here)" installed missing
    continue
  fi
  case_ "$tc: rustup's cargo is first on PATH" "0|$want|${want%/*}" "$(resolve "$tc" "")"
done

echo
echo "$n. a different cargo earlier on PATH"; n=$((n + 1))
want="$(rustup which --toolchain stable cargo 2>/dev/null || true)"
mkdir -p "$work/fake"
printf '#!/bin/sh\necho "cargo 0.0.0-fake"\n' > "$work/fake/cargo"
chmod +x "$work/fake/cargo"
case_ 'stable: rustup cargo wins over the fake' "0|$want|${want%/*}" "$(resolve stable "$work/fake")"
warned=no
if grep -q 'PATH offered cargo 0.0.0-fake' "$work/err"; then warned=yes; else cat "$work/err" >&2; fi
case_ 'warning names the fake as what PATH offered' yes "$warned"

echo
echo "$n. preflight on a throwaway cargo project"
proj="$work/proj"
mkdir -p "$proj/src"
printf '[package]\nname = "rcheck"\nversion = "0.1.0"\nedition = "2021"\n\n[dependencies]\n' > "$proj/Cargo.toml"
printf 'pub fn two() -> u32 { 2 }\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn two() { assert_eq!(super::two(), 2); }\n}\n' > "$proj/src/lib.rs"
rc=0
env -u CI bash "$ROOT/scripts/preflight.sh" --quick --skip-security --stack rust --dir "$proj" >"$work/preflight.out" 2>&1 || rc=$?
line="$(grep -E '^(PASS|FAIL|SKIP)  rust' "$work/preflight.out" | sed -n 1p || true)"
echo "   preflight rc $rc: ${line:-no rust line}"
verdict=bad
case "$rc:$line" in
  0:PASS*|0:SKIP*) verdict=ok ;;
esac
[[ "$verdict" == ok ]] || tail -n 30 "$work/preflight.out" >&2
case_ 'preflight reports PASS or SKIP for rust and exits 0' ok "$verdict"

echo
echo "Not covered here: a missing rustup (exit 2 above), a toolchain rustup has not"
echo "installed, rustup directory overrides, and Windows; run the PowerShell check there:"
echo "  pwsh -NoProfile -File ps/tests/machine/rust_resolver_check.ps1"
echo
echo "summary: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
