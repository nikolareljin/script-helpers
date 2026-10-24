#!/usr/bin/env bash
# SCRIPT: claude_hook_destinations_test.sh
# DESCRIPTION: The Claude hook checks private names in every command, fails closed, and answers fast.
# USAGE: ./tests/claude_hook_destinations_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/claude_hook_destinations_test.sh
# ----------------------------------------------------
#
# Fixture repositories with placeholder names: zzqsecretbox is private,
# zzqopenbox is public. A command wholly inside a private repository may name
# private repositories; anything that can reach another place keeps the full
# check. Every bypass found in review is a case here. CLAUDE_HOOK
# may point at another copy of the hook, to show which cases an older one fails.
# ----------------------------------------------------
set -uo pipefail
# The hooks would download a missing gitleaks or foxguard; tests never do.
export SCRIPT_HELPERS_NO_AUTO_INSTALL=1

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
  printf 'public\texample\tzzqopenbox\tR-902\t\n'
  printf 'private\texample\tzzqotherbox\tR-903\t\n'; } > "$list"

priv="$tmp/zzqsecretbox"; pub="$tmp/zzqopenbox"
for r in "$priv" "$pub"; do
  git init -q "$r" && git -C "$r" commit -q --allow-empty -m init
  git -C "$r" remote add origin "git@github.com:example/$(basename "$r").git"
done

git config --global script-helpers.owners example
# A symlink inside the private repository that points into the public one.
printf 'x\n' > "$pub/notes.md"; ln -s "$pub/notes.md" "$priv/zzqsecretbox-link"
# A repository of another owner whose name is listed private.
other="$tmp/zzqsecretbox-other"
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

# Contained: inside a private repository whose every remote is listed private,
# a command that touches nothing outside it may name private repositories.
n=zzqsecretbox
for v in          "git log --oneline -5 --grep=$n" \
         "git show HEAD:$n.md" \
         "git diff HEAD -- $n.md" \
         "git ls-files $n" \
         "echo $n" \
         "printf '%s' $n" \
         "grep -rn $n docs" \
         "cat ./docs/$n.md" \
         "ls $priv/$n" \
         "head -5 $n.txt" \
         "wc -l $n.txt"; do
  hook 0 "contained in the private repository: [${v//$tmp/<tmp>}]" "$priv" "$v"
done
hook 0 "out of scope: another owner's repository is left alone" "$other" "git commit -m '$n'"
hook 0 "out of scope: another owner's repository, even naming an owner path" "$other" "echo $n > $pub/notes.md && gh pr create -R example/zzqopenbox --body $n"
hook 0 "a pull request into the private repository itself (-R, as before)" "$tmp/plain" \
  "gh pr create -R example/zzqsecretbox --body 'zzqsecretbox internals'"
# Everything else is checked, as before this change.
hook 0 "out of scope: a directory that is not a repository" "$tmp/plain" "echo $n > $pub/notes.md"
hook 2 "a public repository" "$pub" "echo $n"
hook 2 "a pull request into an unlisted repository" "$pub" "gh pr create -R example/elsewhere --body 'see $n'"
hook 2 "gh without -R" "$pub" "gh issue create --body '$n'"
hook 2 "-R on a command that is not gh" "$pub" "ls -R $n"
hook 2 "curl to github" "$pub" "curl -d '$n' https://api.github.com/repos/example/zzqopenbox/issues"

# A public repository checked out inside the private one.
git init -q "$priv/nested" && git -C "$priv/nested" remote add origin git@github.com:example/zzqopenbox.git
# Contained in the private repository: allowed.
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
         "git diff --ext-diff $n" \
         "git log --textconv $n" \
         "sed -n p $n.md" \
         "grep -R $n docs" \
         "grep --dereference-recursive $n docs" \
         "git commit -m $n &" \
         "git push origin $n" \
         "git stash push -m $n" \
         "git log --ext-diff $n" \
         "rg -in $n docs" \
         "sort -u --check $n.md" \
         "git push --force-with-lease origin $n"; do
  hook 0 "contained: [${v//$tmp/<tmp>}]" "$priv" "$v"
