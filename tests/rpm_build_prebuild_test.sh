#!/usr/bin/env bash
# SCRIPT: rpm_build_prebuild_test.sh
# DESCRIPTION: build_rpm_artifacts.sh with a prebuild tars the working tree. The
#              tarball used to be written inside that tree, so tar read its own
#              growing output ("file changed as we read it") and shipped the
#              build directory in the source. Checks the source tarball holds
#              the prebuild output and none of: the build directory, the
#              artifact directory, nested .git entries; and that a rebuild works.
# USAGE: bash tests/rpm_build_prebuild_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/rpm_build_prebuild_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
note()  { echo "[rpm_build_prebuild_test] $*"; }
error() { echo "[rpm_build_prebuild_test][ERROR] $*" >&2; failures=$((failures+1)); }

# The script's tar path uses GNU tar's --transform; BSD tar (macOS) lacks it.
if ! grep -q 'GNU tar' <<<"$(tar --version 2>/dev/null)"; then
  note "skipped: needs GNU tar (the script uses --transform)"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# rpmbuild stand-in: drops one .rpm under _topdir/RPMS, as a real build would.
mkdir -p "$tmp/bin" "$tmp/repo"
cat > "$tmp/bin/rpmbuild" <<'SH'
#!/usr/bin/env bash
top=""
while [ $# -gt 0 ]; do
  case "$1" in --define) case "$2" in _topdir\ *) top="${2#_topdir }";; esac; shift 2;; *) shift;; esac
done
mkdir -p "$top/RPMS/noarch" && touch "$top/RPMS/noarch/demo-1.2.3-1.noarch.rpm"
SH
chmod +x "$tmp/bin/rpmbuild"

repo="$tmp/repo"
printf 'Name: demo\nVersion: 1.2.3\n' > "$repo/demo.spec"
echo src > "$repo/main.txt"
mkdir -p "$repo/sub/.git" && touch "$repo/sub/.git/config"
git -C "$repo" init -q
git -C "$repo" add demo.spec main.txt
git -C "$repo" -c user.name=t -c user.email=t@example.com commit -qm init

for run in 1 2; do
  if ! (cd "$repo" && PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/build_rpm_artifacts.sh" \
        --repo . --spec demo.spec --prebuild 'echo built > generated.txt' --artifact-dir dist) \
        >"$tmp/run$run.log" 2>&1; then
    error "run $run failed:"; cat "$tmp/run$run.log" >&2
  fi
done

src="$repo/packaging/rpm/build/SOURCES/demo-1.2.3.tar.gz"
if [[ ! -f "$src" ]]; then
  error "no source tarball at $src"
else
  list="$(tar -tzf "$src")"
  grep -q '/generated.txt$' <<<"$list" || error "prebuild output generated.txt is missing from the source"
  grep -q '/main.txt$' <<<"$list" || error "main.txt is missing from the source"
  if grep -q 'packaging/rpm/build' <<<"$list"; then error "source contains the build directory"; fi
  if grep -q '/dist/' <<<"$list"; then error "source contains the artifact directory"; fi
  if grep -q '/\.git/' <<<"$list"; then error "source contains .git entries"; fi
fi
[[ -f "$repo/dist/demo-1.2.3-1.noarch.rpm" ]] || error "no .rpm copied to dist/"

if [[ $failures -gt 0 ]]; then
  error "$failures check(s) failed"
  exit 1
fi
note "ok: prebuild source tarball is clean and a rebuild works"
