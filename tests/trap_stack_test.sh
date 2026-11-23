#!/usr/bin/env bash
# SCRIPT: trap_stack_test.sh
# DESCRIPTION: Tests lib/trap_stack.sh: temp directories registered from nested functions are removed on INT, TERM, HUP and EXIT, the caller's traps are kept, and the library's temp-dir creators leave nothing behind when interrupted.
# USAGE: bash tests/trap_stack_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/trap_stack_test.sh
# ----------------------------------------------------
#
# Each signal case starts a real script in the background, waits until it has
# made its directories, sends the signal to that one process and checks what
# is left and the exit code. A stub curl holds the download open until the
# test lets go. Nothing goes to the network.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[trap_stack_test] $*"; }
error() { echo "[trap_stack_test][ERROR] $*" >&2; failures=$((failures+1)); }

work="$(mktemp -d "${TMPDIR:-/tmp}/trap-stack-test.XXXXXX")"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf -- "$work"; fi' EXIT

LIB="$ROOT_DIR/lib/trap_stack.sh"
if [[ ! -f "$LIB" ]]; then
  error "lib/trap_stack.sh is missing; a second cleanup registration replaces the first."
fi

# sig_code <signal>: the exit code a shell gives when it exits on that signal.
sig_code() { case "$1" in HUP) echo 129 ;; INT) echo 130 ;; TERM) echo 143 ;; esac; }

# start <script> [args...]: run it in the background, pid in $bg_pid.
# set -m: without job control bash starts a background command with INT
# ignored, and a shell cannot trap a signal that was ignored when it started.
start() {
  set -m
  "$@" >"$work/out" 2>"$work/err" &
  bg_pid=$!
  set +m
}

