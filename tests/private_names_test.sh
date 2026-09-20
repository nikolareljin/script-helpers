#!/usr/bin/env bash
# SCRIPT: private_names_test.sh
# DESCRIPTION: Exercise scripts/check_private_names.sh across its tiers, subjects, refusals and overrides.
# USAGE: bash tests/private_names_test.sh
# ----------------------------------------------------
#
# Every name used here is invented. The gate's subject is the names of real
# private repositories, so a test that used one would put it in a tracked file
# in a public repository -- the precise thing being prevented. The same reason
# tests/adb_wireless_test.sh builds its bad address in a temp directory.
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/scripts/check_private_names.sh"

failures=0
note()  { echo "[private_names_test] $*"; }
error() { echo "[private_names_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { note "PASS: $*"; }

command -v git >/dev/null 2>&1 || { note "SKIP: git not available"; exit 0; }
command -v python3 >/dev/null 2>&1 || { note "SKIP: python3 not available"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# CI has no git identity, so it is injected per command rather than configured.
# A test that skipped silently here would be worse than no test.
git_t() { git -c user.name='script-helpers tests' -c user.email='tests@localhost' "$@"; }

today="$(date -u +%Y-%m-%d)"
list="$tmp/names.tsv"
{
  printf '# private-names v1\n'
  printf '# generated: %s source: test\n' "$today"
  printf 'private\tbluewidget\tR-111\t\n'
  printf 'private\tbeacon\tR-222\tambiguous\n'
  printf 'public\tscript-helpers\tR-002\t\n'
} > "$list"

stale="$tmp/stale.tsv"
{
  printf '# generated: 2020-01-01 source: test\n'
  printf 'private\tbluewidget\tR-111\t\n'
} > "$stale"

empty="$tmp/empty.tsv"
{
  printf '# generated: %s source: test\n' "$today"
  printf 'public\tscript-helpers\tR-002\t\n'
} > "$empty"

# rc <expected> <description> <text> [extra args...]
rc_of_stdin() {
  local want="$1" desc="$2" text="$3"; shift 3
  local got
  printf '%s' "$text" | bash "$GATE" --stdin --list "$list" "$@" >/dev/null 2>&1
  got=$?
  if [[ "$got" == "$want" ]]; then ok "$desc"; else error "$desc: exit $got, expected $want"; fi
}

# --- the two tiers ---------------------------------------------------------
rc_of_stdin 0 "clean text passes"                     "nothing interesting here"
rc_of_stdin 1 "a private name is refused"             "this mentions bluewidget in passing"
rc_of_stdin 1 "a name inside a longer path is caught" "see vendor/bluewidget-client/readme"
rc_of_stdin 1 "a possessive is caught"                "bluewidget's release notes"
rc_of_stdin 1 "case is ignored"                       "BlueWidget"
# An ambiguous name matches as a whole token only, which is what separates a
# reference from the ordinary word it collides with.
rc_of_stdin 0 "an ambiguous name as a suffix does not fire"   "the regex is beaconed at both ends"
rc_of_stdin 1 "an ambiguous name as a bare token is refused"  "see the beacon for details"
rc_of_stdin 1 "an ambiguous name in a path is refused"        "cloned from owner/beacon last week"
rc_of_stdin 0 "an ambiguous name with a prefix does not fire" "the value is unbeaconed here"

# The refusal has to name the match, or the person reading it cannot act.
out="$(printf 'about bluewidget' | bash "$GATE" --stdin --list "$list" 2>&1)"
case "$out" in
  *bluewidget*R-111*) ok "the refusal names the match and the code to cite instead" ;;
  *) error "the refusal does not name the match and its code: $out" ;;
esac

# --- the overrides ---------------------------------------------------------
got="$(printf 'beaconed at both ends' | PRIVATE_NAMES_ALLOW=beacon bash "$GATE" --stdin --list "$list" >/dev/null 2>&1; echo $?)"
[[ "$got" == 0 ]] && ok "PRIVATE_NAMES_ALLOW lets a term through" \
                  || error "PRIVATE_NAMES_ALLOW did not apply: exit $got"

out="$(printf 'beaconed' | PRIVATE_NAMES_ALLOW=beacon bash "$GATE" --stdin --list "$list" 2>&1)"
case "$out" in
  *"allowed by override"*beacon*) ok "an override says what it disabled" ;;
  *) error "an override was silent: $out" ;;
esac

got="$(printf 'about bluewidget' | PRIVATE_NAMES_ALLOW=beacon bash "$GATE" --stdin --list "$list" >/dev/null 2>&1; echo $?)"
[[ "$got" == 1 ]] && ok "an override for one term does not disable the rest" \
                  || error "overriding one term disabled another: exit $got"

