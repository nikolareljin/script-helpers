#!/usr/bin/env bash
# SCRIPT: dev_deploy_cloudflare_test.sh
# DESCRIPTION: Tests `./dev deploy cloudflare` -- target routing, option pass-through, and the project_deploy override.
# USAGE: bash tests/dev_deploy_cloudflare_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_deploy_cloudflare_test.sh
# ----------------------------------------------------
#
# The two things worth pinning here are both option-parsing, because both fail
# silently rather than loudly.
#
# `--env` has to be in the value-taking list. If it is not, `--env staging`
# parses as a flag followed by a bare word, the word is still appended to
# DEV_ARGS, and cloudflare_deploy sees `--env` with `staging` as a separate
# argument -- which happens to work. It stops working the moment an option
# follows, and the failure is a deploy to the wrong environment, not an error.
#
# The project_deploy override has to keep winning. A repository that has taken
# over the whole verb must not start deploying to Cloudflare because the
# library learned a new target.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_deploy_cloudflare_test] $*"; }
error() { echo "[dev_deploy_cloudflare_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[dev_deploy_cloudflare_test]   ok  $*"; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts"
git -C "$repo" init -q .
cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$repo/scripts/"
ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"

# Runs the verb against a stubbed cloudflare_deploy that records its argv.
# shlib_import is stubbed first: _deploy_cloudflare imports the module itself,
# which would otherwise load the real cloudflare_deploy over the stub.
run_deploy() {
  (
    # shellcheck source=/dev/null
    source "$repo/scripts/cli.sh"      # the source guard stops main
    shlib_import() { :; }
    cloudflare_deploy() { printf '%s\n' "$*" > "$tmp/argv"; return 0; }
    not_applicable() { printf 'not_applicable: %s\n' "$1" > "$tmp/argv"; return 0; }
    parse_dev_options "$@"
    # Recorded so a test can prove an option value was not swallowed as the
    # target word, which is the only thing the value-taking list actually
    # changes.
    printf '%s' "${DEV_TARGET:-}" > "$tmp/target"
    verb_deploy
  ) >/dev/null 2>&1
}

# --- target routing -------------------------------------------------------------
note "target routing"

: > "$tmp/argv"
run_deploy cloudflare --env staging
got="$(cat "$tmp/argv")"
case "$got" in
  not_applicable:*) error "deploy cloudflare fell through to not_applicable" ;;
  *) ok "deploy cloudflare routes to the cloudflare target" ;;
esac

# --- option pass-through --------------------------------------------------------
note "option pass-through"

# These use TARGET WORDS as option values on purpose, and that is the whole
# point of the test.
#
# An earlier version of this file asserted `--env staging`, which proves
# nothing: without `--env` in the value-taking list, `--env` and `staging` both
# fall through to the catch-all `*) DEV_ARGS+=("$1")` in the same order, so the
# resulting argv is byte-identical either way. The test passed with the feature
# reverted.
#
# `web`, `linux` and `host` ARE target words. If the flag is not in the
# value-taking list, the parser consumes the value as the target instead —
# DEV_TARGET flips and the value never reaches cloudflare_deploy. That is a real
# difference, so this fails when the production change is reverted.
: > "$tmp/argv"
run_deploy cloudflare --env web
got="$(cat "$tmp/argv")"
if [[ "$got" == *"--env web"* ]]; then
  ok "--env keeps a value that is also a target word"
else
  error "expected '--env web' to reach cloudflare_deploy, got: '$got'"
fi

: > "$tmp/argv"
: > "$tmp/target"
run_deploy cloudflare --env web --config linux
got="$(cat "$tmp/argv")"
tgt="$(cat "$tmp/target")"
if [[ "$got" == *"--env web"* && "$got" == *"--config linux"* ]]; then
  ok "two value-taking flags both keep target-word values"
else
  error "expected '--env web --config linux', got: '$got'"
fi
if [[ "$tgt" == "cloudflare" ]]; then
  ok "the target stays cloudflare rather than being stolen by an option value"
else
  error "DEV_TARGET was '$tgt', expected 'cloudflare' — an option value was parsed as the target"
fi

: > "$tmp/argv"
run_deploy cloudflare --env production --yes --dry-run
got="$(cat "$tmp/argv")"
if [[ "$got" == *"--env production"* && "$got" == *"--yes"* && "$got" == *"--dry-run"* ]]; then
  ok "a value-taking flag followed by bare flags keeps its value"
else
  error "expected --env production --yes --dry-run intact, got: '$got'"
fi

: > "$tmp/argv"
run_deploy cloudflare --status-path /api/status --command host
got="$(cat "$tmp/argv")"
if [[ "$got" == *"--status-path /api/status"* && "$got" == *"--command host"* ]]; then
  ok "--status-path and --command keep their values"
else
  error "expected --status-path and --command intact, got: '$got'"
fi

# --- the override still wins ----------------------------------------------------
note "project_deploy override"

: > "$tmp/argv"
(
  # shellcheck source=/dev/null
  source "$repo/scripts/cli.sh"
  shlib_import() { :; }
  cloudflare_deploy() { printf 'cloudflare_deploy ran\n' > "$tmp/argv"; return 0; }
  project_deploy() { printf 'project_deploy ran\n' > "$tmp/argv"; return 0; }
  parse_dev_options cloudflare --env staging
  verb_deploy
) >/dev/null 2>&1
got="$(cat "$tmp/argv")"
if [[ "$got" == "project_deploy ran" ]]; then
  ok "project_deploy still takes the whole verb, new target or not"
else
  error "project_deploy override was bypassed, got: $got"
fi

# --- result ---------------------------------------------------------------------
if (( failures > 0 )); then
  echo "[dev_deploy_cloudflare_test] FAILED: $failures" >&2
  exit 1
fi
echo "[dev_deploy_cloudflare_test] all passed"
