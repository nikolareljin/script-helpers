#!/usr/bin/env bash
# SCRIPT: docker_install_test.sh
# DESCRIPTION: Smoke tests for lib/docker_install.sh. Never installs anything —
#              every test is detection-only or --dry-run.
# USAGE: ./tests/docker_install_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/docker_install_test.sh
# ----------------------------------------------------
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[docker_install_test] $*"; }
error() { echo "[docker_install_test][ERROR] $*" >&2; failures=$((failures+1)); }

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging os docker_install

# 1) every public function is defined after import
for fn in docker_cli_installed docker_daemon_running docker_compose_v2_available \
          docker_ready docker_install_status docker_report_state \
          wait_for_docker_daemon docker_start_daemon docker_add_user_to_group \
          install_docker ensure_docker; do
  if declare -f "$fn" >/dev/null 2>&1; then
    note "$fn is defined"
  else
    error "$fn is NOT defined"
  fi
done

# 2) docker_install_status prints one of the four known states
status="$(docker_install_status)"
case "$status" in
  ready|no-cli|no-daemon|no-compose) note "docker_install_status -> $status" ;;
  *) error "docker_install_status returned an unknown value: '$status'" ;;
esac

# 3) the detection predicates never error out, whatever the host looks like
for fn in docker_cli_installed docker_daemon_running docker_compose_v2_available docker_ready; do
  if "$fn"; then note "$fn -> true"; else note "$fn -> false"; fi
done

# 4) docker_ready and docker_install_status agree
if docker_ready; then
  [[ "$status" == "ready" ]] || error "docker_ready true but status is '$status'"
else
  [[ "$status" != "ready" ]] || error "docker_ready false but status is 'ready'"
fi

# 5) an unknown option returns exactly 2 and installs nothing
rc=0; install_docker --definitely-not-an-option >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  note "install_docker rejects unknown options with exit 2"
else
  error "install_docker with a bad option returned $rc, expected 2"
fi

# 6) ensure_docker is a no-op when Docker is already usable.
#    When it is not usable we cannot call it here — it would try to install.
if docker_ready; then
  rc=0; ensure_docker >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    note "ensure_docker is a no-op on a ready host"
  else
    error "ensure_docker returned $rc on a ready host, expected 0"
  fi
else
  note "SKIP ensure_docker no-op check — Docker is not usable on this host"
fi

# 7) timeout values are validated before arithmetic or installation begins
for args in "--timeout" "--timeout nope" "--timeout 0"; do
  rc=0
  # Deliberately split the fixed test cases into arguments.
  # shellcheck disable=SC2086
  install_docker $args >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    note "install_docker rejects '$args' with exit 2"
  else
    error "install_docker '$args' returned $rc, expected 2"
  fi
done

rc=0; wait_for_docker_daemon nope >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  note "wait_for_docker_daemon rejects a non-numeric timeout with exit 2"
else
  error "wait_for_docker_daemon with a bad timeout returned $rc, expected 2"
fi

# 8) dry-run changes nothing. On a ready host install_docker short-circuits
#    before the dry-run path, so only assert it stays silent about mutating.
rc=0; out="$(install_docker --dry-run --yes 2>&1)" || rc=$?
if [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 2 ]]; then
  note "install_docker --dry-run --yes exited $rc without installing"
else
  error "install_docker --dry-run --yes exited $rc"
fi
if grep -q "^  \[dry-run\] " <<<"$out"; then
  note "dry-run emitted planned commands rather than running them"
elif docker_ready; then
  note "no dry-run output — host already has Docker, so it short-circuited (expected)"
else
  error "dry-run produced no planned commands on a host without Docker"
fi

