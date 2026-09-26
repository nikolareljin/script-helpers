#!/usr/bin/env bash
# SCRIPT: refresh_private_names_test.sh
# DESCRIPTION: Tests how scripts/refresh_private_names.sh flags a name as ambiguous.
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
  "api user")      echo "testself" ;;
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

if [[ $failures -gt 0 ]]; then
  echo "[refresh_private_names_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
