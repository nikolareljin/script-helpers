#!/usr/bin/env bash
# SCRIPT: refresh_private_names_test.sh
# DESCRIPTION: Tests how scripts/refresh_private_names.sh flags names, fills codes,
#              lists a renamed repository's old names (aliases), and guards against loss.
# USAGE: bash tests/refresh_private_names_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/refresh_private_names_test.sh
# ----------------------------------------------------
#
# The flag decides whether a name is matched bare or only when qualified. A name
# wrongly flagged is not checked less, it is not checked at all.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/refresh_private_names.sh"
failures=0
note()  { echo "[refresh_private_names_test] $*"; }
ok()    { note "PASS: $*"; }
error() { echo "[refresh_private_names_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# gh is stubbed so this drives the real classifier, not a copy of the rule.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Enough of gh to drive the classifier: the identity call, the GraphQL listing
# (already reduced, because the real -q filter runs inside gh), and the org
# counts used to tell "empty" from "cannot see".
rows() {
  printf 'quarry\tPRIVATE\tfalse\n'
  printf 'harbour\tPRIVATE\tfalse\n'
  printf 'zzqqxx\tPRIVATE\tfalse\n'
}
case "$1 ${2:-}" in
  "auth status")   exit 0 ;;
  "api user")      echo "testns" ;;
  "api user/orgs") : ;;
  "api graphql")   rows ;;
  "repo list")
    printf '[{"name":"quarry","visibility":"PRIVATE","isArchived":false},'
    printf '{"name":"harbour","visibility":"PRIVATE","isArchived":false},'
    printf '{"name":"zzqqxx","visibility":"PRIVATE","isArchived":false}]'
    ;;
  *) echo 0 ;;
esac
STUB
chmod +x "$tmp/bin/gh"

# Both are in the word list. The list cannot tell them apart; only measuring
# how often each appears in the repos being published can.
printf 'quarry\nharbour\n' > "$tmp/words"

flags_for() {   # <name> [override]
  PATH="$tmp/bin:$PATH" \
  PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS="${2-}" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
    bash "$SCRIPT" --owner testns --stdout 2>/dev/null \
    | awk -F'\t' -v n="$1" '!/^#/ && $3 == n { print $5 }'
}

# Without this, every case below passes against an empty list.
gen() {   # <override-file>
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$1" \
    bash "$SCRIPT" --owner testns --stdout 2>/dev/null
}
rows="$(gen "$tmp/does-not-exist" | grep -c '^private')"
if [[ "${rows:-0}" -ge 3 ]]; then
  ok "the stub reaches the classifier, ${rows} rows"
else
  error "the stub produced ${rows:-0} rows; nothing below proves anything"
fi

case "$(flags_for quarry)" in
  *ambiguous*) ok "a dictionary word is flagged ambiguous by default" ;;
  *) error "a dictionary word was not flagged ambiguous" ;;
esac

case "$(flags_for quarry quarry)" in
  *ambiguous*) error "the override did not clear the flag" ;;
  *) ok "a name in the override is not flagged" ;;
esac

case "$(flags_for harbour quarry)" in
  *ambiguous*) ok "the override clears only the name it lists" ;;
  *) error "the override cleared a name it does not list" ;;
esac

case "$(flags_for zzqqxx)" in
  *ambiguous*) error "a non-word was flagged ambiguous" ;;
  *) ok "a name that is not a dictionary word is matched bare" ;;
esac

printf '# a comment\nquarry\n' > "$tmp/never"
out="$(gen "$tmp/never" | awk -F'\t' '!/^#/ && $3 == "quarry" { print $5 }')"
case "$out" in
  *ambiguous*) error "the override file was not read" ;;
  *) ok "the override file is read, comments ignored" ;;
esac

# A --owner subset must not silently replace a file covering more owners.
out_file="$tmp/list.tsv"
printf '# private-names v1\n# generated: 2026-09-26 source: test\n' > "$out_file"
printf 'private\tother\twidgetron\tR-001\t\n' >> "$out_file"
printf 'private\ttestns\tquarry\tR-002\t\n' >> "$out_file"
printf 'private\ttestns\tharbour\tR-003\t\n' >> "$out_file"
printf 'private\ttestns\tzzqqxx\tR-004\t\n' >> "$out_file"
before="$(cat "$out_file")"

PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$out_file" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
  error "a subset overwrite was accepted; the other owner's names are gone"
