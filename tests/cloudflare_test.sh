#!/usr/bin/env bash
# SCRIPT: cloudflare_test.sh
# DESCRIPTION: Tests for lib/cloudflare.sh -- credential resolution, version and config derivation, the confirmation gate, and the wrangler argv.
# USAGE: ./tests/cloudflare_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/cloudflare_test.sh
# ----------------------------------------------------
#
# wrangler, curl and git are PATH shims in a temporary directory. The wrangler
# shim records its argv and the environment it was handed, which is what lets
# these tests assert the two things that matter and cannot be seen from the
# outside: that the version actually reaches `--var VERSION:`, and that the API
# token never appears in argv, where any other user on the machine could read
# it with ps.
#
# The behaviours pinned here are the ones a careless implementation gets wrong
# while looking right: a protected environment deployed unattended because the
# prompt could not run, a smoke test that passes against the previous release,
# a version string computed twice so CI and a laptop disagree, and a deploy
# that silently lands on whatever account the token resolves to.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[cloudflare_test] $*"; }
error() { echo "[cloudflare_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[cloudflare_test]   ok  $*"; }

tmp="$(mktemp -d)"
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  rm -rf "$tmp"
}
trap cleanup EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import cloudflare

# --- stubs ---------------------------------------------------------------------
mkdir -p "$tmp/bin" "$tmp/work"

# Records argv one line per run, and separately whether the token was visible
# in the environment. Exits per $WRANGLER_EXIT so a failure path can be tested.
cat >"$tmp/bin/wrangler" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WRANGLER_ARGV_LOG"
printf 'token_in_env=%s\n' "${CLOUDFLARE_API_TOKEN:-unset}" >> "$WRANGLER_ENV_LOG"
exit "${WRANGLER_EXIT:-0}"
SH

# Serves a canned body for the version endpoint and 200 for everything else.
# -f -o /dev/null (the reachability probe) prints nothing; a bare fetch prints
# $CURL_BODY, which is how the version-mismatch case is driven.
cat >"$tmp/bin/curl" <<'SH'
#!/usr/bin/env bash
out=""
for a in "$@"; do
  case "$a" in
    /dev/null) out="/dev/null" ;;
  esac
done
if [ "${CURL_FAIL:-0}" = "1" ]; then exit 22; fi
if [ "$out" = "/dev/null" ]; then exit 0; fi
# Assigned on its own line, never as "${CURL_BODY:-{...}}": a `}` inside a
# default value closes the expansion early and the rest is appended as literal
# text, so every response gained a stray brace. jq and python3 reject that and
# the grep fallback does not, which made this visible only on the runner that
# installs python3.
body="${CURL_BODY:-}"
if [ -z "$body" ]; then body='{"version":"unset"}'; fi
printf '%s' "$body"
exit 0
SH

chmod +x "$tmp/bin/wrangler" "$tmp/bin/curl"

export WRANGLER_ARGV_LOG="$tmp/wrangler-argv"
export WRANGLER_ENV_LOG="$tmp/wrangler-env"
: > "$WRANGLER_ARGV_LOG"
: > "$WRANGLER_ENV_LOG"

PATH="$tmp/bin:$PATH"
export PATH

# --- cloudflare_version_string -------------------------------------------------
note "version string"

printf '1.4.2\n' > "$tmp/work/VERSION"

out="$(CF_DEPLOY_VERSION=9.9.9-deadbee cloudflare_version_string "$tmp/work/VERSION")"
if [[ "$out" = "9.9.9-deadbee" ]]; then
  ok "defers to CF_DEPLOY_VERSION, so CI's definition is the only live one"
else
  error "expected CF_DEPLOY_VERSION verbatim, got '$out'"
fi

out="$(cloudflare_version_string "$tmp/work/VERSION" 2>/dev/null)"
case "$out" in
  1.4.2-*) ok "computes <version>-<sha> from the file when CI has not decided" ;;
  *) error "expected 1.4.2-<sha>, got '$out'" ;;
esac

cloudflare_version_string "$tmp/work/nope" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "missing version file returns 2"; else error "missing version file should return 2"; fi

: > "$tmp/work/EMPTY"
cloudflare_version_string "$tmp/work/EMPTY" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then ok "empty version file returns 1"; else error "empty version file should return 1"; fi

