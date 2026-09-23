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

# 3. Last run's reports must be cleared. out_dir persists between runs, and a
#    run whose check produces nothing discards its output rather than
#    installing it, so a stale file would be read as this run's findings.
if grep -q 'rm -f "${out_dir}/plugin-check.json"' "$SCRIPT"; then
  note "previous reports are cleared before the run"
else
  error "$SCRIPT never removes a previous plugin-check.json; stale findings would be reported as current"
fi

# 4. Smoke test: the payload the helper actually ships, run in the real image.
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

# 5. The exclusion flags must reach `wp plugin check`, and must be absent when
#    nothing was asked for. `--exclude-files=` with an empty value makes
#    plugin-check treat the empty string as a filename and skip nothing, which
#    looks like it worked.
argv_case() {   # <label> <expect: yes|no> [extra args...]
  local label="$1" expect="$2"; shift 2
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/bin" "$dir/proj"
  # The helper refuses a compose file that is not there, before it ever builds
  # the check command. A stub is enough: docker is the stand-in below.
  printf 'services:\n  wpcli:\n    image: wordpress:cli\n' > "$dir/compose.yml"
  cat > "$dir/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$dir/argv"
EOF
  chmod +x "$dir/bin/docker"
  : > "$dir/argv"
  PATH="$dir/bin:$PATH" bash "$SCRIPT" \
    --compose-file "$dir/compose.yml" --plugin-slug "p/p.php" \
    --plugin-src "$dir/proj" --out-dir "$dir/out" --db-wait-seconds 1 \
    --cleanup false "$@" >/dev/null 2>&1

  # The run must have reached `wp plugin check` at all. Asserting only that a
  # flag is absent passes just as well when the helper died before that step,
  # and `[[ -n "$x" ]] && arr+=(...)` under `set -e` is exactly that shape.
  if grep -qx -- 'check' "$dir/argv" 2>/dev/null; then
    note "$label: the run reached wp plugin check"
  else
    error "$label: the run never reached wp plugin check, so the flag assertions prove nothing"
  fi

  # Both flags, separately. Asserting only one meant the other could be
  # dropped entirely with the suite still green -- checked by doing it.
  local flag found
  for flag in --exclude-directories --exclude-files; do
    found=no
    grep -q -- "${flag}=" "$dir/argv" 2>/dev/null && found=yes
    if [[ "$found" == "$expect" ]]; then
      note "$label: ${flag} present=$found, as expected"
    else
      error "$label: ${flag} present=$found, expected $expect"
    fi
  done
  if [[ "$expect" == "no" ]] && grep -qE -- '--exclude-(files|directories)=$' "$dir/argv" 2>/dev/null; then
    error "$label: an empty exclusion flag was passed; plugin-check would skip nothing"
  fi
  rm -rf "$dir"
}

argv_case "with exclusions" yes --exclude-directories "vendor,test" --exclude-files ".gitignore"
argv_case "without exclusions" no

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_plugin_check_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_plugin_check_test] OK"