# wait_for <file>: until it exists, 10 seconds at most.
wait_for() {
  local i=0
  while [[ ! -e "$1" && "$i" -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
  [[ -e "$1" ]]
}

# finish <signal>: send it to $bg_pid, let the stubs go, exit code in $rc.
finish() {
  kill "-$1" "$bg_pid" 2>/dev/null
  : >"$work/release"
  rc=0; wait "$bg_pid" 2>/dev/null || rc=$?
}

# hold: what a script runs while it waits for the signal. Short sleeps: bash
# runs a trap only after the command in the foreground returns.
cat >"$work/hold.sh" <<'EOF'
hold() {
  local i=0
  : >"$WORK/ready"
  while [[ ! -e "$WORK/release" && "$i" -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
  i=0
  while [[ "$i" -lt 20 ]]; do sleep 0.1; i=$((i + 1)); done
}
EOF
export WORK="$work" ROOT_DIR

reset() { rm -rf -- "$work/ready" "$work/release" "$work/d1" "$work/d2" "$work/f3" "$work/trap.out" "$work/exit.out"; }

# ---------------------------------------------------------------- nested, signalled
# An outer function registers a directory, an inner one registers a second and
# a file. A signal removes all three; with no trap of the caller's the script
# exits 129, 130 or 143.
cat >"$work/nested.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/lib/trap_stack.sh"
source "$WORK/hold.sh"
inner() {
  mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"
  : >"$WORK/f3"; trap_stack_push "$WORK/f3"
  hold
  trap_stack_pop
  trap_stack_pop
}
outer() {
  mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"
  : >"$WORK/d1/file"
  inner
  trap_stack_pop
}
outer
EOF
left() { local p out=""; for p in d1 d2 f3; do [[ -e "$work/$p" ]] && out="$out $p"; done; echo "${out:- none}"; }
for sig in INT TERM HUP; do
  reset
  start bash "$work/nested.sh"
  wait_for "$work/ready" || error "$sig nested: the script never got ready: $(cat "$work/err" 2>/dev/null)"
  finish "$sig"
  if [[ "$rc" -eq "$(sig_code "$sig")" && "$(left)" == " none" ]]; then
    note "$sig, nested twice: both directories and the file removed, exit $rc"
  else
    error "$sig nested: rc=$rc (want $(sig_code "$sig")), left:$(left)"
  fi
done

# Not interrupted: every pop removes its own path, and the script exits 0.
reset; : >"$work/release"
rc=0; bash "$work/nested.sh" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 0 && "$(left)" == " none" ]] && note "no signal: pops removed everything, exit 0" || error "no signal: rc=$rc left:$(left)"

# ---------------------------------------------------------------- the caller's traps
# The caller's INT trap runs after the removal and its exit code wins.
cat >"$work/caller_int.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/lib/trap_stack.sh"
source "$WORK/hold.sh"
trap 'echo caller-int >"$WORK/trap.out"; [[ -e "$WORK/d1" || -e "$WORK/d2" ]] && echo early >>"$WORK/trap.out"; exit 9' INT
trap 'echo "exit=$?" >"$WORK/exit.out"' EXIT
mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"
f() { mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; hold; trap_stack_pop; }
f
trap_stack_pop
EOF
reset
start bash "$work/caller_int.sh"
wait_for "$work/ready" || error "caller INT trap: never ready"
finish INT
if [[ "$rc" -eq 9 && "$(left)" == " none" && "$(cat "$work/trap.out" 2>/dev/null)" == caller-int && "$(cat "$work/exit.out" 2>/dev/null)" == "exit=9" ]]; then
  note "INT with the caller's INT and EXIT traps: removal first, then both traps, exit 9"
else
  error "caller INT trap: rc=$rc left:$(left) trap='$(cat "$work/trap.out" 2>/dev/null)' exit='$(cat "$work/exit.out" 2>/dev/null)'"
fi

# A signal the caller ignores stays ignored: the script runs to the end.
cat >"$work/ignored.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/lib/trap_stack.sh"
source "$WORK/hold.sh"
trap '' TERM
mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"
hold
[[ -d "$WORK/d1" ]] && echo kept >"$WORK/trap.out"
trap_stack_pop
trap -p TERM >>"$WORK/trap.out"
EOF
reset
start bash "$work/ignored.sh"
wait_for "$work/ready" || error "ignored TERM: never ready"
finish TERM
if [[ "$rc" -eq 0 && "$(left)" == " none" && "$(cat "$work/trap.out" 2>/dev/null)" == "kept"$'\n'"trap -- '' SIGTERM" ]]; then
  note "TERM ignored by the caller: still ignored, the script finished"
else
  error "ignored TERM: rc=$rc left:$(left) out='$(cat "$work/trap.out" 2>/dev/null)'"
fi

# run <code>: the code as a script of its own, with the module loaded.
run() {
  printf '%s\n' 'set -euo pipefail' 'source "$ROOT_DIR/lib/trap_stack.sh"' "$1" >"$work/case.sh"
  bash "$work/case.sh" 2>&1
}

# EXIT: an exit inside the nested function, and a set -e failure, remove both
# directories; the caller's EXIT trap sees the real status.
for how in "exit 7" "false"; do
  [[ "$how" == false ]] && want=1 || want=7
  reset
  rc=0
  HOW="$how" run 'trap '\''echo "exit=$?" >"$WORK/exit.out"'\'' EXIT
    mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"
    f() { mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; $HOW; trap_stack_pop; }
    f; trap_stack_pop' >/dev/null || rc=$?
  if [[ "$rc" -eq "$want" && "$(left)" == " none" && "$(cat "$work/exit.out" 2>/dev/null)" == "exit=$want" ]]; then
    note "EXIT after '$how': both directories removed, the caller's EXIT trap saw $want"
  else
    error "EXIT after '$how': rc=$rc left:$(left) exit='$(cat "$work/exit.out" 2>/dev/null)'"
  fi
done
# The same with no trap of the caller's.
reset; rc=0
run 'mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"; mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; exit 5' >/dev/null || rc=$?
[[ "$rc" -eq 5 && "$(left)" == " none" ]] && note "EXIT with no caller trap: removed, exit 5" || error "EXIT no caller trap: rc=$rc left:$(left)"

# ---------------------------------------------------------------- traps put back
got="$(run 'trap "echo x" INT; trap "" TERM; trap "echo bye >/dev/null" EXIT
  trap_stack_push "$WORK/d1"; trap_stack_push "$WORK/d2"; trap_stack_pop; trap_stack_pop
  trap -p EXIT HUP INT TERM')"
want="trap -- 'echo bye >/dev/null' EXIT"$'\n'"trap -- 'echo x' SIGINT"$'\n'"trap -- '' SIGTERM"
[[ "$got" == "$want" ]] && note "the caller's traps are back after the last pop" || error "traps after the last pop: '$got'"

got="$(run 'trap_stack_push "$WORK/d1"; trap_stack_push "$WORK/d2"; trap_stack_pop; trap_stack_pop; trap -p EXIT HUP INT TERM')"
[[ -z "$got" ]] && note "no trap left behind" || error "trap left behind: '$got'"

# An inner pop keeps the outer registration: the traps stay until the last pop.
got="$(run 'trap_stack_push "$WORK/d1"; trap_stack_push "$WORK/d2"; trap_stack_pop; t="$(trap -p INT)"; case "$t" in *_trap_stack_fire*) echo 1 ;; *) echo 0 ;; esac')"
[[ "$got" == 1 ]] && note "an inner pop leaves the outer path registered" || error "inner pop: '$got'"

# A trap the caller sets while a path is registered is not replaced by a pop,
# and the next push chains onto it.
reset; mkdir "$work/d1"
got="$(run 'trap_stack_push "$WORK/d1"; trap "echo mine" INT
  trap_stack_push "$WORK/d2"; t="$(trap -p INT)"; case "$t" in *_trap_stack_fire*"echo mine"*) echo 1 ;; *) echo 0 ;; esac
  trap_stack_pop; trap_stack_pop; trap -p INT')"
