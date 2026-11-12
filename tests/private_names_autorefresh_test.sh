#!/usr/bin/env bash
# SCRIPT: private_names_autorefresh_test.sh
# DESCRIPTION: Tests the pre-push hook's background refresh of the private-name list.
# USAGE: bash tests/private_names_autorefresh_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/private_names_autorefresh_test.sh
# ----------------------------------------------------
#
# A stale list misses every repository created since it was built, and nothing
# says so. The refresh must never block or fail a push, and never run twice at
# once.
set -uo pipefail
unset CI GITHUB_ACTIONS
# The hooks would download a missing gitleaks or foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Run from inside the global hooks, their script directory would be used.
unset SCRIPT_HELPERS_SECURITY_DIR
failures=0
note()  { echo "[private_names_autorefresh_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[private_names_autorefresh_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

export XDG_STATE_HOME="$tmp/state"
repo="$tmp/repo"
mkdir -p "$repo/scripts"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init

probe="$tmp/refresh-ran"
# Slow on purpose: a push that waits for it would show up as elapsed >= 3s.
cat > "$repo/scripts/refresh_private_names.sh" <<STUB
#!/usr/bin/env bash
sleep 3
printf '%s\n' "\$@" > "$probe.args"
echo ran > "$probe"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/check_private_names.sh"
# The push also needs the sensitive-data check; a missing one now refuses it.
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/check_sensitive.sh"

list="$tmp/list.tsv"

hook_run() {
  (cd "$repo" && PRIVATE_NAMES_FILE="$list" "$@" bash -c '
    source "$1/scripts/security_hooks.sh"
    sec_maybe_refresh_private_names
  ' _ "$ROOT_DIR")
}

make_list() { printf 'private\tns\tx\t-\t\n' > "$list"; }
stale()     { make_list; touch -d '30 days ago' "$list" 2>/dev/null || touch -t 202001010000 "$list"; }
fresh()     { make_list; touch "$list"; }
clean()     { rm -f "$probe" "$probe.args"; rm -rf "$list.refresh.lock"; }

if ! command -v gh >/dev/null 2>&1; then
  note "SKIP: gh is not installed, the hook returns before deciding anything"
  note "ALL PASSED"
  exit 0
fi

# 1. Stale: it refreshes, and the push does not wait for it.
clean; stale
start="$(date +%s)"
out="$(hook_run)"; rc=$?
elapsed=$(( $(date +%s) - start ))
if [[ $rc -ne 0 ]]; then
  error "a stale list failed the push (exit $rc)"
elif ! grep -q 'refreshing in the background' <<<"$out"; then
  error "a stale list did not trigger a refresh"
elif [[ $elapsed -ge 3 ]]; then
  error "the push waited ${elapsed}s for the refresh"
else
  ok "a stale list refreshes without blocking the push"
fi
sleep 4
[[ -f "$probe" ]] && ok "the refresh really ran" || error "the refresh was announced but never ran"
# A custom PRIVATE_NAMES_FILE is the list that is refreshed, not the default.
if [[ "$(cat "$probe.args" 2>/dev/null)" == "$(printf -- '--out\n%s' "$list")" ]]; then
  ok "the refresh writes the list it checked (PRIVATE_NAMES_FILE)"
else
  error "the refresh was not pointed at PRIVATE_NAMES_FILE: $(tr '\n' ' ' < "$probe.args" 2>/dev/null)"
fi

# 2. Fresh: nothing happens. Without this the refresh is simply always on.
clean; fresh
out="$(hook_run)"
sleep 4
if grep -q 'refreshing' <<<"$out" || [[ -f "$probe" ]]; then
  error "a fresh list was refreshed anyway"
else
  ok "a fresh list is left alone"
fi

# 3. An empty list counts as stale: it cannot be told from a complete one.
clean; : > "$list"; touch "$list"
out="$(hook_run)"
grep -q 'refreshing' <<<"$out" && ok "an empty list counts as stale" \
                               || error "an empty list was treated as fresh"
sleep 4

# 4. One at a time.
clean; stale
out1="$(hook_run)"; out2="$(hook_run)"
if grep -q 'refreshing' <<<"$out1" && ! grep -q 'refreshing' <<<"$out2"; then
  ok "a second push does not start a second refresh"
else
  error "the lock did not hold: two refreshes were started"
fi
sleep 4
[[ -d "$list.refresh.lock" ]] && error "the lock was not released" \
                              || ok "the lock is released when the refresh finishes"

# 5. Opt out.
clean; stale
out="$(hook_run env PRIVATE_NAMES_AUTO_REFRESH=false)"
sleep 4
if [[ -f "$probe" ]] || grep -q 'refreshing' <<<"$out"; then
  error "PRIVATE_NAMES_AUTO_REFRESH=false still refreshed"
else
  ok "PRIVATE_NAMES_AUTO_REFRESH=false is respected"
fi

# 6. Without PRIVATE_NAMES_FILE, the default list is the one refreshed. HOME
# and XDG_CONFIG_HOME point into $tmp, and the stub writes nothing there.
clean
default_list="$tmp/xdg/script-helpers/private-names.tsv"
mkdir -p "$tmp/xdg/script-helpers"
printf 'private\tns\tx\t-\t\n' > "$default_list"
touch -d '30 days ago' "$default_list" 2>/dev/null || touch -t 202001010000 "$default_list"
(cd "$repo" && env -u PRIVATE_NAMES_FILE HOME="$tmp" XDG_CONFIG_HOME="$tmp/xdg" bash -c '
  source "$1/scripts/security_hooks.sh"
  sec_maybe_refresh_private_names
' _ "$ROOT_DIR") >/dev/null
sleep 4
if [[ "$(cat "$probe.args" 2>/dev/null)" == "$(printf -- '--out\n%s' "$default_list")" ]]; then
  ok "without PRIVATE_NAMES_FILE, the default list is refreshed"
else
  error "the default list was not the one refreshed: $(tr '\n' ' ' < "$probe.args" 2>/dev/null)"
fi
rm -rf "$default_list.refresh.lock"

# 7. A relative PRIVATE_NAMES_FILE is not refreshed: the hook runs in the
# working tree, and the list would be written into the repository.
clean
mkdir -p "$repo/rel"
printf 'private\tns\tx\t-\t\n' > "$repo/rel/list.tsv"
touch -d '30 days ago' "$repo/rel/list.tsv" 2>/dev/null || touch -t 202001010000 "$repo/rel/list.tsv"
out="$(cd "$repo" && HOME="$tmp" XDG_CONFIG_HOME="$tmp/xdg" PRIVATE_NAMES_FILE=rel/list.tsv bash -c '
  source "$1/scripts/security_hooks.sh"
  sec_maybe_refresh_private_names
' _ "$ROOT_DIR")"
sleep 4
if [[ -f "$probe" ]] || [[ -e "$repo/rel/list.tsv.refresh.lock" ]] || [[ -e "$repo/rel/list.tsv.refresh.log" ]]; then
  error "a relative PRIVATE_NAMES_FILE was refreshed inside the working tree"
elif ! grep -q 'is not absolute' <<<"$out"; then
  error "a relative PRIVATE_NAMES_FILE was skipped without saying so"
else
  ok "a relative PRIVATE_NAMES_FILE is not refreshed, and the hook says why"
fi

# 8. An absolute list with a relative XDG_CONFIG_HOME: the per-owner caches,
# which hold the same names, would be written into the working tree.
clean; stale
out="$(cd "$repo" && HOME="$tmp" XDG_CONFIG_HOME=relxdg PRIVATE_NAMES_FILE="$list" bash -c '
  source "$1/scripts/security_hooks.sh"
  sec_maybe_refresh_private_names
' _ "$ROOT_DIR")"
sleep 4
if [[ -f "$probe" ]] || [[ -e "$repo/relxdg" ]]; then
  error "a relative cache directory was refreshed inside the working tree"
elif ! grep -q 'is not absolute' <<<"$out"; then
  error "a relative cache directory was skipped without saying so"
else
  ok "a relative XDG_CONFIG_HOME (the cache directory) is not refreshed either"
fi

if [[ $failures -gt 0 ]]; then
  echo "[private_names_autorefresh_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
