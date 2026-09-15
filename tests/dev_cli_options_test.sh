#!/usr/bin/env bash
# SCRIPT: dev_cli_options_test.sh
# DESCRIPTION: Tests ./dev option parsing and stack detection in templates/dev-cli/cli.sh.
# USAGE: bash tests/dev_cli_options_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_cli_options_test.sh
# ----------------------------------------------------
#
# Two ways the template lost information on the way to the scripts it drives:
# a flag's value that was also a target word (`--stack ios`) became the target,
# and stack detection returned nothing under CI=true.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_cli_options_test] $*"; }
error() { echo "[dev_cli_options_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A stand-in consumer repo running the real template.
repo="$tmp/repo"
mkdir -p "$repo/scripts"
git -C "$repo" init -q .
cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$repo/scripts/"
ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"

# parsed <args...>: prints "target=<t>|args=<a1>,<a2>,..." from parse_dev_options,
# plus "|release=<r>" / "|device=<d>" when those options are in the arguments.
parsed() {
  (
    # shellcheck source=/dev/null
    source "$repo/scripts/cli.sh"          # the source guard stops main
    local asked=" $* "
    parse_dev_options "$@"
    printf 'target=%s|args=' "$DEV_TARGET"
    local IFS=,
    printf '%s' "${DEV_ARGS[*]-}"
    # --release and --device are reported only when asked, so the older
    # expectations above keep their exact shape.
    case "$asked" in *" --release "*) printf '|release=%s' "$DEV_RELEASE" ;; esac
    case "$asked" in *" --device "*) printf '|device=%s' "$DEV_DEVICE" ;; esac
    printf '\n'
  ) 2>/dev/null
}

expect() {
  local label="$1" want="$2"; shift 2
  local got; got="$(parsed "$@")"
  if [[ "$got" == "$want" ]]; then note "$label"; else error "$label: want '$want', got '$got'"; fi
}

expect "--stack ios stays a preflight argument" \
  "target=|args=--stack,ios" --stack ios
expect "--dir android stays a preflight argument" \
  "target=|args=--quick,--dir,android" --quick --dir android
expect "screenshot --out web keeps its value" \
  "target=android|args=--out,web" android --out web
expect "record --seconds and --size keep their values" \
  "target=ios|args=--seconds,10,--size,web" ios --seconds 10 --size web
expect "--platform keeps its value" \
  "target=|args=--platform,ios" --platform ios
expect "a bare target word is still the target" \
  "target=ios|args=--quick" ios --quick
expect "a trailing value flag is passed through for the script to reject" \
  "target=|args=--stack" --stack
# A value flag followed by another option has no value: the option is parsed
# as itself rather than swallowed as the value.
expect "--dir with no value leaves --release as an option" \
  "target=|args=--dir|release=true" --dir --release
expect "--platform with no value leaves --device to be parsed" \
  "target=|args=--platform|device=X" --platform --device X
expect "--stack ios after a value-less --out" \
  "target=|args=--out,--stack,ios" --out --stack ios
help_out="$(
  (
    # shellcheck source=/dev/null
    source "$repo/scripts/cli.sh"
    # shellcheck disable=SC2317  # called by parse_dev_options on -h/--help
    usage() { echo USAGE-SHOWN; }
    parse_dev_options --stack --help
    echo PARSED-ON
  ) 2>/dev/null
)"
if [[ "$help_out" == "USAGE-SHOWN" ]]; then
  note "--stack --help shows help instead of taking --help as the stack"
else
  error "--stack --help: --help was swallowed as the value of --stack"
fi
expect "unrelated arguments pass through unchanged" \
  "target=web|args=1.4.0,--gif" web 1.4.0 --gif

# --- stack detection under CI=true -------------------------------------------
mkdir -p "$repo/mobile"
printf 'name: demo\n' > "$repo/mobile/pubspec.yaml"
got="$(
  cd "$repo" || exit 1
  # shellcheck source=/dev/null
  source "$repo/scripts/cli.sh"
  CI=true dev_stack_dir flutter
)"
if [[ "$got" == "mobile" ]]; then
  note "nested flutter app detected with CI=true"
else
  error "nested flutter app not detected with CI=true: got '$got'"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
