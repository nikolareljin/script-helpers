#!/usr/bin/env bash
# SCRIPT: ollama_endpoint_trim_test.sh
# DESCRIPTION: lib/ollama_endpoint.sh trims settings and models-file values in the shell; the result must match the sed and tr it replaced.
# USAGE: ./tests/ollama_endpoint_trim_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ollama_endpoint_trim_test.sh
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1
# shellcheck source=/dev/null
source lib/ollama_endpoint.sh || exit 1

failures=0
error() { echo "[ollama_endpoint_trim_test][ERROR] $*" >&2; failures=$((failures+1)); }
shown() { printf '%s' "$1" | od -An -c | tr -s ' \n' ' '; }

tmp="$(mktemp -d)" || exit 1
owner=${BASHPID-$$}
trap 'if [[ ${BASHPID-$$} == "$owner" ]]; then rm -rf "$tmp"; fi' EXIT

# The result goes only to the named variable. Checked first, before any
# other call could have made the same variable.
got=""
before="$(compgen -v | grep -v -x -e BASH_REMATCH -e _ -e before | sort)"
_ollama_ep_trim got $'  a\n b  '; _ollama_ep_trim got "  a  "; _ollama_ep_squeeze got "a b"
after="$(compgen -v | grep -v -x -e BASH_REMATCH -e _ -e before | sort)"
[[ "$before" == "$after" ]] || error "a helper left a variable behind: $(comm -13 <(echo "$before") <(echo "$after") | tr '\n' ' ')"

inputs=(
  "" " " $'\t' "a" " a" "a " "  a b  " $'\ta\t' $'a\r' $'\r a \r' $'\v\fa\f\v'
  "a #b" "a # b # c" "a#b" " #b" "#b" $'a\t#b' $'a \t #b  ' "a  #" "a b#c d #e"
  $'a\nb' $'  a \n  b  ' $'a\n' $'\na' "x y z" "'q'" "\"q\""
)

# The references: the commands the library ran before.
ref_trim()    { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
ref_squeeze() { printf '%s' "$1" | tr -d ' \t\r\n'; }
ref_comment() { printf '%s' "$1" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//'; }

for v in "${inputs[@]}"; do
  want="$(ref_trim "$v")" || true
  _ollama_ep_trim got "$v"
  [[ "$got" == "$want" ]] || error "trim [$(shown "$v")]: expected [$(shown "$want")], got [$(shown "$got")]"

  want="$(ref_squeeze "$v")" || true
  _ollama_ep_squeeze got "$v"
  [[ "$got" == "$want" ]] || error "squeeze [$(shown "$v")]: expected [$(shown "$want")], got [$(shown "$got")]"

  # A models-file value: one line, after NAME=. Quoted values keep everything.
  case "$v" in *$'\n'*|*$'\r'*) continue ;; esac
  printf 'M=%s\n' "$v" >"$tmp/models.env"
  got="$(ollama_models_file_get "$tmp/models.env" M)"
  stripped="$(printf '%s' "$v" | sed -E 's/^[[:space:]]*//')"
  case "$stripped" in
    \"*\"*|\'*\'*) continue ;;
  esac
  want="$(ref_comment "$stripped")" || true
  [[ "$got" == "$want" ]] || error "file value [$(shown "$v")]: expected [$(shown "$want")], got [$(shown "$got")]"
done

# Whole files, against the sed and tail that read them before.
ref_file_get() { # ref_file_get <file> <name>: the old reader, then the same unquoting
  local value bom=$'\xef\xbb\xbf'
  value="$(sed -n -E "1s/^${bom}//; s/^[[:space:]]*(export[[:space:]]+)?${2}[[:space:]]*=[[:space:]]*//p" "$1" | tail -n 1)" || true
  value="${value%$'\r'}"
  case "$value" in
    \"*\"*) value="${value#\"}"; value="${value%%\"*}" ;;
    \'*\'*) value="${value#\'}"; value="${value%%\'*}" ;;
    *) value="$(ref_comment "$value")" || true ;;
  esac
  printf '%s\n' "$value"
}
files=(
  $'\xef\xbb\xbfM=bom\n'
  $'M=first\nM=last\n'
  $'M=no-newline'
  $'M=crlf\r\nN=x\r\n'
  $'export M = spaced # note\n'
  $'  export\tM\t=\tq\n'
  $'MX=longer\nXM=other\n'
  $'M=one\nMX=longer\n'
  $'# M=commented\n'
  $'M=\n'
  $'M= \r\n'
  $'M="quoted # kept"\n'
  $'M=\'single\' # c\n'
  $'M=\xff\xfe raw # c\n'
  $'\n\nM=after blank lines\n\n'
  $'M=a\nexportM=b\n'
  ''
)
for content in "${files[@]}"; do
  printf '%s' "$content" >"$tmp/models.env"
  for n in M MX N; do
    want="$(ref_file_get "$tmp/models.env" "$n")"
    got="$(ollama_models_file_get "$tmp/models.env" "$n")"
    [[ "$got" == "$want" ]] || error "file [$(shown "$content")] $n: expected [$(shown "$want")], got [$(shown "$got")]"
  done
done

# The single-line cases start no sed and no tr: a PATH without them still works.
(
  # shellcheck disable=SC2123 # an empty PATH is the point
  PATH="$tmp/empty"
  _ollama_ep_trim got "  a b  " && [[ "$got" == "a b" ]] || exit 1
  _ollama_ep_squeeze got $' a\tb\r\n' && [[ "$got" == "ab" ]] || exit 1
) || error "trim or squeeze needed an external command"

if [[ "$failures" -ne 0 ]]; then
  echo "[ollama_endpoint_trim_test] $failures failure(s)" >&2
  exit 1
fi
echo "[ollama_endpoint_trim_test] all passed"