elif [[ "$(cat "$out_file")" != "$before" ]]; then
  error "the write was refused but the file changed anyway"
else
  ok "a write that would drop names is refused, and the file is untouched"
fi

PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$out_file" --force >/dev/null 2>&1
if [[ "$(cat "$out_file")" == "$before" ]]; then
  error "--force did not overwrite"
else
  ok "--force overwrites"
fi

# The refusal has to say which of the two shrank. "would shrink the list:
# 1499 -> 1504 names, 65 -> 0 with codes" reads as a name loss when it was codes.
printf '# private-names v1\n# generated: 2026-09-26 source: test\n' > "$out_file"
printf 'private\ttestns\tquarry\tR-002\t\n' >> "$out_file"
printf 'private\ttestns\tharbour\tR-003\t\n' >> "$out_file"
printf 'private\ttestns\tzzqqxx\tR-004\t\n' >> "$out_file"
out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
       PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
       bash "$SCRIPT" --owner testns --out "$out_file" 2>&1)"
if grep -q 'names carrying a code' <<<"$out" && ! grep -q '^\[ERROR\]   names:' <<<"$out"; then
  ok "the refusal names codes, not names, when only codes were lost"
else
  error "the refusal did not say which of the two shrank: ${out}"
fi

# --codes fills the column gh cannot supply. Without it every code is "-", and
# the gate loses the thing it tells people to cite instead of a name.
printf '# name\tcode\nquarry\tR-002\nharbour\tR-003\n' > "$tmp/codes"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes" \
  bash "$SCRIPT" --owner testns --stdout 2>/dev/null)"
code_for() { awk -F'\t' -v n="$1" '!/^#/ && $3 == n { print $4 }' <<<"$rows_out"; }

[[ "$(code_for quarry)"  == "R-002" ]] && ok "a code from --codes reaches the row" \
  || error "quarry got code '$(code_for quarry)', expected R-002"
[[ "$(code_for harbour)" == "R-003" ]] && ok "every listed name gets its code" \
  || error "harbour got code '$(code_for harbour)'"
[[ "$(code_for zzqqxx)"  == "-" ]] && ok "a name absent from --codes keeps -" \
  || error "zzqqxx got code '$(code_for zzqqxx)', expected -"

# and without the file, nothing gains a code
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/no-such-file" \
  bash "$SCRIPT" --owner testns --stdout 2>/dev/null)"
[[ "$(code_for quarry)" == "-" ]] && ok "no --codes file means no codes, not an error" \
  || error "a missing --codes file produced code '$(code_for quarry)'"

# A renamed repository is listed by gh under its new name only. Its old names
# come from the codes file's third column, and must be refused like the new one.
printf '# name\tcode\nquarry\tR-002\nharbour\tR-003\n' > "$tmp/codes-alias"
printf 'oldquarry\tR-002\talias-of=quarry\n' >> "$tmp/codes-alias"
printf 'olderquarry\tR-002\talias-of=quarry\n' >> "$tmp/codes-alias"
printf 'harbour\tR-009\talias-of=quarry\n' >> "$tmp/codes-alias"
printf 'ghostname\tR-007\talias-of=no-such-repo\n' >> "$tmp/codes-alias"
alias_err="$tmp/alias.err"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-alias" \
  bash "$SCRIPT" --owner testns --stdout 2>"$alias_err")"
row_for() { awk -F'\t' -v n="$1" '!/^#/ && $3 == n' <<<"$rows_out"; }

[[ "$(row_for oldquarry)" == $'private\ttestns\toldquarry\tR-002\talias' ]] \
  && ok "an alias is a private row in its repository's namespace, with the code and 'alias'" \
  || error "alias row was '$(row_for oldquarry)'"
[[ -n "$(row_for olderquarry)" ]] && ok "a second alias for the same repository is listed too" \
  || error "the second alias is missing"
[[ "$(code_for quarry)" == "R-002" && "$(row_for quarry | cut -f5)" != *alias* ]] \
  && ok "the current name keeps its code and is not marked alias" \
  || error "the current name changed: '$(row_for quarry)'"
[[ "$(row_for harbour | cut -f4)" == "R-003" && "$(row_for harbour | cut -f5)" != *alias* ]] \
  && grep -q 'skipped alias harbour: it is the name of a listed repository' "$alias_err" \
  && ok "an alias that is a listed name is skipped with a warning" \
  || error "an alias equal to a listed name was not skipped: '$(row_for harbour)'"
