#!/usr/bin/env bash
# SCRIPT: docker_install_keys_test.sh
# DESCRIPTION: The apt and dnf installers in lib/docker_install.sh use Docker's
#              signing key only when it holds exactly one primary key with the
#              pinned fingerprint. curl, gpg, sudo, apt-get, dnf and rpm are
#              stubs; no network, nothing outside a temp dir is written.
# USAGE: ./tests/docker_install_keys_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/docker_install_keys_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[docker_install_keys_test] $*"; }
error() { echo "[docker_install_keys_test][ERROR] $*" >&2; failures=$((failures+1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/docker-keys-test.XXXXXX")"
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  rm -rf -- "$work"
}
trap cleanup EXIT
stubs="$work/stubs"; fake="$work/root"; mkdir -p "$stubs"
export FAKE_ROOT="$fake" STUB_LOG="$work/calls.log"

# The stub key file is the colon listing the stub gpg prints for it.
APT_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
RPM_FPR="060A61C51B558A7F742B77AAC52FEB6B621E9F35"
BAD_FPR="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
key_for() {
  local f
  for f in "$@"; do
    printf 'pub:-:4096:1:%s:1487788800:::-:\nfpr:::::::::%s:\nsub:-:4096:1:X:::::\nfpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:\n' "${f:24}" "$f"
  done
}

# curl: STUB_CURL=ok writes $STUB_KEY to -o; fail exits 22; empty writes nothing.
cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >>"$STUB_LOG"
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
case "${STUB_CURL:-ok}" in
  fail) exit 22 ;;
  empty) : >"$out" ;;
  *) cat "$STUB_KEY" >"$out" ;;
esac
EOF
# gpg: --import copies the file into the homedir; --fingerprint prints it back;
# --export prints it; --dearmor copies stdin to -o.
cat >"$stubs/gpg" <<'EOF'
#!/usr/bin/env bash
echo "gpg $*" >>"$STUB_LOG"
home=""; out=""; mode=""; last=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --homedir) home="$2"; shift ;;
    -o) out="$2"; shift ;;
    --import) mode=import ;;
    --fingerprint) mode=list ;;
    --dearmor) mode=dearmor ;;
    --export) mode=export ;;
  esac
  last="$1"; shift
done
case "$mode" in
  import) cat "$last" >>"$home/pubring" ;;
  list|export) cat "$home/pubring" 2>/dev/null ;;
  dearmor) cat >"$out" ;;
