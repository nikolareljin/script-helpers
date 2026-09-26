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
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "repo list")
    printf '[{"name":"quarry","visibility":"PRIVATE","isArchived":false},'
    printf '{"name":"harbour","visibility":"PRIVATE","isArchived":false},'
    printf '{"name":"zzqqxx","visibility":"PRIVATE","isArchived":false}]'
    ;;
  *) exit 0 ;;
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
  PRIVATE_NAMES_NEVER_AMBIGUOUS_FILE="$tmp/does-not-exist" \
    bash "$SCRIPT" --owner testns --stdout 2>/dev/null \
    | awk -F'\t' -v n="$1" '!/^#/ && $3 == n { print $5 }'
}

# Without this, every case below passes against an empty list.
gen() {   # <override-file>
  PATH="$tmp/bin:$PATH" PRIVATE_NAMES_WORDLIST="$tmp/words" \
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

if [[ $failures -gt 0 ]]; then
  echo "[refresh_private_names_test] FAILED ($failures)" >&2
  exit 1
fi
note "ALL PASSED"
