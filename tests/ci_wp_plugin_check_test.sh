#!/usr/bin/env bash
# SCRIPT: ci_wp_plugin_check_test.sh
# DESCRIPTION: Asserts ci_wp_plugin_check.sh loads WP-CLI config a way WP-CLI supports.
# USAGE: bash tests/ci_wp_plugin_check_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_wp_plugin_check_test.sh
# ----------------------------------------------------
#
# The helper passed `wp --config=<path>`. WP-CLI has no such parameter and
# refuses the command before it runs:
#
#   $ wp --config=/tmp/wp-cli.yml core version
#   Error: Parameter errors:
#    unknown --config parameter
#
# The supported mechanism is WP_CLI_CONFIG_PATH, which the helper already
# exported on every `docker run` while also passing the argument that broke it.
#
# Not every command surfaces this. `wp cli version` accepts `--config` without
# complaint, which is why the smoke test below runs `wp core version`.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_wp_plugin_check.sh"
failures=0
note()  { echo "[ci_wp_plugin_check_test] $*"; }
error() { echo "[ci_wp_plugin_check_test][ERROR] $*" >&2; failures=$((failures+1)); }

# 1. No wp invocation may pass --config.
if grep -n -- 'wp --config' "$SCRIPT" >/dev/null 2>&1; then
  error "$SCRIPT passes --config to wp, which WP-CLI does not accept:"
  grep -n -- 'wp --config' "$SCRIPT" | sed 's/^/    /' >&2
else
  note "no wp invocation passes --config"
fi

# 2. And the replacement must actually be set. Dropping --config without
#    exporting WP_CLI_CONFIG_PATH swaps a loud failure for a silent one: WP-CLI
#    would run with default config and never say the file was ignored.
wp_runs=$(grep -c 'WP_CLI_CONFIG_CONTENTS=' "$SCRIPT")
wp_paths=$(grep -c 'WP_CLI_CONFIG_PATH=' "$SCRIPT")
if [[ "$wp_runs" -gt 0 && "$wp_runs" -eq "$wp_paths" ]]; then
  note "all $wp_runs wp container invocations export WP_CLI_CONFIG_PATH"
else
  error "$wp_runs invocations write a config but only $wp_paths say where to read it"
fi

# 3. Smoke test: the payload the helper actually ships, run in the real image.
#    Extracted from the script rather than retyped, so editing the helper
#    without editing this test cannot leave the test passing on old text.
payload="$(sed -n "s/.*sh -lc '\(.*\)' -- \"\\\$@\".*/\1/p" "$SCRIPT" | head -1)"
if [[ -z "$payload" ]]; then
  error "could not extract the wp payload from $SCRIPT; the test would assert nothing"
elif ! docker info >/dev/null 2>&1; then
  # The macOS runner has no Docker daemon, and the repository's convention for
  # that is to skip rather than fail -- see docker_install_test.sh. The smoke
  # test is not optional, it is enforced on the Linux leg, which has one. A
  # host where docker exists but the run fails is a failure, not a skip.
  note "SKIP the smoke test -- Docker is not usable on this host; the Linux leg is where it runs"
else
  out="$(docker run --rm --entrypoint sh \
    -e WP_CLI_CONFIG_CONTENTS='color: false' \
    -e WP_CLI_CONFIG_PATH=/tmp/wp-cli.yml \
    wordpress:cli -c "$payload" -- core version 2>&1)"
  # `wp core version` on a container with no WordPress installed still fails,
  # and should: the assertion is about which failure. A parameter error means
  # the command never ran at all.
  # -E, not a BRE with \|: BSD grep does not read that as alternation, so on
  # macOS the pattern would be taken literally and never match -- a false pass.
  if grep -qiE 'unknown --config parameter|Parameter errors' <<<"$out"; then
    error "wp rejected the command before running it:"
    sed 's/^/    /' <<<"$out" >&2
  else
    note "wp accepted the command; config is loaded from the environment"
  fi
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_plugin_check_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_plugin_check_test] OK"