esac
EOF
# sudo: run the command with every /etc path moved under $FAKE_ROOT.
cat >"$stubs/sudo" <<'EOF'
#!/usr/bin/env bash
args=()
for a in "$@"; do
  case "$a" in
    /etc/*) a="$FAKE_ROOT$a" ;;
  esac
  args+=("$a")
done
exec "${args[@]}"
EOF
for t in apt-get rpm yum; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$STUB_LOG"\n' "$t" >"$stubs/$t"
done
cat >"$stubs/dnf" <<'EOF'
#!/usr/bin/env bash
echo "dnf $*" >>"$STUB_LOG"
if [[ "$1" == config-manager ]]; then
  mkdir -p "$FAKE_ROOT/etc/yum.repos.d"
  printf '[docker-ce-stable]\ngpgcheck=1\ngpgkey=https://download.docker.com/linux/centos/gpg\n' \
    >"$FAKE_ROOT/etc/yum.repos.d/docker-ce.repo"
fi
EOF
# install: refuse -D the way BSD install on macOS does, so Linux runs catch it.
real_install="$(command -v install)"
cat >"$stubs/install" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == -D ]] && { echo "install: illegal option -- D" >&2; exit 64; }; done
exec "$real_install" "\$@"
EOF
printf '#!/usr/bin/env bash\necho amd64\n' >"$stubs/dpkg"
printf '#!/usr/bin/env bash\necho 1000\n' >"$stubs/id"
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os docker_install

distro_id=ubuntu
_shlib_docker_distro_field() {
  case "$1" in
    ID) echo "$distro_id" ;;
    UBUNTU_CODENAME|VERSION_CODENAME) echo noble ;;
    *) echo "" ;;
  esac
}

leftover_temp() {
  local d
  for d in "${TMPDIR:-/tmp}"/shlib-docker-key.*; do
    [[ -e "$d" ]] && { echo "$d"; return 0; }
  done
  return 0
}

run_case() {
  # $1 name, $2 installer, $3 expected rc class (ok|refuse); STUB_* set by caller
  local name="$1" fn="$2" want="$3" rc=0 out
  rm -rf -- "$fake"; mkdir -p "$fake/etc/apt/sources.list.d"; : >"$STUB_LOG"
  out="$("$fn" 2>&1)" || rc=$?
  if [[ "$want" == ok ]]; then
    [[ "$rc" -eq 0 ]] || { error "$name: rc $rc, expected 0: $out"; return; }
  else
    [[ "$rc" -ne 0 ]] || { error "$name: installed, expected refusal"; return; }
    ! grep -q "install -y -qq docker-ce\|-y install docker-ce" "$STUB_LOG" \
      || error "$name: packages installed after refusal"
    for f in etc/apt/keyrings/docker.gpg etc/apt/sources.list.d/docker.list \
             etc/pki/rpm-gpg/docker-ce.gpg etc/yum.repos.d/docker-ce.repo; do
      [[ ! -e "$fake/$f" ]] || error "$name: left /$f behind"
    done
  fi
  [[ -z "$(leftover_temp)" ]] || error "$name: left temp dir $(leftover_temp)"
  note "$name: rc $rc ($want)"
}

export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"
key_for "$APT_FPR" >"$work/apt.good"
key_for "$RPM_FPR" >"$work/rpm.good"
key_for "$BAD_FPR" >"$work/bad"
key_for "$APT_FPR" "$BAD_FPR" >"$work/apt.two"
key_for "$RPM_FPR" "$BAD_FPR" >"$work/rpm.two"

# apt
distro_id=ubuntu
export STUB_CURL=ok STUB_KEY="$work/apt.good"
run_case "apt matching key" _shlib_docker_install_apt ok
cmp -s "$fake/etc/apt/keyrings/docker.gpg" "$work/apt.good" || error "apt: keyring is not the verified key"
grep -q "signed-by=/etc/apt/keyrings/docker.gpg" "$fake/etc/apt/sources.list.d/docker.list" 2>/dev/null \
  || error "apt: source list missing"
grep -q "install -y -qq docker-ce" "$STUB_LOG" || error "apt: packages not installed"
STUB_KEY="$work/bad"     run_case "apt wrong key" _shlib_docker_install_apt refuse
STUB_KEY="$work/apt.two" run_case "apt two primary keys" _shlib_docker_install_apt refuse
# The refusal lists both fingerprints on one line, with no literal $' (bash 3.2).
out="$(STUB_KEY="$work/apt.two" _shlib_docker_install_apt 2>&1)" || true
grep -qF "got 2 ($APT_FPR $BAD_FPR)" <<<"$out" || error "two-key refusal message: $out"
[[ "$out" != *"\$'"* ]] || error "refusal message has a literal \$': $out"
STUB_KEY="$work/rpm.good" run_case "apt given the rpm key" _shlib_docker_install_apt refuse
STUB_CURL=empty run_case "apt empty response" _shlib_docker_install_apt refuse
STUB_CURL=fail  run_case "apt curl failure" _shlib_docker_install_apt refuse

# dnf
distro_id=fedora
export STUB_KEY="$work/rpm.good"
run_case "dnf matching key" _shlib_docker_install_dnf ok
cmp -s "$fake/etc/pki/rpm-gpg/docker-ce.gpg" "$work/rpm.good" || error "dnf: key file is not the verified key"
grep -q "^gpgkey=file:///etc/pki/rpm-gpg/docker-ce.gpg$" "$fake/etc/yum.repos.d/docker-ce.repo" 2>/dev/null \
  || error "dnf: repo gpgkey not pointed at the local key"
grep -q "^rpm --import" "$STUB_LOG" || error "dnf: key not imported"
grep -q "dnf -y install docker-ce" "$STUB_LOG" || error "dnf: packages not installed"
STUB_KEY="$work/bad"      run_case "dnf wrong key" _shlib_docker_install_dnf refuse
STUB_KEY="$work/rpm.two"  run_case "dnf two primary keys" _shlib_docker_install_dnf refuse
STUB_KEY="$work/apt.good" run_case "dnf given the apt key" _shlib_docker_install_dnf refuse
STUB_CURL=empty run_case "dnf empty response" _shlib_docker_install_dnf refuse
STUB_CURL=fail  run_case "dnf curl failure" _shlib_docker_install_dnf refuse

# dry-run: apt output is unchanged and nothing is fetched or written.
distro_id=ubuntu; : >"$STUB_LOG"; rm -rf -- "$fake"; mkdir -p "$fake"
_shlib_docker_dry_run=true
out="$(_shlib_docker_install_apt 2>&1)" || error "apt dry-run failed"
_shlib_docker_dry_run=false
grep -qF "  [dry-run] curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" <<<"$out" \
  || error "apt dry-run key line changed: $out"
grep -qF "  [dry-run] echo 'deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable' > /etc/apt/sources.list.d/docker.list" <<<"$out" \
  || error "apt dry-run source line changed"
[[ ! -s "$STUB_LOG" ]] || error "apt dry-run ran commands: $(cat "$STUB_LOG")"
[[ -z "$(ls -A "$fake")" ]] || error "apt dry-run wrote files"
note "apt dry-run unchanged"

distro_id=fedora; : >"$STUB_LOG"; rm -rf -- "$fake"; mkdir -p "$fake"
_shlib_docker_dry_run=true
out="$(_shlib_docker_install_dnf 2>&1)" || error "dnf dry-run failed"
_shlib_docker_dry_run=false
grep -qF "  [dry-run] verify https://download.docker.com/linux/fedora/gpg is $RPM_FPR" <<<"$out" \
  || error "dnf dry-run does not show the key check: $out"
! grep -q "^curl\|^rpm" "$STUB_LOG" || error "dnf dry-run fetched or imported: $(cat "$STUB_LOG")"
[[ -z "$(ls -A "$fake")" ]] || error "dnf dry-run wrote files"
note "dnf dry-run fetches and writes nothing"

if [[ "$failures" -eq 0 ]]; then
  note "All checks passed."
  exit 0
fi
error "$failures check(s) failed."
exit 1