[[ -z "$(row_for ghostname)" ]] \
  && grep -q 'skipped alias ghostname: no-such-repo, the repository it points at, is not listed' "$alias_err" \
  && ok "an alias of a repository that is not listed is skipped, never invented" \
  || error "an alias of an unknown repository produced '$(row_for ghostname)'"

# The same repository name in two namespaces. An alias line names no
# namespace, so the old name is listed under every private repository of that
# name: citable by code in your own (the stub's login is testns), never-name in
# an organization's. Nothing is guessed and nothing is dropped.
mkdir -p "$tmp/cache-two" "$tmp/cache-three"
printf 'quarry\tPRIVATE\tfalse\n' > "$tmp/cache-two/otherorg.tsv"
printf 'quarry\tPRIVATE\tfalse\n' > "$tmp/cache-three/thirdorg.tsv"
printf 'quarry\tR-002\noldquarry\tR-002\talias-of=quarry\n' > "$tmp/codes-two"
two_err="$tmp/two.err"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache-two" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-two" \
  bash "$SCRIPT" --owner testns --stdout 2>"$two_err")"
[[ "$(row_for oldquarry | grep testns)" == $'private\ttestns\toldquarry\tR-002\talias' \
   && "$(row_for oldquarry | grep otherorg)" == $'private\totherorg\toldquarry\t-\talias never-name' ]] \
  && ok "with the name in two namespaces, the alias is listed in both: coded in yours, never-name in the other" \
  || error "the alias was not listed in both namespaces: '$(row_for oldquarry | tr '\n' '|')'"
# An organization's private repository is never-name, and never borrows the
# code of one of yours with the same name.
[[ "$(row_for quarry | grep otherorg)" == $'private\totherorg\tquarry\t-\tnever-name ambiguous' ]] \
  && ok "an organization's private repository is never-name and takes no code by name" \
  || error "an organization's repository row was '$(row_for quarry | grep otherorg)'"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache-three" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-two" \
  bash "$SCRIPT" --owner otherorg --stdout 2>"$two_err")"
[[ "$(row_for oldquarry | grep -c never-name)" == 2 && "$(row_for oldquarry | cut -f4 | sort -u)" == "-" ]] \
  && ok "with the name private in two organizations, the alias is never-name in both, not dropped" \
  || error "an alias in two organizations was dropped or coded: '$(row_for oldquarry | tr '\n' '|')'"

# A private copy wins over a public namesake: the renamed repository is an
# organization's private one, and your own account has a public repository of
# the same name. Filing the old name under the public one would make it a
# public row with no code, and it would stop being refused.
mkdir -p "$tmp/cache-pub"
printf 'quarry\tPUBLIC\tfalse\n' > "$tmp/cache-pub/testns.tsv"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache-pub" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-two" \
  bash "$SCRIPT" --owner otherorg --stdout 2>/dev/null)"
[[ "$(row_for oldquarry)" == $'private\totherorg\toldquarry\t-\talias never-name' ]] \
  && ok "an alias goes to the private copy, never to a public namesake in your own account" \
  || error "an old private name was filed under a public namesake: '$(row_for oldquarry)'"

# A former name another account has taken since. The caches are fresh, so
# nothing is refetched and the listing is exactly what is written here.
cached_rows() {   # <cache dir> <codes file> <stderr file>
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
    PRIVATE_NAMES_CACHE_DIR="$1" PRIVATE_NAMES_TTL_SELF=99 PRIVATE_NAMES_TTL_ORG=99 \
    PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
    PRIVATE_NAMES_CODES_FILE="$2" \
    bash "$SCRIPT" --owner testns --stdout 2>"$3"
}
mkdir -p "$tmp/cache-taken"
printf 'quarry\tPRIVATE\tfalse\n' > "$tmp/cache-taken/testns.tsv"
printf 'midname\tPUBLIC\tfalse\nwidget\tPUBLIC\tfalse\n' > "$tmp/cache-taken/otherorg.tsv"
printf 'quarry\tR-002\nmidname\tR-002\talias-of=quarry\noldname\tR-002\talias-of=midname\n' > "$tmp/codes-taken"
printf 'widget\tR-002\talias-of=quarry\n' >> "$tmp/codes-taken"
rows_out="$(cached_rows "$tmp/cache-taken" "$tmp/codes-taken" "$tmp/taken.err")"
[[ "$(row_for oldname)" == $'private\ttestns\toldname\tR-002\talias' ]] \
  && ok "a chain through a name another account has taken still ends at the renamed repository" \
  || error "a chain through a taken name went astray: '$(row_for oldname)'"
