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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/git-hooks/pre-push"
failures=0
note()  { echo "[private_names_autorefresh_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[private_names_autorefresh_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init

probe="$tmp/refresh-ran"
# Slow on purpose: a push that waits for it would show up as elapsed >= 3s.
cat > "$repo/scripts/refresh_private_names.sh" <<STUB
#!/usr/bin/env bash
sleep 3
echo ran > "$probe"
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/scripts/check_private_names.sh"

list="$tmp/list.tsv"
zeroes="$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 \
                          21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"

hook_run() {
  local sha; sha="$(git -C "$repo" rev-parse HEAD)"
  ( cd "$repo" && PRIVATE_NAMES_FILE="$list" "$@" \
      bash -c 'printf "refs/heads/main %s refs/heads/main %s\n" "$1" "$2" | bash "$3" origin git@e.invalid:x' \
        _ "$sha" "$zeroes" "$HOOK" 2>&1 )
}

make_list() { printf 'private\tns\tx\t-\t\n' > "$list"; }
stale()     { make_list; touch -d '30 days ago' "$list" 2>/dev/null || touch -t 202001010000 "$list"; }
fresh()     { make_list; touch "$list"; }
clean()     { rm -f "$probe"; rm -rf "$list.refresh.lock"; }

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

if [[ $failures -gt 0 ]]; then
  echo "[private_names_autorefresh_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