# The machine-level allowlist, for a word that recurs in every repository
# rather than one. Pointed at a temporary HOME so the test never reads or
# writes the real one.
mkdir -p "$tmp/home/.cache/script-helpers"
printf 'beacon\n' > "$tmp/home/.cache/script-helpers/private-names-allow"
got="$(printf 'see the beacon for details' | HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache" \
  bash "$GATE" --stdin --list "$list" >/dev/null 2>&1; echo $?)"
[[ "$got" == 0 ]] && ok "a machine-level allowlist applies to every repository" \
                  || error "the machine-level allowlist was not read: exit $got"
got="$(printf 'about bluewidget' | HOME="$tmp/home" XDG_CACHE_HOME="$tmp/home/.cache" \
  bash "$GATE" --stdin --list "$list" >/dev/null 2>&1; echo $?)"
[[ "$got" == 1 ]] && ok "a machine-level allowlist does not disable the rest" \
                  || error "the machine-level allowlist disabled an unrelated name: exit $got"

# --- cannot check is never a pass -----------------------------------------
printf 'bluewidget' | bash "$GATE" --stdin --list "$tmp/absent.tsv" >/dev/null 2>&1
[[ $? == 2 ]] && ok "a missing list exits 2, not 0" || error "a missing list did not exit 2"

printf 'bluewidget' | bash "$GATE" --stdin --list "$empty" >/dev/null 2>&1
[[ $? == 2 ]] && ok "a list with no private names exits 2, not 0" \
              || error "an empty list did not exit 2"

# A stale list still checks: refusing to push because a *list* is old punishes
# the wrong thing, and 30-day-old names are still overwhelmingly the right ones.
printf 'bluewidget' | bash "$GATE" --stdin --list "$stale" >/dev/null 2>&1
[[ $? == 1 ]] && ok "a stale list still refuses a match" || error "a stale list stopped checking"
out="$(printf 'clean' | bash "$GATE" --stdin --list "$stale" 2>&1)"
case "$out" in
  *days\ old*) ok "a stale list says so" ;;
  *) error "a stale list was silent about its age: $out" ;;
esac

# --- the subjects ----------------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
git_t -C "$repo" init -q .
printf 'the regex is beaconed at both ends\n' > "$repo/notes.md"
git_t -C "$repo" add notes.md
git_t -C "$repo" commit -q -m "docs: describe the beaconed regex"

