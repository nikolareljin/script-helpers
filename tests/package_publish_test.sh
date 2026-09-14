#!/usr/bin/env bash
# SCRIPT: package_publish_test.sh
# DESCRIPTION: Tests for lib/package_publish.sh (changes-file lookup, source-package signing).
# USAGE: ./tests/package_publish_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/package_publish_test.sh
# ----------------------------------------------------
#
# debuild and gpg are replaced by stubs on PATH, so nothing is built or signed
# and no Debian tooling is required.
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[package_publish_test] $*"; }
error() { echo "[package_publish_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging package_publish

for fn in pkg_require_cmds pkg_run_prebuild pkg_set_series pkg_build_deb_artifacts \
          pkg_build_source_package pkg_find_changes_file pkg_upload_ppa; do
  if declare -f "$fn" >/dev/null 2>&1; then note "$fn is defined"; else error "$fn is NOT defined"; fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1) a lone .changes file is still found, as before
mkdir -p "$tmp/one/app"
touch "$tmp/one/app_1.0.0_source.changes"
got="$(pkg_find_changes_file "$tmp/one/app" 2>/dev/null)" || got=""
[[ "$got" == "$tmp/one/app/../app_1.0.0_source.changes" ]] || error "a lone .changes file was not found (got '$got')"

# 2) in a shared parent, the package's own file is chosen over another project's.
#    `otherproj` sorts after `myapp` here and before it in the next case, so
#    neither directory order can make the check pass by accident.
if command -v dpkg-parsechangelog >/dev/null 2>&1; then
  for other in aaa-otherproj zzz-otherproj; do
    ws="$tmp/ws-$other"
    mkdir -p "$ws/myapp/debian"
    printf 'myapp (1:1.1.0-1) unstable; urgency=medium\n\n  * Release.\n\n -- Test <test@example.invalid>  Mon, 14 Sep 2026 12:00:00 +0000\n' \
      > "$ws/myapp/debian/changelog"
    touch "$ws/${other}_2.0.0_source.changes" "$ws/myapp_1.1.0-1_source.changes"
    got="$(pkg_find_changes_file "$ws/myapp" 2>/dev/null)" || got=""
    [[ "$got" == "$ws/myapp/../myapp_1.1.0-1_source.changes" ]] \
      || error "with $other alongside, pkg_find_changes_file gave '$got'"
  done
  note "the package's own .changes file is chosen, epoch stripped"
else
  note "dpkg-parsechangelog not installed — skipping the named-lookup assertion (not a failure)"
fi

# 3) several .changes files and none named for the package: an error, not a guess
mkdir -p "$tmp/many/app"
touch "$tmp/many/a_1_source.changes" "$tmp/many/b_2_source.changes"
set +e
pkg_find_changes_file "$tmp/many/app" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "ambiguous .changes files returned $status (expected 1)"
set +e
pkg_find_changes_file "$tmp/one/nothing-here/x" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 1 ]] || error "no .changes file returned $status (expected 1)"
note "an ambiguous or missing .changes file is an error"

# 4) the GPG passphrase never reaches a command line, survives spaces, and the
#    file holding it is gone afterwards -- also when the build fails under set -e.
bin="$tmp/bin"; mkdir -p "$bin" "$tmp/repo" "$tmp/tmpdir"
cat > "$bin/debuild" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$DEBUILD_LOG.args"
for a in "$@"; do
  case "$a" in
    -p*) set -- $a; while [ $# -gt 0 ]; do
           if [ "$1" = "--passphrase-file" ]; then cat "$2" > "$DEBUILD_LOG.pass"; ls -l "$2" | cut -c1-10 > "$DEBUILD_LOG.mode"; fi
           shift
         done ;;
  esac
done
exit "${DEBUILD_EXIT:-0}"
SH
printf '#!/usr/bin/env sh\nexit 0\n' > "$bin/gpg"
chmod +x "$bin/debuild" "$bin/gpg"

set +e
( PATH="$bin:$PATH" TMPDIR="$tmp/tmpdir" DEBUILD_LOG="$tmp/db" PPA_GPG_PASSPHRASE='GPG secret phrase' \
    pkg_build_source_package "$tmp/repo" "" "" "" KEYID ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "pkg_build_source_package returned $status"
if grep -q 'secret' "$tmp/db.args" 2>/dev/null; then error "the passphrase was on debuild's command line: $(cat "$tmp/db.args")"; fi
[[ "$(cat "$tmp/db.pass" 2>/dev/null)" == "GPG secret phrase" ]] \
  || error "gpg would not read the passphrase from its file: '$(cat "$tmp/db.pass" 2>/dev/null)'"
[[ "$(cat "$tmp/db.mode" 2>/dev/null)" == "-rw-------" ]] \
  || error "the passphrase file was not 0600: '$(cat "$tmp/db.mode" 2>/dev/null)'"
[[ -z "$(ls -A "$tmp/tmpdir")" ]] || error "the passphrase file was left behind: $(ls -A "$tmp/tmpdir")"

set +e
( set -e
  PATH="$bin:$PATH" TMPDIR="$tmp/tmpdir" DEBUILD_LOG="$tmp/db2" DEBUILD_EXIT=9 PPA_GPG_PASSPHRASE='x'
  export PATH TMPDIR DEBUILD_LOG DEBUILD_EXIT PPA_GPG_PASSPHRASE
  pkg_build_source_package "$tmp/repo" "" "" "" KEYID
) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 9 ]] || error "a failing debuild under set -e gave $status (expected 9)"
[[ -z "$(ls -A "$tmp/tmpdir")" ]] || error "a failing build left the passphrase file behind: $(ls -A "$tmp/tmpdir")"
note "the GPG passphrase is passed in a private file that is removed afterwards"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
