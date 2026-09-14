#!/usr/bin/env bash
# SCRIPT: ports_test.sh
# DESCRIPTION: Tests for lib/ports.sh -- listener detection under non-gawk awks, port validation.
# USAGE: ./tests/ports_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ports_test.sh
# ----------------------------------------------------
#
# The parsers ran gawk-only awk. Under mawk (Debian/Ubuntu's default) or BSD
# awk (macOS) that was a syntax error on a discarded stderr, so a port in use
# was reported free. ss, netstat and fuser are stubs with canned output; PATH
# is narrowed to a directory holding only the tools the module uses, with
# `awk` pointed at each non-gawk awk this machine has.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[ports_test] $*"; }
error() { echo "[ports_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[ports_test]   ok  $*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os json env ports

# Candidate awks: anything that is not gawk. The system awk is included when it
# is not gawk itself (macOS: BSD awk).
awks=()
if command -v mawk >/dev/null 2>&1; then awks+=("mawk:$(command -v mawk)"); fi
if command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nexec %s awk "$@"\n' "$(command -v busybox)" >"$tmp/busybox-awk"; chmod +x "$tmp/busybox-awk"
  awks+=("busybox:$tmp/busybox-awk")
fi
sys_awk="$(command -v awk)"
if ! "$sys_awk" --version 2>/dev/null | grep -q "GNU Awk"; then awks+=("system:$sys_awk"); fi
if [[ ${#awks[@]} -eq 0 ]]; then
  note "no non-gawk awk here; running against the system awk only"
  awks+=("system:$sys_awk")
fi

# make_bin DIR AWK TOOL...: a PATH directory with only what the module needs.
make_bin() {
  local dir="$1" awk_bin="$2"; shift 2
  mkdir -p "$dir"
  ln -sf "$awk_bin" "$dir/awk"
  local t
  for t in bash env sort tr cat grep sed head "$@"; do
    [[ -e "$dir/$t" ]] || ln -sf "$(command -v "$t")" "$dir/$t"
  done
}

port=18765
cat >"$tmp/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'LISTEN 0      5          127.0.0.1:18765      0.0.0.0:*    users:(("python3",pid=4242,fd=3))' \
  'LISTEN 0      511          0.0.0.0:28080      0.0.0.0:*    users:(("nginx",pid=11,fd=6),("nginx",pid=12,fd=6))' \
  'LISTEN 0      4096       127.0.0.1:18766      0.0.0.0:*'
EOF
cat >"$tmp/netstat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' \
  'Active Internet connections (only servers)' \
  'Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name' \
  'tcp        0      0 127.0.0.1:18765         0.0.0.0:*               LISTEN      4242/python3' \
  'tcp        0      0 127.0.0.1:18766         0.0.0.0:*               LISTEN      -'
EOF
cat >"$tmp/fuser" <<'EOF'
#!/usr/bin/env bash
echo "$1:" >&2
printf ' 111  222\n'
EOF
chmod +x "$tmp/ss" "$tmp/netstat" "$tmp/fuser"

saved_path="$PATH"
for entry in "${awks[@]}"; do
  label="${entry%%:*}" awk_bin="${entry#*:}"
  note "awk: $label"

  bin="$tmp/bin-ss-$label"; make_bin "$bin" "$awk_bin"; ln -sf "$tmp/ss" "$bin/ss"
  PATH="$bin"
  d="$(list_port_usage_details "$port")"; rc=$?
  p="$(list_port_listener_pids "$port")"
  p2="$(list_port_listener_pids 28080 | tr '\n' ' ')"
  u="$(list_port_usage_details 18766)"
  port_in_use_by "$port" >/dev/null; in_use_rc=$?
  REQUIRED_PORT_DEFAULTS=("BACKEND_PORT:$port")
  : >"$tmp/empty.env"
  check_required_ports_available "$tmp/empty.env" >/dev/null 2>&1; crpa_rc=$?
  PATH="$saved_path"
  if [[ "$rc" == "0" && "$d" == "python3 (PID 4242)" ]]; then ok "$label/ss: details name the process"; else error "$label/ss: details rc=$rc [$d]"; fi
  if [[ "$p" == "4242" ]]; then ok "$label/ss: pid found"; else error "$label/ss: pids [$p]"; fi
  if [[ "$p2" == "11 12 " ]]; then ok "$label/ss: every pid on a shared socket"; else error "$label/ss: shared-socket pids [$p2]"; fi
  if [[ "$u" == "unknown process" ]]; then ok "$label/ss: a listener without process info is still in use"; else error "$label/ss: no-users line [$u]"; fi
  if [[ "$in_use_rc" == "0" ]]; then ok "$label/ss: port_in_use_by says in use"; else error "$label/ss: port_in_use_by reported the port free"; fi
  if [[ "$crpa_rc" == "1" && "$REQUIRED_PORT_CONFLICTS_JSON" == *'"port":18765'* ]]; then ok "$label/ss: conflict reported"; else error "$label/ss: check_required_ports_available rc=$crpa_rc json=$REQUIRED_PORT_CONFLICTS_JSON"; fi

  bin="$tmp/bin-netstat-$label"; make_bin "$bin" "$awk_bin"; ln -sf "$tmp/netstat" "$bin/netstat"
  PATH="$bin"
  d="$(list_port_usage_details "$port")"
  p="$(list_port_listener_pids "$port")"
  dash="$(list_port_listener_pids 18766)"
  PATH="$saved_path"
  if [[ "$d" == "python3 (PID 4242)" ]]; then ok "$label/netstat: details"; else error "$label/netstat: details [$d]"; fi
  if [[ "$p" == "4242" ]]; then ok "$label/netstat: pid"; else error "$label/netstat: pids [$p]"; fi
  if [[ -z "$dash" ]]; then ok "$label/netstat: '-' is not a pid"; else error "$label/netstat: '-' gave [$dash]"; fi

  bin="$tmp/bin-fuser-$label"; make_bin "$bin" "$awk_bin"; ln -sf "$tmp/fuser" "$bin/fuser"
  PATH="$bin"
  p="$(list_port_listener_pids "$port" | tr '\n' ' ')"
  PATH="$saved_path"
  if [[ "$p" == "111 222 " ]]; then ok "$label/fuser: one pid per line"; else error "$label/fuser: pids [$p]"; fi
done

note "port validation"
bin="$tmp/bin-ss-validate"; make_bin "$bin" "$sys_awk"; ln -sf "$tmp/ss" "$bin/ss"; ln -sf "$tmp/fuser" "$bin/fuser"
for bad in '' '1-65535' '0' '65536' 'abc' '80,443' ' 80'; do
  PATH="$bin"
  out="$(list_port_listener_pids "$bad")"; rc=$?
  dout="$(list_port_usage_details "$bad")"; drc=$?
  PATH="$saved_path"
  if [[ "$rc" != "0" && -z "$out" && "$drc" != "0" && -z "$dout" ]]; then ok "refused port [$bad]"; else error "port [$bad]: pids rc=$rc [$out] details rc=$drc [$dout]"; fi
done
PATH="$bin"
out="$(list_port_listener_pids 018765)"
PATH="$saved_path"
if [[ "$out" == "4242" ]]; then ok "a leading zero is the same port"; else error "leading zero port gave [$out]"; fi

if [[ $failures -eq 0 ]]; then
  note "all ports tests passed"
  exit 0
fi
note "$failures failure(s)"
exit 1
