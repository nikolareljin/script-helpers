#!/usr/bin/env bash
# SCRIPT: deps_node_test.sh
# DESCRIPTION: lib/deps.sh installs Node.js from a package repository whose
#              signing key is the pinned one, never by piping a remote script
#              to a shell. curl, gpg, sudo, apt-get, apt-cache, dpkg, brew and
#              node are stubs; no network, nothing outside a temp dir is written.
# USAGE: ./tests/deps_node_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/deps_node_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[deps_node_test] $*"; }
error() { echo "[deps_node_test][ERROR] $*" >&2; failures=$((failures+1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/deps-node-test.XXXXXX")"
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  rm -rf -- "$work"
}
trap cleanup EXIT

# ---------------------------------------------------------------- static
# No executed line pipes a download into a shell. Comment lines do not count.
pipe_re='(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+(-[A-Za-z]+[[:space:]]+)*)?(ba|z|da|k)?sh([[:space:]]|$)'
piped_lines() {
  grep -rnHE "$pipe_re" "$@" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true
}
# The pattern is checked against the lines it is there to catch, and one it must pass.
printf '%s\n' \
  '  curl -fsSL https://example.com/setup_20.x | sudo -E bash -' \
  'curl -fsSL https://example.com/install.sh | sh' \
  'wget -qO- https://example.com/i | sudo bash' >"$work/bad.sh"
# shellcheck disable=SC2016
printf '%s\n' \
  '# curl -fsSL https://example.com/install.sh | sh' \
  'curl -fsSL https://example.com/key | gpg --dearmor -o key.gpg' \
  'curl -fsS "$url" | tr -d "[:space:]"' >"$work/good.sh"
[[ "$(piped_lines "$work/bad.sh" | wc -l | tr -d ' ')" == 3 ]] || error "static: the pattern misses a piped install"
[[ -z "$(piped_lines "$work/good.sh")" ]] || error "static: the pattern flags a line that runs no shell"
hits="$(piped_lines lib scripts templates bin)"
[[ -z "$hits" ]] || error "a download is piped to a shell: $hits"
note "static: no download piped to a shell in lib/ scripts/ templates/ bin/"

# The NodeSource pins are written once, in lib/ci_defaults.sh.
NS_FPR="6F71F525282841EEDAF851B42F59B5F99B1BE0B4"
hits="$(grep -rlE "$NS_FPR|setup_[0-9]+\.x" lib scripts templates bin 2>/dev/null | grep -v '^lib/ci_defaults\.sh$' || true)"
[[ -z "$hits" ]] || error "NodeSource fingerprint or setup script named outside lib/ci_defaults.sh: $hits"
grep -q "CI_DEFAULT_NODESOURCE_APT_FPR:-$NS_FPR" lib/ci_defaults.sh || error "CI_DEFAULT_NODESOURCE_APT_FPR is not pinned in lib/ci_defaults.sh"
grep -q 'CI_DEFAULT_NODE_APT_MAJOR:-24}' lib/ci_defaults.sh || error "CI_DEFAULT_NODE_APT_MAJOR is not 24 in lib/ci_defaults.sh"

# ---------------------------------------------------------------- stubs
stubs="$work/stubs"; fake="$work/root"; mkdir -p "$stubs" "$work/empty"
export FAKE_ROOT="$fake" STUB_LOG="$work/calls.log" NODE_VER_FILE="$work/node_version"

BAD_FPR="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
# The stub key file is the colon listing the stub gpg prints for it.
key_for() {
  local f
  for f in "$@"; do
    printf 'pub:-:2048:1:%s:1464022864:::-:\nfpr:::::::::%s:\nsub:-:2048:1:X:::::\nfpr:::::::::BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB:\n' "${f:24}" "$f"
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
# gpg: --import copies the file into the homedir; --fingerprint and --export
# print it back; --dearmor copies stdin to -o.
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
echo "sudo $*" >>"$STUB_LOG"
# STUB_SUDO_FAIL: a path fragment; a command naming it fails.
[[ -n "${STUB_SUDO_FAIL:-}" && "$*" == *"$STUB_SUDO_FAIL"* && "$1" != rm ]] && exit 1
args=()
for a in "$@"; do
  case "$a" in
    /etc/*) a="$FAKE_ROOT$a" ;;
  esac
  args+=("$a")
done
exec "${args[@]}"
EOF
# apt-get: "install -y nodejs" makes node report $STUB_NODE_AFTER, when set.
cat >"$stubs/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >>"$STUB_LOG"
[[ "$1" == update && "${STUB_APT_UPDATE:-ok}" == fail ]] && exit 100
if [[ "$*" == "install -y nodejs" && -n "${STUB_NODE_AFTER:-}" ]]; then
  printf '%s\n' "$STUB_NODE_AFTER" >"$NODE_VER_FILE"
fi
exit 0
EOF
cat >"$stubs/apt-cache" <<'EOF'
#!/usr/bin/env bash
echo "apt-cache $*" >>"$STUB_LOG"
printf 'nodejs:\n  Installed: (none)\n  Candidate: %s\n  Version table:\n' "${STUB_CAND:-(none)}"
EOF
cat >"$stubs/brew" <<'EOF'
#!/usr/bin/env bash
echo "brew $*" >>"$STUB_LOG"
if [[ "$1" == link && -n "${STUB_NODE_AFTER:-}" ]]; then
  printf '%s\n' "$STUB_NODE_AFTER" >"$NODE_VER_FILE"
fi
exit 0
EOF
# node: prints the version in $NODE_VER_FILE; with no file it is "not installed".
cat >"$stubs/node" <<'EOF'
#!/usr/bin/env bash
[[ -s "$NODE_VER_FILE" ]] || exit 127
cat "$NODE_VER_FILE"
EOF
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\necho "${STUB_ARCH:-amd64}"\n' >"$stubs/dpkg"
# install: refuse -D the way BSD install on macOS does, so Linux runs catch it.
real_install="$(command -v install)"
cat >"$stubs/install" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [[ "\$a" == -D ]] && { echo "install: illegal option -- D" >&2; exit 64; }; done
exec "$real_install" "\$@"
EOF
chmod +x "$stubs"/*
export PATH="$stubs:$PATH"
export TMPDIR="$work/tmp"; mkdir -p "$TMPDIR"

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os deps

for fn in _deps_node_major _deps_install_node_linux _deps_install_node_mac fetch_verified_gpg_key; do
  declare -F "$fn" >/dev/null 2>&1 || error "$fn is not defined"
done
if [[ "$failures" -gt 0 ]]; then
  error "lib/deps.sh has no checked Node.js install; the remaining cases cannot run."
  exit 1
fi

# ---------------------------------------------------------------- node major
major_case() {
  # $1 version text ("" = no file), $2 expected major
  local got err
  if [[ -n "$1" ]]; then printf '%s\n' "$1" >"$NODE_VER_FILE"; else rm -f -- "$NODE_VER_FILE"; fi
  got="$(_deps_node_major 2>"$work/err")"; err="$(cat "$work/err")"
  [[ "$got" == "$2" && -z "$err" ]] || error "node major for '${1:-none}': got '$got' (stderr '$err'), expected $2"
}
major_case "" 0
major_case "v24.11.0" 24
major_case "v8.17.0" 8
major_case "v08.1.0" 8
major_case "garbage" 0
major_case "v99999.0.0" 0
# No node on PATH at all: 0, and no "integer expression expected" from bash.
got="$(PATH="$work/empty" _deps_node_major 2>"$work/err")"
[[ "$got" == 0 && ! -s "$work/err" ]] || error "node missing: got '$got' (stderr '$(cat "$work/err")'), expected 0"
rm -f -- "$NODE_VER_FILE"
out="$( { [[ "$(_deps_node_major)" -lt 24 ]] && echo below; } 2>&1 )"
[[ "$out" == below ]] || error "node missing: comparison printed '$out'"
note "node major: 0 when missing or unparsable, no bash error"

# ---------------------------------------------------------------- installs
leftover_temp() {
  local d
  for d in "$TMPDIR"/shlib-gpg-key.* "$TMPDIR"/shlib-deps-node.*; do
    [[ -e "$d" ]] && { echo "$d"; return 0; }
  done
  return 0
}
wrote_etc() { find "$fake" -type f 2>/dev/null | sed -n 1p; }

run_case() {
  # $1 name, $2 expected: ok|refuse. Env: STUB_*; NODE_BEFORE = starting version.
  local name="$1" want="$2" rc=0
  rm -rf -- "$fake"; mkdir -p "$fake/etc/apt/sources.list.d"; : >"$STUB_LOG"
  if [[ -n "${NODE_BEFORE:-}" ]]; then printf '%s\n' "$NODE_BEFORE" >"$NODE_VER_FILE"; else rm -f -- "$NODE_VER_FILE"; fi
  case_out="$(_deps_install_node_linux 24 2>&1)" || rc=$?
  if [[ "$want" == ok ]]; then
    [[ "$rc" -eq 0 ]] || error "$name: rc $rc, expected 0: $case_out"
  else
    [[ "$rc" -eq 1 ]] || error "$name: rc $rc, expected 1: $case_out"
    grep -q "Install it by hand" <<<"$case_out" || error "$name: no manual instruction: $case_out"
  fi
  # sudo logs its argv: "sudo -E bash -" would show here.
  ! grep -qE '(^| )(bash|sh)( |$)' "$STUB_LOG" || error "$name: a shell was run: $(grep -E '(^| )(bash|sh)( |$)' "$STUB_LOG")"
  ! grep -q 'setup_' "$STUB_LOG" || error "$name: a setup script was fetched"
  [[ -z "$(leftover_temp)" ]] || error "$name: left temp dir $(leftover_temp)"
  note "$name: rc $rc ($want)"
}
refused_clean() {
  [[ -z "$(wrote_etc)" ]] || error "$1: wrote $(wrote_etc)"
  ! grep -q "^apt-get" "$STUB_LOG" || error "$1: apt-get ran: $(grep '^apt-get' "$STUB_LOG")"
}

key_for "$NS_FPR" >"$work/good"
key_for "$BAD_FPR" >"$work/bad"
key_for "$NS_FPR" "$BAD_FPR" >"$work/two"
export STUB_CURL=ok STUB_KEY="$work/good" STUB_CAND="18.19.1+dfsg-6ubuntu5" STUB_NODE_AFTER="v24.11.0"

# Node 24 or newer is already there: nothing is run.
NODE_BEFORE="v24.0.0" run_case "node 24 present" ok
[[ ! -s "$STUB_LOG" ]] || error "node 24 present: commands ran: $(cat "$STUB_LOG")"
NODE_BEFORE="v26.1.0" run_case "node 26 present" ok
[[ ! -s "$STUB_LOG" ]] || error "node 26 present: commands ran: $(cat "$STUB_LOG")"

# The pinned key: keyring, source list, then apt.
run_case "matching key" ok
cmp -s "$fake/etc/apt/keyrings/nodesource.gpg" "$work/good" || error "matching key: keyring is not the verified key"
[[ "$(cat "$fake/etc/apt/sources.list.d/nodesource.list" 2>/dev/null)" == "deb [arch=amd64 signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" ]] \
  || error "matching key: source list is '$(cat "$fake/etc/apt/sources.list.d/nodesource.list" 2>/dev/null)'"
grep -q "^apt-get update$" "$STUB_LOG" || error "matching key: apt-get update not run"
grep -q "^apt-get install -y nodejs$" "$STUB_LOG" || error "matching key: nodejs not installed"
[[ "$(grep -c '^apt-get install' "$STUB_LOG")" == 1 ]] || error "matching key: the older distribution nodejs was installed first"
grep -q "^curl .*--proto =https --proto-redir =https .*https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" "$STUB_LOG" \
  || error "matching key: key not fetched over https only: $(grep '^curl' "$STUB_LOG")"
grep -q "^curl .*--retry 3 " "$STUB_LOG" || error "matching key: key fetched without retries"
NODE_BEFORE="v18.19.1" run_case "old node, matching key" ok
STUB_ARCH=arm64 run_case "arm64" ok
grep -q "arch=arm64 " "$fake/etc/apt/sources.list.d/nodesource.list" 2>/dev/null || error "arm64: source list has another arch"

# A key that is not the pinned one: refused, nothing written, apt not run.
STUB_KEY="$work/bad" run_case "wrong fingerprint" refuse; refused_clean "wrong fingerprint"
grep -qF "expected one primary key $NS_FPR, got 1 ($BAD_FPR)" <<<"$case_out" || error "wrong fingerprint: message: $case_out"
STUB_KEY="$work/two" run_case "two primary keys" refuse; refused_clean "two primary keys"
grep -qF "got 2 ($NS_FPR $BAD_FPR)" <<<"$case_out" || error "two primary keys: message: $case_out"
STUB_CURL=empty run_case "empty response" refuse; refused_clean "empty response"
STUB_CURL=fail run_case "curl failure" refuse; refused_clean "curl failure"
STUB_ARCH=riscv64 run_case "unsupported arch" refuse; refused_clean "unsupported arch"
! grep -q "^curl" "$STUB_LOG" || error "unsupported arch: the key was fetched"

# The distribution has Node 24 or newer: its package, no NodeSource.
STUB_CAND="24.2.0+dfsg-1" run_case "distribution has 24" ok
grep -q "^apt-get install -y nodejs$" "$STUB_LOG" || error "distribution has 24: nodejs not installed"
! grep -q "^curl" "$STUB_LOG" || error "distribution has 24: NodeSource key fetched"
[[ -z "$(wrote_etc)" ]] || error "distribution has 24: wrote $(wrote_etc)"
STUB_CAND="2:26.1.0-1" run_case "distribution candidate with an epoch" ok
! grep -q "^curl" "$STUB_LOG" || error "epoch candidate: NodeSource key fetched"

# apt ran but node is still old: 1, with the instruction.
STUB_NODE_AFTER="v18.19.1" run_case "apt left an old node" refuse


# /etc/apt cannot be written, or apt cannot read the new list: nothing is left.
STUB_SUDO_FAIL="sources.list.d/nodesource.list" run_case "source list not writable" refuse; refused_clean "source list not writable"
STUB_APT_UPDATE=fail run_case "apt-get update fails" refuse
[[ -z "$(wrote_etc)" ]] || error "apt-get update fails: left $(wrote_etc)"
! grep -q "^apt-get install" "$STUB_LOG" || error "apt-get update fails: nodejs installed anyway"

# No apt-get on PATH (another distribution): the instruction, nothing run.
mkdir -p "$work/noapt"
# shellcheck disable=SC2016
printf '#!%s\n[[ -s "$NODE_VER_FILE" ]] || exit 127\n' "$BASH" >"$work/noapt/node"; chmod +x "$work/noapt/node"
rm -f -- "$NODE_VER_FILE"; : >"$STUB_LOG"; rc=0
out="$(PATH="$work/noapt" _deps_install_node_linux 24 2>&1)" || rc=$?
[[ "$rc" == 1 && "$out" == *"Install it by hand"* && ! -s "$STUB_LOG" ]] || error "no apt-get: rc $rc, log '$(cat "$STUB_LOG")': $out"
note "no apt-get: rc $rc (refuse)"

# A fingerprint that is not 40 upper-case hex digits is a usage error.
rc=0; fetch_verified_gpg_key t https://example.com/k "abc" "$work/k.asc" 2>/dev/null || rc=$?
[[ "$rc" == 2 && ! -e "$work/k.asc" ]] || error "bad fingerprint argument: rc $rc"
rc=0; fetch_verified_gpg_key t https://example.com/k "$NS_FPR" "-o" 2>/dev/null || rc=$?
[[ "$rc" == 2 ]] || error "output that starts with -: rc $rc"
rc=0; _deps_install_node_linux "24; id" >/dev/null 2>&1 || rc=$?
[[ "$rc" == 2 ]] || error "bad major argument: rc $rc"

# macOS: the pinned major from Homebrew, linked.
rm -f -- "$NODE_VER_FILE"; : >"$STUB_LOG"; rc=0
_deps_install_node_mac 24 >/dev/null 2>&1 || rc=$?
[[ "$rc" == 0 ]] || error "mac: rc $rc"
grep -q "^brew install node@24$" "$STUB_LOG" || error "mac: node@24 not installed: $(cat "$STUB_LOG")"
grep -q "^brew link --overwrite --force node@24$" "$STUB_LOG" || error "mac: node@24 not linked"
printf 'v24.3.0\n' >"$NODE_VER_FILE"; : >"$STUB_LOG"
_deps_install_node_mac 24 >/dev/null 2>&1 || error "mac, node 24 present: failed"
[[ ! -s "$STUB_LOG" ]] || error "mac, node 24 present: commands ran: $(cat "$STUB_LOG")"
note "mac: brew node@24, linked; nothing when node 24 is there"

if [[ "$failures" -eq 0 ]]; then
  note "All checks passed."
  exit 0
fi
error "$failures check(s) failed."
exit 1