( cd "$repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "an ambiguous word as a suffix in the tree does not refuse" \
              || error "the tree scan fired on an ordinary English word"

# The tree is scanned for ambiguous names too. Exempting it was the first
# design, and the hole swallowed a real path naming a private repository.
printf 'cloned from owner/beacon\n' > "$repo/clone-notes.md"
git_t -C "$repo" add clone-notes.md
git_t -C "$repo" commit -q -m "docs: notes"
( cd "$repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "an ambiguous name as a token in the tree is refused" \
              || error "the tree scan skipped an ambiguous name"
git_t -C "$repo" rm -q clone-notes.md
git_t -C "$repo" commit -q -m "docs: drop notes"

printf 'bluewidget belongs here\n' >> "$repo/notes.md"
git_t -C "$repo" add notes.md
git_t -C "$repo" commit -q -m "docs: more"
( cd "$repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "a private name in the tree is refused" || error "the tree scan missed a private name"

git_t -C "$repo" commit -q --allow-empty -m "feat: wire bluewidget into the thing"
( cd "$repo" && bash "$GATE" --commits "HEAD~1..HEAD" --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "a private name in a commit message is refused" \
              || error "the commit scan missed a private name"

git_t -C "$repo" commit -q --allow-empty -m "docs: mention the beacon explicitly"
( cd "$repo" && bash "$GATE" --commits "HEAD~1..HEAD" --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "an ambiguous name as a token in a commit message is refused" \
              || error "the commit scan ignored an ambiguous name"

body="$tmp/pr-body.md"
printf 'This aligns with bluewidget.\n' > "$body"
bash "$GATE" --file "$body" --list "$list" >/dev/null 2>&1
[[ $? == 1 ]] && ok "a body file naming a private repository is refused" \
              || error "the body-file scan missed a private name"
printf 'This aligns with R-111.\n' > "$body"
bash "$GATE" --file "$body" --list "$list" >/dev/null 2>&1
[[ $? == 0 ]] && ok "a body file citing the code instead passes" \
              || error "the body-file scan fired on a code citation"

bash "$GATE" --file "$tmp/no-such-body.md" --list "$list" >/dev/null 2>&1
[[ $? == 2 ]] && ok "a missing body file exits 2, not 0" || error "a missing body file did not exit 2"

# --- does the rule apply here? --------------------------------------------
# One hook is installed everywhere, so the check decides for itself whether the
# repository it is running in is one the rule is about.
pub="$tmp/pub.tsv"; priv="$tmp/priv.tsv"
{ printf '# generated: %s source: test\n' "$today"
  printf 'private\tbluewidget\tR-111\t\n'
  printf 'public\t%s\tR-002\t\n' "$(basename "$repo")"; } > "$pub"
{ printf '# generated: %s source: test\n' "$today"
  printf 'private\tbluewidget\tR-111\t\n'
  printf 'private\t%s\tR-002\t\n' "$(basename "$repo")"; } > "$priv"
git_t -C "$repo" remote add origin "git@github.com:example/$(basename "$repo").git"

( cd "$repo" && printf 'about bluewidget' | bash "$GATE" --stdin --only-public --list "$pub" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "--only-public checks a public repository" \
              || error "--only-public skipped a public repository"
( cd "$repo" && printf 'about bluewidget' | bash "$GATE" --stdin --only-public --list "$priv" >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "--only-public skips a private repository" \
              || error "--only-public checked a private repository"
# An unlisted repository is most likely one created since the list was made --
# the newest repositories are exactly where a wrong guess would hurt most.
( cd "$repo" && printf 'about bluewidget' | bash "$GATE" --stdin --only-public --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "--only-public checks an unlisted repository rather than assuming it is private" \
              || error "--only-public assumed an unlisted repository was private"

# --names, the list-free path used by callers that already know the names.
printf 'about bluewidget' | bash "$GATE" --stdin --names "bluewidget,other" >/dev/null 2>&1
[[ $? == 1 ]] && ok "--names refuses without a list file" || error "--names did not refuse"

# --- the baseline ----------------------------------------------------------
# Grandfathering what is already there, without ever allowing the word.
base_repo="$tmp/baserepo"
mkdir -p "$base_repo"
git_t -C "$base_repo" init -q .
printf 'the beacon is lit\n' > "$base_repo/notes.md"
git_t -C "$base_repo" add notes.md
git_t -C "$base_repo" commit -q -m "docs: notes"

( cd "$base_repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "an ambiguous match blocks before a baseline exists" \
              || error "the ambiguous match did not block"

( cd "$base_repo" && bash "$GATE" --tree --list "$list" --write-baseline >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "--write-baseline records the known matches" \
              || error "--write-baseline failed"
[[ -s "$base_repo/.git/private-names-baseline" ]] && ok "the baseline file is written inside .git" \
              || error "no baseline file was written"
# Hashes only: the file must not carry the name it is about.
if grep -qi "beacon" "$base_repo/.git/private-names-baseline" 2>/dev/null; then
  error "the baseline contains the name in clear"
else
  ok "the baseline holds hashes, not names"
fi

( cd "$base_repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "a baselined match stops blocking" \
              || error "the baseline did not take effect"

# The point of a baseline rather than an allowlist: new text still fails.
printf 'cloned from owner/beacon today\n' >> "$base_repo/notes.md"
git_t -C "$base_repo" add notes.md
git_t -C "$base_repo" commit -q -m "docs: more"
( cd "$base_repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "a new match still blocks with a baseline in place" \
              || error "the baseline hid a new match"

# A hard name is never grandfathered, whatever the baseline says.
printf 'bluewidget is wired in\n' >> "$base_repo/notes.md"
git_t -C "$base_repo" add notes.md
git_t -C "$base_repo" commit -q -m "docs: widget"
( cd "$base_repo" && bash "$GATE" --tree --list "$list" --write-baseline >/dev/null 2>&1 )
( cd "$base_repo" && bash "$GATE" --tree --list "$list" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "a baseline never grandfathers an unambiguous private name" \
              || error "the baseline suppressed a hard name"

# Writing a baseline must not report success while an unambiguous name is
# present. A baseline covers ambiguous names only, and exit 0 from the command
# a person runs to "clear" the noise would read as "this tree is clean".
( cd "$base_repo" && bash "$GATE" --tree --list "$list" --write-baseline >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "--write-baseline still fails when a private name is present" \
              || error "--write-baseline reported success with a private name in the tree"

# --- the hooks -------------------------------------------------------------
# The gate is only worth having if the hooks actually call it. These drive the
# hook files themselves rather than re-implementing what they do.
hook_repo="$tmp/hookrepo"
mkdir -p "$hook_repo/scripts"
git_t -C "$hook_repo" init -q .
git_t -C "$hook_repo" remote add origin "git@github.com:example/hookrepo.git"
cp "$GATE" "$hook_repo/scripts/check_private_names.sh"
mkdir -p "$hook_repo/lib"
cp "$ROOT_DIR/helpers.sh" "$hook_repo/helpers.sh" 2>/dev/null || true
cp "$ROOT_DIR/lib/logging.sh" "$hook_repo/lib/logging.sh" 2>/dev/null || true

hook_list="$tmp/hook.tsv"
{ printf '# generated: %s source: test\n' "$today"
  printf 'private\tbluewidget\tR-111\t\n'
  printf 'public\thookrepo\tR-002\t\n'; } > "$hook_list"

msg="$tmp/COMMIT_EDITMSG"
printf 'feat: wire bluewidget into the thing\n' > "$msg"
( cd "$hook_repo" && PRIVATE_NAMES_FILE="$hook_list" \
    bash "$ROOT_DIR/scripts/git-hooks/commit-msg" "$msg" >/dev/null 2>&1 )
[[ $? == 1 ]] && ok "the commit-msg hook refuses a message naming a private repository" \
              || error "the commit-msg hook let a private name through"

printf 'feat: wire R-111 into the thing\n' > "$msg"
( cd "$hook_repo" && PRIVATE_NAMES_FILE="$hook_list" \
    bash "$ROOT_DIR/scripts/git-hooks/commit-msg" "$msg" >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "the commit-msg hook passes a message citing the code" \
              || error "the commit-msg hook refused a clean message"

# Cannot-check must not become a refusal of every commit, or the first machine
# without a list is a machine where nobody can commit.
printf 'feat: wire bluewidget into the thing\n' > "$msg"
( cd "$hook_repo" && PRIVATE_NAMES_FILE="$tmp/absent.tsv" \
    bash "$ROOT_DIR/scripts/git-hooks/commit-msg" "$msg" >/dev/null 2>&1 )
[[ $? == 0 ]] && ok "the commit-msg hook allows the commit when it cannot check" \
              || error "a missing list blocked a commit"

if command -v python3 >/dev/null 2>&1; then
  agent_hook="$ROOT_DIR/scripts/claude-hooks/pretooluse_private_names.sh"
  agent() {   # agent <expected> <description> <command string>
    local want="$1" desc="$2" cmd="$3" got
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
      "$(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
      | ( cd "$hook_repo" && PRIVATE_NAMES_FILE="$hook_list" bash "$agent_hook" >/dev/null 2>&1 )
    got=$?
    [[ "$got" == "$want" ]] && ok "$desc" || error "$desc: exit $got, expected $want"
  }
  agent 0 "the agent hook ignores an unrelated command" "ls -la"
  agent 0 "the agent hook passes a clean body"          'gh pr create --body "aligns with R-111"'
  agent 2 "the agent hook blocks a body naming a private repository" \
          'gh pr create --body "aligns with bluewidget"'
  agent 2 "the agent hook blocks an issue comment naming one" \
          'gh issue comment 5 --body "bluewidget needs this"'
  agent 2 "the agent hook blocks a commit message naming one" \
          'git commit -m "feat: wire bluewidget in"'
  agent 2 "the agent hook refuses --no-verify"          "git push --no-verify origin main"
  # One shell line usually holds several commands and the interesting one is
  # rarely first. Judging only the first word let `cd repo && gh pr create`
  # through, which is the ordinary shape, not an exotic one.
  agent 2 "a chained gh pr create is still seen" \
          'cd /tmp && gh pr create --body "aligns with bluewidget"'
  agent 2 "a semicolon-separated command is still seen" \
          'cd /tmp; gh issue comment 5 --body "bluewidget"'
  agent 2 "a chained git commit is still seen" \
          'cd /tmp && git add -A && git commit -m "wire bluewidget in"'
  agent 2 "--no-verify is refused after a chain"        "cd /tmp && git push --no-verify origin main"
  agent 0 "a chained clean body passes"                 'cd /tmp && gh pr create --body "aligns with R-111"'
  # A body legitimately contains "#", and a lexer treating it as a comment
  # would read half the text and call the rest clean.
  agent 2 "a body with a # heading is read in full" \
          'gh pr create --body "# Title
mentions bluewidget"' 
  # A pull request *into* the private repository is exactly where its name
  # belongs. Blocking it would get the hook removed within a day.
  agent 0 "the agent hook allows a pull request into the private repository itself" \
          'gh pr create --repo example/bluewidget --body "bluewidget internals"'
else
  note "SKIP: python3 unavailable, agent hook not exercised"
fi

if (( failures )); then
  note "$failures check(s) failed."
  exit 1
fi
note "ALL PASSED"
exit 0
