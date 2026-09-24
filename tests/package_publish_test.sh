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
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

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

# 2b) the source name is known but its own .changes is absent: a lone .changes
#     of ANOTHER package is refused, not returned for upload. dpkg-parsechangelog
#     is stubbed so this runs without Debian tooling.
pbin="$tmp/pbin"; mkdir -p "$pbin"
cat > "$pbin/dpkg-parsechangelog" <<'SH'
#!/usr/bin/env sh
# -l <file> -S <field>: read "name (version) ..." from the first line.
file=""; field=""
while [ $# -gt 0 ]; do
  case "$1" in -l) file="$2"; shift ;; -S) field="$2"; shift ;; esac
  shift
done
case "$field" in
  Source)  sed -n '1s/ .*//p' "$file" ;;
  Version) sed -n '1s/^[^(]*(\([^)]*\)).*/\1/p' "$file" ;;
esac
SH
chmod +x "$pbin/dpkg-parsechangelog"
ws="$tmp/ws-lone-other"
mkdir -p "$ws/myapp/debian"
printf 'myapp (1.1.0-1) unstable; urgency=medium\n\n  * Release.\n\n -- Test <test@example.invalid>  Mon, 14 Sep 2026 12:00:00 +0000\n' \
  > "$ws/myapp/debian/changelog"
touch "$ws/otherproj_2.0.0_source.changes"
set +e
got="$(PATH="$pbin:$PATH" pkg_find_changes_file "$ws/myapp" 2>"$tmp/lone.err")"
status=$?
set -e
[[ "$status" -eq 1 && -z "$got" ]] \
  || error "with only another package's .changes alongside, pkg_find_changes_file returned $status and '$got' (expected 1 and nothing)"
grep -q "myapp" "$tmp/lone.err" || error "the refusal did not name the source package: $(cat "$tmp/lone.err")"
# The package's own binary .changes, alone, is still found by its source name.
touch "$ws/myapp_1.1.0-1_amd64.changes"
got="$(PATH="$pbin:$PATH" pkg_find_changes_file "$ws/myapp" 2>/dev/null)" || got=""
[[ "$got" == "$ws/myapp/../myapp_1.1.0-1_amd64.changes" ]] \
  || error "the package's own lone .changes was not found by source name (got '$got')"
# Without a readable debian/changelog the lone-file fallback still applies.
mkdir -p "$ws/nochangelog"
rm -f "$ws/myapp_1.1.0-1_amd64.changes"
got="$(PATH="$pbin:$PATH" pkg_find_changes_file "$ws/nochangelog" 2>/dev/null)" || got=""
[[ "$got" == "$ws/nochangelog/../otherproj_2.0.0_source.changes" ]] \
  || error "without debian/changelog a lone .changes was not taken (got '$got')"
note "a known source name refuses another package's lone .changes"

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
# shellcheck disable=SC2030,SC2031  # each fixture sets PATH for its own subshell only
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

# 5) TMPDIR with a space: the sign command is word-split, so the passphrase
#    file must be made somewhere its path survives that -- and still removed.
spaced="$tmp/tmp dir"; mkdir -p "$spaced"
set +e
# shellcheck disable=SC2030,SC2031  # each fixture sets PATH for its own subshell only
( PATH="$bin:$PATH" TMPDIR="$spaced" DEBUILD_LOG="$tmp/db3" PPA_GPG_PASSPHRASE='spaced phrase' \
    pkg_build_source_package "$tmp/repo" "" "" "" KEYID ) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 0 ]] || error "with a space in TMPDIR pkg_build_source_package returned $status"
[[ "$(cat "$tmp/db3.pass" 2>/dev/null)" == "spaced phrase" ]] \
  || error "with a space in TMPDIR gpg would not find the passphrase file: $(cat "$tmp/db3.args" 2>/dev/null)"
pass_path="$(sed -n 's/.*--passphrase-file \([^ ]*\).*/\1/p' "$tmp/db3.args" 2>/dev/null)"
[[ -n "$pass_path" && ! -e "$pass_path" ]] || error "the /tmp passphrase file was left behind: '$pass_path'"
[[ -z "$(ls -A "$spaced")" ]] || error "a passphrase file was left in the spaced TMPDIR: $(ls -A "$spaced")"
note "a TMPDIR with a space does not break the sign command"

# 6) INT/TERM during the build: the file is removed, the caller's own trap is
#    put back, and the signal is not swallowed. The stub signals the shell that
#    called it, as a Ctrl-C or a CI cancel would.
mkdir -p "$tmp/sigbin" "$tmp/sigtmp"
cat > "$tmp/sigbin/debuild" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$*" > "$DEBUILD_LOG.args"
kill -s "$DEBUILD_SIG" "$PPID"
exit 1
SH
cp "$bin/gpg" "$tmp/sigbin/gpg"
chmod +x "$tmp/sigbin/debuild"
# In a subshell: the conventional status comes back and the prior trap is intact.
set +e
# shellcheck disable=SC2030,SC2031  # each fixture sets PATH for its own subshell only
out="$(
  PATH="$tmp/sigbin:$PATH" TMPDIR="$tmp/sigtmp" DEBUILD_LOG="$tmp/db4" DEBUILD_SIG=TERM PPA_GPG_PASSPHRASE='x'
  export PATH TMPDIR DEBUILD_LOG DEBUILD_SIG PPA_GPG_PASSPHRASE
  trap 'echo caller-int' INT
  pkg_build_source_package "$tmp/repo" "" "" "" KEYID >/dev/null 2>&1
  echo "rc=$?"
  trap -p INT
)"
set -e
[[ "$out" == *"rc=143"* ]] || error "TERM during the build did not return 143 from a subshell: $out"
[[ "$out" == *"caller-int"* ]] || error "the caller's INT trap was not restored: $out"
[[ -z "$(ls -A "$tmp/sigtmp")" ]] || error "TERM during the build left the passphrase file behind: $(ls -A "$tmp/sigtmp")"
# In a top-level shell: the signal is re-delivered, so the shell dies of it.
rm -rf "$tmp/sigtmp"; mkdir -p "$tmp/sigtmp"
set +e
# shellcheck disable=SC2030,SC2031  # each fixture sets PATH for its own subshell only
PATH="$tmp/sigbin:$PATH" TMPDIR="$tmp/sigtmp" DEBUILD_LOG="$tmp/db5" DEBUILD_SIG=INT PPA_GPG_PASSPHRASE='x' \
  bash -c 'source "$1/helpers.sh"; shlib_import logging package_publish
           pkg_build_source_package "$2" "" "" "" KEYID; echo "survived rc=$?"' _ "$root_dir" "$tmp/repo" \
  > "$tmp/sig5.out" 2>/dev/null
status=$?
set -e
[[ -z "$(ls -A "$tmp/sigtmp")" ]] || error "INT during the build left the passphrase file behind: $(ls -A "$tmp/sigtmp")"
grep -q survived "$tmp/sig5.out" && error "INT during the build was swallowed: $(cat "$tmp/sig5.out")"
[[ "$status" -eq 130 ]] || error "INT during the build: the shell exited $status (expected 130)"
note "INT/TERM during the build removes the passphrase file and keeps the caller's traps"

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"
else
  note "$failures FAILURE(S)"
  exit 1
fi
