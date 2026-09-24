#!/usr/bin/env bash
# SCRIPT: android_test.sh
# DESCRIPTION: Smoke tests for lib/android.sh and lib/gradle.sh.
# USAGE: ./tests/android_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/android_test.sh
# ----------------------------------------------------
#
# The Android SDK and a Gradle wrapper are not assumed. Anything needing them is
# a skip with a note, never a failure.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[android_test] $*"; }
error() { echo "[android_test][ERROR] $*" >&2; failures=$((failures+1)); }
# Run a command with a time limit and return its status, or 137 when it had to
# be killed. For checks whose regression is a hang (an option parser that
# loops on a missing value): a hang must fail the run, not stall it. The
# watcher's output goes to /dev/null so its sleep cannot hold a pipe open.
run_bounded() {
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 & local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import android

# 1) functions defined after import — including gradle's, which android loads
for fn in android_available android_sdk_root android_sdk_tool android_ensure_sdk \
          android_gradlew android_build android_artifact android_sign \
          android_avd_list android_avd_create android_emulator_start android_emulator_stop; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

for fn in gradle_available gradle_wrapper gradle_run gradle_lint gradle_test gradle_assemble gradle_clean; do
  declare -f "$fn" >/dev/null 2>&1 \
    || error "$fn is not defined — android did not load the gradle module"
done
for fn in adb_ready_serials adb_getprop adb_available; do
  declare -f "$fn" >/dev/null 2>&1 \
    || error "$fn is not defined — android did not load the adb module"
done
note "dependency modules are loaded by import"

# 2) bad args return exactly 2
set +e
android_sdk_tool >/dev/null 2>&1;               [[ $? -eq 2 ]] || error "android_sdk_tool with no args did not return 2"
android_build . bogus apk >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "android_build with a bad variant did not return 2"
android_build . debug bogus >/dev/null 2>&1;    [[ $? -eq 2 ]] || error "android_build with a bad format did not return 2"
android_avd_create >/dev/null 2>&1;             [[ $? -eq 2 ]] || error "android_avd_create with no name did not return 2"
android_sign >/dev/null 2>&1;                   [[ $? -eq 2 ]] || error "android_sign with no artifact did not return 2"
android_sign --bogus x >/dev/null 2>&1;         [[ $? -eq 2 ]] || error "android_sign with an unknown option did not return 2"
gradle_run >/dev/null 2>&1;                     [[ $? -eq 2 ]] || error "gradle_run with no args did not return 2"
gradle_run /nonexistent-dir test >/dev/null 2>&1; [[ $? -eq 2 ]] || error "gradle_run on a missing dir did not return 2"
set -e
note "bad arguments return 2"

# Canonicalised with `pwd -P`: on macOS /var is a symlink to /private/var, so
# mktemp returns /var/folders/... while anything resolving the path returns
# /private/var/folders/... . gradle_wrapper deliberately returns a resolved
# path, so an unresolved fixture path fails the comparison on macOS only.
tmp="$(cd "$(mktemp -d)" && pwd -P)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# 3) signing: a missing keystore is an error, unless the caller opted into the
#    debug-signed fallback. This is the branch a local build depends on.
printf 'fake apk' > "$tmp/app.apk"
set +e
android_sign "$tmp/app.apk" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign without a keystore returned $status (expected 2)"

set +e
android_sign "$tmp/app.apk" --allow-unsigned >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "android_sign --allow-unsigned returned $status (expected 0)"
note "the debug-signed fallback is opt-in and works"

# 4) an invalid base64 keystore is rejected, and leaves no temp file behind
set +e
SH_TEST_KS="not valid base64 !!!" android_sign "$tmp/app.apk" --base64-env SH_TEST_KS --alias x >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign with invalid base64 returned $status (expected 2)"

set +e
SH_TEST_EMPTY="" android_sign "$tmp/app.apk" --base64-env SH_TEST_EMPTY --alias x >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "android_sign with an empty base64 var returned $status (expected 2)"
note "a malformed base64 keystore is rejected"

# 5) gradle_wrapper prefers the project wrapper over a system gradle
mkdir -p "$tmp/proj"
printf '#!/usr/bin/env bash\necho gradlew "$@"\n' > "$tmp/proj/gradlew"
chmod +x "$tmp/proj/gradlew"
got="$(gradle_wrapper "$tmp/proj")"
[[ "$got" == "$tmp/proj/gradlew" ]] || error "gradle_wrapper gave '$got' (expected the project wrapper)"
gradle_available "$tmp/proj" || error "gradle_available said no with a wrapper present"
note "the project wrapper is preferred over a system gradle"

# 6) gradle_wrapper returns 3 when there is neither
mkdir -p "$tmp/bare"
if command -v gradle >/dev/null 2>&1; then
  note "a system gradle is installed — skipping the no-gradle assertion"
else
  set +e
  gradle_wrapper "$tmp/bare" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "gradle_wrapper with no gradle at all returned $status (expected 3)"
fi

# 7) android_artifact reports "not built" distinctly from "here it is"
set +e
android_artifact "$tmp/proj" debug apk >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "android_artifact with nothing built returned $status (expected 1)"

mkdir -p "$tmp/proj/app/build/outputs/apk/debug"
printf 'apk' > "$tmp/proj/app/build/outputs/apk/debug/app-debug.apk"
got="$(android_artifact "$tmp/proj" debug apk 2>/dev/null)"
[[ "$got" == *"app-debug.apk" ]] || error "android_artifact did not find the built APK (got '$got')"
note "android_artifact distinguishes not-built from built"

# 8) SDK-dependent paths degrade rather than crash
if android_available; then
  note "an Android SDK is present at $(android_sdk_root)"
else
  set +e
  android_sdk_root >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 3 ]] || error "android_sdk_root with no SDK returned $status (expected 3)"
  note "no Android SDK installed — skipping the SDK assertions (not a failure)"
