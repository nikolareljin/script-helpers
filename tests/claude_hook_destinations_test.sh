#!/usr/bin/env bash
# SCRIPT: claude_hook_destinations_test.sh
# DESCRIPTION: The Claude hook judges private names by where a command publishes, and answers fast.
# USAGE: ./tests/claude_hook_destinations_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/claude_hook_destinations_test.sh
# ----------------------------------------------------
#
# Fixture repositories with placeholder names: zzqsecretbox is private,
# zzqopenbox is public. The cases are the false positives seen live (work
# inside a private repository refused) and the blocks that must stay. CLAUDE_HOOK
# may point at another copy of the hook, to show which cases an older one fails.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
HOOK="${CLAUDE_HOOK:-$root_dir/scripts/claude-hooks/pretooluse_private_names.sh}"
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

failures=0
note()  { echo "[claude_hook_destinations_test] $*"; }
error() { echo "[claude_hook_destinations_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(sys.version_info[0] != 3)' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then note "SKIP: no Python 3"; exit 0; fi

export HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_CACHE_HOME="$tmp/cache" \
       GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
       GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com \
       GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
unset SCRIPT_HELPERS_OWNERS 2>/dev/null || true
mkdir -p "$HOME" "$tmp/bin" "$tmp/plain"
: > "$GIT_CONFIG_GLOBAL"
# Out of any repository: git config would otherwise read this checkout.
cd "$tmp" || exit 1
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/gitleaks"; chmod +x "$tmp/bin/gitleaks"
: > "$tmp/no-machine-ids"; : > "$tmp/no-terms"

list="$tmp/names.tsv"
{ printf '# generated: 2026-10-11 source: test\n'
  printf '# visibility\tnamespace\tname\tcode\tflags\n'
  printf 'private\texample\tzzqsecretbox\tR-901\t\n'
  printf 'public\texample\tzzqopenbox\tR-902\t\n'; } > "$list"

priv="$tmp/zzqsecretbox"; pub="$tmp/zzqopenbox"
for r in "$priv" "$pub"; do
  git init -q "$r" && git -C "$r" commit -q --allow-empty -m init
  git -C "$r" remote add origin "git@github.com:example/$(basename "$r").git"
done

git config --global script-helpers.owners example
# A private repository with a second, public remote, and one of another owner.
# A symlink inside the private repository that points into the public one.
printf 'x\n' > "$pub/notes.md"; ln -s "$pub/notes.md" "$priv/zzqsecretbox-link"
priv2="$tmp/zzqsecretbox-two"; other="$tmp/zzqsecretbox-other"
git init -q "$priv2" && git -C "$priv2" commit -q --allow-empty -m init
git -C "$priv2" remote add origin git@github.com:example/zzqsecretbox.git
git -C "$priv2" remote add mirror git@github.com:example/zzqopenbox.git
git init -q "$other" && git -C "$other" commit -q --allow-empty -m init
git -C "$other" remote add origin git@github.com:someone-else/zzqsecretbox.git

# hook <want> <description> <cwd> <command> [names list]
# The payload carries cwd as Claude Code sends it; PAYLOAD_CWD overrides it
# ("-" leaves it out).
hook() {
  local want="$1" desc="$2" cwd="$3" cmd="$4" names="${5:-$list}" got
  "$PY" -c 'import json,sys
d = {"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}
if sys.argv[2] != "-":
    d["cwd"] = sys.argv[2]
print(json.dumps(d))' "$cmd" "${PAYLOAD_CWD:-$cwd}" > "$tmp/payload"
  ( cd "$cwd" && PATH="$tmp/bin:$PATH" PRIVATE_NAMES_FILE="$names" SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" \
      SENSITIVE_TERMS_FILE="$tmp/no-terms" bash "$HOOK" < "$tmp/payload" > "$tmp/out" 2>&1 )
  got=$?
  [[ "$got" == "$want" ]] && ok "$desc" || error "$desc: exit $got, want $want: $(head -c 400 "$tmp/out")"
}

# Inside a private repository of an owner, whose every remote is private, the
# name is its own business, for a closed list of plain commands. The same
# forms are checked when the repository has one public remote.
n=zzqsecretbox
for v in "git status" \
         "git log --oneline -5 --grep=$n" \
         "git show HEAD:$n.md" \
         "git diff HEAD -- $n.md" \
         "git branch -a" \
         "git blame README" \
         "git rev-parse HEAD" \
         "git ls-files $n" \
         "echo $n" \
         "printf '%s' $n" \
         "grep -rn $n docs" \
         "cat ./docs/$n.md" \
         "ls $priv/$n" \
         "head -5 $n.txt" \
         "wc -l $n.txt"; do
  hook 0 "allowed in the private repository: [${v//$tmp/<tmp>}]" "$priv" "$v"
  v2="${v//$priv/$priv2}"
  [[ "$v2" == *"$n"* ]] && hook 2 "checked with one public remote: [${v2//$tmp/<tmp>}]" "$priv2" "$v2"
done
hook 2 "a private name of another owner" "$other" "git commit -m '$n'"
hook 0 "a pull request into the private repository itself (-R, as before)" "$tmp/plain" \
  "gh pr create -R example/zzqsecretbox --body 'zzqsecretbox internals'"
# Everything else is checked, as before this change.
hook 2 "a plain directory (cd into the repository first; cwd persists)" "$tmp/plain" "echo $n"
hook 2 "a public repository" "$pub" "echo $n"
hook 2 "a pull request into an unlisted repository" "$tmp/plain" "gh pr create -R example/elsewhere --body 'see $n'"
hook 2 "gh without -R outside a repository" "$tmp/plain" "gh issue create --body '$n'"
hook 2 "-R on a command that is not gh is not a repository" "$tmp/plain" "ls -R $n"
hook 2 "curl to github" "$tmp/plain" "curl -d '$n' https://api.github.com/repos/example/zzqopenbox/issues"

# From inside the private repository, anything outside the allowlist is
# checked. Each of these blocks.
for v in "git commit -m $n" \
         "git add $n.md" \
         "git add -p $n.md" \
         "git checkout $n" \
         "git switch $n" \
         "git restore $n.md" \
         "git stash list $n" \
         "git grep $n" \
         "git branch -m $n" \
         "git branch --edit-description $n" \
         "git log --output=$n.txt" \
         "git diff --ext-diff $n" \
         "git log --textconv $n" \
         "git diff -Oorder $n" \
         "git log -x $n" \
         "sed -n p $n.md" \
         "grep -R $n docs" \
         "grep --dereference-recursive $n docs" \
         "cat $n-link" \
         "cd $pub && git commit -m $n" \
         "cd $pub/$n" \
         "c''d $pub; git commit -m $n" \
         "pushd $pub && git commit -m $n" \
         "git -C $pub commit -m $n" \
         "git -c core.editor=true commit -m $n" \
         "git --git-dir=$pub/.git commit -m $n" \
         "git --work-tree=$pub commit -m $n" \
         "GIT_DIR=$pub/.git git commit -m $n" \
         "(git commit -m $n)" \
         "{ git commit -m $n; }" \
         "git commit -m \"\$N $n\"" \
         "git commit -m \$(echo $n)" \
         "git commit -m \`echo $n\`" \
         "git commit -m $n &" \
         "git commit -F - <<< $n" \
         "git commit -m $n
git push" \
         "git push origin $n" \
         "git push https://example.invalid/x.git $n" \
         "git remote add $n git@github.com:example/zzqopenbox.git" \
         "git config remote.origin.url https://github.com/example/zzqopenbox $n" \
         "git fetch $n" \
         "git worktree add ../$n" \
         "git send-email $n" \
         "git stash push -m $n" \
         "git diff --output=$pub/$n.txt" \
         "git grep -O $n" \
         "git log --ext-diff $n" \
         "git commit -F $pub/$n.md" \
         "git show HEAD:$n --output=../$n" \
         "gh pr create -R example/zzqopenbox --body $n" \
         "gh api repos/example/zzqopenbox/issues -f body=$n" \
         "bash -c 'git commit -m $n'" \
         "sed -n 'w $pub/$n' README" \
         "env git commit -m $n" \
         "exec git commit -m $n" \
         "echo $n > $pub/notes.md" \
         "cat $pub/$n.md" \
         "cat ../zzqopenbox/$n.md" \
         "ls ~/$n" \
         "cp README $pub/$n.md" \
         "curl -d $n https://example.invalid/x"; do
  hook 2 "strict: [${v//$tmp/<tmp>}]" "$priv" "$v"
done
PAYLOAD_CWD=- hook 2 "strict: no cwd in the payload" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD=relative/dir hook 2 "strict: a relative cwd" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD="$pub" hook 2 "strict: the payload cwd decides, not the process cwd" "$priv" "git commit -m $n"
# Sensitive data is never relaxed by the destination.
hook 2 "sensitive: PII in a commit inside the private repository is refused" "$tmp/plain" \
  "cd $priv && git commit -m 'mail jane.roe""@""mailbox.org'"

# The relaxation has one switch. Off, an allowed form is checked again.
off="$tmp/switch-off"; mkdir -p "$off"
cp -R "$root_dir/scripts" "$root_dir/lib" "$root_dir/helpers.sh" "$off/"
"$PY" -c 'import sys
p = sys.argv[1]; s = open(p).read()
assert "RELAX_PRIVATE_NAMES = True" in s
open(p, "w").write(s.replace("RELAX_PRIVATE_NAMES = True", "RELAX_PRIVATE_NAMES = False", 1))' \
  "$off/scripts/claude-hooks/pretooluse_private_names.sh"
saved_hook="$HOOK"; HOOK="$off/scripts/claude-hooks/pretooluse_private_names.sh"
hook 2 "RELAX_PRIVATE_NAMES = False: echo naming it is checked in the private repository" "$priv" "echo $n"
HOOK="$saved_hook"

# A refusal is exit 2 with the reason on stderr, and a deny decision on stdout.
"$PY" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"echo zzqsecretbox"}}))' "$pub" > "$tmp/payload"
( cd "$pub" && PATH="$tmp/bin:$PATH" PRIVATE_NAMES_FILE="$list" SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" \
    SENSITIVE_TERMS_FILE="$tmp/no-terms" bash "$HOOK" < "$tmp/payload" > "$tmp/stdout" 2> "$tmp/stderr" ); rc=$?
if [[ "$rc" == 2 ]] && grep -q 'private repository' "$tmp/stderr" \
   && "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1]))["hookSpecificOutput"]; sys.exit(0 if d["permissionDecision"]=="deny" and "private repository" in d["permissionDecisionReason"] else 1)' "$tmp/stdout"; then
  ok "a refusal: exit 2, reason on stderr, deny JSON on stdout"
else
  error "refusal output: rc=$rc stdout=$(cat "$tmp/stdout")"
fi

# Latency: a hit against 5,000 names. A timeout lets the command run, so the
# hook has to be well inside its 60 s; the old per-name grep took 14 s.
big="$tmp/big.tsv"
{ printf '# generated: 2026-10-11 source: test\n'; printf '# visibility\tnamespace\tname\tcode\tflags\n'
  awk 'BEGIN { for (i = 1; i <= 5000; i++) printf "private\texample\tzzqfixture%04d\tR-%04d\t\n", i, i }'; } > "$big"
now_ms() { "$PY" -c 'import time; print(int(time.time() * 1000))'; }
t0="$(now_ms)"
hook 2 "a hit against 5,000 names is refused" "$pub" "gh pr create --body 'see zzqfixture4999'" "$big"
t1="$(now_ms)"
ms=$((t1 - t0))
[[ "$ms" -lt 2000 ]] && ok "the hit took $ms ms (< 2000)" || error "the hit took $ms ms, want < 2000"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
