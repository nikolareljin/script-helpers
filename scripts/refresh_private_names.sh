#!/usr/bin/env bash
# SCRIPT: refresh_private_names.sh
# DESCRIPTION: Build the private-repository name list that check_private_names.sh reads, from your own GitHub account or organisation.
# USAGE: scripts/refresh_private_names.sh [--owner <user-or-org>] [--out <path>] [--stdout] [--check] [-h]
# PARAMETERS:
#   --owner <name>  GitHub user or organisation. Default: the owner of this repo's origin remote.
#   --out <path>    Where to write. Default: ${XDG_CACHE_HOME:-~/.cache}/script-helpers/private-names.tsv
#   --stdout        Print the list instead of writing it.
#   --check         Compare the written list with GitHub; change nothing.
#   -h, --help      Show this help message.
# EXIT_CODES:
#   0  written (or, with --check, unchanged)
#   1  --check found the list out of date
#   2  bad arguments, or the account has no private repositories
#   3  gh is missing or not authenticated
# ----------------------------------------------------
#
# check_private_names.sh refuses text that names a private repository, and it
# needs to know which names those are. That list is yours: your account, your
# organisation, your repositories. Nothing about it is shared, and nothing about
# it can be committed -- a file listing your private repositories is exactly the
# thing the gate exists to keep out of public trees.
#
# So it lives outside every working tree, at
# ${XDG_CACHE_HOME:-~/.cache}/script-helpers/private-names.tsv, one file per
# machine serving every repository on it.
#
# WHY THE NETWORK IS HERE AND NOWHERE ELSE. This script talks to GitHub; the
# gate never does. A check that made a network call would add a round trip to
# every commit and every push, to catch an event -- a repository being created,
# or changing visibility -- that happens a few times a month and that you
# perform deliberately. Refresh after one of those, or on a cadence of days.
#
# AMBIGUOUS NAMES. A repository whose name is also an ordinary word is flagged,
# and the gate then requires it to appear as a whole token rather than as a
# substring, so an everyday use of the word in prose stops matching while
# "owner/<name>" still does. The flag comes from the system word list when there is one.
#
# The `code` column is for citing a private repository in public text without
# naming it. If you have no such scheme it stays `-`, and the gate simply says
# which name it found.
# ----------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging >/dev/null 2>&1 || true
type log_info >/dev/null 2>&1 || log_info() { printf '[INFO] %s\n' "$*"; }
type log_warn >/dev/null 2>&1 || log_warn() { printf '[WARN] %s\n' "$*" >&2; }
type log_error >/dev/null 2>&1 || log_error() { printf '[ERROR] %s\n' "$*" >&2; }

OWNER=""
OUT="${XDG_CACHE_HOME:-$HOME/.cache}/script-helpers/private-names.tsv"
TO_STDOUT=false
CHECK=false
WORDLIST="${PRIVATE_NAMES_WORDLIST:-/usr/share/dict/words}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="${2:?--owner needs a name}"; shift 2 ;;
    --out) OUT="${2:?--out needs a path}"; shift 2 ;;
    --stdout) TO_STDOUT=true; shift ;;
    --check) CHECK=true; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) log_error "Unknown argument: $1"; exit 2 ;;
  esac
done

# A missing tool is exit 3, distinct from "found nothing", so a caller can tell
# "not set up here" from "your account has no private repositories".
if ! command -v gh >/dev/null 2>&1; then
  log_error "gh is not installed. This is the only step that talks to GitHub;"
  log_error "the check itself never does. See https://cli.github.com."
  exit 3
fi
if ! gh auth status >/dev/null 2>&1; then
  log_error "gh is not authenticated. Run: gh auth login"
  exit 3
fi