[[ "$got" == "1"$'\n'"trap -- 'echo mine' SIGINT" ]] && note "a trap set between pushes is chained, then kept" || error "trap set between pushes: '$got'"
got="$(run 'trap_stack_push "$WORK/d1"; trap "echo mine" INT; trap_stack_pop; trap -p INT')"
[[ "$got" == "trap -- 'echo mine' SIGINT" ]] && note "a pop does not replace a trap the caller set since" || error "pop over a caller trap: '$got'"

# pop removes, pop --keep does not; bad arguments.
reset; mkdir "$work/d1" "$work/d2"
run 'trap_stack_push "$WORK/d1"; trap_stack_push "$WORK/d2"; trap_stack_pop --keep; trap_stack_pop' >/dev/null
[[ ! -e "$work/d1" && -d "$work/d2" ]] && note "pop removes the path, pop --keep leaves it" || error "pop/--keep: d1=$([[ -e "$work/d1" ]] && echo left || echo gone) d2=$([[ -e "$work/d2" ]] && echo left || echo gone)"
# A kept path is off the stack: exit does not remove it.
[[ -d "$work/d2" ]] || error "a path popped with --keep was removed at exit"
for bad in "" "/"; do
  rc=0; BAD="$bad" run 'trap_stack_push "$BAD"' >/dev/null || rc=$?
  [[ "$rc" -eq 2 ]] || error "trap_stack_push '$bad': rc=$rc, want 2"
done
rc=0; run 'trap_stack_pop; trap_stack_pop --keep' >/dev/null || rc=$?
[[ "$rc" -eq 0 ]] && note "bad path refused (2); a pop with nothing registered is 0" || error "pop with nothing registered: rc=$rc"
# A relative path is the one it named at the push, also after a cd.
reset; mkdir -p "$work/d1/rel" "$work/d2/rel"
( cd "$work/d1" && run 'trap_stack_push rel; cd "$WORK/d2"; exit 0' >/dev/null )
[[ ! -e "$work/d1/rel" && -d "$work/d2/rel" ]] && note "a relative path survives a cd: the right directory is removed" \
  || error "relative path after cd: d1/rel=$([[ -e "$work/d1/rel" ]] && echo left || echo gone) d2/rel=$([[ -e "$work/d2/rel" ]] && echo left || echo gone)"
# Sourcing the file again keeps what is registered.
reset; mkdir "$work/d1"
run 'trap_stack_push "$WORK/d1"; source "$ROOT_DIR/lib/trap_stack.sh"; exit 0' >/dev/null
[[ ! -e "$work/d1" ]] && note "a second source keeps the stack" || error "a second source dropped the registered path"

# ---------------------------------------------------------------- subshells
# A push inside $( ... ) must not run the parent's EXIT trap in the subshell,
# and a subshell must not remove what the parent registered.
reset
got="$(run 'trap "echo parent-exit >>\"\$WORK/exit.out\"" EXIT
  mkdir "$WORK/d1"; trap_stack_push "$WORK/d1"
  f() { mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; echo in-sub; trap_stack_pop; }
  v="$(f)"; w="$(mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; echo exits)"
  ( : >"$WORK/f3"; trap_stack_push "$WORK/f3" )
  [[ -d "$WORK/d1" ]] && echo "$v $w parent-dir-kept"; trap_stack_pop')"
