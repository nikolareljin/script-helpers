#!/usr/bin/env bash
# SCRIPT: pretooluse_private_names.sh
# DESCRIPTION: Claude Code PreToolUse hook — stop an agent publishing text that names a private repository.
# USAGE: wired into a Claude Code settings.json PreToolUse hook for the Bash tool; reads the hook payload on stdin.
# EXIT_CODES:
#   0  the call may proceed
#   2  the call is blocked; the reason on stderr goes back to the agent
# ----------------------------------------------------
#
# The git hooks in scripts/git-hooks/ cover the tree and commit messages. They
# cannot cover the surface where this actually went wrong: a pull request body
# and an issue body never touch git, so `gh pr create --body ...` publishes text
# no git hook will ever see. This runs before the tool call does.
#
# Only the text being published is checked -- the title, body and message
# arguments -- not the whole command line. `gh pr create --repo <private-repo>`
# is legitimate when the pull request belongs to that private repository, and a
# gate that blocked it would be turned off within a day.
#
# It also refuses --no-verify on commit and push. An agent has no legitimate
# reason to skip a local gate, and without this the git hooks are advisory for
# the one actor they were written for. A human at a terminal is unaffected:
# this hook only ever sees an agent's calls.
#
# INSTALL: in the settings.json Claude Code reads for the directory,
#
#   "hooks": { "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command",
#     "command": "bash <path>/script-helpers/scripts/claude-hooks/pretooluse_private_names.sh" } ] } ] }
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="${SCRIPT_DIR}/../check_private_names.sh"

PUBLISH_RE='(^|[^[:alnum:]_-])(gh[[:space:]]+(pr|issue|release|api)|git[[:space:]]+commit)([^[:alnum:]_-]|$)'

# Without python3 the text cannot be extracted. A command that looks like it
# publishes is refused rather than waved through; anything else proceeds.
if ! command -v python3 >/dev/null 2>&1; then
  if grep -qE "$PUBLISH_RE" 2>/dev/null; then
    if [[ "${SECURITY_GATE_ALLOW_UNCHECKED:-}" == 1 ]]; then
      echo "WARNING: python3 missing, publishing command NOT checked; SECURITY_GATE_ALLOW_UNCHECKED=1, allowed." >&2
      exit 0
    fi
    echo "python3 is missing, so this publishing command could not be checked; refused." >&2
    echo "Install python3, or ask the user to allow it once with SECURITY_GATE_ALLOW_UNCHECKED=1." >&2
    exit 2
  fi
  exit 0
fi

# The payload goes to a file rather than a pipe: the parser below is itself fed
# to python on stdin, so a pipe would be overridden and python would end up
# reading its own source as the payload -- and every call would sail through.
payload_file="$(mktemp)"
# Guarded: a subshell inherits an EXIT trap, and bash runs it there when the
# subshell is signalled -- so this could tear down the caller's stack, or
# delete a directory, while the run is still using it. ${BASHPID-$$} rather
# than $BASHPID alone: bash 3.2, which macOS ships, does not define BASHPID,
# and $$ is the top-level shell's pid in every subshell, so the comparison
# degrades to always-true there rather than to always-false.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -f "$payload_file"; fi' EXIT
cat > "$payload_file"

# One python pass: is this a publishing command, which repository is it aimed
# at, and what text would it publish. Returns three NUL-free lines plus a body.
parsed="$(python3 - "$payload_file" <<'PY'
import json, shlex, sys, pathlib

try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    # Not judged here: the shell side refuses it if it looks like publishing.
    print("VERDICT\tbad-payload")
    sys.exit(0)

if data.get("tool_name") != "Bash":
    sys.exit(0)
command = (data.get("tool_input") or {}).get("command") or ""
if not command:
    sys.exit(0)

try:
    # punctuation_chars, so `;` and `&&` come back as their own tokens: plain
    # shlex.split yields "/tmp;" as one word, and a command after a semicolon
    # would never be seen. commenters is cleared because a body legitimately
    # contains "#", and the default lexer would truncate the line there.
    lexer = shlex.shlex(command, posix=True, punctuation_chars=True)
    lexer.whitespace_split = True
    lexer.commenters = ""
    args = list(lexer)
except ValueError:
    # An unparseable command is not a licence to publish: fall back to checking
    # the whole string rather than letting it through unread.
    #
    # Reported, not enforced, for everyday words. We could not parse it, so we
    # do not know it publishes anything -- and a heredoc of Python containing
    # `s.index(...)` is not a pull request body. Blocking those trains people
    # to switch the hook off.
    print("VERDICT\tcheck-unparsed")
    print("REPO\t")
    print("TEXT")
    print(command)
    sys.exit(0)