[[ "$(row_for midname | grep testns)" == $'private\ttestns\tmidname\tR-002\talias qualified-only' ]] \
  && [[ "$(row_for widget | grep testns)" == $'private\ttestns\twidget\tR-002\talias qualified-only' ]] \
  && ok "an old name that is public in another namespace stays, matched qualified" \
  || error "an old name public elsewhere was dropped: '$(row_for widget)' / '$(row_for midname)'"

# Chains, a missing code, an empty target and a name claimed twice.
{
  printf 'quarry\tR-002\nharbour\tR-003\n'
  printf 'midquarry\tR-002\talias-of=quarry\n'
  printf 'oldquarry\tR-002\talias-of=midquarry\n'
  printf 'nocodequarry\talias-of=quarry\n'
  printf 'emptytarget\tR-002\talias-of=\n'
  printf 'twiceclaimed\tR-003\talias-of=harbour\n'
  printf 'twiceclaimed\tR-002\talias-of=quarry\n'
} > "$tmp/codes-edge"
edge_err="$tmp/edge.err"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-edge" \
  bash "$SCRIPT" --owner testns --stdout 2>"$edge_err")"
[[ "$(row_for oldquarry)" == $'private\ttestns\toldquarry\tR-002\talias' && -n "$(row_for midquarry)" ]] \
  && ok "an alias that points at an older alias is followed to the repository" \
  || error "a chained alias was dropped: '$(row_for oldquarry)'"
[[ "$(row_for nocodequarry)" == $'private\ttestns\tnocodequarry\tR-002\talias' ]] \
  && ok "an alias line without a code takes its repository's code" \
  || error "an alias line without a code produced '$(row_for nocodequarry)'"
[[ -z "$(row_for emptytarget)" ]] && grep -q 'skipped alias emptytarget: alias-of= names no repository' "$edge_err" \
  && ok "an empty alias-of= is skipped with a warning, not read as a code" \
  || error "an empty alias-of= was not reported: '$(row_for emptytarget)'"
[[ "$(row_for twiceclaimed | cut -f4)" == "R-003" ]] && grep -q 'alias twiceclaimed is claimed by two repositories' "$edge_err" \
  && ok "one old name pointed at two repositories keeps the first and warns" \
  || error "a doubly claimed alias was not reported: '$(row_for twiceclaimed)'"

# Ambiguity is decided for the alias itself, not inherited.
printf 'quarry\tR-002\nharbour\tR-003\n' > "$tmp/codes-amb"
printf 'harbours\tR-003\talias-of=harbour\n' >> "$tmp/codes-amb"
printf 'harbours\n' >> "$tmp/words"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-amb" \
  bash "$SCRIPT" --owner testns --stdout 2>/dev/null)"
case "$(row_for harbours | cut -f5)" in
  *alias*ambiguous*) ok "an alias that is a dictionary word is flagged ambiguous" ;;
  *) error "alias ambiguity was not computed: '$(row_for harbours)'" ;;
esac

# The loss guard: a list that had an old name keeps it when the codes file
# carries the alias, so no --force is needed; without the alias it refuses.
printf '# private-names v1\n# generated: 2026-09-26 source: test\n' > "$out_file"
printf 'private\ttestns\tharbour\tR-003\t\n' >> "$out_file"
printf 'private\ttestns\toldquarry\tR-002\t\n' >> "$out_file"
printf 'private\ttestns\tquarry\tR-002\t\n' >> "$out_file"
printf 'private\ttestns\tzzqqxx\t-\t\n' >> "$out_file"
cp "$out_file" "$tmp/with-alias.tsv"
printf 'quarry\tR-002\nharbour\tR-003\noldquarry\tR-002\talias-of=quarry\n' > "$tmp/codes-guard"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-guard" \
  bash "$SCRIPT" --owner testns --out "$out_file" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && awk -F'\t' '$3=="oldquarry" && $4=="R-002" && $5 ~ /alias/ {f=1} END{exit !f}' "$out_file"; then
  ok "a refresh keeps an old name the codes file carries, without --force"
