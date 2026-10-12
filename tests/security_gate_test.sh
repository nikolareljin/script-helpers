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
  if [[ "$2" == "$3" ]]; then ok "$1"; return 0; fi
  error "$1: want exit $2, got $3"
  [[ -f "$tmp/out" ]] && sed 's/^/    | /' "$tmp/out" | tail -20 >&2
}

# Hermetic: no real config, terms, cache or identity of this machine.
export HOME="$tmp/home"
mkdir -p "$HOME"
cd "$tmp" || exit 1
export XDG_CONFIG_HOME="$HOME/.config" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
# On Windows (Git Bash) setup-hooks.sh keeps its copies under %LOCALAPPDATA%.
export LOCALAPPDATA="$XDG_DATA_HOME"
# native <path>: the form git stores a path in (C:/... under Git for Windows).
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
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
  # Nor a committed .gitleaksignore listing the leak's own fingerprint.
  commit_file "$repo" creds3.txt "aws_access_key_id = $aws_key
aws_secret_access_key = $aws_secret"
  run --repo "$repo" --range HEAD~1..HEAD --no-machine >/dev/null
  sed -n 's/.*Fingerprint: *//p' "$tmp/out" > "$repo/.gitleaksignore"
  gc -C "$repo" add .gitleaksignore; gc -C "$repo" commit -q -m "ignore it"
  expect "a committed .gitleaksignore cannot allow its own key" 1 "$(run --repo "$repo" --range HEAD~2..HEAD --no-machine)"
  cp "$repo/.gitleaksignore" "$repo/.git/gitleaksignore"
  expect "a local .git/gitleaksignore does allow it" 0 "$(run --repo "$repo" --range HEAD~2..HEAD --no-machine)"
  rm -f "$repo/.git/gitleaksignore"
  gc -C "$repo" rm -q creds3.txt .gitleaksignore; gc -C "$repo" commit -q -m "remove it"
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

# gitleaks sees the index git hands a hook: GIT_INDEX_FILE=.git/index, relative.
# The stand-in reports a finding only if the staged file is visible from where
# it runs, as the real gitleaks reads it.
printf '#!/usr/bin/env bash\nr=""; while [[ $# -gt 0 ]]; do [[ "$1" == --report-path ]] && r="$2"; shift; done\ngit diff --cached --name-only | grep -q idx.txt || exit 0\nprintf %s "[{\\"RuleID\\": \\"x\\"}]" > "$r"; exit 1\n' > "$tmp/gl-index"; chmod +x "$tmp/gl-index"
printf 'clean\n' > "$repo/idx.txt"; gc -C "$repo" add idx.txt
(cd "$repo" && GIT_INDEX_FILE=.git/index GITLEAKS_BIN="$tmp/gl-index" bash "$CHECK" --staged --no-machine >/dev/null 2>&1)
expect "--staged under a hook's relative GIT_INDEX_FILE: gitleaks sees the staged file" 1 "$?"
gc -C "$repo" rm -q --cached idx.txt; rm -f "$repo/idx.txt"

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

# A rename re-adds nothing: the file is already where it was going.
commit_file "$repo" moved.md "Write to $real_email"
gc -C "$repo" mv moved.md moved2.md; gc -C "$repo" commit -q -m "rename"
expect "a rename-only commit passes" 0 "$(run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks)"
gc -C "$repo" rm -q moved2.md; gc -C "$repo" commit -q -m "drop it"

# A merge commit's own lines (a conflict resolution) are checked.
mbase="$(gc -C "$repo" rev-parse HEAD)"
gc -C "$repo" checkout -q -b side
commit_file "$repo" conflict.md "side"
gc -C "$repo" checkout -q -
commit_file "$repo" conflict.md "main"
gc -C "$repo" merge -q side >/dev/null 2>&1
printf 'resolved by %s\n' "$real_email" > "$repo/conflict.md"
gc -C "$repo" add conflict.md; gc -C "$repo" commit -q --no-edit
expect "a line added by the merge commit itself blocks" 1 "$(run --repo "$repo" --range "$mbase..HEAD" --no-gitleaks)"
grep -q "conflict.md:1: an email" "$tmp/out" || error "the merge line was not named: $(cat "$tmp/out")"
gc -C "$repo" reset -q --hard "$mbase"; gc -C "$repo" branch -q -D side