# 9) the macOS and Windows installer downloads leave no temp dir behind:
#    after a dry run, after a failed download, and (macOS) after a failed attach.
tdir="$(mktemp -d)"
for case in mac-dry mac-fail mac-attach win-fail; do
  rm -rf "${tdir:?}"/*
  rc=0
  (
    export TMPDIR="$tdir"
    # macOS mktemp -d without a template ignores TMPDIR.
    mktemp() { builtin command mktemp -d "$TMPDIR/tmp.XXXXXX"; }
    uname() { echo arm64; }
    command() { [[ "$1 $2" == "-v brew" || "$1 $2" == "-v choco" ]] && return 1; builtin command "$@"; }
    log_info() { :; }; log_error() { :; }; log_warn() { :; }
    _shlib_docker_do_start=false
    case "$case" in
      mac-dry)    _shlib_docker_dry_run=true; _shlib_docker_install_mac ;;
      mac-fail)   _shlib_docker_dry_run=false; fetch_to_file() { : >"$3"; return 1; }; _shlib_docker_install_mac ;;
      mac-attach) _shlib_docker_dry_run=false; fetch_to_file() { : >"$3"; }; hdiutil() { return 1; }; _shlib_docker_install_mac ;;
      win-fail)   _shlib_docker_dry_run=false; fetch_to_file() { : >"$3"; return 1; }; _shlib_docker_install_windows_fallback ;;
    esac
  ) >/dev/null 2>&1 || rc=$?
  left="$(find "$tdir" -mindepth 1 | sed -n '1,3p')"
  [[ -z "$left" ]] && note "$case: no temp dir left (rc $rc)" || error "$case: left behind: $left"
done
rm -rf "$tdir"

# 10) the dmg mount point: detached before it is removed, on a failed install
#     and on TERM; never removed while still mounted. hdiutil is a stub that
#     logs each call and whether the mount dir still existed at that moment.
tdir="$(mktemp -d)"
for case in mac-install-fail mac-term mac-stuck; do
  rm -rf "${tdir:?}"/*; mkdir "$tdir/t"; : >"$tdir/log"
  rc=0
  (
    export TMPDIR="$tdir/t"
    mktemp() { builtin command mktemp -d "$TMPDIR/tmp.XXXXXX"; }
    uname() { echo arm64; }
    command() { [[ "$1 $2" == "-v brew" ]] && return 1; builtin command "$@"; }
    log_info() { :; }; log_error() { :; }; log_warn() { :; }
    _shlib_docker_do_start=false; _shlib_docker_dry_run=false
    fetch_to_file() { : >"$3"; }
    hdiutil() {
      local m="${4:-}"; [[ "$1" == detach ]] && m="$2"
      if [[ -d "$m" ]]; then echo "$1 ${3:-} present" >>"$tdir/log"; else echo "$1 ${3:-} gone" >>"$tdir/log"; fi
      [[ "$1" == detach && "$case" == mac-stuck ]] && return 1
      return 0
    }
    _shlib_docker_is_mounted() { [[ "$case" == mac-stuck ]]; }
    # A child bash signals this subshell through its $PPID: bash 3.2 has no
    # BASHPID.
    case "$case" in
      mac-term) _shlib_docker_sudo() { "$BASH" -c 'kill -TERM $PPID'; sleep 1; return 1; } ;;
      *)        _shlib_docker_sudo() { return 1; } ;;
    esac
    _shlib_docker_install_mac
  ) >/dev/null 2>&1 || rc=$?
  log="$(tr '\n' ';' <"$tdir/log")"
  left="$(find "$tdir/t" -mindepth 1 -maxdepth 1)"
  case "$case" in
    mac-stuck)
      if [[ "$log" == "attach -mountpoint present;detach -quiet present;detach -force present;" && -n "$left" && -z "$(find "$tdir/t" -name Docker.dmg)" ]]; then
        note "$case: mount dir kept while detach fails (log: $log)"
      else
        error "$case: expected the mount dir kept and only it; log: $log; left: $left"
      fi ;;
    *)
      if [[ "$log" == "attach -mountpoint present;detach -quiet present;" && -z "$left" ]]; then
        note "$case: detached, then removed (rc $rc)"
      else
        error "$case: expected detach before removal and nothing left; log: $log; left: $left; rc $rc"
      fi
      if [[ "$case" == mac-term && "$rc" -ne 143 ]]; then error "$case: exit $rc, expected 143"; fi ;;
  esac
done
rm -rf "$tdir"

if [[ "$failures" -eq 0 ]]; then
  note "All checks passed."
  exit 0
fi
error "$failures check(s) failed."
exit 1