else
  error "the refresh with the alias was refused or dropped it (exit $rc)"
fi
cp "$tmp/with-alias.tsv" "$out_file"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes" \
  bash "$SCRIPT" --owner testns --out "$out_file" >/dev/null 2>&1
[[ $? -ne 0 ]] && cmp -s "$out_file" "$tmp/with-alias.tsv" \
  && ok "without the alias line the old name would be lost, so the write is refused" \
  || error "a refresh without the alias dropped the old name instead of refusing"

# --limit belongs to the `gh repo list` fallback only: GraphQL paginates, so
# there is no page size to overflow. A page that comes back exactly full is
# the only truncation signal gh offers, and the stub returns 3 repos, so
# --limit 3 looks full and --limit 4 does not.
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --stdout --no-graphql --limit 3 >/dev/null 2>&1
[[ $? -ne 0 ]] && ok "a full page is refused as probably truncated" \
               || error "a full page was accepted; a truncated list blocks nothing"

PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --stdout --no-graphql --limit 4 >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "a page under the limit is accepted" \
               || error "a page under the limit was refused"

# Org-wide `*` rows cannot come from gh, so a refresh must carry them over.
printf '# private-names v1\n# generated: 2026-09-26 source: test\n' > "$out_file"
printf 'private\totherorg\t*\t-\tnever-name\n' >> "$out_file"
printf 'private\ttestns\tquarry\tR-002\t\n' >> "$out_file"
printf 'private\ttestns\tharbour\tR-003\t\n' >> "$out_file"
printf 'private\ttestns\tzzqqxx\tR-004\t\n' >> "$out_file"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes" \
  bash "$SCRIPT" --owner testns --out "$out_file" --force >/dev/null 2>&1
if awk -F'\t' '$1=="private" && $2=="otherorg" && $3=="*" {found=1} END{exit !found}' "$out_file"; then
  ok "an org-wide row survives a refresh"
else
  error "the org-wide row was dropped, taking its never-name policy with it"
fi

# GraphQL is the default and has no limit to overflow, so the same limit that
# refuses the fallback must not refuse it.
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache-gql" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --stdout --limit 3 >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "--limit does not apply to the GraphQL path" \
               || error "--limit refused the GraphQL path, which has no page to fill"

# A listing that dies part-way must not be cached. gh --paginate failing on a
# later page leaves a short file that a size check calls complete.
mkdir -p "$tmp/badbin"
cat > "$tmp/badbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "api user") echo testself ;;
  "api graphql") printf 'a\tPRIVATE\tfalse\nb\tPRIVATE\tfalse\n'; exit 1 ;;
  *) echo 0 ;;
esac
STUB
chmod +x "$tmp/badbin/gh"
rm -rf "$tmp/partial"
out="$(PATH="$tmp/badbin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/partial" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --stdout 2>&1)"; rc=$?
if [[ $rc -eq 0 ]]; then
  error "a listing that failed part-way was accepted"
elif [[ -n "$(find "$tmp/partial" -name '*.tsv' 2>/dev/null)" ]]; then
  error "a partial listing was cached"
else
  ok "a listing that dies part-way is refused and not cached"
fi

# --check must ask GitHub. It reported "matches GitHub" while reading caches.
rm -rf "$tmp/checkcache"; mkdir -p "$tmp/checkcache"
printf 'quarry\tPRIVATE\tfalse\n' > "$tmp/checkcache/testns.tsv"
out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/checkcache" PRIVATE_NAMES_TTL_SELF=99 PRIVATE_NAMES_TTL_ORG=99 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$tmp/anyfile.tsv" --check 2>&1)"
if grep -q 'testns: fetching' <<<"$out"; then
  ok "--check refetches instead of answering from a cache"
else
  error "--check answered from a cache: it cannot compare with GitHub that way"
fi

# An organization's namespace is never-name in its own right, and gh cannot
# produce that row. It used to be inherited from the previous file, so a fresh
# machine had none and the namespace matched nothing.
rm -rf "$tmp/wildcache"
out_w="$tmp/wild.tsv"; rm -f "$out_w"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/wildcache" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner someorg --out "$out_w" >/dev/null 2>&1
if awk -F'\t' '$1=="private" && $2=="someorg" && $3=="*" && $5 ~ /never-name/ {f=1} END{exit !f}' "$out_w"; then
  ok "an organization gets a never-name row on a machine with no previous file"
