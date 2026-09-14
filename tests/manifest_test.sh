#!/usr/bin/env bash
# SCRIPT: manifest_test.sh
# DESCRIPTION: Smoke tests for lib/manifest.sh (detect, read, write, sync, versionCode).
# USAGE: ./tests/manifest_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/manifest_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[manifest_test] $*"; }
error() { echo "[manifest_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import manifest

# 1) functions defined after import
for fn in manifest_kind manifest_detect manifest_read_version \
          manifest_write_version manifest_android_version_code manifest_sync_version; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) bad args return exactly 2
set +e
manifest_kind >/dev/null 2>&1;              [[ $? -eq 2 ]] || error "manifest_kind with no args did not return 2"
manifest_read_version >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "manifest_read_version with no args did not return 2"
manifest_write_version >/dev/null 2>&1;     [[ $? -eq 2 ]] || error "manifest_write_version with no args did not return 2"
manifest_android_version_code >/dev/null 2>&1; [[ $? -eq 2 ]] || error "manifest_android_version_code with no args did not return 2"
manifest_kind foo.txt >/dev/null 2>&1;      [[ $? -eq 2 ]] || error "manifest_kind on an unknown name did not return 2"
set -e
note "bad arguments return 2"

# 3) versionCode arithmetic, and a refusal rather than a wrong number
[[ "$(manifest_android_version_code 1.2.3)"  == "10203" ]] || error "1.2.3 should map to 10203"
[[ "$(manifest_android_version_code 2.11.7)" == "21107" ]] || error "2.11.7 should map to 21107"
[[ "$(manifest_android_version_code 1.2.3 5)" == "10208" ]] || error "offset is not applied"
set +e
manifest_android_version_code "not-a-version" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "a non-semver version returned $status (expected 2)"
note "versionCode arithmetic is correct"

# 4) round-trip each manifest kind in a temp tree
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/android/app"
printf 'name: demo\nversion: 1.2.3+45\n'                                    > "$tmp/pubspec.yaml"
printf 'android {\n  defaultConfig {\n    versionCode 10203\n    versionName "1.2.3"\n  }\n}\n' > "$tmp/android/app/build.gradle"
printf '1.2.3\n'                                                            > "$tmp/VERSION"
printf '{\n  "name": "demo",\n  "version": "1.2.3"\n}\n'                    > "$tmp/package.json"
printf '[project]\nversion = "1.2.3"\n'                                     > "$tmp/pyproject.toml"

for f in pubspec.yaml android/app/build.gradle VERSION package.json pyproject.toml; do
  got="$(manifest_read_version "$tmp/$f" 2>/dev/null)"
  if [[ "$got" == "1.2.3" ]]; then
    note "read $f -> 1.2.3"
  else
    error "read $f gave '$got' (expected 1.2.3)"
  fi
done

# detect finds every one of them
found="$(manifest_detect "$tmp" | wc -l)"
[[ "$found" -eq 5 ]] || error "manifest_detect found $found manifests (expected 5)"

# 5) sync writes them all, preserves the pubspec build number, recomputes versionCode
manifest_sync_version "$tmp" 2.0.0 >/dev/null 2>&1 || error "manifest_sync_version failed"
for f in pubspec.yaml android/app/build.gradle VERSION package.json pyproject.toml; do
  got="$(manifest_read_version "$tmp/$f" 2>/dev/null)"
  [[ "$got" == "2.0.0" ]] || error "after sync, $f reads '$got' (expected 2.0.0)"
done
grep -q 'version: 2.0.0+45' "$tmp/pubspec.yaml" \
  || error "pubspec build number '+45' was not preserved"
grep -q 'versionCode 20000' "$tmp/android/app/build.gradle" \
  || error "versionCode was not recomputed to 20000"
note "sync updates every manifest and preserves the build number"

# 6) a rewrite is refused rather than emptying a file
set +e
manifest_write_version "$tmp/VERSION" "not-a-version" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]] || error "writing a non-semver version returned $status (expected 2)"
[[ -s "$tmp/VERSION" ]] || error "VERSION was emptied by a rejected write"

# 7) a vendored repository's manifests are not this project's. A submodule is
# marked by a `.git` FILE in its directory, or listed in .gitmodules before it is
# initialised; syncing either one rewrote the shared library's own VERSION.
sub="$(mktemp -d)"
mkdir -p "$sub/scripts/script-helpers" "$sub/tools/lib"
printf '1.0.0\n' > "$sub/VERSION"
printf '0.28.0\n' > "$sub/scripts/script-helpers/VERSION"
printf 'gitdir: ../../.git/modules/scripts/script-helpers\n' > "$sub/scripts/script-helpers/.git"
printf '0.5.0\n' > "$sub/tools/lib/VERSION"
printf '[submodule "tools/lib"]\n\tpath = tools/lib\n\turl = https://example.invalid/lib.git\n' > "$sub/.gitmodules"
detected="$(manifest_detect "$sub")"
[[ "$detected" == "version_file	$sub/VERSION" ]] \
  || error "manifest_detect listed nested-repository manifests: $detected"
