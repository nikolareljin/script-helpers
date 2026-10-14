#!/usr/bin/env bash
# SCRIPT: pre_push_ssh_note_test.sh
# DESCRIPTION: Tests the pre-push note about SSH keepalive: shown for an SSH remote with no keepalive, not otherwise.
# USAGE: bash tests/pre_push_ssh_note_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/pre_push_ssh_note_test.sh
# ----------------------------------------------------
#
# git holds the push's connection open while pre-push runs; over SSH a long
# test run is cut off (exit 141). The hook says so before the checks when no
# keepalive is set. ssh is a stub that answers `ssh -G` with $FAKE_ALIVE.
set -uo pipefail
# The hooks would download a missing gitleaks or foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT_DIR/scripts/git-hooks/pre-push"
export SECURITY_GATE_ALLOW_UNCHECKED=1 PRIVATE_NAMES_AUTO_REFRESH=false
export PRIVATE_NAMES_FILE=/nonexistent/private-names.tsv
# A keepalive in the caller's environment (a push run with one) or global git
# config would hide the note: the test sets up its own.
unset GIT_SSH_COMMAND GIT_SSH SCRIPT_HELPERS_SSH_NOTE_SHOWN
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
failures=0
note()  { echo "[pre_push_ssh_note_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[pre_push_ssh_note_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env sh
[ "$1" = "-G" ] && { echo "hostname $2"; echo "serveraliveinterval ${FAKE_ALIVE:-0}"; exit 0; }
exit 1
EOF
chmod +x "$tmp/bin/ssh"
export PATH="$tmp/bin:$PATH"

repo="$tmp/repo"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init
printf 'test:\n\t@exit 0\n' > "$repo/Makefile"
zeroes="$(printf '0%.0s' $(seq 1 40))"

run() {   # <url> -> hook output
  local sha; sha="$(git -C "$repo" rev-parse HEAD)"
  ( cd "$repo" && printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$zeroes" | bash "$HOOK" origin "$1" 2>&1 )
}
shows() {   # <label> <url> [env...]
  local label="$1" url="$2" out; shift 2
  out="$(env "$@" bash -c "$(declare -f run); repo='$repo' zeroes='$zeroes' HOOK='$HOOK'; run '$url'")"
  grep -q "ServerAliveInterval 20" <<<"$out" && ok "$label" || error "$label: no note"
}
silent() {
  local label="$1" url="$2" out; shift 2
  out="$(env "$@" bash -c "$(declare -f run); repo='$repo' zeroes='$zeroes' HOOK='$HOOK'; run '$url'")"
  grep -q "ServerAliveInterval" <<<"$out" && error "$label: note shown" || ok "$label"
}

shows  "scp-style SSH remote, no keepalive: note" "git@github.com:me/x.git"
out="$(run git@github.com:me/x.git)"
grep -q "Host github.com" <<<"$out" && ok "the note names the host" || error "host missing from the note"
shows  "ssh:// with user and port: note" "ssh://git@ssh.github.com:443/me/x.git"
silent "keepalive in the ssh config: no note" "git@github.com:me/x.git" FAKE_ALIVE=20
silent "keepalive in GIT_SSH_COMMAND: no note" "git@github.com:me/x.git" "GIT_SSH_COMMAND=ssh -o ServerAliveInterval=15"
silent "HTTPS remote: no note" "https://github.com/me/x.git"
silent "local path remote: no note" "/srv/git/x.git"
out="$(run git@github.com:me/x.git)"; rc=$?
[[ "$rc" -eq 0 ]] && grep -q "All checks passed" <<<"$out" && ok "the note does not change the result" || error "push result changed: rc=$rc"

# Color: yellow on a terminal, plain in CI or with NO_COLOR. `script` (util-linux)
# gives the hook a terminal; elsewhere (BSD script) this part is skipped.
out="$(run git@github.com:me/x.git)"
[[ "$out" != *$'\033[1;33m'* ]] && ok "no color when stderr is not a terminal" || error "color codes in non-terminal output"
if script --version 2>/dev/null | grep -q util-linux; then
  sha="$(git -C "$repo" rev-parse HEAD)"
  printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$zeroes" > "$tmp/refs"
  tty_run() { (cd "$repo" && env -u CI -u NO_COLOR TERM=xterm "$@" script -qec "bash '$HOOK' origin git@github.com:me/x.git < '$tmp/refs'" /dev/null 2>&1); }
  out="$(tty_run)"
  [[ "$out" == *$'\033[1;33m[pre-push] The push waits'* ]] && ok "yellow on a terminal" || error "no color on a terminal"
  out="$(tty_run CI=true)"
  [[ "$out" == *"[pre-push] The push waits"* && "$out" != *$'\033[1;33m'* ]] && ok "plain in CI (CI set)" || error "color in CI"
  out="$(tty_run NO_COLOR=1)"
  [[ "$out" != *$'\033[1;33m'* ]] && ok "plain with NO_COLOR" || error "color with NO_COLOR"
else
  note "skip: no util-linux script for a terminal"
fi

# The host as git reads the URL: drive-letter paths, paths with a colon after a
# slash, IPv6 in brackets, and a host that would read as an ssh option.
source "$ROOT_DIR/scripts/ssh_keepalive.sh"
host_is() {   # <url> <expected host, empty for none>
  local got; got="$(ssh_host_of "$1")"
  [[ "$got" == "$2" ]] && ok "host of $1: '${2}'" || error "host of $1: '$got', expected '$2'"
}
host_is 'git@github.com:me/x.git' github.com
host_is 'ssh://git@ssh.github.com:443/me/x.git' ssh.github.com
host_is 'ssh://host.example/x' host.example
host_is 'C:/repo' ''
host_is 'C:\repo' ''
host_is 'C:' ''
host_is './a:b' ''
host_is 'dir/sub:x' ''
host_is 'ssh://[::1]:22/x' '::1'
host_is 'git@[::1]:x' '::1'
host_is '-oProxyCommand=touch /tmp/x:y' ''
host_is 'https://github.com/me/x.git' ''
silent "GIT_SSH (non-OpenSSH client): no note" "git@github.com:me/x.git" "GIT_SSH=/usr/bin/plink"
# Remotes with no SSH host: the push still succeeds (the hook runs under set -e).
for url in https://github.com/me/x.git /srv/git/x.git 'C:/repo'; do
  out="$(run "$url")"; rc=$?
  [[ "$rc" -eq 0 && "$out" == *"All checks passed"* ]] && ok "push to $url still succeeds" || error "push to $url: rc=$rc"
done

# The note lists every way to keep the connection alive.
out="$(run git@github.com:me/x.git)"
for want in "add to ~/.ssh/config" 'git config core.sshCommand "ssh -o ServerAliveInterval=20"' \
            'GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push' "HTTPS remote is not affected"; do
  grep -qF -- "$want" <<<"$out" && ok "note names: $want" || error "note lacks: $want"
done
# A push that only deletes refs runs no checks: no note.
out="$( (cd "$repo" && printf 'refs/heads/gone %s refs/heads/gone %s\n' "$zeroes" "$(git rev-parse HEAD)" | bash "$HOOK" origin git@github.com:me/x.git 2>&1) )"
grep -q "ServerAliveInterval" <<<"$out" && error "note on a deletions-only push" || ok "no note on a deletions-only push"

# A chained setup: the dispatcher shows the note before the security checks and
# the repository's own pre-push, and only once even when that pre-push is the
# shared hook (which would show it too).
SETUP="$ROOT_DIR/scripts/setup-hooks.sh"
ch="$tmp/chained"
git -c init.defaultBranch=main init -q "$ch"
git -C "$ch" -c user.email=t@localhost -c user.name=t commit -q --allow-empty -m init
git -C "$ch" remote add origin git@github.com:example-owner/x.git
mkdir -p "$ch/.githooks"
cp "$HOOK" "$ch/.githooks/pre-push"; printf '#!/usr/bin/env bash\nexit 0\n' > "$ch/.githooks/pre-commit"
chmod +x "$ch/.githooks/pre-push" "$ch/.githooks/pre-commit"
printf 'test:\n\t@exit 0\n' > "$ch/Makefile"
export XDG_DATA_HOME="$tmp/data" SCRIPT_HELPERS_OWNERS=example-owner   # setup refuses without owners
(cd "$ch" && bash "$SETUP" >/dev/null 2>&1) || error "chained: setup failed"
wrapper="$(git -C "$ch" config --get core.hooksPath)/pre-push"
if [[ -x "$wrapper" ]]; then
  sha="$(git -C "$ch" rev-parse HEAD)"
  out="$( (cd "$ch" && printf 'refs/heads/main %s refs/heads/main %s\n' "$sha" "$zeroes" | "$wrapper" origin git@github.com:example-owner/x.git 2>&1) )"
  n="$(grep -c "The push waits" <<<"$out")"
  [[ "$n" == 1 ]] && ok "chained: the note is shown once" || error "chained: note shown $n times"
  grep -q "^\[script-helpers\] The push waits" <<<"$out" && ok "chained: shown by the dispatcher, before the checks" || error "chained: not from the dispatcher"
else
  error "chained: no installed pre-push wrapper at $wrapper"
fi

# A repository's own pre-push must not inherit the once-per-push marker: in a
# push with no keepalive the note is shown, and a test of the note run from
# that hook would see it suppressed and refuse the push.
mkdir -p "$repo/.githooks"
printf '#!/usr/bin/env bash\n[ -z "${SCRIPT_HELPERS_SSH_NOTE_SHOWN:-}" ] || { echo leaked; exit 1; }\n' > "$repo/.githooks/pre-push"
out="$(run git@github.com:me/x.git)"; rc=$?
[[ "$rc" -eq 0 && "$out" == *"The push waits"* && "$out" != *leaked* ]] && ok "the repository's own pre-push does not inherit the note marker" \
  || error "the note marker leaked into the repository's pre-push (rc=$rc)"
rm -rf "$repo/.githooks"

# setup-hooks.sh --status lists the keepalive with the prerequisites. In a
# repository with no agent hooks it used to stop with exit 1 before them.
SETUP="$ROOT_DIR/scripts/setup-hooks.sh"
out="$(cd "$repo" && HOME="$tmp/h" XDG_CONFIG_HOME="$tmp/h/.config" bash "$SETUP" --status 2>&1)"
grep -q "prerequisites:" <<<"$out" && ok "--status in a repository reaches the prerequisites" || error "--status stopped early: $(tail -1 <<<"$out")"
grep -q "ssh       WARN: no keepalive for github.com" <<<"$out" && ok "--status warns about the missing keepalive" || error "--status: no keepalive line"
out="$(cd "$repo" && FAKE_ALIVE=20 HOME="$tmp/h" bash "$SETUP" --status 2>&1)"
grep -q "ssh       ok (keepalive set for github.com)" <<<"$out" && ok "--status: keepalive ok" || error "--status: keepalive not seen"

if [[ "$failures" -gt 0 ]]; then note "$failures failure(s)"; exit 1; fi
note "ALL PASSED"