else
  error "no org-wide row was derived, so the namespace itself matches nothing"
fi
if awk -F'\t' '$2=="someorg" && $3!="*" && !($4=="-" && $5 ~ /never-name/) {bad=1} $2=="someorg" && $3!="*" {n++} END{exit !(n && !bad)}' "$out_w"; then
  ok "every private repository of an organization is never-name, with no code"
else
  error "an organization's repository is citable: $(awk -F'\t' '$2=="someorg" && n++ < 3' "$out_w")"
fi

# ...but not for your own account, which has a public form: its code.
rm -rf "$tmp/selfcache"; out_s="$tmp/self.tsv"; rm -f "$out_s"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/selfcache" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$out_s" >/dev/null 2>&1
if awk -F'\t' '$2=="testns" && $3=="*" {f=1} END{exit !f}' "$out_s"; then
  error "your own account was marked never-name; its repositories have codes"
else
  ok "your own account gets no never-name row"
fi

# Without your login an organization's repositories cannot be told from yours:
# refuse rather than write a list in which none of them is never-name.
mkdir -p "$tmp/nologinbin"
sed 's/"api user")      echo "testns" ;;/"api user")      exit 1 ;;/' "$tmp/bin/gh" > "$tmp/nologinbin/gh"
chmod +x "$tmp/nologinbin/gh"
out_n="$tmp/nologin.tsv"; printf 'keep\n' > "$out_n"
PATH="$tmp/nologinbin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/nologincache" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner someorg --out "$out_n" >/dev/null 2>&1; rc=$?
[[ $rc -eq 3 && "$(cat "$out_n")" == "keep" ]] \
  && ok "a token whose login cannot be read writes nothing (exit 3)" \
  || error "a refresh without your login wrote a list (exit $rc)"

# Logins ignore case: --owner TestNS is your own account, not an organization.
rm -rf "$tmp/casecache"; out_c="$tmp/case.tsv"; rm -f "$out_c"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/casecache" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner TestNS --out "$out_c" >/dev/null 2>&1; rc=$?
if [[ $rc -ne 0 || ! -s "$out_c" ]]; then
  error "a refresh with your login in other case failed (exit $rc)"
elif awk -F'\t' '$3=="*" || $5 ~ /never-name/ {f=1} END{exit !f}' "$out_c"; then
  error "your own account in other case was treated as an organization"
else
  ok "your own account in other case is still yours"
fi

# Two caches of your own account in different case: only the newest is read,
# so its repositories are not listed twice and an alias into it still resolves.
rm -rf "$tmp/dupcache"; mkdir -p "$tmp/dupcache"
printf 'quarry\tPRIVATE\tfalse\n' > "$tmp/dupcache/TestNS.tsv"
touch -d '2 days ago' "$tmp/dupcache/TestNS.tsv" 2>/dev/null || touch -t 202001010000 "$tmp/dupcache/TestNS.tsv"
printf 'quarry\tR-002\noldquarry\tR-002\talias-of=quarry\n' > "$tmp/codes-dup"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/dupcache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-dup" \
  bash "$SCRIPT" --owner testns --stdout 2>/dev/null)"
[[ "$(row_for quarry | wc -l | tr -d ' ')" == 1 && "$(row_for oldquarry)" == $'private\ttestns\toldquarry\tR-002\talias' ]] \
  && ok "two caches of one account in other case are read once, and its aliases resolve" \
  || error "a second-case cache doubled the account: quarry '$(row_for quarry | tr '\n' '|')', alias '$(row_for oldquarry)'"

# A `*` row for your own account, left by an older version, is not carried.
rm -rf "$tmp/staleself"; out_ss="$tmp/staleself.tsv"
printf '# visibility\tnamespace\tname\tcode\tflags\nprivate\tTestNS\t*\t-\tnever-name\n' > "$out_ss"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/staleself" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$out_ss" --force >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]] && ! awk -F'\t' 'tolower($2)=="testns" && $3=="*" {f=1} END{exit !f}' "$out_ss"; then
  ok "a stale never-name row for your own account is dropped"
else
  error "your own account kept a never-name row (exit $rc)"
fi