# One shell line can hold several commands, and the interesting one is rarely
# first: `cd repo && gh pr create --body ...` is the ordinary shape. Judging
# only the first word let exactly that through. Split on the separators and
# consider each command on its own.
SEPARATORS = {"&&", "||", ";", "|", "&", "\n"}
segments, current = [], []
for token in args:
    if token in SEPARATORS:
        if current:
            segments.append(current)
        current = []
    else:
        current.append(token)
if current:
    segments.append(current)

PUBLISHES = (("gh", "pr", "create"), ("gh", "pr", "edit"), ("gh", "pr", "comment"),
             ("gh", "issue", "create"), ("gh", "issue", "edit"), ("gh", "issue", "comment"),
             ("gh", "release", "create"), ("gh", "api"))

def is_publishing(seg):
    low = [a.lower() for a in seg]
    for seq in PUBLISHES:
        if len(low) >= len(seq) and tuple(low[:len(seq)]) == seq:
            return True
    return len(low) >= 2 and low[0] == "git" and low[1] == "commit"

def skips_hooks(seg):
    low = [a.lower() for a in seg]
    return (low[:1] == ["git"] and len(low) > 1 and low[1] in ("commit", "push")
            and "--no-verify" in low)

if any(skips_hooks(seg) for seg in segments):
    print("VERDICT\tno-verify")
    print("REPO\t")
    print("TEXT")
    sys.exit(0)

publishing_segments = [seg for seg in segments if is_publishing(seg)]
if not publishing_segments:
    sys.exit(0)
# Only the publishing commands' own arguments: a `--repo` belonging to some
# other command on the line is not this one's destination.
args = [a for seg in publishing_segments for a in seg]

TEXT_FLAGS = {"-b", "--body", "-t", "--title", "-m", "--message", "-c", "--comment", "-f", "--field"}
FILE_FLAGS = {"-F", "--body-file", "--file"}
REPO_FLAGS = {"-R", "--repo"}

pieces, repo, unreadable = [], "", []
i = 0
while i < len(args):
    a = args[i]
    nxt = args[i + 1] if i + 1 < len(args) else None
    if a in REPO_FLAGS and nxt:
        repo = nxt
        i += 2
        continue
    if a in TEXT_FLAGS and nxt:
        pieces.append(nxt)
        i += 2
        continue
    if a in FILE_FLAGS and nxt:
        try:
            # "-" is stdin (a heredoc): this hook cannot see it.
            if nxt == "-":
                raise OSError("stdin")
            pieces.append(pathlib.Path(nxt).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            unreadable.append(nxt)
        i += 2
        continue
    for flag in TEXT_FLAGS | FILE_FLAGS:
        if a.startswith(flag + "="):
            value = a.split("=", 1)[1]
            if flag in FILE_FLAGS:
                try:
                    if value == "-":
                        raise OSError("stdin")
                    value = pathlib.Path(value).read_text(encoding="utf-8", errors="replace")
                except OSError:
                    unreadable.append(value)
                    value = ""
            pieces.append(value)
            break
    i += 1

if unreadable:
    print("VERDICT\tunreadable")
    print("REPO\t%s" % repo)
    print("TEXT")
    sys.stdout.write("\n".join(unreadable))
    sys.exit(0)
if not pieces:
    sys.exit(0)
print("VERDICT\tcheck")
print("REPO\t%s" % repo)
print("TEXT")
sys.stdout.write("\n".join(pieces))
PY
)"
parse_rc=$?

# The decision follows the checkers exactly: 0 allow, 1 refuse with the
# reason, anything else refuse as "could not check" unless the user set
# SECURITY_GATE_ALLOW_UNCHECKED=1. Refusal is exit 2 with the reason on stderr,
# which Claude Code returns to the agent and does not run the command.
reason=""
unchecked() {  # <what>
  if [[ "${SECURITY_GATE_ALLOW_UNCHECKED:-}" == 1 ]]; then
    echo "WARNING: $1 could not run; SECURITY_GATE_ALLOW_UNCHECKED=1, allowed unchecked." >&2
    return 0
  fi
  {
    echo "$1 could not run, so this text was NOT checked; refused."
    [[ -n "$reason" ]] && { echo; printf '%s\n' "$reason"; }
    echo
    echo "Fix the cause, or ask the user to allow it once with SECURITY_GATE_ALLOW_UNCHECKED=1."
    echo "Do not set it yourself."
  } >&2
  exit 2
}

if [[ "$parse_rc" -ne 0 ]]; then
  reason="the command parser exited $parse_rc"
  unchecked "The publishing-command parser"
  exit 0
fi
[[ -z "$parsed" ]] && exit 0

