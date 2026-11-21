#!/usr/bin/env bash
# SCRIPT: install_ollama_model_deps_test.sh
# DESCRIPTION: install_ollama_model.sh -D -i goes on to install the Ollama CLI
#              when install_dependencies_ai_runner returns 1 (for example no
#              Node.js on a host without apt). Both helpers are stubs.
# USAGE: ./tests/install_ollama_model_deps_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/install_ollama_model_deps_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/ollama-deps-test.XXXXXX")"
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  rm -rf -- "$work"
}
trap cleanup EXIT

# A helpers.sh that loads the real one, then replaces the two installers.
cat >"$work/helpers.sh" <<STUB
SCRIPT_HELPERS_DIR="$root_dir"
source "$root_dir/helpers.sh"
eval "_real_\$(declare -f shlib_import)"
shlib_import() {
  _real_shlib_import "\$@"
  install_dependencies_ai_runner() { echo "deps stub"; return 1; }
  ollama_install_cli() { echo "cli stub"; exit 0; }
}
STUB

rc=0
out="$(cd "$work" && SCRIPT_HELPERS_DIR="$work" \
  bash "$root_dir/scripts/install_ollama_model.sh" -D -i -n 2>&1 </dev/null)" || rc=$?
# The CLI step ran: the stub, or "already installed" when ollama is on PATH.
if [[ "$out" == *"deps stub"* && ( "$out" == *"cli stub"* || "$out" == *"ollama is already installed"* ) ]]; then
  echo "[install_ollama_model_deps_test] a failed dependency step does not stop the CLI install"
  exit 0
fi
echo "[install_ollama_model_deps_test][ERROR] rc $rc, output: $out" >&2
exit 1