# Your own account typed in another case: written as your login, so a run with
# discovered owners afterwards is not refused as a namespace that lost names.
rm -rf "$tmp/flipcache"; out_f="$tmp/flip.tsv"; rm -f "$out_f"
flip_run() {
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
    PRIVATE_NAMES_CACHE_DIR="$tmp/flipcache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
    PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
    PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
    bash "$SCRIPT" "$@" --out "$out_f" >/dev/null 2>&1
}
flip_run --owner TestNS; rc1=$?
sleep 1
flip_run --owner testns; rc2=$?
if [[ $rc1 -eq 0 && $rc2 -eq 0 ]] && ! awk -F'\t' '$2=="TestNS"{f=1} END{exit !f}' "$out_f"; then
  ok "your own account is written as your login, whatever case was typed"
else
  error "a run after --owner in other case was refused or kept the typed case (exit $rc1, $rc2)"
fi

# A list from an older version: your account twice in two cases, plus a `*` row
# for it. Merging those is not a loss, so no --force is needed.
rm -rf "$tmp/upcache"; out_u="$tmp/up.tsv"
{
  printf '# visibility\tnamespace\tname\tcode\tflags\n'
  printf 'private\ttestns\tquarry\t-\tambiguous\n'
  printf 'private\tTestNS\tquarry\t-\tambiguous\n'
  printf 'private\tTestNS\t*\t-\tnever-name\n'
} > "$out_u"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/upcache" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --out "$out_u" >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 ]] && ! awk -F'\t' '$3=="*" && tolower($2)=="testns" {f=1} END{exit !f}' "$out_u"; then
  ok "an older list's case duplicates and own-account * row are merged without --force"
else
  error "an older list's case duplicates were refused as a loss (exit $rc)"
fi

# A chain through a name that is a repository in the same namespace now ends
# there: the renamed repository left it, and a new one took it.
printf 'quarry\tR-002\nharbour\tR-003\nquarry\talias-of=harbour\noldthing\talias-of=quarry\n' > "$tmp/codes-reuse"
rows_out="$(PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/cache" PRIVATE_NAMES_TTL_SELF=0 PRIVATE_NAMES_TTL_ORG=0 \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/codes-reuse" \
  bash "$SCRIPT" --owner testns --stdout 2>/dev/null)"
[[ "$(row_for oldthing | cut -f4)" == "R-002" ]] \
  && ok "a chain stops at a name a repository in the same namespace has now" \
  || error "a chain went past a live name in its own namespace: '$(row_for oldthing)'"

# ...but a public repository that took a name along the chain never takes the
# old name from the private repository at the end of it.
mkdir -p "$tmp/cache-pubmid"
printf 'quarry\tPRIVATE\tfalse\nmidpub\tPUBLIC\tfalse\n' > "$tmp/cache-pubmid/testns.tsv"
printf 'quarry\tR-002\nmidpub\talias-of=quarry\noldpriv\talias-of=midpub\n' > "$tmp/codes-pubmid"
rows_out="$(cached_rows "$tmp/cache-pubmid" "$tmp/codes-pubmid" /dev/null)"
[[ "$(row_for oldpriv)" == $'private\ttestns\toldpriv\tR-002\talias' ]] \
  && ok "a public repository along a chain does not take a private repository's old name" \
  || error "an old private name went to a public repository: '$(row_for oldpriv)'"

# A public repository's old name does not relax a private namesake elsewhere.
mkdir -p "$tmp/cache-pubold"
printf 'pubnew\tPUBLIC\tfalse\n' > "$tmp/cache-pubold/testns.tsv"
printf 'orgsecret\tPRIVATE\tfalse\n' > "$tmp/cache-pubold/otherorg.tsv"
printf 'orgsecret\talias-of=pubnew\n' > "$tmp/codes-pubold"
rows_out="$(cached_rows "$tmp/cache-pubold" "$tmp/codes-pubold" /dev/null)"
[[ "$(row_for orgsecret | grep otherorg | cut -f5)" == "never-name" ]] \
  && ok "a public repository's old name leaves a private namesake matched bare" \
  || error "a public old name relaxed a private namesake: '$(row_for orgsecret | grep otherorg)'"