# --- cloudflare_deploy_config --------------------------------------------------
note "deploy config derivation"

cat >"$tmp/work/wrangler.toml" <<'TOML'
# a comment mentioning name = "not-this-one"
name = "example-worker"
main = "src/index.ts"
TOML

out="$(cloudflare_deploy_config "$tmp/work/wrangler.toml" "$tmp/work/dist")"
if [[ "$out" = "$tmp/work/dist/example_worker/wrangler.json" ]]; then
  ok "derives the generated config path from the worker name, hyphens to underscores"
else
  error "expected dist/example_worker/wrangler.json, got '$out'"
fi

out="$(CLOUDFLARE_DEPLOY_CONFIG=/explicit/path.json cloudflare_deploy_config "$tmp/work/wrangler.toml" "$tmp/work/dist")"
if [[ "$out" = "/explicit/path.json" ]]; then
  ok "CLOUDFLARE_DEPLOY_CONFIG overrides the derivation"
else
  error "override ignored, got '$out'"
fi

printf 'main = "x"\n' > "$tmp/work/noname.toml"
cloudflare_deploy_config "$tmp/work/noname.toml" "$tmp/work/dist" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then ok "a config with no name returns 1"; else error "no-name config should return 1"; fi

cloudflare_deploy_config "$tmp/work/wrangler.toml" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "missing argument returns 2"; else error "missing argument should return 2"; fi

# --- cloudflare_base_url -------------------------------------------------------
note "base URL resolution"

cat >"$tmp/work/.env" <<'ENV'
STAGING_BASE_URL=https://staging.example.com
BASE_URL=https://example.com
ENV

out="$( cd "$tmp/work" && CF_DEPLOY_BASE_URL=https://ci.example.com cloudflare_base_url staging )"
if [[ "$out" = "https://ci.example.com" ]]; then
  ok "prefers CF_DEPLOY_BASE_URL over anything in .env"
else
  error "expected CF_DEPLOY_BASE_URL, got '$out'"
fi

# `env -u` would exec a binary and never see a shell function, so the
# environment is cleared inside the subshell instead.
out="$( cd "$tmp/work" && unset CF_DEPLOY_BASE_URL STAGING_BASE_URL BASE_URL && cloudflare_base_url staging )"
if [[ "$out" = "https://staging.example.com" ]]; then
  ok "falls back to <ENV>_BASE_URL"
else
  error "expected the per-environment URL, got '$out'"
fi

out="$( cd "$tmp/work" && unset CF_DEPLOY_BASE_URL PROD_BASE_URL BASE_URL && cloudflare_base_url prod )"
if [[ "$out" = "https://example.com" ]]; then
  ok "falls back to BASE_URL when there is no per-environment name"
else
  error "expected BASE_URL, got '$out'"
fi

cloudflare_base_url "" >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "empty environment returns 2"; else error "empty environment should return 2"; fi

# --- cloudflare_confirm_environment --------------------------------------------
note "confirmation gate"

cloudflare_confirm_environment staging </dev/null >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "an unprotected environment needs no confirmation"; else error "staging should not prompt"; fi

# The important one: no terminal, no --yes. It must refuse promptly rather than
# block on a read nobody can answer.
cloudflare_confirm_environment production </dev/null >/dev/null 2>&1
if [[ $? -eq 5 ]]; then
  ok "protected environment unattended returns 5 instead of hanging"
else
  error "unattended production deploy should return 5"
fi

cloudflare_confirm_environment production --yes </dev/null >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "--yes confirms a protected environment"; else error "--yes should confirm"; fi

CLOUDFLARE_DEPLOY_YES=1 cloudflare_confirm_environment production </dev/null >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "CLOUDFLARE_DEPLOY_YES=1 confirms"; else error "CLOUDFLARE_DEPLOY_YES should confirm"; fi

out="$(CLOUDFLARE_PROTECTED_ENVS="production live" bash -c '
  source ./helpers.sh; shlib_import cloudflare
  cloudflare_confirm_environment live </dev/null >/dev/null 2>&1; echo $?')"
if [[ "$out" = "5" ]]; then
  ok "CLOUDFLARE_PROTECTED_ENVS extends the protected set"
else
  error "expected 'live' to be protected, got exit '$out'"
fi

# --- cloudflare_credentials_ok -------------------------------------------------
note "credentials"