# A binary file cannot be read line by line; that is said, not silent.
printf 'a\000b\n' > "$repo/blob.bin"; gc -C "$repo" add blob.bin; gc -C "$repo" commit -q -m blob
run --repo "$repo" --range HEAD~1..HEAD --no-gitleaks >/dev/null
grep -q "binary file not checked" "$tmp/out" && ok "a binary file is named as not checked" || error "binary file skipped silently: $(cat "$tmp/out")"

# An annotated tag's message is published with the tag.
gc -C "$repo" tag -a v9 -m "release by $real_email"
printf 'refs/tags/v9 %s refs/tags/v9 %s\n' "$(gc -C "$repo" rev-parse v9)" 0000000000000000000000000000000000000000 > "$tmp/tag-ref"
expect "an annotated tag message with an email blocks" 1 "$(run --repo "$repo" --push-refs "$tmp/tag-ref" --no-gitleaks)"
grep -q "BLOCK tag " "$tmp/out" || error "the tag message was not named: $(cat "$tmp/out")"
gc -C "$repo" tag -d v9 >/dev/null
# The private-name step reads the same tag messages (sec_tag_messages).
gc -C "$repo" tag -a v9 -m "outer note"
gc -C "$repo" tag -a v9b -m "inner note" v9 >/dev/null 2>&1
printf 'refs/tags/v9b %s refs/tags/v9b %s\n' "$(gc -C "$repo" rev-parse v9b)" 0000000000000000000000000000000000000000 > "$tmp/tag-ref"
got="$(cd "$repo" && source "$ROOT_DIR/scripts/security_hooks.sh" && sec_tag_messages "$tmp/tag-ref")"
[[ "$got" == *"outer note"* && "$got" == *"inner note"* ]] && ok "sec_tag_messages reads every level of a tag of a tag" || error "tag messages: '$got'"
gc -C "$repo" tag -d v9 v9b >/dev/null

# --no-inline-allow: a marker written by the author being checked is ignored.
printf 'mail %s sensitive:allow\n' "$real_email" > "$tmp/marked.txt"
expect "sensitive:allow lets a line through" 0 "$(run --file "$tmp/marked.txt" --no-gitleaks)"
expect "--no-inline-allow ignores it" 1 "$(run --file "$tmp/marked.txt" --no-gitleaks --no-inline-allow)"

# ------------------------------------------------ shared pre-push (repo mode)
# A repository that vendors script-helpers at scripts/script-helpers.
vend="$tmp/vend"; new_repo "$vend"
mkdir -p "$vend/scripts/script-helpers"
cp -R "$ROOT_DIR/scripts" "$ROOT_DIR/lib" "$ROOT_DIR/helpers.sh" "$vend/scripts/script-helpers/"
# preflight.sh is not under test here and detects stacks from the host's tools.
rm -f "$vend/scripts/script-helpers/scripts/preflight.sh"
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

# A hooks copy without security_hooks.sh still hands over to the repo's own
# commit-msg hook: the missing library skips the checks, not the repository.
lone="$tmp/lone"; new_repo "$lone"
mkdir -p "$lone/hooks-only" "$lone/.githooks"
cp "$ROOT_DIR/scripts/git-hooks/commit-msg" "$lone/hooks-only/"
printf '#!/usr/bin/env bash\necho local-commit-msg-ran\nexit 5\n' > "$lone/.githooks/commit-msg"
printf 'msg\n' > "$tmp/lone-msg"
(cd "$lone" && bash hooks-only/commit-msg "$tmp/lone-msg" >"$tmp/out" 2>&1)
expect "commit-msg without its library still runs .githooks/commit-msg" 5 "$?"

