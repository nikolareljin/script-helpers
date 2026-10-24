#!/usr/bin/env bash
# SCRIPT: local_test_node_ci_test.sh
# DESCRIPTION: Tests that local_test_node.sh runs npm test with CI=true, so a watch-mode test runner (react-scripts, Jest, Vitest) exits instead of waiting.
# USAGE: bash tests/local_test_node_ci_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/local_test_node_ci_test.sh
# ----------------------------------------------------
#
# A stub npm records the CI it was given. Without CI, `react-scripts test`
# starts Jest in watch mode and a pre-push hook never returns. A CI the caller
# set is kept.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[local_test_node_ci_test] $*"; }
error() { echo "[local_test_node_ci_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin" "$tmp/app"
cat > "$tmp/bin/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s CI=%s\n' "$*" "${CI-unset}" >> "$NPM_LOG"
EOF
chmod +x "$tmp/bin/npm"
git init -q "$tmp/app"
printf '{"name":"x","version":"1.0.0","scripts":{"test":"react-scripts test"}}\n' > "$tmp/app/package.json"
export NPM_LOG="$tmp/npm.log"

# check <label> <want line> <env args...> -- <script args...>
check() {
  local label="$1" want="$2"; shift 2
  local envs=() rc=0
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  : > "$NPM_LOG"
  env -u CI ${envs[@]+"${envs[@]}"} PATH="$tmp/bin:$PATH" bash scripts/local_test_node.sh --quick "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then
    error "$label: exit $rc"
  elif grep -qxF -e "$want" "$NPM_LOG"; then
    note "ok  $label"
  else
    error "$label: want '$want', npm got: $(cat "$NPM_LOG")"
  fi
}

check "CI unset: npm test gets CI=true" "test CI=true" -- --dir "$tmp/app"
check "a workspace's npm test gets CI=true" "test --workspace web CI=true" -- --dir "$tmp/app" --workspace web
check "a CI the caller set is kept" "test CI=1" CI=1 -- --dir "$tmp/app"

exit "$failures"