if [[ "$parsed" == "VERDICT"$'\t'"bad-payload"* ]]; then
  grep -qE "$PUBLISH_RE" "$payload_file" || exit 0
  reason="the hook payload is not valid JSON"
  unchecked "Reading the command"
  exit 0
fi

verdict="$(printf '%s' "$parsed" | sed -n '1s/^VERDICT\t//p')"
repo="$(printf '%s' "$parsed" | sed -n '2s/^REPO\t//p')"
text="$(printf '%s' "$parsed" | sed -n '4,$p')"

if [[ "$verdict" == "no-verify" ]]; then
  echo "Refusing --no-verify: it skips the local gate that checks this commit for" >&2
  echo "the name of a private repository, among other things. If a hook is wrong," >&2
  echo "say which one and let the user decide -- do not bypass it unasked." >&2
  exit 2
fi
if [[ "$verdict" == "unreadable" ]]; then
  reason="body file(s) this hook cannot read: $(printf '%s' "$text" | tr '\n' ' ')(use a real file with --body-file, not stdin)"
  unchecked "Reading the text to publish"
  exit 0
fi

[[ "$verdict" == "check" || "$verdict" == "check-unparsed" ]] || exit 0

if [[ ! -f "$GATE" ]]; then
  reason="check_private_names.sh is missing next to this hook"
  unchecked "The private-name check"
else
  # Strict here, warn elsewhere: nothing reads a warning from a hook that then
  # allows the call. The PR is created and the warning scrolls past.
  gate_args=(--stdin --only-public)
  # Strict only when a publishing command was actually identified. See the
  # unparseable fallback above.
  [[ "$verdict" == "check" ]] && gate_args+=(--strict-ambiguous)
  [[ -n "$repo" ]] && gate_args+=(--for-repo "$repo")

  reason="$(printf '%s' "$text" | bash "$GATE" "${gate_args[@]}" 2>&1)"
  rc=$?
  case "$rc" in
    0) ;;
    1)
      {
        echo "This text names a private repository, and the destination is public."
        echo "GitHub keeps the edit history of every pull request and issue body"
        echo "publicly, so this cannot be fixed by editing it afterwards."
        echo
        printf '%s\n' "$reason"
        echo
        echo "Cite the repository by its code instead. If this is a false positive,"
        echo "ask the user before overriding -- do not set PRIVATE_NAMES_ALLOW yourself."
      } >&2
      exit 2
      ;;
    *) unchecked "The private-name check (exit $rc)" ;;
  esac
fi

# Then credentials, personal identifiers and PII. Scoped like the global git
# hooks (scripts/owner_scope.sh), failing closed: with no owners configured,
# every destination; with owners, the -R target and every remote of this
# directory, and anything that cannot be identified. An unparsed command is the
# whole command line, which names local paths, so there this machine's
# identifiers are left out (--no-machine); everything else is checked.
SENSITIVE="${SCRIPT_DIR}/../check_sensitive.sh"
SCOPE_LIB="${SCRIPT_DIR}/../owner_scope.sh"
if [[ ! -f "$SENSITIVE" || ! -f "$SCOPE_LIB" ]]; then
  reason="check_sensitive.sh or owner_scope.sh is missing next to this hook"
  unchecked "The sensitive-data check"
  exit 0
fi
# shellcheck source=/dev/null
source "$SCOPE_LIB"
in_scope=true
if owners="$(scope_owners)" && [[ -n "$owners" ]]; then
  # The -R target plus every remote here. Nothing to go on (no -R, no
  # repository, or git failing with no -R): checked.
  remote_urls="$(scope_repo_urls)" || remote_urls=""
  if [[ -n "$repo$remote_urls" ]]; then
    urls=("$repo")
    while IFS= read -r u; do urls+=("$u"); done <<EOF_URLS
$remote_urls
EOF_URLS
    scope_in_scope "$owners" "${urls[@]}" || in_scope=false
  fi
fi
[[ "$in_scope" == true ]] || exit 0

sens_args=(--stdin)
if [[ "$verdict" == "check-unparsed" ]]; then
  # Any command shlex cannot split lands here, most of them not publishing
  # anything. Only one that names a publishing command is scanned.
  printf '%s' "$text" | grep -qE "$PUBLISH_RE" || exit 0
  sens_args+=(--no-machine)
fi
reason="$(printf '%s' "$text" | bash "$SENSITIVE" "${sens_args[@]}" 2>&1)"
rc=$?
case "$rc" in
  0) exit 0 ;;
  1)
    {
      echo "This text carries a credential, a personal identifier or PII."
      echo
      printf '%s\n' "$reason"
      echo
      echo "Remove it. If this is a false positive, ask the user before allowing it."
    } >&2
    exit 2
    ;;
  *) unchecked "The sensitive-data check (exit $rc)" ;;
esac
exit 0
