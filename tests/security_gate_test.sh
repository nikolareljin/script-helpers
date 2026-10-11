#!/usr/bin/env bash
# SCRIPT: security_gate_test.sh
# DESCRIPTION: Tests for check_sensitive.sh, the security steps of the shared hooks, and setup-hooks.sh --global.
# USAGE: ./tests/security_gate_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/security_gate_test.sh
# ----------------------------------------------------
#
# Every sensitive value below is assembled at run time from pieces, so this
# file itself passes the checks it tests. Addresses are RFC 5737, domains
# example.*, owners are placeholders.
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT_DIR/scripts/check_sensitive.sh"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[security_gate_test] $*"; }
error() { echo "[security_gate_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }
expect() {  # <description> <want rc> <got rc>
  if [[ "$2" == "$3" ]]; then ok "$1"; else error "$1: want exit $2, got $3"; fi
}

# Hermetic: no real config, terms, cache or identity of this machine.
export HOME="$tmp/home"
mkdir -p "$HOME"
cd "$tmp" || exit 1
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1
unset SCRIPT_HELPERS_OWNERS SENSITIVE_ALLOW SENSITIVE_TERMS_FILE SCRIPT_HELPERS_SECURITY_DIR FOXGUARD_CMD GITLEAKS_BIN SECURITY_GATE_ALLOW_UNCHECKED SENSITIVE_ALLOW_UNCHECKED PRIVATE_NAMES_FILE
: > "$tmp/no-machine-ids"
export SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids"
export PRIVATE_NAMES_AUTO_REFRESH=false

have_gitleaks=false
command -v gitleaks >/dev/null 2>&1 && have_gitleaks=true

gc() { git -c user.name=Test -c user.email=test@example.com -c core.hooksPath=/dev/null "$@"; }
new_repo() { git init -q "$1" && gc -C "$1" commit -q --allow-empty -m init; }
commit_file() {  # <repo> <file> <content>
  printf '%s\n' "$3" > "$1/$2" && gc -C "$1" add "$2" && gc -C "$1" commit -q -m "add $2"
}
run() { bash "$CHECK" "$@" >"$tmp/out" 2>&1; echo $?; }

aws_key="AKIA""QYLPMN5HHHFPZAM2"
aws_secret="wJalrXUtnFEMI/K7MDENG/bPxRfiCY""1234567890ab"
real_email="jane.roe""@""mailbox.org"
ssn="219-09-""9999"
card="4539 1488 ""0343 6467"
phone="(212) 555-""7341"

# ------------------------------------------------------- check_sensitive.sh
repo="$tmp/r1"; new_repo "$repo"

if [[ "$have_gitleaks" == true ]]; then
  commit_file "$repo" creds.txt "aws_access_key_id = $aws_key
aws_secret_access_key = $aws_secret"
  expect "a fake AWS key in a commit blocks" 1 "$(run --repo "$repo" --range HEAD~1..HEAD)"
  grep -q "$aws_key" "$tmp/out" && error "the key itself was printed"
  gc -C "$repo" rm -q creds.txt; gc -C "$repo" commit -q -m "remove it"
  expect "the commit that deletes the key passes" 0 "$(run --repo "$repo" --range HEAD~1..HEAD)"
  # A committed .gitleaks.toml that allows everything is not honored.
  printf '[allowlist]\npaths = [".*"]\n' > "$repo/.gitleaks.toml"
  commit_file "$repo" creds2.txt "aws_access_key_id = $aws_key
aws_secret_access_key = $aws_secret"
  expect "a committed .gitleaks.toml cannot allow a key" 1 "$(run --repo "$repo" --range HEAD~1..HEAD)"
  gc -C "$repo" rm -q creds2.txt; gc -C "$repo" commit -q -m "remove it"; rm -f "$repo/.gitleaks.toml"
else
  note "SKIP: gitleaks not installed; credential cases not run here"
fi

commit_file "$repo" docs.md "Point it at 192.0.2.10 or 2001:db8::5; mail admin@example.com, bot <noreply@example.org>, x@users.noreply.github.com, logo@2x.png. Call 555-0142. Card 4242 4242 4242 4242. Built 2026-10-11, id 1696867200000, v1.2.3."
expect "RFC 5737 / example / noreply / test-card text passes" 0 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"

commit_file "$repo" contact.md "Write to $real_email"
expect "a real-looking email blocks" 1 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"
grep -q "$real_email" "$tmp/out" && error "the email was printed unmasked"

printf 'call %s\n' "$phone" > "$tmp/phone.txt"
expect "a phone number blocks (--file)" 1 "$(run --file "$tmp/phone.txt" --no-gitleaks)"
printf 'ssn %s\n' "$ssn" | bash "$CHECK" --stdin --no-gitleaks >/dev/null 2>&1
expect "an SSN blocks (--stdin)" 1 "$?"
printf 'card %s\n' "$card" | bash "$CHECK" --stdin --no-gitleaks >/dev/null 2>&1
expect "a Luhn-valid card number blocks" 1 "$?"
printf 'card 4539 1488 0343 6468\n' | bash "$CHECK" --stdin --no-gitleaks >/dev/null 2>&1
expect "a Luhn-invalid number passes" 0 "$?"

printf 'Write to %s  sensitive:allow\n' "$real_email" > "$tmp/inline.txt"
expect "inline sensitive:allow passes" 0 "$(run --file "$tmp/inline.txt" --no-gitleaks)"
grep -q "allowed by inline" "$tmp/out" || error "the inline allow was not reported"
printf '@mailbox.org\n' > "$repo/.sensitive-allow"
expect "a committed .sensitive-allow is ignored" 1 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"
rm -f "$repo/.sensitive-allow"
printf '@mailbox.org\n' > "$repo/.git/sensitive-allow"
expect ".git/sensitive-allow @domain passes" 0 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"
grep -q "allowed by .git/sensitive-allow" "$tmp/out" || error "the file allow was not reported"
rm -f "$repo/.git/sensitive-allow"
printf 'a %s sensitive:allow\nb %s\n' "$real_email" "$real_email" > "$tmp/inline2.txt"
expect "sensitive:allow covers only its own line" 1 "$(run --file "$tmp/inline2.txt" --no-gitleaks)"
SENSITIVE_ALLOW="$real_email" bash "$CHECK" --repo "$repo" --range HEAD~1..HEAD --no-gitleaks >/dev/null 2>&1
expect "SENSITIVE_ALLOW passes" 0 "$?"

# Personal terms: whole tokens only, values never printed.
mkdir -p "$XDG_CONFIG_HOME/script-helpers"
terms="$XDG_CONFIG_HOME/script-helpers/sensitive-terms.txt"
printf '# a comment\n192.0.2.109\nquux-corp\n' > "$terms"; chmod 600 "$terms"
printf 'near misses: 192.0.2.1090 1.192.0.2.109 a192.0.2.109 quux-corporation\n' > "$tmp/near.txt"
expect "a term inside a longer address or word passes" 0 "$(run --file "$tmp/near.txt" --no-gitleaks)"
printf 'listen 192.0.2.109:8080\n' > "$tmp/hit.txt"
expect "a term as a whole token blocks" 1 "$(run --file "$tmp/hit.txt" --no-gitleaks)"
grep -q '192.0.2.109' "$tmp/out" && error "the term value was printed"
grep -q 'sensitive-terms.txt line 2' "$tmp/out" || error "the term was not cited by line"
printf 'Ask QUUX-CORP.\n' > "$tmp/hit2.txt"
expect "terms match case-insensitively" 1 "$(run --file "$tmp/hit2.txt" --no-gitleaks)"
printf 'quux-corp at the start of a line\n' > "$tmp/hit3.txt"
expect "a term at the start of a line blocks" 1 "$(run --file "$tmp/hit3.txt" --no-gitleaks)"
# A NUL byte once made grep call the whole input binary and drop every line.
printf 'bin\000ary\nskip sensitive:allow\nlisten 192.0.2.109\n' > "$tmp/nul.txt"
expect "a NUL byte elsewhere does not hide a term" 1 "$(run --file "$tmp/nul.txt" --no-gitleaks)"
printf 'bin\000ary\nmail %s\n' "$real_email" > "$tmp/nul2.txt"
expect "a NUL byte elsewhere does not hide an email" 1 "$(run --file "$tmp/nul2.txt" --no-gitleaks)"
rm -f "$terms"

# A deleted line never blocks.
printf 'contact %s\n' "$real_email" > "$repo/old.txt"; gc -C "$repo" add old.txt; gc -C "$repo" commit -q -m "old" --no-verify
gc -C "$repo" rm -q old.txt; gc -C "$repo" commit -q -m "drop old"
expect "a deleted line with a sensitive value passes" 0 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"

# Live machine identifiers (injected).
printf "this machine's IPv4 address (eth0)\t198.51.100.23\n" > "$tmp/ids"
printf 'ssh 198.51.100.23\n' > "$tmp/ip.txt"
SENSITIVE_MACHINE_IDS_FILE="$tmp/ids" bash "$CHECK" --file "$tmp/ip.txt" --no-gitleaks >"$tmp/out" 2>&1
expect "this machine's address blocks" 1 "$?"
grep -q "IPv4 address (eth0)" "$tmp/out" || error "the identifier kind was not named"
SENSITIVE_MACHINE_IDS_FILE="$tmp/ids" bash "$CHECK" --file "$tmp/ip.txt" --no-gitleaks --no-machine >/dev/null 2>&1
expect "--no-machine skips it" 0 "$?"
printf "this machine's MAC address (eth0)\t02:00:5e:10:00:01\n" > "$tmp/ids"
printf 'mac 02-00-5E-10-00-01\n' > "$tmp/mac.txt"
SENSITIVE_MACHINE_IDS_FILE="$tmp/ids" bash "$CHECK" --file "$tmp/mac.txt" --no-gitleaks >/dev/null 2>&1
expect "a MAC written with dashes blocks too" 1 "$?"

# A commit message is checked too.
gc -C "$repo" commit -q --allow-empty -m "ping $real_email"
expect "a commit message with an email blocks" 1 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"

# Staged lines.
printf 'x %s\n' "$real_email" > "$repo/staged.txt"; gc -C "$repo" add staged.txt
(cd "$repo" && bash "$CHECK" --staged --no-gitleaks >/dev/null 2>&1)
expect "--staged blocks a staged email" 1 "$?"
gc -C "$repo" rm -q --cached staged.txt; rm -f "$repo/staged.txt"

# gitleaks missing: could not check, exit 2.
GITLEAKS_BIN="$tmp/none" bash "$CHECK" --file "$tmp/near.txt" >"$tmp/out" 2>&1
expect "gitleaks missing -> exit 2" 2 "$?"
grep -q "install" "$tmp/out" || error "no install hint when gitleaks is missing"
SENSITIVE_NO_MACHINE=1 bash "$CHECK" --file "$tmp/near.txt" --no-gitleaks 2>"$tmp/out" >/dev/null
grep -q "notice: --no-gitleaks" "$tmp/out" && ok "--no-gitleaks is announced" || error "--no-gitleaks silent"
grep -q "WARNING: SENSITIVE_NO_MACHINE=1" "$tmp/out" && ok "SENSITIVE_NO_MACHINE=1 is announced" || error "SENSITIVE_NO_MACHINE silent"
# Unreadable inputs are "could not check", never "clean".
printf 'quux-corp\n' > "$tmp/terms-locked"; chmod 000 "$tmp/terms-locked"
if [[ -r "$tmp/terms-locked" ]]; then
  note "SKIP: running as root; an unreadable file cannot be made"
else
  expect "unreadable sensitive-terms.txt -> exit 2" 2 "$(run --file "$tmp/near.txt" --no-gitleaks --terms "$tmp/terms-locked")"
fi
chmod 600 "$tmp/terms-locked"
SENSITIVE_MACHINE_IDS_FILE="$tmp/missing-ids" bash "$CHECK" --file "$tmp/near.txt" --no-gitleaks >/dev/null 2>&1
expect "machine identifiers unreadable -> exit 2" 2 "$?"
env -u HOME -u XDG_CONFIG_HOME bash "$CHECK" --file "$tmp/near.txt" --no-gitleaks --no-machine >/dev/null 2>&1
expect "HOME and XDG_CONFIG_HOME unset -> exit 2" 2 "$?"
: > "$tmp/empty-refs"
expect "an empty push-refs input -> exit 2, not clean" 2 "$(run --repo "$repo" --push-refs "$tmp/empty-refs" --no-gitleaks)"
printf 'refs/heads/x %s refs/heads/x %s\n' "$(gc -C "$repo" rev-parse HEAD)" 0000000000000000000000000000000000000000 > "$tmp/one-ref"
SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" bash "$CHECK" --repo "$repo" --push-refs "$tmp/one-ref" --no-gitleaks >/dev/null 2>&1
rc=$?; [[ "$rc" -ne 2 ]] && ok "a real push-refs input is checked (exit $rc)" || error "a real push-refs input was not checked"
printf 'mail %s\n' "$real_email" | bash "$CHECK" --stdin --no-gitleaks --no-machine 2>"$tmp/out" >/dev/null
grep -q "notice: no " "$tmp/out" && ok "a missing terms file is said" || error "no notice for a missing terms file"

# ------------------------------------------------ shared pre-push (repo mode)
# A repository that vendors script-helpers at scripts/script-helpers.
vend="$tmp/vend"; new_repo "$vend"
mkdir -p "$vend/scripts/script-helpers"
cp -R "$ROOT_DIR/scripts" "$ROOT_DIR/lib" "$ROOT_DIR/helpers.sh" "$vend/scripts/script-helpers/"
gc -C "$vend" add -A; gc -C "$vend" commit -q -m vendor
base="$(gc -C "$vend" rev-parse HEAD)"
HOOK="$vend/scripts/script-helpers/scripts/git-hooks/pre-push"
(cd "$vend" && bash scripts/script-helpers/scripts/setup-hooks.sh >/dev/null 2>&1)
[[ "$(git -C "$vend" config --local script-helpers.trust-repo-hooks)" == true ]] && ok "per-repo setup-hooks.sh records the local opt-in" || error "setup-hooks.sh did not set script-helpers.trust-repo-hooks"
git -C "$vend" config --local --unset core.hooksPath
push() {  # runs the hook for HEAD against $base; extra env as args
  (cd "$vend" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$base" \
    | env PRE_PUSH_SKIP_TESTS=1 "$@" bash "$HOOK" origin git@github.com:example-owner/vend.git >"$tmp/out" 2>&1)
  echo $?
}
commit_file "$vend" a.md "Write to $real_email"
expect "pre-push refuses a real email" 1 "$(push GITLEAKS_BIN="$tmp/none")"
gc -C "$vend" reset -q --hard "$base"
commit_file "$vend" b.md "docs at https://example.com"
expect "pre-push refuses when gitleaks is missing (could not check)" 1 "$(push GITLEAKS_BIN="$tmp/none")"
expect "SENSITIVE_ALLOW_UNCHECKED=1 lets it through" 0 "$(push GITLEAKS_BIN="$tmp/none" SENSITIVE_ALLOW_UNCHECKED=1)"
grep -q "foxguard not installed" "$tmp/out" && ok "foxguard missing -> one-line notice" || error "no foxguard notice"
expect "SECURITY_GATE_ALLOW_UNCHECKED=1 lets it through" 0 "$(push GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1)"
grep -q "WARNING: .*allowed unchecked" "$tmp/out" && ok "with a visible warning" || error "no warning on an unchecked push"
# No private-name list: the push is refused, not waved through.
expect "private-name list missing -> push refused" 1 "$(push)"
grep -q "private-name check could not run" "$tmp/out" && ok "and says why" || error "no reason: $(cat "$tmp/out")"
printf '#!/usr/bin/env bash\necho "b.md:1 example-rule: something to look at"\nexit 1\n' > "$tmp/fakefox"; chmod +x "$tmp/fakefox"
expect "foxguard findings do not block" 0 "$(push GITLEAKS_BIN="$tmp/none" SENSITIVE_ALLOW_UNCHECKED=1 FOXGUARD_CMD="$tmp/fakefox")"
grep -q "WARNING (foxguard): b.md:1 example-rule" "$tmp/out" && ok "foxguard findings shown as warnings" || error "foxguard warning missing: $(cat "$tmp/out")"
deleted="$(printf 'refs/heads/x %s refs/heads/x %s\n' 0000000000000000000000000000000000000000 "$base")"
(cd "$vend" && printf '%s\n' "$deleted" | bash "$HOOK" origin x >"$tmp/out" 2>&1)
expect "deletions-only push passes untouched" 0 "$?"
# The repository's own .githooks/pre-push runs after the checks, with the refs.
mkdir -p "$vend/.githooks"
printf '#!/usr/bin/env bash\ncat > "%s/local-ran"\nexit 0\n' "$tmp" > "$vend/.githooks/pre-push"
expect "a repo-local pre-push runs after the checks" 0 "$(push GITLEAKS_BIN="$tmp/none" SENSITIVE_ALLOW_UNCHECKED=1)"
grep -q refs/heads/main "$tmp/local-ran" 2>/dev/null && ok "and receives the ref lines" || error "repo-local pre-push did not get the refs"
gc -C "$vend" reset -q --hard "$base"
commit_file "$vend" c.md "Write to $real_email"
rm -f "$tmp/local-ran"
expect "a repo-local pre-push cannot skip the checks" 1 "$(push GITLEAKS_BIN="$tmp/none" SENSITIVE_ALLOW_UNCHECKED=1)"
[[ -f "$tmp/local-ran" ]] && error "the repo-local hook ran although the push was refused"
rm -rf "$vend/.githooks"

# No environment marker can skip the checks.
gc -C "$vend" reset -q --hard "$base"
commit_file "$vend" d.md "Write to $real_email"
expect "SCRIPT_HELPERS_SECURITY_DONE=1 does not skip the checks" 1 "$(push GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 SCRIPT_HELPERS_SECURITY_DONE=1)"
# A global script directory missing a checker is not replaced by the repo's copy.
mkdir -p "$tmp/emptysec"
expect "SCRIPT_HELPERS_SECURITY_DIR without the checker refuses" 1 "$(push GITLEAKS_BIN="$tmp/none" SCRIPT_HELPERS_SECURITY_DIR="$tmp/emptysec")"
grep -q "check_sensitive.sh not found\|check_private_names.sh not found" "$tmp/out" && ok "and says the checker is missing" || error "no reason: $(cat "$tmp/out")"

# A commit already on another remote (a private one) is still new to the target.
gc -C "$vend" update-ref refs/remotes/priv/main HEAD
git -C "$vend" remote add priv "$tmp/priv.git"
git -C "$vend" remote add pub "$tmp/pub.git"
(cd "$vend" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | env PRE_PUSH_SKIP_TESTS=1 GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$HOOK" pub "$tmp/pub.git" >"$tmp/out" 2>&1)
expect "a commit on another remote is checked when pushed to a new one" 1 "$?"
(cd "$vend" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | env PRE_PUSH_SKIP_TESTS=1 GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$HOOK" priv "$tmp/priv.git" >"$tmp/out" 2>&1)
expect "the same push to the remote that has it passes" 0 "$?"
git -C "$vend" remote remove priv; git -C "$vend" remote remove pub
gc -C "$vend" reset -q --hard "$base"

# Public or private is decided by the push target, not by origin.
printf '# visibility\tnamespace\tname\tcode\tflags\nprivate\tex-ns\tzzqsecretproj\tR-1\t\npublic\tex-ns\tzzqpubmirror\tR-2\t\n' > "$tmp/vis.tsv"
git -C "$vend" remote add origin git@github.com:ex-ns/zzqsecretproj.git
gc -C "$vend" commit -q --allow-empty -m "port from zzqsecretproj"
(cd "$vend" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$base" \
  | env PRE_PUSH_SKIP_TESTS=1 PRIVATE_NAMES_FILE="$tmp/vis.tsv" PRIVATE_NAMES_AUTO_REFRESH=false GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 \
    bash "$HOOK" mirror git@github.com:ex-ns/zzqpubmirror.git >"$tmp/out" 2>&1)
expect "a private repo pushed to a public mirror is checked for private names" 1 "$?"
git -C "$vend" remote remove origin
gc -C "$vend" reset -q --hard "$base"

# ---------------------------------------------------------- --global install
SETUP="$ROOT_DIR/scripts/setup-hooks.sh"
gdir="$XDG_DATA_HOME/script-helpers/git-hooks"
mkdir -p "$tmp/earlier-hooks"
printf '#!/usr/bin/env bash\necho ran >> "%s/earlier-hook"\nexit 0\n' "$tmp" > "$tmp/earlier-hooks/pre-commit"
chmod +x "$tmp/earlier-hooks/pre-commit"
git config --global core.hooksPath "$tmp/earlier-hooks"
bash "$SETUP" --global >"$tmp/out" 2>&1
expect "--global refuses without owners" 2 "$?"
[[ "$(git config --global core.hooksPath)" == "$tmp/earlier-hooks" ]] && ok "and changes nothing" || error "hooksPath changed without owners"

git config --global script-helpers.owners "example-owner,Second-Org"
bash "$SETUP" --global >"$tmp/out" 2>&1
expect "--global installs once owners are set" 0 "$?"
grep -q "current global core.hooksPath: $tmp/earlier-hooks" "$tmp/out" || error "the previous value was not shown"
[[ "$(git config --global core.hooksPath)" == "$gdir/hooks" ]] && ok "global core.hooksPath points at the install" || error "hooksPath: $(git config --global core.hooksPath)"
[[ -f "$gdir/scripts/check_sensitive.sh" && -f "$gdir/lib/logging.sh" ]] && ok "the install carries its own check scripts" || error "check scripts not copied"
bash "$SETUP" --global >/dev/null 2>&1
[[ "$(cat "$gdir/previous-hooksPath")" == "$tmp/earlier-hooks" ]] && ok "a second --global keeps the original backup" || error "backup overwritten: $(cat "$gdir/previous-hooksPath")"
bash "$SETUP" --status >"$tmp/out" 2>&1
grep -q "installed at $gdir" "$tmp/out" && ok "--status reports the install" || error "--status: $(cat "$tmp/out")"

# An owner repository: checked through the real git hook path.
own="$tmp/own"; new_repo "$own"
git -C "$own" remote add origin https://github.com/Example-Owner/own.git
printf 'x %s\n' "$real_email" > "$own/f.txt"; git -C "$own" add f.txt
git -C "$own" -c user.name=T -c user.email=t@example.com commit -q -m "add f" >"$tmp/out" 2>&1
expect "global pre-commit refuses a real email in an owner repo" 1 "$?"
git -C "$own" rm -q --cached f.txt
printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git -C "$own" rev-parse HEAD)" > "$tmp/refs"
(cd "$own" && gc commit -q --allow-empty -m "mail $real_email" && \
  printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | GITLEAKS_BIN="$tmp/none" bash "$gdir/hooks/pre-push" origin git@github.com:example-owner/own.git >"$tmp/out" 2>&1)
expect "global pre-push refuses an owner push (ssh URL)" 1 "$?"
(cd "$own" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | GITLEAKS_BIN="$tmp/none" bash "$gdir/hooks/pre-push" origin https://github.com/second-org/own >"$tmp/out" 2>&1)
expect "a second configured owner is checked too" 1 "$?"
(cd "$own" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | GITLEAKS_BIN="$tmp/none" bash "$gdir/hooks/pre-push" mirror "$tmp/mirror.git" >"$tmp/out" 2>&1)
expect "an owner repo pushed to a non-GitHub mirror is checked (origin decides)" 1 "$?"

# An owner repository's committed hook runs only when the clone opted in.
mkdir -p "$own/.githooks"
printf '#!/usr/bin/env bash\necho ran >> "%s/own-tracked"\nexit 0\n' "$tmp" > "$own/.githooks/pre-commit"
printf 'docs\n' > "$own/g.txt"; git -C "$own" add g.txt
git -C "$own" -c user.name=T -c user.email=t@example.com commit -q -m "add g" >/dev/null 2>&1 || error "clean owner commit refused"
[[ -f "$tmp/own-tracked" ]] && error "an owner repo's committed hook ran without the local opt-in" || ok "an owner repo's committed hook does not run without opt-in"
git -C "$own" config --local script-helpers.trust-repo-hooks true
printf 'more\n' > "$own/h.txt"; git -C "$own" add h.txt
git -C "$own" -c user.name=T -c user.email=t@example.com commit -q -m "add h" >/dev/null 2>&1 || error "clean owner commit refused"
grep -q ran "$tmp/own-tracked" 2>/dev/null && ok "with the opt-in, the owner repo's .githooks/pre-commit runs after the checks" || error "owner .githooks/pre-commit did not run with opt-in"

# Another org's repository: pure pass-through. What git would have run before
# (here the earlier global hooks directory) still runs; tracked hooks do not.
other="$tmp/other"; new_repo "$other"
git -C "$other" remote add origin git@github.com:other-org/other.git
printf '#!/usr/bin/env bash\necho ran >> "%s/other-hook"\nexit 0\n' "$tmp" > "$other/.git/hooks/pre-commit"
chmod +x "$other/.git/hooks/pre-commit"
mkdir -p "$other/.githooks"
printf '#!/usr/bin/env bash\necho ran >> "%s/other-tracked"\nexit 0\n' "$tmp" > "$other/.githooks/pre-commit"
printf 'x %s\n' "$real_email" > "$other/f.txt"; git -C "$other" add f.txt
git -C "$other" -c user.name=T -c user.email=t@example.com commit -q -m "add f" >"$tmp/out" 2>&1
expect "another org's repo commits untouched" 0 "$?"
[[ -s "$tmp/out" ]] && error "pass-through printed: $(cat "$tmp/out")"
grep -q ran "$tmp/earlier-hook" 2>/dev/null && ok "the earlier global hook still runs there" || error "earlier global pre-commit did not run"
[[ -f "$tmp/other-tracked" ]] && error "a tracked hook of a non-owner repo ran"
# Even an opt-in does not make another org's committed hooks run, nor a push.
git -C "$other" config --local script-helpers.trust-repo-hooks true
printf '#!/usr/bin/env bash\necho pwned > "%s/evil-ran"\nexit 0\n' "$tmp" > "$other/.githooks/pre-push"; chmod +x "$other/.githooks/pre-push"
(cd "$other" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | bash "$gdir/hooks/pre-push" origin git@github.com:other-org/other.git >/dev/null 2>&1)
[[ -f "$tmp/evil-ran" ]] && error "an untrusted repo's .githooks/pre-push was executed" || ok "an untrusted repo's .githooks/pre-push is not executed"
git -C "$other" config --local --unset script-helpers.trust-repo-hooks
[[ -f "$tmp/other-hook" ]] && error ".git/hooks ran although git would have used the earlier global path"

# No owners configured at push time: pass-through with one notice.
git config --global --unset script-helpers.owners
(cd "$own" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | bash "$gdir/hooks/pre-push" origin git@github.com:example-owner/own.git >"$tmp/out" 2>&1)
expect "unconfigured owners: pass-through" 0 "$?"
grep -q "no owners set" "$tmp/out" && ok "with a one-line notice" || error "no notice when owners are unset"

# A repository-local core.hooksPath overrides the global one; its hooks still check.
git config --global script-helpers.owners example-owner
bash "$SETUP" --global --uninstall >"$tmp/out" 2>&1
expect "--global --uninstall" 0 "$?"
[[ "$(git config --global core.hooksPath)" == "$tmp/earlier-hooks" ]] && ok "restores the previous global value" || error "not restored: $(git config --global core.hooksPath || echo unset)"
[[ ! -d "$gdir/hooks" ]] && ok "and removes the install" || error "install left behind"
git config --global --unset core.hooksPath
bash "$SETUP" --global >/dev/null 2>&1
git -C "$other" -c user.name=T -c user.email=t@example.com commit -q --allow-empty -m "again" >/dev/null 2>&1
grep -q ran "$tmp/other-hook" 2>/dev/null && ok "with no earlier global path, .git/hooks runs" || error ".git/hooks/pre-commit did not run"
printf '#!/usr/bin/env bash\nexit 7\n' > "$other/.git/hooks/pre-push"; chmod +x "$other/.git/hooks/pre-push"
(cd "$other" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | bash "$gdir/hooks/pre-push" origin git@github.com:other-org/other.git >/dev/null 2>&1)
expect "a chained hook's exit status is the hook's" 7 "$?"

# A broken install refuses a push instead of passing it.
mv "$gdir/scripts/owner_scope.sh" "$tmp/owner_scope.bak"
(cd "$own" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
  | bash "$gdir/hooks/pre-push" origin git@github.com:example-owner/own.git >"$tmp/out" 2>&1)
expect "a broken global install refuses the push" 1 "$?"
mv "$tmp/owner_scope.bak" "$gdir/scripts/owner_scope.sh"

# Scope fails closed. Every case pushes a commit carrying a real email.
gpush() {  # <repo> <push url>: run the installed pre-push; echo its exit
  (cd "$1" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
    | GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$gdir/hooks/pre-push" x "$2" >"$tmp/out" 2>&1)
  echo $?
}
sc="$tmp/scope"; new_repo "$sc"; gc -C "$sc" commit -q --allow-empty -m "mail $real_email"
expect "lookalike host github.com.evil/<owner> is checked" 1 "$(gpush "$sc" https://github.com.evil/example-owner/x)"
grep -q "an email address" "$tmp/out" && ok "refused for the email, not for a setup gap" || error "lookalike: $(cat "$tmp/out")"
expect "https://host/@github.com/<owner> is checked" 1 "$(gpush "$sc" https://evil.example/@github.com/example-owner/x)"
expect "an owner-prefixed other account (<owner>-fork) is passed through" 0 "$(gpush "$sc" git@github.com:example-owner-fork/x.git)"
expect "no remote, push to another org: passed through" 0 "$(gpush "$sc" git@github.com:other-org/x.git)"
expect "no remote, push to the owner: checked" 1 "$(gpush "$sc" https://github.com/EXAMPLE-OWNER/x)"
git -C "$sc" remote add origin git@github.com:other-org/x.git
git -C "$sc" remote add mine https://github.com/example-owner/x.git
expect "a second remote under the owner puts the repo in scope" 1 "$(gpush "$sc" git@github.com:other-org/x.git)"
git -C "$sc" remote remove mine
git -C "$sc" remote set-url --push origin https://gitlab.example/example-owner/x
expect "an owner-looking push URL on another host is checked" 1 "$(gpush "$sc" git@github.com:other-org/x.git)"
git -C "$sc" remote remove origin

bash "$SETUP" --global --uninstall >/dev/null 2>&1
git config --global --get core.hooksPath >/dev/null && error "uninstall did not unset a previously unset value" || ok "uninstall unsets a value that was unset before"

# ------------------------------------------------------------ owner_scope.sh
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/owner_scope.sh"
for u in git@github.com:Example-Owner/x git@github.com:example-owner/x.git ssh://git@github.com/EXAMPLE-OWNER/x.git \
         ssh://git@github.com:22/example-owner/x https://github.com/example-owner/x/ https://tok@github.com/example-owner/x.git \
         github.com/example-owner/x example-owner/x https://github.com.evil/example-owner/x git://github.com/example-owner/x \
         ssh://github.com/example-owner/x https://evil.example/@github.com/example-owner/x; do
  scope_in_scope example-owner "$u" && ok "scope: $u checked" || error "scope: $u passed through"
done
for u in git@github.com:example-owner-fork/x git@github.com:other-org/example-owner https://github.com/other-org/x.git /srv/mirror.git; do
  scope_in_scope example-owner "$u" && error "scope: $u checked" || ok "scope: $u passed through"
done
# insteadOf and pushurl are what git really talks to; scope reads them expanded.
sr="$tmp/sr"; new_repo "$sr"
git -C "$sr" remote add origin gh:other-org/x
git -C "$sr" config url.git@github.com:example-owner/.insteadOf gh:other-org/
urls_out="$(cd "$sr" && scope_repo_urls)"   # captured: grep -q in a pipe trips pipefail
grep -q "git@github.com:example-owner/x" <<<"$urls_out" && ok "scope: insteadOf is expanded" || error "scope: insteadOf not expanded"
git -C "$sr" config --unset url.git@github.com:example-owner/.insteadOf
git -C "$sr" remote set-url origin git@github.com:other-org/x
git -C "$sr" remote set-url --push origin git@github.com:example-owner/x
urls_out="$(cd "$sr" && scope_repo_urls)"
grep -q 'example-owner' <<<"$urls_out" && ok "scope: a pushurl is read" || error "scope: pushurl ignored"
SCRIPT_HELPERS_OWNERS=example-owner scope_owners 2>"$tmp/out" >/dev/null
grep -q "owners from SCRIPT_HELPERS_OWNERS" "$tmp/out" && ok "an owners override from the environment is announced" || error "SCRIPT_HELPERS_OWNERS silent"

# ------------------------------------------------- Claude Code PreToolUse hook
CLAUDE_HOOK="$ROOT_DIR/scripts/claude-hooks/pretooluse_private_names.sh"
if command -v python3 >/dev/null 2>&1; then
  git config --global script-helpers.owners example-owner
  printf 'private\tns\tzzq-private-thing\t-\t\n' > "$tmp/names.tsv"
  export PRIVATE_NAMES_FILE="$tmp/names.tsv"
  payload() { printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R %s --title t --body \\"mail %s\\""}}' "$1" "$2"; }
  payload example-owner/x "$real_email" | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook refuses PII in an owner repo's PR body" 2 "$?"
  payload other-org/x "$real_email" | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook leaves another org's PR body alone" 0 "$?"
  if [[ "$have_gitleaks" == true ]]; then
    payload example-owner/x "a@example.com" | bash "$CLAUDE_HOOK" >/dev/null 2>&1
    expect "Claude hook passes a clean body" 0 "$?"
  fi
  payload example-owner/x "a@example.com" | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook blocks a body it could not scan for credentials" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --title t --body \\"mail %s\\""}}' "$real_email" \
    | GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: no -R and no repository here -> checked, not passed" 2 "$?"
  payload other-org/x "$real_email" | SENSITIVE_MACHINE_IDS_FILE="$tmp/missing-ids" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: a clean -R to another org decides, even outside a repository" 0 "$?"
  payload example-owner/x "a@example.com" | SENSITIVE_MACHINE_IDS_FILE="$tmp/missing-ids" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "Claude hook blocks when the checker fails" 2 "$?"
  grep -q "NOT checked" "$tmp/out" && ok "and says the text was not checked" || error "no reason: $(cat "$tmp/out")"
  payload example-owner/x "a@example.com" | SENSITIVE_MACHINE_IDS_FILE="$tmp/missing-ids" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "SECURITY_GATE_ALLOW_UNCHECKED=1 lets the Claude hook allow it" 0 "$?"
  unset PRIVATE_NAMES_FILE
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R example-owner/x --title t --body ok"}}' \
    | PRIVATE_NAMES_FILE="$tmp/no-list" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook blocks when the private-name list is missing" 2 "$?"
  export PRIVATE_NAMES_FILE="$tmp/names.tsv"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R example-owner/x --title t --body-file -"}}' \
    | bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "Claude hook blocks a body read from stdin (it cannot see it)" 2 "$?"
  printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R example-owner/x --title t --body-file /nonexistent/body.md"}}' \
    | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook blocks an unreadable body file" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R example-owner/x --body \\"mail %s \x27"}}' "$real_email" \
    | GITLEAKS_BIN="$tmp/none" SECURITY_GATE_ALLOW_UNCHECKED=1 bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an unparsable publishing command with an email is blocked" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"python3 -c \\"print(\x27%s\\""}}' "$real_email" \
    | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an unparsable non-publishing command passes" 0 "$?"
  printf 'not json: gh pr create --body x' | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an invalid payload that publishes is blocked" 2 "$?"
  printf 'not json: ls -la' | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an invalid payload that does not publish passes" 0 "$?"
  # A crash inside the hook must refuse (exit 2), never exit 1: Claude Code
  # runs the command on any exit other than 2.
  mkdir -p "$tmp/broken/claude-hooks"
  cp "$CLAUDE_HOOK" "$tmp/broken/claude-hooks/"
  cp "$ROOT_DIR/scripts/check_private_names.sh" "$ROOT_DIR/scripts/check_sensitive.sh" "$tmp/broken/"
  cp -R "$ROOT_DIR/lib" "$ROOT_DIR/helpers.sh" "$tmp/" 2>/dev/null
  printf 'echo crashing >&2; exit 3\n' > "$tmp/broken/owner_scope.sh"
  payload example-owner/x "a@example.com" | PRIVATE_NAMES_FILE="$tmp/names.tsv" bash "$tmp/broken/claude-hooks/pretooluse_private_names.sh" >"$tmp/out" 2>&1
  expect "Claude hook: a crash refuses with exit 2" 2 "$?"
  unset PRIVATE_NAMES_FILE
else
  note "SKIP: python3 missing; Claude hook cases not run"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "[security_gate_test] $failures failure(s)" >&2
  exit 1
fi
echo "[security_gate_test] all passed"