done
# Git Bash makes ln -s a copy unless native symlinks are on; a copy is contained.
if [[ -L "$priv/$n-link" ]]; then
  hook 2 "strict: a symlink out of the repository [cat $n-link]" "$priv" "cat $n-link"
else
  note "SKIP: ln -s made a copy here, so the symlink case cannot run"
fi
# From inside the private repository, anything that can reach another place
# keeps the full check. Each of these blocks.
for v in "cd $pub && git commit -m $n" \
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
         "git commit -F - <<< $n" \
         "git push https://example.invalid/x.git $n" \
         "git remote add $n git@github.com:example/zzqopenbox.git" \
         "git config remote.origin.url https://github.com/example/zzqopenbox $n" \
         "git fetch $n" \
         "git worktree add ../$n" \
         "git send-email $n" \
         "git diff --output=$pub/$n.txt" \
         "git grep -O $n" \
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
         "curl -d $n https://example.invalid/x" \
         "git log --output=$n.txt" \
         "git commit -m $n
git push" \
         "echo $n
nice gh issue create -R example/zzqopenbox --body $n" \
         "echo $n |& nice gh issue create -R example/zzqopenbox --body $n" \
         "git log -x $n" \
         "cd - && echo $n" \
         "cd -P $pub && echo $n" \
         "true && cd - && echo $n" \
         "true && cd zzqopenbox && echo $n" \
         "cd zzqopenbox && echo $n" \
         "sed 's/x/y/e' $n.md" \
         "sed -n 1p -i $n.md" \
         "sed -n 's/a/b/w out' $n.md" \
         "rg --pre ./run $n" \
         "sort --compress-program=./run $n.md" \
         "sort --compress=./run -S 64K $n.md" \
         "rg --hostname-bin=./run --hyperlink-format=default $n" \
         "rg -iz $n" \
         "git push --recurse-submodules=on-demand origin $n" \
         "git push --recurse=on-demand origin $n" \
         "git rebase -x ./run $n" \
         "git rebase --exec ./run $n" \
         "git fetch --upload-pack=./run origin $n" \
         "git push --receive-pack=./run origin $n" \
         "cp $n.md .git/hooks/pre-push" \
         "echo $n >> .git/config" \
         "git push; echo $n" \
         "git pull; echo $n" \
         "sort -o/tmp/zzq-out $n.md" \
         "cd ./nested && git commit -m $n" \
         "true && cd ./nested && git commit -m $n" \
         "echo $n > nested/x.md" \
         "git diff -Oorder $n" \
         "cd ~- && echo $n" \
         "true && cd ~+/../zzqopenbox && echo $n" \
         "cat ~root/$n" \
         "git fetch --up=./run origin $n" \
         "git push --rec=./run origin $n" \
         "git rebase --exe ./run $n" \
         "git log --outp=../zzqopenbox/$n" \
         "echo $n >~+/../zzqopenbox/x" \
         "echo $n >~-/x" \
         "git rebase -ix ./run $n" \
         "cp $n.md x{,/../../zzqopenbox/x}" \
         "echo $n >{~+,x}/../zzqopenbox/y" \
         "cp $n.md *-link" \
         "echo $n > docs/../../zzqopenbox/$n.md" \
         "gh issue create -Rexample/zzqopenbox --body $n" \
         "gh issue create --repo=example/zzqopenbox --body $n" \
         "gh gist create $n.md" \
         "gh repo create $n" \
         "gh release create $n" \
         "nice git commit -m $n" \
         "make $n" \
         "/usr/bin/git commit -m $n" \
         "sed -n 'e echo' $n.md" \
         "tee $n.md" \
         "git -P -C $pub log $n" \
         "git push $pub $n" \
         "git push --repo=https://example.invalid/x $n"; do
  hook 2 "strict: [${v//$tmp/<tmp>}]" "$priv" "$v"
