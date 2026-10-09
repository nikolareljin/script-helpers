#!/usr/bin/env bash
# SCRIPT: dev_signing_test.sh
# DESCRIPTION: Tests the ./dev signing command for Android and Fire JKS files.
# USAGE: bash tests/dev_signing_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_signing_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note() { echo "[dev_signing_test] $*"; }
error() { echo "[dev_signing_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$tmp/bin"
git -C "$repo" init -q .
cp "$ROOT_DIR/templates/dev-cli/cli.sh" "$ROOT_DIR/templates/dev-cli/_bootstrap.sh" "$repo/scripts/"
ln -s "$ROOT_DIR" "$repo/scripts/script-helpers"

cat > "$tmp/bin/keytool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KEYTOOL_ARGS"
EOF
chmod +x "$tmp/bin/keytool"
export PATH="$tmp/bin:$PATH"
export KEYTOOL_ARGS="$tmp/keytool.args"

output="$tmp/credentials/release.jks"
if (cd "$repo" && bash scripts/cli.sh signing android-keystore "$output") \
  && grep -qx -- '-storetype' "$KEYTOOL_ARGS" \
  && grep -qx -- 'JKS' "$KEYTOOL_ARGS"; then
  note 'signing android-keystore runs keytool with JKS'
else
  error 'signing android-keystore did not generate a JKS invocation'
fi

rc=0
(cd "$repo" && bash scripts/cli.sh signing android-keystore) >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 2 ]]; then
  note 'missing output returns usage error 2'
else
  error "missing output: expected 2, got $rc"
fi

if [[ $failures -eq 0 ]]; then
  note 'ALL PASSED'
  exit 0
fi
exit 1