manifest_sync_version "$sub" 2.0.0 >/dev/null 2>&1 || error "manifest_sync_version failed on the submodule fixture"
[[ "$(cat "$sub/scripts/script-helpers/VERSION")" == "0.28.0" ]] || error "sync rewrote a submodule (.git file) VERSION"
[[ "$(cat "$sub/tools/lib/VERSION")" == "0.5.0" ]] || error "sync rewrote a .gitmodules-listed VERSION"
[[ "$(cat "$sub/VERSION")" == "2.0.0" ]] || error "sync did not write the project's own VERSION"
# A trailing slash on <dir> must not defeat the guard.
[[ "$(manifest_detect "$sub/" | wc -l)" -eq 1 ]] || error "manifest_detect with a trailing slash listed nested manifests"
rm -rf "$sub"
note "manifests inside a submodule or nested repository are skipped"

# 8) a pubspec version that carries its own build number replaces the existing
# suffix instead of stacking onto it; an explicit --build still wins.
printf 'name: demo\nversion: 1.2.3+45\n' > "$tmp/pubspec.yaml"
manifest_write_version "$tmp/pubspec.yaml" 1.4.0+46 >/dev/null 2>&1 || error "writing 1.4.0+46 failed"
grep -qx 'version: 1.4.0+46' "$tmp/pubspec.yaml" || error "1.4.0+46 wrote: $(grep ^version "$tmp/pubspec.yaml")"
manifest_write_version "$tmp/pubspec.yaml" 1.4.1+47 --build 50 >/dev/null 2>&1 || error "writing with --build failed"
grep -qx 'version: 1.4.1+50' "$tmp/pubspec.yaml" || error "--build did not win: $(grep ^version "$tmp/pubspec.yaml")"
manifest_write_version "$tmp/pubspec.yaml" 1.4.2 >/dev/null 2>&1
grep -qx 'version: 1.4.2+50' "$tmp/pubspec.yaml" || error "existing suffix not preserved: $(grep ^version "$tmp/pubspec.yaml")"
note "pubspec build number in the version is not doubled"

# 9) sed metacharacters in a version are written literally
manifest_write_version "$tmp/pubspec.yaml" '1.4.0-a&b|c\d' >/dev/null 2>&1 || error "writing a version with & | \\ failed"
grep -qxF 'version: 1.4.0-a&b|c\d+50' "$tmp/pubspec.yaml" || error "sed metacharacters mangled: $(grep ^version "$tmp/pubspec.yaml")"
manifest_write_version "$tmp/package.json" '1.4.0-x&y' >/dev/null 2>&1
grep -qF '"version": "1.4.0-x&y"' "$tmp/package.json" || error "package.json & mangled: $(grep version "$tmp/package.json")"
note "sed metacharacters are escaped"

# 10) --build is validated, and a trailing --build with no value is an error
set +e
manifest_write_version "$tmp/android/app/build.gradle" 2.0.0 --build 12a >/dev/null 2>&1
[[ $? -eq 2 ]] || error "a non-integer gradle --build did not return 2"
grep -q 'versionCode 20000' "$tmp/android/app/build.gradle" || error "a rejected --build changed the gradle file"
manifest_write_version "$tmp/pubspec.yaml" 2.0.0 --build 'a b' >/dev/null 2>&1
[[ $? -eq 2 ]] || error "an invalid pubspec --build did not return 2"
( manifest_write_version "$tmp/VERSION" 2.0.0 --build ) >/dev/null 2>&1
[[ $? -eq 2 ]] || error "manifest_write_version with a trailing --build did not return 2"
( manifest_sync_version "$tmp" 2.0.0 --build ) >/dev/null 2>&1
[[ $? -eq 2 ]] || error "manifest_sync_version with a trailing --build did not return 2"
set -e
note "--build is validated"

# 11) a Flutter module's gradle file has no literal: still success, but it says so
printf 'android {\n  defaultConfig {\n    versionCode = flutter.versionCode\n    versionName = flutter.versionName\n  }\n}\n' > "$tmp/flutter.gradle.kts"
mkdir -p "$tmp/flutter/app"; mv "$tmp/flutter.gradle.kts" "$tmp/flutter/app/build.gradle.kts"
set +e
msg="$(manifest_write_version "$tmp/flutter/app/build.gradle.kts" 2.0.0 2>&1)"
status=$?
set -e
[[ "$status" -eq 0 ]] || error "a gradle file without a literal returned $status (expected 0)"
[[ "$msg" == *"no versionName literal"* ]] || error "a gradle file without a literal was reported as written: $msg"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