# ---------------------------------------------------------- --global install
SETUP="$ROOT_DIR/scripts/setup-hooks.sh"
gdir="$XDG_DATA_HOME/script-helpers/git-hooks"
mkdir -p "$tmp/earlier-hooks"
printf '#!/usr/bin/env bash\necho ran >> "%s/earlier-hook"\nexit 0\n' "$tmp" > "$tmp/earlier-hooks/pre-commit"
chmod +x "$tmp/earlier-hooks/pre-commit"
git config --global core.hooksPath "$tmp/earlier-hooks"
bash "$SETUP" --global >"$tmp/out" 2>&1
expect "--global refuses without owners" 2 "$?"
[[ "$(git config --global core.hooksPath)" == "$(native "$tmp/earlier-hooks")" ]] && ok "and changes nothing" || error "hooksPath changed without owners"

git config --global script-helpers.owners "example-owner,Second-Org"
bash "$SETUP" --global >"$tmp/out" 2>&1
expect "--global installs once owners are set" 0 "$?"
grep -qF "current global core.hooksPath: $(native "$tmp/earlier-hooks")" "$tmp/out" || error "the previous value was not shown"
[[ "$(git config --global core.hooksPath)" == "$(native "$gdir/hooks")" ]] && ok "global core.hooksPath points at the install" || error "hooksPath: $(git config --global core.hooksPath)"
[[ -f "$gdir/scripts/check_sensitive.sh" && -f "$gdir/lib/logging.sh" ]] && ok "the install carries its own check scripts" || error "check scripts not copied"
bash "$SETUP" --global >/dev/null 2>&1
[[ "$(cat "$gdir/previous-hooksPath")" == "$(native "$tmp/earlier-hooks")" ]] && ok "a second --global keeps the original backup" || error "backup overwritten: $(cat "$gdir/previous-hooksPath")"
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
[[ "$(git config --global core.hooksPath)" == "$(native "$tmp/earlier-hooks")" ]] && ok "restores the previous global value" || error "not restored: $(git config --global core.hooksPath || echo unset)"
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
REAL_CLAUDE_HOOK="$ROOT_DIR/scripts/claude-hooks/pretooluse_private_names.sh"
# The hook acts only when the session's repository (payload cwd) has its
# origin under an owner. Payloads here that carry no cwd run in such a
# repository; a payload with its own cwd keeps it.
owner_cwd="$tmp/owner-session"
git init -q "$owner_cwd" && git -C "$owner_cwd" remote add origin git@github.com:example-owner/session.git
CLAUDE_HOOK="$tmp/claude-hook-with-cwd.sh"
# inject_cwd: add "cwd" to a payload that starts with { and has none.
inject_cwd() { LC_ALL=C sed '1{/"cwd"/!s|^{|{"cwd":"'"$owner_cwd"'",|;}'; }
cat > "$CLAUDE_HOOK" <<EOF_WRAP
#!/usr/bin/env bash
LC_ALL=C sed '1{/"cwd"/!s|^{|{"cwd":"$owner_cwd",|;}' | bash "$REAL_CLAUDE_HOOK"
EOF_WRAP
if command -v python3 >/dev/null 2>&1; then
  # Every call is scanned, so without gitleaks every call would be "could not
  # check". A stub that finds nothing keeps these cases about the hook; the
  # cases about a missing gitleaks set GITLEAKS_BIN themselves.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/gl-clean"; chmod +x "$tmp/gl-clean"
  export GITLEAKS_BIN="$tmp/gl-clean"
  printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: without gitleaks even an ordinary command is refused (fail closed)" 2 "$?"
  git config --global script-helpers.owners example-owner
  printf 'private\tns\tzzq-private-thing\t-\t\n' > "$tmp/names.tsv"
  export PRIVATE_NAMES_FILE="$tmp/names.tsv"
  payload() { printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create -R %s --title t --body \\"mail %s\\""}}' "$1" "$2"; }
  payload example-owner/x "$real_email" | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook refuses PII in an owner repo's PR body" 2 "$?"
  payload other-org/x "$real_email" | GITLEAKS_BIN="$tmp/none" bash "$CLAUDE_HOOK" >/dev/null 2>&1
  # -R can name any repository, so it never takes a command out of scope.
  expect "Claude hook checks a PR body sent with -R to another org" 2 "$?"
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
  expect "Claude hook: -R to another org does not skip the check outside a repository" 2 "$?"
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
  expect "Claude hook: every command is scanned, an unparsable one with an email too" 2 "$?"
  printf 'not json: gh pr create --body x' | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  # No cwd can be read from it, so the session repository is unknown: out of
  # scope by the owner's rule.
  expect "Claude hook: a payload with no readable cwd is out of scope" 0 "$?"
  printf '{not json: gh pr create --body x' | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an invalid payload that publishes, in an owner repository, is blocked" 2 "$?"
  printf 'not json: ls -la' | bash "$CLAUDE_HOOK" >/dev/null 2>&1
  expect "Claude hook: an invalid payload that does not publish passes" 0 "$?"
  # A crash inside the hook must refuse (exit 2), never exit 1: Claude Code
  # runs the command on any exit other than 2.
  mkdir -p "$tmp/broken/claude-hooks"
  cp "$REAL_CLAUDE_HOOK" "$tmp/broken/claude-hooks/"
  cp "$ROOT_DIR/scripts/check_private_names.sh" "$ROOT_DIR/scripts/check_sensitive.sh" "$tmp/broken/"
  cp -R "$ROOT_DIR/lib" "$ROOT_DIR/helpers.sh" "$tmp/" 2>/dev/null
  printf 'echo crashing >&2; exit 3\n' > "$tmp/broken/owner_scope.sh"
  payload example-owner/x "a@example.com" | inject_cwd | PRIVATE_NAMES_FILE="$tmp/names.tsv" bash "$tmp/broken/claude-hooks/pretooluse_private_names.sh" >"$tmp/out" 2>&1
  expect "Claude hook: a crash refuses with exit 2" 2 "$?"
  # Wrapped and attached forms still publish. A stub gitleaks keeps these
  # about the parsing, with or without a real one installed.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/gl-clean"; chmod +x "$tmp/gl-clean"
  hook_cmd() {  # <description> <command>
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$2" \
      | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
    expect "$1" 2 "$?"
  }
  printf 'body %s\n' "$real_email" > "$tmp/field-body.md"
  hook_cmd "Claude hook: VAR=value before gh is seen"     "GH_TOKEN=x gh pr create -R example-owner/x --body 'mail $real_email'"
  hook_cmd "Claude hook: env before gh is seen"           "env -i GH_TOKEN=x gh pr create -R example-owner/x --body 'mail $real_email'"
  hook_cmd "Claude hook: git -C <dir> commit is seen"     "git -C /tmp commit -m 'mail $real_email'"
  hook_cmd "Claude hook: git -c k=v commit is seen"       "git -c core.pager=cat commit -m 'mail $real_email'"
  hook_cmd "Claude hook: an attached -b value is read"    "gh pr create -R example-owner/x -t t -b'mail $real_email'"
  hook_cmd "Claude hook: an attached -m value is read"    "git commit -m'mail $real_email'"
  hook_cmd "Claude hook: gh api --raw-field is read"      "gh api repos/example-owner/x/issues --raw-field body='mail $real_email'"
  hook_cmd "Claude hook: gh api -F key=value is read"     "gh api repos/example-owner/x/issues -F body='mail $real_email'"
  hook_cmd "Claude hook: gh api -F key=@file is read"     "gh api repos/example-owner/x/issues -F body=@$tmp/field-body.md"
  hook_cmd "Claude hook: git tag -m is published text"    "git tag -a v1 -m 'mail $real_email'"
  hook_cmd "Claude hook: gh release --notes is read"      "gh release create v1 -R example-owner/x --notes 'mail $real_email'"
  hook_cmd "Claude hook: git commit -n is --no-verify"     "git commit -n -m 'msg'"
  hook_cmd "Claude hook: git commit -an is --no-verify"    "git commit -an -m 'msg'"
  # git takes any unambiguous prefix of a long option.
  hook_cmd "Claude hook: --no-verif is --no-verify"         "git commit --no-verif -m 'msg'"
  hook_cmd "Claude hook: --no-ver on push is --no-verify"   "git push --no-ver origin main"
  # Other git config sources drop the global core.hooksPath.
  hook_cmd "Claude hook: GIT_CONFIG_GLOBAL= is refused"     "GIT_CONFIG_GLOBAL=/dev/null git push"
  hook_cmd "Claude hook: GIT_CONFIG_NOSYSTEM is refused"    "GIT_CONFIG_NOSYSTEM=1 git push"
  hook_cmd "Claude hook: -c include.path is refused"        "git -c include.path=/tmp/x push"
  # A body read by command substitution is scanned like --body-file.
  hook_cmd "Claude hook: --body \"\$(cat file)\" is read"   "gh pr create -R example-owner/x --body \"\$(cat $tmp/field-body.md)\""
  hook_cmd "Claude hook: --body \"\$(<file)\" is read"      "gh pr create -R example-owner/x --body \"\$(<$tmp/field-body.md)\""
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "git commit -m -n -mrun" \
    | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  # The whole-command pass errs closed: a bare -n after commit is refused.
  expect "Claude hook: a bare -n after git commit is refused even as a value" 2 "$?"
  # Shapes the parser does not read: the broad pass checks the whole text.
  hook_rc() {  # <want> <description> <command>
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$3" \
      | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
    expect "$2" "$1" "$?"
  }
  for v in "git -C /tmp push" "env X=1 git push" "command git push" "\\git push" "GIT_DIR=.git git push" \
           "cd /tmp && git push" "bash -c 'git push'" "echo \$(git push)" "echo \`git push\`" "true; git push" "true | git push"; do
    hook_rc 2 "broad: $v --no-verify is refused" "$v --no-verify"
    hook_rc 0 "broad: $v alone is left to the git hooks" "$v"
  done
  hook_rc 2 "broad: git -c core.hooksPath=/dev/null push is refused" "git -c core.hooksPath=/dev/null push"
  hook_rc 2 "broad: GIT_CONFIG_COUNT hook override is refused" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/x git push"
  hook_rc 2 "broad: bash -c git commit -n is refused" "bash -c 'git commit -an -m x'"
  hook_rc 0 "broad: git commit -mrun is not -n" "git commit -mrun"
  for v in "bash -c \"gh pr create -R example-owner/x --body 'mail $real_email'\"" \
           "echo \$(gh pr comment 1 -R example-owner/x --body 'mail $real_email')" \
           "\\gh issue create -R example-owner/x --body 'mail $real_email'" \
           "gh issue comment 1 -R example-owner/x --body='mail $real_email'" \
           "gh release create v1 -R example-owner/x --notes 'mail $real_email'" \
           "gh api repos/example-owner/x/issues -f body='mail $real_email'" \
           "gh gist create -d 'mail $real_email'" \
           "curl -d '{\"body\":\"mail $real_email\"}' https://api.github.com/repos/example-owner/x/issues" \
           "x=1; gh pr create -R example-owner/x -b 'mail $real_email'"; do
    hook_rc 2 "broad: PII in [$v] is refused" "$v"
  done
  hook_rc 2 "broad: a body file named in bash -c is read" "bash -c 'gh pr create -R example-owner/x --body-file $tmp/field-body.md'"
  hook_rc 2 "broad: another org's -R is still checked" "bash -c \"gh pr create -R other-org/x --body 'mail $real_email'\""
  hook_rc 2 "broad: a cd target that cannot be entered is checked" "cd /nonexistent/dir && bash -c \"gh pr create --body 'mail $real_email'\""
  hook_rc 0 "broad: a clean publishing command passes" "bash -c \"gh pr create -R example-owner/x --body 'all fine'\""
  # Obfuscated or indirect command words next to a publishing verb.
  for v in "g''it push --no-verify" "\"git\" push --no-verify" "\$'git' push --no-verify" \
           "G=git; \$G push" "\${X:-git} push" "eval git push" "echo push | xargs git" \
           "source ./publish.sh push" ". ./publish.sh push"; do
    hook_rc 2 "obfuscated: [$v] is refused" "$v"
  done
  # Overrides come from the hook's environment only, never from the command.
  for v in "SECURITY_GATE_ALLOW_UNCHECKED=1 git push" "export SENSITIVE_ALLOW=x; git push" \
           "PRIVATE_NAMES_ALLOW=x gh pr create --body y" "HOME=/tmp/h git push" \
           "git config --global script-helpers.owners nobody" "git -c script-helpers.owners=x push" \
           "echo x >> .git/sensitive-allow" "rm ~/.config/script-helpers/sensitive-terms.txt" \
           "GITLEAKS_BIN=/bin/true git push"; do
    hook_rc 2 "override in the command: [$v] is refused" "$v"
  done
  # A here-document that only becomes a file is data: a test or a doc may
  # mention an override. Anything that runs the body is still refused.
  hook_rc 0 "heredoc: a body written to a file may mention HOME=" "cat > $tmp/hd-notes.md <<'EOF'
set HOME=/tmp/h and script-helpers.owners in the test
EOF"
  hook_rc 0 "heredoc: tee into a file, <<- form" "tee $tmp/hd-notes2.md <<-\"EOF\"
	export SENSITIVE_ALLOW=x is documented here
	EOF"
  hook_rc 2 "heredoc: an unquoted delimiter expands \$(...) in the body, so it is read" "cat > $tmp/hd-z.md <<EOF
\$(HOME=/tmp/h git push)
EOF"
  hook_rc 2 "heredoc: a body piped to bash is read" "cat <<'EOF' | bash
HOME=/tmp/h git push
EOF"
  hook_rc 2 "heredoc: a body fed to bash is read" "bash <<'EOF'
HOME=/tmp/h git push
EOF"
  hook_rc 2 "heredoc: a command after the body is read" "cat > $tmp/hd-x.md <<'EOF'
plain
EOF
HOME=/tmp/h git push"
  hook_rc 2 "heredoc: a body that never ends hides nothing after a chained command" "cat > $tmp/hd-y.md <<'EOF'; HOME=/tmp/h git push
EOF"
  hook_rc 2 "heredoc: a body fed to python is read" "python3 - <<'EOF'
import subprocess; subprocess.run('HOME=/tmp/h git push', shell=True)
EOF"
  # Every command is scanned, not only publishing ones.
  hook_rc 2 "any command: PII in plain echo is refused" "echo 'mail $real_email' > notes.txt"
  hook_rc 2 "any command: PII in a file read with < is refused" "wc -l < $tmp/field-body.md"
  hook_rc 0 "any command: an ordinary command passes" "ls -la /tmp && git status"
  hook_rc 0 "any command: reading the gate's variables is not setting them" "grep -n SENSITIVE_ALLOW scripts/check_sensitive.sh"
  # The cheap name test in front of check_private_names.sh is a superset.
  { printf '# generated: 2026-10-11 source: test\n'; printf '# visibility\tnamespace\tname\tcode\tflags\n'
    printf 'private\tns\tzzq-hidden-widget\tR-777\t\n'; } > "$tmp/names-hdr.tsv"
  # Run from a repository with no remote (unlisted, so public): an echo in a
  # directory that is not a repository has no destination and is not checked.
  new_repo "$tmp/prefilter-repo"
  for v in "echo zzq-hidden-widget" "echo ZZQ-HIDDEN-WIDGET" "gh pr create -R example-owner/x --body 'see zzq-hidden-widget'"; do
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$v" \
      | (cd "$tmp/prefilter-repo" && PRIVATE_NAMES_FILE="$tmp/names-hdr.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK") >"$tmp/out" 2>&1
    rc=$?
    # The full check decides; the prefilter must only let it run.
    grep -q "names a private repository\|R-777\|zzq" "$tmp/out" && ok "prefilter passes [$v] to the full check" || error "prefilter hid [$v]: rc=$rc $(cat "$tmp/out")"
  done
  # No path allows without a scan: other tools, invalid or non-UTF-8 input,
  # no python3.
  python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":"/tmp/x.md","content":sys.argv[1]}}))' "mail $real_email" \
    | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "fail-closed: a Write tool payload is scanned too" 2 "$?"
  printf 'not json at all: mail %s' "$real_email" | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "out of scope: invalid JSON with no cwd" 0 "$?"
  printf '{not json at all: mail %s' "$real_email" | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "fail-closed: invalid JSON in an owner repository is scanned raw" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"echo \xff\xfe mail %s"}}' "$real_email" \
    | PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "fail-closed: non-UTF-8 input is scanned raw" 2 "$?"
  hook_rc 0 "fail-closed: an empty command runs nothing and passes" ""
  hook_rc 2 "fail-closed: a very long command is scanned to its end" "echo $(printf 'x%.0s' $(seq 1 20000)) mail $real_email"
  # A PATH without python, made of symlinks. Where ln -s copies (Git Bash
  # without symlink support) that would copy every program on PATH: skipped.
  ln -s "$tmp" "$tmp/link-probe" 2>/dev/null
  if [[ -L "$tmp/link-probe" ]]; then
  mkdir -p "$tmp/nopy"
  for d in $(printf '%s' "$PATH" | tr ':' ' '); do
    for f in "$d"/*; do
      n="${f##*/}"; case "$n" in python3*|python) continue ;; esac
      [[ -e "$tmp/nopy/$n" ]] || ln -s "$f" "$tmp/nopy/$n" 2>/dev/null
    done
  done
  printf '{"tool_name":"Bash","tool_input":{"command":"echo mail %s"}}' "$real_email" \
    | PATH="$tmp/nopy" PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "fail-closed: without python3 the raw payload is scanned" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body ok"}}' \
    | PATH="$tmp/nopy" PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "fail-closed: without python3 a publishing command is refused" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
    | PATH="$tmp/nopy" PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1
  expect "without python3 a clean ordinary command passes" 0 "$?"
  else
    echo "[security_gate_test] SKIP: ln -s makes no symlink here; the no-python cases are not checked"
  fi
  hook_cmd "Claude hook: an agent's sensitive:allow is ignored" "gh pr create -R example-owner/x --body 'mail $real_email sensitive:allow'"
  # Scope follows where the command runs, not only the session's directory.
  other="$tmp/other-org-clone"; new_repo "$other"
  git -C "$other" remote add origin git@github.com:other-org/x.git
  own="$tmp/owner-clone"; new_repo "$own"
  git -C "$own" remote add origin git@github.com:example-owner/x.git
  printf '{"tool_name":"Bash","tool_input":{"command":"cd %s && gh pr create --body \\"mail %s\\""}}' "$own" "$real_email" \
    | (cd "$other" && PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1)
  expect "Claude hook: cd into an owner repo from another org's is checked" 2 "$?"
  printf '{"tool_name":"Bash","tool_input":{"command":"git -C %s commit -m \\"mail %s\\""}}' "$own" "$real_email" \
    | (cd "$other" && PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1)
  expect "Claude hook: git -C <owner repo> from another org's is checked" 2 "$?"
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"gh pr create --body \\"mail %s\\""}}' "$other" "$real_email" \
    | (cd "$other" && PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1)
  expect "Claude hook: another org's repository (payload cwd) is still left alone" 0 "$?"
  # Without the payload cwd the scope cannot be trusted: checked.
  printf '{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \\"mail %s\\""}}' "$real_email" \
    | (cd "$other" && PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1)
  expect "Claude hook: another org's repository without a payload cwd is checked" 2 "$?"
  # Scope is the session's repository only: from another org's repository
  # nothing is checked, whatever the command names (owner decision).
  for v in "gh pr create -R example-owner/x --body 'mail $real_email'" \
           "gh api repos/example-owner/x/issues -f body='mail $real_email'" \
           "curl -d 'mail $real_email' https://example.invalid/x" \
           "cd .. && gh pr create --body 'mail $real_email'" \
           "git push git@github.com:example-owner/x.git && echo 'mail $real_email'" \
           "echo 'mail $real_email' > ../owner-repo/notes.md"; do
    python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[2],"tool_input":{"command":sys.argv[1]}}))' "$v" "$other" \
      | (cd "$other" && PRIVATE_NAMES_FILE="$tmp/names.tsv" GITLEAKS_BIN="$tmp/gl-clean" bash "$CLAUDE_HOOK" >"$tmp/out" 2>&1)
    expect "Claude hook: from another org's repository, [$v] is out of scope (owner decision)" 0 "$?"
  done
  unset PRIVATE_NAMES_FILE GITLEAKS_BIN
else
  note "SKIP: python3 missing; Claude hook cases not run"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "[security_gate_test] $failures failure(s)" >&2
  exit 1
fi
echo "[security_gate_test] all passed"