done
# Also contained: another private repository named inside this one.
hook 0 "contained: another private repository named" "$priv" "echo zzqotherbox >> notes.md"
hook 0 "contained: an issue in the repository itself" "$priv" "gh issue create --body 'see $n and zzqotherbox'"
hook 0 "contained: -R the repository itself" "$priv" "gh pr create -R example/zzqsecretbox --body $n"
# A leading cd picks the repository, whatever the session is in.
hook 0 "contained: a leading cd into the private repository" "$pub" "cd $priv && git log --grep=$n"
hook 0 "contained: sed prints a line range" "$priv" "sed -n 1,5p $n.md"
hook 0 "contained: push to a named remote" "$priv" "git push origin $n"
hook 2 "a leading cd, then a path back out" "$pub" "cd $priv && cat ../zzqopenbox/$n.md"
hook 2 "a leading cd, then a second cd out" "$pub" "cd $priv && cd $pub && echo $n"
hook 2 "a command in the session repository before the cd" "$pub" "echo $n; cd $priv"
# A cd that may not move the next command: a subshell, or a command run when it failed.
for v in "cd $priv | gh issue create --body $n" \
         "cd $priv & gh issue create --body $n" \
         "cd $priv || gh issue create --body $n" \
         "cd $priv; gh issue create --body $n" \
         "true | cd $priv && gh issue create --body $n" \
         "true || cd $priv && gh issue create --body $n"; do
  hook 2 "a cd that may not move the next command: [${v//$tmp/<tmp>}]" "$pub" "$v"
done
# A branch whose tree has a symlink into the public repository: after a checkout
# or merge, a path checked while missing can be that symlink.
git -C "$priv" checkout -q -b with-out-link
ln -s "$pub/notes.md" "$priv/out-link"
ln -s "$pub" "$priv/out-dir"
git -C "$priv" add out-link out-dir && git -C "$priv" commit -q -m out-link
git -C "$priv" checkout -q -
for v in "git checkout with-out-link && echo $n >> out-link" \
         "git merge with-out-link && cp $n.md out-link" \
         "git stash pop && touch $n-out-link/x" \
         "git switch with-out-link && cd ./out-dir && echo $n" \
         "git checkout with-out-link && sort -o out-link $n.md" \
         "git checkout with-out-link && uniq $n.md out-link" \
         "git checkout with-out-link && file -C -m out-dir/$n"; do
  hook 2 "a write after the tree changed: [$v]" "$priv" "$v"
done
hook 0 "contained: reads after a checkout" "$priv" "git checkout with-out-link && git log --grep=$n"
# Text written in the private repository, sent to a public one: refused.
printf 'plan for %s\n' "$n" > "$priv/task.md"
hook 2 "a private file as the body of a public issue" "$priv" "gh issue create -R example/zzqopenbox --body-file task.md"
hook 2 "a private file as a public issue body, by URL" "$priv" "gh issue create -R https://github.com/example/zzqopenbox --body-file task.md"
hook 2 "cp a private file into the public repository" "$priv" "cp task.md $pub/$n.md"
# Not contained: a remote that is not listed private, or a repository not listed at all.
mixed="$tmp/zzqsecretbox-mixed"; git init -q "$mixed"
git -C "$mixed" remote add origin git@github.com:example/zzqsecretbox.git
git -C "$mixed" remote add mirror git@github.com:example/zzqopenbox.git
hook 2 "a remote listed public: not contained" "$mixed" "echo $n"
unl="$tmp/zzqunlisted"; git init -q "$unl"; git -C "$unl" remote add origin git@github.com:example/zzqunlisted.git
hook 2 "an unlisted repository: not contained" "$unl" "echo $n"
# insteadOf rewrites show in remote -v, so a rewrite to a public URL is not contained.
rw="$tmp/zzqsecretbox-rewrite"; git init -q "$rw"
git -C "$rw" remote add origin git@github.com:example/zzqsecretbox.git
git -C "$rw" config url.git@github.com:example/zzqopenbox.git.pushInsteadOf git@github.com:example/zzqsecretbox.git
hook 2 "a pushInsteadOf to a public URL: not contained" "$rw" "git push origin $n"
# A local path remote is not judged by how its path is spelled.
lp="$tmp/zzqsecretbox-localremote"; git init -q "$lp"
git -C "$lp" remote add origin git@github.com:example/zzqsecretbox.git
git -C "$lp" remote add backup "$tmp/srv/example/zzqsecretbox"
hook 2 "a local path remote: not contained" "$lp" "echo $n"
# Origins that are the owner's but are not in the canonical forms: in scope.
for u in "ssh://github.com/example/zzqalias.git" "ssh://git@ssh.github.com:443/example/zzqalias.git" "ghx:example/zzqalias"; do
  a="$tmp/alias-$RANDOM"; git init -q "$a"; git -C "$a" remote add origin "$u"
  git -C "$a" config url.git@github.com:.insteadOf ghx:
  hook 2 "in scope: origin $u" "$a" "echo $n"