fi

# 9) android_package_name reads the package, not the last name= on the badging
#    line, and build-tools are searched newest first under an SDK root that has
#    a space in it. build-tools 37 appends compileSdkVersionCodename='15', which
#    the old greedy match returned as the package name.
sdk="$tmp/sdk root"
mkdir -p "$sdk/build-tools/9.0.0" "$sdk/build-tools/37.0.0"
printf '#!/usr/bin/env sh\necho "package: name='"'"'com.example.old'"'"' versionCode='"'"'1'"'"'"\n' > "$sdk/build-tools/9.0.0/aapt2"
printf '#!/usr/bin/env sh\necho "package: name='"'"'com.example.app.debug'"'"' versionCode='"'"'1'"'"' versionName='"'"'1.0'"'"' platformBuildVersionName='"'"'15'"'"' compileSdkVersion='"'"'35'"'"' compileSdkVersionCodename='"'"'15'"'"'"\necho "sdkVersion:'"'"'21'"'"'"\n' > "$sdk/build-tools/37.0.0/aapt2"
chmod +x "$sdk/build-tools/9.0.0/aapt2" "$sdk/build-tools/37.0.0/aapt2"
got="$(ANDROID_SDK_ROOT="$sdk" android_sdk_tool aapt2 2>/dev/null)" || got=""
[[ "$got" == "$sdk/build-tools/37.0.0/aapt2" ]] || error "android_sdk_tool under a spaced SDK root gave '$got'"
got="$(ANDROID_SDK_ROOT="$sdk" android_package_name "$tmp" "$tmp/app.apk" 2>/dev/null)" || got=""
[[ "$got" == "com.example.app.debug" ]] || error "android_package_name gave '$got' (expected com.example.app.debug)"
# A real badging dump runs to hundreds of lines. Stopping at the first match
# (grep -m1) left aapt2 writing into a closed pipe; under the caller's pipefail
# (this test runs with it, like the dev-CLI template) the pipeline failed and
# the package came back empty. A dump long enough to fill the pipe buffer makes
# that deterministic rather than a race.
{
  printf '#!/usr/bin/env sh\n'
  printf 'echo "package: name='"'"'com.example.app.debug'"'"' versionCode='"'"'1'"'"'"\n'
  # shellcheck disable=SC2016  # $i belongs to the stub, not this script
  printf 'i=0; while [ $i -lt 4000 ]; do echo "uses-permission: name='"'"'android.permission.P$i'"'"'"; i=$((i+1)); done\n'
} > "$sdk/build-tools/37.0.0/aapt2"
chmod +x "$sdk/build-tools/37.0.0/aapt2"
got="$(ANDROID_SDK_ROOT="$sdk" android_package_name "$tmp" "$tmp/app.apk" 2>/dev/null)" || got=""
[[ "$got" == "com.example.app.debug" ]] || error "android_package_name with a long badging dump under pipefail gave '$got'"
note "package name is read from the package: attribute of the newest build-tools"

# 10) jarsigner gets its passwords from the environment, never argv
fakebin="$tmp/fakebin"; mkdir -p "$fakebin" "$tmp/nosdk"
cat > "$fakebin/jarsigner" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$JARSIGNER_LOG.args"
printf 'store=%s key=%s\n' "$ANDROID_SIGN_STOREPASS" "$ANDROID_SIGN_KEYPASS" > "$JARSIGNER_LOG.env"
SH
chmod +x "$fakebin/jarsigner"
printf 'ks' > "$tmp/ks.jks"
if PATH="$fakebin:$PATH" command -v apksigner >/dev/null 2>&1; then
  note "apksigner is on PATH — skipping the jarsigner assertions (not a failure)"
