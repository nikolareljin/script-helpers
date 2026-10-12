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
# name is its own business: the session directory (payload cwd) decides.
hook 0 "in the private repository: git status" "$priv" "git status"
hook 0 "in the private repository: git commit naming it" "$priv" "git commit -m 'zzqsecretbox: fix'"
hook 0 "in the private repository: git log" "$priv" "git log --oneline -5 | grep zzqsecretbox"
hook 0 "in the private repository: echo naming it" "$priv" "echo zzqsecretbox"
hook 0 "in the private repository: a path inside it" "$priv" "mkdir -p $priv/zzqsecretbox-docs && ls docs/../"
hook 0 "a pull request into the private repository itself (-R, as before)" "$tmp/plain" \
  "gh pr create -R example/zzqsecretbox --body 'zzqsecretbox internals'"
# Everything else is checked, as before this change.
hook 2 "a private repository with one public remote" "$priv2" "git commit -m 'zzqsecretbox'"
hook 2 "a private name of another owner" "$other" "git commit -m 'zzqsecretbox'"
hook 2 "a plain directory (cd into the repository first; cwd persists)" "$tmp/plain" "echo zzqsecretbox"
hook 2 "a public repository" "$pub" "echo zzqsecretbox"
hook 2 "a pull request into an unlisted repository" "$tmp/plain" "gh pr create -R example/elsewhere --body 'see zzqsecretbox'"
hook 2 "gh without -R outside a repository" "$tmp/plain" "gh issue create --body 'zzqsecretbox'"
hook 2 "curl to github" "$tmp/plain" "curl -d 'zzqsecretbox' https://api.github.com/repos/example/zzqopenbox/issues"
hook 2 "a push to a URL" "$priv" "git push https://example.invalid/x.git zzqsecretbox"

# From inside the private repository, anything that could move the text
# elsewhere is checked. Each of these blocks.
n=zzqsecretbox
for v in "cd $pub && git commit -m $n" \
         "cd $priv && git commit -m $n" \
         "pushd $pub && git commit -m $n" \
         "popd && git commit -m $n" \
         "git -C $pub commit -m $n" \
         "git -C . commit -m $n" \
         "(cd $pub && git commit -m $n)" \
         "{ cd $pub; git commit -m $n; }" \
         "f() { git commit -m $n; }; cd $pub; f" \
         "git commit -m \"\$N $n\"" \
         "git commit -m \$(echo $n)" \
         "git commit -m \`echo $n\`" \
         "GIT_DIR=$pub/.git git commit -m $n" \
         "GIT_WORK_TREE=$pub git commit -m $n" \
         "git --git-dir=$pub/.git commit -m $n" \
         "git --work-tree=$pub commit -m $n" \
         "git -c core.editor=true commit -m $n" \
         "git -c url.git@github.com:example/zzqopenbox.insteadOf=x push origin $n" \
         "git remote add pub git@github.com:example/zzqopenbox.git && git push pub $n" \
         "git remote set-url origin git@github.com:example/zzqopenbox.git && git push origin $n" \
         "git config remote.origin.url https://github.com/example/zzqopenbox && git push origin $n" \
         "gh pr create -R example/zzqopenbox --body $n" \
         "gh pr create --repo=example/zzqopenbox --body $n" \
         "gh api repos/example/zzqopenbox/issues -f body=$n" \
         "bash -c 'git commit -m $n'" \
         "sh -c 'git commit -m $n'" \
         "eval git commit -m $n" \
         "exec git commit -m $n" \
         "env -C $pub git commit -m $n" \
         "echo $n > $pub/notes.md" \
         "echo $n > ../zzqopenbox/notes.md" \
         "cp README $pub/$n.md" \
         "mkdir -p ~/$n" \
         "wget --post-data=$n https://example.invalid/x"; do
  hook 2 "strict: [${v//$tmp/<tmp>}]" "$priv" "$v"
done
PAYLOAD_CWD=- hook 2 "strict: no cwd in the payload" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD=relative/dir hook 2 "strict: a relative cwd" "$priv" "git -C $priv commit -m $n"
PAYLOAD_CWD="$pub" hook 2 "strict: the payload cwd decides, not the process cwd" "$priv" "git commit -m $n"
# Sensitive data is never relaxed by the destination.
hook 2 "sensitive: PII in a commit inside the private repository is refused" "$tmp/plain" \
  "cd $priv && git commit -m 'mail jane.roe""@""mailbox.org'"

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