if [[ "$got" == "in-sub exits parent-dir-kept" && "$(left)" == " none" && "$(grep -c parent-exit "$work/exit.out" 2>/dev/null)" == 1 ]]; then
  note "subshells: their own paths removed, the parent's kept, the parent's EXIT trap ran once"
else
  error "subshells: got='$got' left:$(left) parent EXIT trap ran $(grep -c parent-exit "$work/exit.out" 2>/dev/null) time(s)"
fi

# A subshell's own EXIT trap is chained and put back (bash 4 or newer: bash
# 3.2 cannot tell it from a copy of the parent's, see lib/trap_stack.sh).
if [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
  reset
  got="$(run 'trap "echo parent-exit" EXIT
    v="$(trap "echo sub-exit" EXIT; mkdir "$WORK/d2"; trap_stack_push "$WORK/d2"; trap_stack_pop; trap_stack_push "$WORK/f3")"
    echo "$v"')"
  [[ "$got" == "sub-exit"$'\n'"parent-exit" && "$(left)" == " none" ]] && note "a subshell's own EXIT trap is kept and still runs" \
    || error "subshell's own EXIT trap: got='$got' left:$(left)"
fi

# ---------------------------------------------------------------- the library's own temp dirs
# fetch_verified_gpg_key makes a directory and calls fetch_to_file, which
# registers the partial file: two registrations, one inside the other.
# _deps_install_node_linux adds a third around both. gitleaks_install makes
# its directory in the cache.
stubs="$work/stubs"; mkdir -p "$stubs" "$work/tmp"
# curl: writes a partial file, then waits to be released and fails.
cat >"$stubs/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then echo "curl 8.5.0 (x86_64-pc-linux-gnu)"; exit 0; fi
out=""; while [[ $# -gt 0 ]]; do [[ "$1" == -o ]] && out="$2"; shift; done
printf 'partial' >"$out"
: >"$WORK/ready"
i=0; while [[ ! -e "$WORK/release" && "$i" -lt 100 ]]; do sleep 0.1; i=$((i + 1)); done
exit 7
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/gpg"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/apt-get"
printf '#!/usr/bin/env bash\nprintf "nodejs:\\n  Candidate: (none)\\n"\n' >"$stubs/apt-cache"
printf '#!/usr/bin/env bash\necho amd64\n' >"$stubs/dpkg"
printf '#!/usr/bin/env bash\nexit 127\n' >"$stubs/node"
chmod +x "$stubs"/*

cat >"$work/gpg_key.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/lib/fetch.sh"
fetch_verified_gpg_key t "https://example.com/key" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$WORK/key.out"
EOF
cat >"$work/deps_node.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/helpers.sh"
shlib_import logging os deps
_deps_install_node_linux 24
EOF
cat >"$work/gitleaks.sh" <<'EOF'
set -euo pipefail
source "$ROOT_DIR/helpers.sh"
shlib_import logging foxguard gitleaks
gitleaks_install
EOF
# What is left under TMPDIR, the cache's own directories aside.
tmp_left() { find "$work/tmp" -mindepth 1 2>/dev/null | sed "s|^$work/tmp/||" | grep -v -E '^cache(/script-helpers(/gitleaks(/[^/]*)?)?)?$' | tr '\n' ' '; }
for script in gpg_key deps_node gitleaks; do
  for sig in INT TERM; do
    reset; rm -rf -- "$work/tmp"; mkdir -p "$work/tmp"
    PATH="$stubs:$PATH" TMPDIR="$work/tmp" XDG_CACHE_HOME="$work/tmp/cache" start bash "$work/$script.sh"
    wait_for "$work/ready" || error "$script $sig: the download never started: $(cat "$work/err" 2>/dev/null)"
    [[ -n "$(tmp_left)" ]] || error "$script $sig: no temp directory to remove; the case tests nothing"
    finish "$sig"
    if [[ "$rc" -eq "$(sig_code "$sig")" && -z "$(tmp_left)" && ! -e "$work/key.out" ]]; then
      note "$script, $sig mid-download: no temp directory left, exit $rc"
    else
      error "$script $sig mid-download: rc=$rc (want $(sig_code "$sig")), left in TMPDIR: $(tmp_left)"
    fi
  done
done

if [[ "$failures" -gt 0 ]]; then
  note "FAILED: $failures"
  exit 1
fi
note "All trap_stack tests passed."