else
  set +e
  ANDROID_SDK_ROOT="$tmp/nosdk" PATH="$fakebin:$PATH" JARSIGNER_LOG="$tmp/js" \
    android_sign "$tmp/app.apk" --keystore "$tmp/ks.jks" --alias upload --storepass 'STORE secret' >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -eq 0 ]] || error "android_sign via jarsigner returned $status"
  if grep -q 'secret' "$tmp/js.args" 2>/dev/null; then error "jarsigner received a password on its command line: $(cat "$tmp/js.args")"; fi
  grep -q -- '-storepass:env ANDROID_SIGN_STOREPASS -keypass:env ANDROID_SIGN_KEYPASS' "$tmp/js.args" 2>/dev/null \
    || error "jarsigner was not told to read passwords from the environment: $(cat "$tmp/js.args" 2>/dev/null)"
  [[ "$(cat "$tmp/js.env" 2>/dev/null)" == "store=STORE secret key=STORE secret" ]] \
    || error "jarsigner did not see the passwords in its environment: $(cat "$tmp/js.env" 2>/dev/null)"
  note "jarsigner passwords are passed through the environment"
fi

# 11) a failing signer under set -e still removes the decoded keystore
mkdir -p "$sdk/build-tools/37.0.0" "$tmp/tmpdir"
printf '#!/usr/bin/env sh\nexit 7\n' > "$sdk/build-tools/37.0.0/apksigner"
chmod +x "$sdk/build-tools/37.0.0/apksigner"
set +e
( set -e
  TMPDIR="$tmp/tmpdir" ANDROID_SDK_ROOT="$sdk" SH_TEST_KS="$(printf 'FAKE-KEYSTORE' | base64)"
  export TMPDIR ANDROID_SDK_ROOT SH_TEST_KS
  android_sign "$tmp/app.apk" --base64-env SH_TEST_KS --alias upload --storepass x
) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 7 ]] || error "a failing apksigner under set -e gave status $status (expected 7)"
leftover="$(ls -A "$tmp/tmpdir")"
[[ -z "$leftover" ]] || error "a failing signer left the decoded keystore behind: $leftover"
rm -f "$sdk/build-tools/37.0.0/apksigner"
note "a failing signer cleans up the decoded keystore"

# 12) an option given without its value is an error, not a hang
set +e
run_bounded 10 android_sign "$tmp/app.apk" --alias x --storepass >/dev/null 2>&1
[[ $? -eq 2 ]] || error "android_sign with a trailing --storepass did not return 2 (137 = hung)"
run_bounded 10 android_emulator_start myavd --wait >/dev/null 2>&1
[[ $? -eq 2 ]] || error "android_emulator_start with a trailing --wait did not return 2 (137 = hung)"
set -e
note "a trailing option without a value returns 2"

# 13) gradle_assemble capitalizes the variant as documented; one that already is
#     capitalized is passed through unchanged.
for pair in "release:assembleRelease" "Debug:assembleDebug" "prodRelease:assembleProdRelease"; do
  got="$(gradle_assemble "$tmp/proj" "${pair%%:*}" 2>/dev/null)" || got=""
  [[ "$got" == "gradlew --no-daemon ${pair#*:}" ]] || error "gradle_assemble ${pair%%:*} ran '$got' (expected ${pair#*:})"
done
got="$(gradle_assemble "$tmp/proj" 2>/dev/null)" || got=""
[[ "$got" == "gradlew --no-daemon assembleDebug" ]] || error "gradle_assemble with no variant ran '$got'"
# In the C locale whatever the caller's: case mapping is locale data (a Turkish
# locale maps `i` to a dotted capital I). Those locales are rarely installed, so
# a `tr` on PATH stands in for one: it answers wrongly unless LC_ALL=C.
real_tr="$(command -v tr)"
mkdir -p "$tmp/localebin"
{
  printf '#!/bin/sh\n'
  # shellcheck disable=SC2016  # $LC_ALL and $@ belong to the stub
  printf 'if [ "${LC_ALL:-}" != C ]; then printf "\\304\\260"; exit 0; fi\n'
  printf 'exec "%s" "$@"\n' "$real_tr"
} > "$tmp/localebin/tr"
chmod +x "$tmp/localebin/tr"
got="$(PATH="$tmp/localebin:$PATH" LC_ALL='' gradle_assemble "$tmp/proj" instrumented 2>/dev/null)" || got=""
[[ "$got" == "gradlew --no-daemon assembleInstrumented" ]] \
  || error "gradle_assemble capitalized with the caller's locale: ran '$got'"
note "gradle_assemble capitalizes the variant"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