CLOUDFLARE_API_TOKEN=tok cloudflare_credentials_ok >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "a token is enough"; else error "a token should satisfy the check"; fi

# wrangler whoami succeeds in the stub, so an authenticated session passes too.
out="$( cd "$tmp/work" && env -u CLOUDFLARE_API_TOKEN WRANGLER_EXIT=1 bash -c '
  source '"$root_dir"'/helpers.sh; shlib_import cloudflare
  cloudflare_credentials_ok >/dev/null 2>&1; echo $?')"
if [[ "$out" = "4" ]]; then
  ok "no token and no session returns 4"
else
  error "expected 4 with no credentials, got '$out'"
fi

# --- cloudflare_smoke_test -----------------------------------------------------
note "smoke test"

CURL_BODY='{"version":"1.4.2-abc1234"}' cloudflare_smoke_test https://example.com 1.4.2-abc1234 /api/status >/dev/null 2>&1
if [[ $? -eq 0 ]]; then ok "matching version passes"; else error "matching version should pass"; fi

# The failure this exists to catch: the service answers, but with the release
# that was already live.
CURL_BODY='{"version":"1.4.1-oldsha0"}' cloudflare_smoke_test https://example.com 1.4.2-abc1234 /api/status >/dev/null 2>&1
if [[ $? -eq 1 ]]; then
  ok "a 200 carrying the PREVIOUS version fails, not passes"
else
  error "stale version should fail the smoke test"
fi

CURL_FAIL=1 cloudflare_smoke_test https://example.com 1.4.2 /api/status >/dev/null 2>&1
if [[ $? -eq 1 ]]; then ok "unreachable returns 1"; else error "unreachable should return 1"; fi

cloudflare_smoke_test "" 1.4.2 >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "missing base URL returns 2"; else error "missing base URL should return 2"; fi

# --- cloudflare_deploy: the argv ------------------------------------------------
note "deploy argv"

: > "$WRANGLER_ARGV_LOG"
: > "$WRANGLER_ENV_LOG"

( cd "$tmp/work" && \
  CLOUDFLARE_API_TOKEN="s3cr3t-token-value" \
  CLOUDFLARE_ACCOUNT_ID="0123456789abcdef" \
  CF_DEPLOY_VERSION="1.4.2-abc1234" \
  CF_DEPLOY_BASE_URL="https://example.com" \
  CURL_BODY='{"version":"1.4.2-abc1234"}' \
  bash -c 'source '"$root_dir"'/helpers.sh; shlib_import cloudflare
    cloudflare_deploy --env staging --config wrangler.toml --status-path /api/status' \
  >/dev/null 2>&1 )

argv="$(cat "$WRANGLER_ARGV_LOG")"

# Asserted FIRST, because every check below is a grep over this file: an empty
# log would make the "token never appears in argv" assertion pass vacuously,
# which is the shape of test that reports success while the code is broken.
if [[ -s "$WRANGLER_ARGV_LOG" ]]; then
  ok "wrangler was actually invoked (the argv log is non-empty)"
else
  error "wrangler was never invoked — every argv assertion below is vacuous"
fi

case "$argv" in
  *"--var VERSION:1.4.2-abc1234"*) ok "the deployed version reaches --var VERSION:" ;;
  *) error "expected --var VERSION:1.4.2-abc1234 in argv, got: $argv" ;;
esac
case "$argv" in
  *"--env staging"*) ok "--env carries the environment" ;;
  *) error "expected --env staging in argv, got: $argv" ;;
esac

# The security assertion. A token in argv is readable by every other user on
# the machine; it must reach wrangler through the environment only.
if grep -q 's3cr3t-token-value' "$WRANGLER_ARGV_LOG"; then
  error "the API token appeared in wrangler's argv"
else
  ok "the API token never appears in argv"
fi
if grep -q 'token_in_env=s3cr3t-token-value' "$WRANGLER_ENV_LOG"; then
  ok "the API token reaches wrangler through the environment"
else
  error "wrangler did not receive the token in its environment"
fi

# --- cloudflare_deploy: exit status ---------------------------------------------
note "deploy exit status"

