#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$TMP"; fi' EXIT
export PATH="$TMP:$PATH"
source "$ROOT/helpers.sh"
shlib_import android
cat > "$TMP/keytool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KEYTOOL_ARGS"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-keystore" ]]; then
    : > "$2"
    break
  fi
  shift
done
EOF
chmod +x "$TMP/keytool"
export KEYTOOL_ARGS="$TMP/args"
android_generate_keystore "$TMP/credentials/new.jks"
grep -qx -- '-storetype' "$KEYTOOL_ARGS"
grep -qx -- 'JKS' "$KEYTOOL_ARGS"
[[ -f "$TMP/credentials/new.jks" ]]
touch "$TMP/existing.jks"
if android_generate_keystore "$TMP/existing.jks"; then exit 1; fi
ln -s "$TMP/missing-target.jks" "$TMP/dangling.jks"
if android_generate_keystore "$TMP/dangling.jks"; then exit 1; fi
echo '[android_keystore_test] PASS'
