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

# hook <want> <description> <cwd> <command> [names list]
hook() {
  local want="$1" desc="$2" cwd="$3" cmd="$4" names="${5:-$list}" got
  "$PY" -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$cmd" > "$tmp/payload"
  ( cd "$cwd" && PATH="$tmp/bin:$PATH" PRIVATE_NAMES_FILE="$names" SENSITIVE_MACHINE_IDS_FILE="$tmp/no-machine-ids" \
      SENSITIVE_TERMS_FILE="$tmp/no-terms" bash "$HOOK" < "$tmp/payload" > "$tmp/out" 2>&1 )
  got=$?
  [[ "$got" == "$want" ]] && ok "$desc" || error "$desc: exit $got, want $want: $(head -c 400 "$tmp/out")"
}

# Work inside the private repository: its name is its own business.
hook 0 "a: git -C <private> and a new worktree beside it, from a plain directory" "$tmp/plain" \
  "git -C $priv fetch && git -C $priv worktree add $priv-wt-x -b x"
hook 0 "a: the same from a public repository" "$pub" \
  "git -C $priv fetch && git -C $priv worktree add $priv-wt-x -b x"
hook 0 "b: echo in a plain directory publishes nothing" "$tmp/plain" "echo zzqsecretbox"
hook 2 "b: echo in a public repository is still checked" "$pub" "echo zzqsecretbox"
hook 2 "c: a pull request into an unlisted repository is checked" "$tmp/plain" \
  "gh pr create -R example/elsewhere --body 'see zzqsecretbox'"
hook 0 "d: cd <private> && git commit naming it" "$tmp/plain" "cd $priv && git commit -m 'zzqsecretbox: fix'"
# Blocks that must stay.
hook 2 "gh without -R outside a repository is checked" "$tmp/plain" "gh issue create --body 'zzqsecretbox'"
hook 2 "curl to github naming it is checked" "$tmp/plain" \
  "curl -d 'zzqsecretbox' https://api.github.com/repos/example/zzqopenbox/issues"
hook 2 "a redirect into a public repository is checked" "$tmp/plain" "echo zzqsecretbox > $pub/notes.md"
hook 2 "cd <public> && git commit naming it" "$tmp/plain" "cd $pub && git commit -m 'zzqsecretbox'"
hook 2 "git -C <public> commit naming it, from the private one" "$priv" "git -C $pub commit -m 'zzqsecretbox'"
hook 2 "a push to a URL is checked" "$priv" "git push https://example.invalid/x.git zzqsecretbox"
hook 0 "a pull request into the private repository itself" "$tmp/plain" \
  "gh pr create -R example/zzqsecretbox --body 'zzqsecretbox internals'"

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