# Nothing used to assert the SUCCESS path's status at all — only that the argv
# looked right. A function that did all the right things and then returned 1
# would have passed every test in this file.
rc=0
( cd "$tmp/work" && \
  CLOUDFLARE_API_TOKEN=tok CLOUDFLARE_ACCOUNT_ID=acct \
  CF_DEPLOY_VERSION="1.4.2-abc1234" CF_DEPLOY_BASE_URL="https://example.com" \
  CURL_BODY='{"version":"1.4.2-abc1234"}' \
  bash -c 'source '"$root_dir"'/helpers.sh; shlib_import cloudflare
    cloudflare_deploy --env staging --config wrangler.toml --status-path /api/status' \
  >/dev/null 2>&1 ) || rc=$?
if [[ $rc -eq 0 ]]; then ok "a successful deploy returns 0"; else error "successful deploy returned $rc, expected 0"; fi

# The gate that stops an unattended production deploy must propagate its code
# all the way out of cloudflare_deploy, not just out of the gate function.
rc=0
( cd "$tmp/work" && cloudflare_deploy --env production --config wrangler.toml </dev/null >/dev/null 2>&1 ) || rc=$?
if [[ $rc -eq 5 ]]; then
  ok "an unattended protected deploy returns 5 through cloudflare_deploy"
else
  error "expected 5 from an unattended production deploy, got $rc"
fi

# Runs a command with a deadline, portably. macOS has no `timeout` — it is GNU
# coreutils — so a bare `timeout` returned 127 on the macOS runner and the
# assertion below could not tell "hung" from "no such command". gtimeout is used
# when coreutils is installed; otherwise a backgrounded watchdog does the same
# job with nothing but the shell.
# Returns the command's status, or 124 when the deadline was hit.
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@"; return $?
  fi
  local cmd_pid watch_pid rc=0
  "$@" & cmd_pid=$!
  ( sleep "$secs"; kill -9 "$cmd_pid" 2>/dev/null ) & watch_pid=$!
  wait "$cmd_pid" 2>/dev/null || rc=$?
  kill -9 "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  # 128+9 from the watchdog's SIGKILL is a deadline hit, not a real status.
  [[ $rc -eq 137 ]] && rc=124
  return $rc
}

# Regression test for a trailing value flag. `shift 2` with one positional left
# returns 1 and shifts NOTHING, so this used to spin forever — and under
# `set -euo pipefail` it died silently instead. Bounded, so a regression fails
# the suite rather than hanging CI until the job times out.
for trailing in "--env" "--config" "--command" "--status-path"; do
  rc=0
  run_bounded 10 bash -c 'set -uo pipefail; source '"$root_dir"'/helpers.sh; shlib_import cloudflare
    cloudflare_deploy '"$trailing"'' >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 2 ]]; then
    ok "a trailing ${trailing} returns 2 instead of looping forever"
  elif [[ $rc -eq 124 ]]; then
    error "a trailing ${trailing} HUNG — the option parser loops when shift 2 cannot shift"
  else
    error "a trailing ${trailing} returned $rc, expected 2"
  fi
done

# --- cloudflare_deploy: guards --------------------------------------------------
note "deploy guards"

( cd "$tmp/work" && cloudflare_deploy --env staging --command 'rm -rf /' ) >/dev/null 2>&1
if [[ $? -eq 2 ]]; then
  ok "an unknown --command is refused before wrangler runs"
else
  error "the command allowlist did not refuse an unknown command"
fi

( cd "$tmp/work" && cloudflare_deploy --config x ) >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "a missing --env returns 2"; else error "missing --env should return 2"; fi

( cd "$tmp/work" && cloudflare_deploy --env staging --frobnicate ) >/dev/null 2>&1
if [[ $? -eq 2 ]]; then ok "an unknown option returns 2"; else error "unknown option should return 2"; fi

# A dry run must not reach wrangler at all.
: > "$WRANGLER_ARGV_LOG"
( cd "$tmp/work" && CF_DEPLOY_VERSION=1.4.2-abc1234 \
  cloudflare_deploy --env staging --config wrangler.toml --dry-run ) >/dev/null 2>&1
if [[ -s "$WRANGLER_ARGV_LOG" ]]; then
  error "a dry run invoked wrangler"
else
  ok "a dry run invokes no wrangler and needs no credentials"
fi

# --- result ---------------------------------------------------------------------
if (( failures > 0 )); then
  echo "[cloudflare_test] FAILED: $failures" >&2
  exit 1
fi
echo "[cloudflare_test] all passed"