done
# Every remote counts, not only origin: an "upstream" alone, or an owner's push URL.
u1="$tmp/upstream-only-$RANDOM"; git init -q "$u1"; git -C "$u1" remote add upstream git@github.com:example/zzqup.git
hook 2 "in scope: only an upstream remote under the owner" "$u1" "echo $n"
u2="$tmp/pushurl-$RANDOM"; git init -q "$u2"; git -C "$u2" remote add origin https://github.com/someone-else/x.git
git -C "$u2" remote set-url --push origin git@github.com:example/zzqup.git
hook 2 "in scope: the owner's push URL behind another fetch URL" "$u2" "echo $n"
PAYLOAD_CWD=- hook 0 "out of scope: no cwd in the payload" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD=relative/dir hook 0 "out of scope: a relative cwd" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD="$pub" hook 2 "strict: the payload cwd decides, not the process cwd" "$priv" "git commit -m $n"
# Sensitive data is never relaxed by the destination.
hook 2 "sensitive: PII in a commit inside the private repository is refused" "$priv" \
  "git commit -m 'mail jane.roe""@""mailbox.org'"

# Fail closed: a name list the prefilter cannot read runs the full check,
# which refuses as "could not check" rather than allowing.
mkdir -p "$tmp/list-is-a-dir"
hook 2 "an unreadable name list refuses, not allows" "$pub" "echo $n" "$tmp/list-is-a-dir"

# Temp files: one private directory per run, removed at exit.
mkdir -p "$tmp/tmpdir"
"$PY" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","cwd":sys.argv[1],"tool_input":{"command":"echo hello"}}))' "$pub" > "$tmp/payload"
( cd "$pub" && TMPDIR="$tmp/tmpdir" PATH="$tmp/bin:$PATH" PRIVATE_NAMES_FILE="$list" SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" \
    SENSITIVE_TERMS_FILE="$tmp/no-terms" bash "$HOOK" < "$tmp/payload" > /dev/null 2>&1 )
[[ -z "$(ls -A "$tmp/tmpdir")" ]] && ok "no temp file is left in TMPDIR" || error "left in TMPDIR: $(ls -A "$tmp/tmpdir")"
if grep -q 'payload_file="$(mktemp)"' "$HOOK" || ! grep -q 'work_dir="$(mktemp -d' "$HOOK"; then
  error "the hook writes temp files outside a private directory"
else
  ok "temp files live in a private mktemp -d directory"
fi

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
# Git Bash on Windows forks slowly (about 2 s for this hit on a CI runner,
# 0.25 s on Linux), so its bound is wider; both are far inside the timeout.
limit=2000
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) limit=5000 ;; esac
[[ "$ms" -lt "$limit" ]] && ok "the hit took $ms ms (< $limit)" || error "the hit took $ms ms, want < $limit"
# Out of scope is decided before any scan: it must stay cheap on every call.
t0="$(now_ms)"
hook 0 "out of scope, against 5,000 names" "$other" "gh pr create --body 'see zzqfixture4999'" "$big"
t1="$(now_ms)"
ms=$((t1 - t0))
[[ "$ms" -lt "$limit" ]] && ok "out of scope took $ms ms (< $limit)" || error "out of scope took $ms ms, want < $limit"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