if [[ -z "$OWNER" ]]; then
  origin="$(git config --get remote.origin.url 2>/dev/null)"
  # owner from git@host:owner/name.git or https://host/owner/name(.git)
  case "$origin" in
    *:*/*) OWNER="${origin##*:}"; OWNER="${OWNER%%/*}" ;;
  esac
  if [[ "$origin" == http*://* ]]; then
    stripped="${origin#*://}"       # host/owner/name
    stripped="${stripped#*/}"       # owner/name
    OWNER="${stripped%%/*}"
  fi
fi
if [[ -z "$OWNER" ]]; then
  log_error "Could not work out whose repositories to list."
  log_error "Pass --owner <user-or-org>."
  exit 2
fi

raw="$(gh repo list "$OWNER" --limit 1000 --json name,visibility,isArchived 2>/dev/null)"
status=$?
if (( status != 0 )) || [[ -z "$raw" ]]; then
  log_error "gh repo list $OWNER failed (exit $status)."
  log_error "Check the name, and that this account can see it."
  exit 3
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.body"' EXIT

# One python pass: the JSON, the word list and the flagging. python3 is already
# required by the gate for the same reason -- parsing JSON in bash is how a
# quoted name with a bracket in it silently drops out of a security list.
printf '%s' "$raw" | WORDLIST="$WORDLIST" python3 -c '
import json, os, sys, pathlib

rows = json.load(sys.stdin)
wordlist = pathlib.Path(os.environ.get("WORDLIST", ""))
words = set()
if wordlist.is_file():
    with wordlist.open(encoding="utf-8", errors="ignore") as fh:
        words = {w.strip().lower() for w in fh if w.strip()}

out = []
for repo in rows:
    if repo.get("isArchived"):
        continue
    name = repo.get("name")
    if not name:
        continue
    visibility = "public" if str(repo.get("visibility", "")).upper() == "PUBLIC" else "private"
    flags = "ambiguous" if visibility == "private" and name.lower() in words else ""
    out.append((visibility, name, "-", flags))

out.sort(key=lambda r: r[1].lower())
for row in out:
    print("\t".join(row))
' > "$tmp.body"
status=$?
if (( status != 0 )); then
  log_error "could not parse the repository list (exit $status)"
  exit 3
fi

private_count="$(grep -c '^private' "$tmp.body")"
public_count="$(grep -c '^public' "$tmp.body")"
ambiguous="$(awk -F'\t' '$1=="private" && $4=="ambiguous" {print $2}' "$tmp.body" | tr '\n' ' ')"

# A list with no private names in it cannot be told from a clean tree by
# anything downstream, and the gate treats an empty list as a failure rather
# than a pass. Refusing to write one keeps that failure here, where the cause
# is visible.
if [[ "$private_count" -eq 0 ]]; then
  log_error "$OWNER has no private repositories visible to this account."
  log_error "Writing an empty list would leave a check that scans for nothing"
  log_error "and reports success, so nothing was written."
  exit 2
fi

{
  echo "# private-names v1 -- generated, never commit this to a public repository"
  echo "# generated: $(date -u +%Y-%m-%d) source: gh repo list $OWNER"
  printf '# visibility\tname\tcode\tflags\n'
  cat "$tmp.body"
} > "$tmp"

if [[ "$TO_STDOUT" == true ]]; then
  cat "$tmp"
  exit 0
fi

if [[ "$CHECK" == true ]]; then
  if [[ ! -f "$OUT" ]]; then
    log_error "no list at $OUT; run without --check to write it"
    exit 1
  fi
  # The generated-on line differs on every run and says nothing about content.
  if diff -q <(grep -v '^# generated:' "$OUT") <(grep -v '^# generated:' "$tmp") >/dev/null; then
    log_info "$OUT matches GitHub ($private_count private, $public_count public)"
    exit 0
  fi
  log_error "$OUT no longer matches GitHub; re-run without --check"
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
cp "$tmp" "$OUT"
log_info "wrote $OUT: $private_count private, $public_count public"
[[ -n "${ambiguous// /}" ]] && log_info "ambiguous, matched as whole tokens only: ${ambiguous% }"
exit 0
