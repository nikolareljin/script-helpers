#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export PATH="$TMP:$PATH"
source "$ROOT/helpers.sh"
shlib_import android
cat > "$TMP/keytool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KEYTOOL_ARGS"
EOF
chmod +x "$TMP/keytool"
export KEYTOOL_ARGS="$TMP/args"
android_generate_keystore "$TMP/new.jks"
grep -qx -- '-storetype' "$KEYTOOL_ARGS"
grep -qx -- 'JKS' "$KEYTOOL_ARGS"
touch "$TMP/existing.jks"
if android_generate_keystore "$TMP/existing.jks"; then exit 1; fi
echo '[android_keystore_test] PASS'