# A namespace that has a name along the chain, though not its end, gets the
# alias too: the chain ends there, at the repository that has the name now.
mkdir -p "$tmp/cache-mid"
printf 'bravo\tPRIVATE\tfalse\n' > "$tmp/cache-mid/testns.tsv"
printf 'charlie\tPRIVATE\tfalse\n' > "$tmp/cache-mid/otherorg.tsv"
printf 'bravo\tR-001\ncharlie\tR-009\nab1\talias-of=bravo\nbravo\talias-of=charlie\n' > "$tmp/codes-mid"
rows_out="$(cached_rows "$tmp/cache-mid" "$tmp/codes-mid" /dev/null)"
[[ "$(row_for ab1 | grep testns | cut -f2,4)" == $'testns\tR-001' && -n "$(row_for ab1 | grep otherorg)" ]] \
  && ok "a namespace with a middle name of the chain lists the alias under that repository" \
  || error "a namespace holding a middle name of the chain did not get the alias: '$(row_for ab1 | tr '\n' '|')'"

# A former name never switches the check off in a public repository that has
# that name now: --only-public reads the visibility of the current repository.
rm -rf "$tmp/op"; mkdir -p "$tmp/op"
{
  printf '# visibility\tnamespace\tname\tcode\tflags\n'
  printf 'private\tmeuser\tfoothing\tR-1\talias qualified-only\n'
  printf 'private\tmeuser\tquietgadget\tR-2\t\n'
  printf 'public\tzeta-org\tfoothing\t-\n'
} > "$tmp/op/list.tsv"
git -C "$tmp/op" init -q 2>/dev/null
git -C "$tmp/op" remote add origin https://github.com/zeta-org/foothing.git
printf 'see quietgadget\n' > "$tmp/op/README.md"
git -C "$tmp/op" add README.md
( cd "$tmp/op" && bash "$ROOT_DIR/scripts/check_private_names.sh" --tree --only-public --list "$tmp/op/list.tsv" >/dev/null 2>&1 ); rc=$?
[[ $rc -ne 0 ]] && ok "an alias row does not make a public repository of that name read as private" \
  || error "--only-public skipped a public repository because an old private name matched it"

# A non-numeric TTL is not a smaller number, it is no check: find -mtime +abc
# errors, prints nothing, and the cache reads as fresh. --ttl abc silently
# meant "never refetch", and the log said "under abcd".
for bad in abc -1 1.5; do
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
    PRIVATE_NAMES_CACHE_DIR="$tmp/ttlcache" \
    PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
    PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
    bash "$SCRIPT" --owner testns --stdout --ttl "$bad" >/dev/null 2>&1
  [[ $? -eq 2 ]] && ok "--ttl ${bad} is refused" || error "--ttl ${bad} was accepted"
done

PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/ttlcache2" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner testns --stdout --ttl 0 >/dev/null 2>&1
[[ $? -eq 0 ]] && ok "--ttl 0 is still accepted" || error "--ttl 0 was refused"

# An owner is a file name under the cache directory; a path in it is refused
# before anything is fetched or written.
for bad in "../escape" "a/b" "testns,../x" ".hidden" "-dash" $'\xc3\xa9'; do
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
    PRIVATE_NAMES_CACHE_DIR="$tmp/ownercache/c" \
    bash "$SCRIPT" --owner "$bad" --stdout >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 2 && ! -e "$tmp/ownercache/escape.tsv" && ! -e "$tmp/ownercache/x.tsv" ]]; then
    ok "--owner '${bad}' is refused"
  else
    error "--owner '${bad}' was accepted (exit ${rc})"
  fi
done
printf '#!/bin/sh\n: > "%s/owner-was-run"\n' "$tmp" > "$tmp/bin/test-ns"
chmod +x "$tmp/bin/test-ns"
PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
  PRIVATE_NAMES_CACHE_DIR="$tmp/ownercache2" \
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
  PRIVATE_NAMES_CODES_FILE="$tmp/does-not-exist" \
  bash "$SCRIPT" --owner "test-ns, Other1, mona_acme" --stdout >/dev/null 2>"$tmp/owner-stderr"
[[ $? -eq 0 ]] && ok "valid owner names are still accepted, one with '_' included" || error "valid owner names were refused: $(cat "$tmp/owner-stderr")"
# The owner list is data. A program on PATH named like the first owner is not
# run, and a clean run reports no missing command.
if [[ -e "$tmp/owner-was-run" ]]; then error "the first owner was run as a command"; else ok "an owner is never run as a command"; fi
if grep -q "command not found" "$tmp/owner-stderr"; then
  error "a run printed: $(grep -m 1 "command not found" "$tmp/owner-stderr")"
else
  ok "a run reports no missing command"
fi

if [[ $failures -gt 0 ]]; then
  echo "[refresh_private_names_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
