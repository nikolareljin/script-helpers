#!/usr/bin/env bash
# SCRIPT: model_select_check.sh
# DESCRIPTION: Real-machine check of scripts/ollama_models.sh select on Linux or macOS: the tier this machine measures, and a select against the Ollama on 127.0.0.1:11434 with pulling off. No model is pulled or removed.
# USAGE: bash tests/machine/model_select_check.sh [--keep] [-h]
# PARAMETERS:
#   --keep      Leave the throwaway directory for inspection (its path is printed).
#   -h, --help  Show this help.
# EXIT_CODES:
#   0  every case passed
#   1  a case failed
#   2  bad arguments, or this machine cannot run the check (no Ollama on 127.0.0.1:11434)
# EXAMPLE:
#   bash tests/machine/model_select_check.sh
# ----------------------------------------------------
# Not part of `make test`. OLLAMA_PULL_MISSING=0 throughout, so a missing model
# is reported (5 or 12), never fetched. The .env written is in a directory made here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
keep=false
for arg in "$@"; do
  case "$arg" in
    --keep) keep=true ;;
    -h|--help) sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

URL=http://127.0.0.1:11434
curl -fsS -m 3 "$URL/api/tags" >/dev/null 2>&1 || { echo "SKIP: no Ollama answers at $URL"; exit 2; }

passed=0
failed=0
case_() { # case_ <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    printf 'PASS  %s\n' "$1"; passed=$((passed + 1))
  else
    printf 'FAIL  %s\n      expected [%s]\n      got      [%s]\n' "$1" "$2" "$3"; failed=$((failed + 1))
  fi
}
work="$(mktemp -d)"
cleanup() { if [[ "$keep" == true ]]; then echo "kept: $work"; else rm -rf "$work"; fi; }
trap cleanup EXIT
script="$ROOT/scripts/ollama_models.sh"
unset AI_MODEL_TIER OLLAMA_MODEL
export OLLAMA_PULL_MISSING=0

before="$(curl -fsS -m 5 "$URL/api/tags")"
tier="$(cd "$work" && bash "$script" class | sed -n 's/^tier=//p')"
case "$tier" in small|standard|large|xlarge) case_ "class measures a tier ($tier)" ok ok ;; *) case_ "class measures a tier" "a tier" "$tier" ;; esac

rc=0; out="$(cd "$work" && bash "$script" select general "$URL" "$work/.env" OLLAMA_MODEL </dev/null 2>"$work/err")" || rc=$?
case "$rc" in
  0) case_ "select prints one model on stdout ($out)" 1 "$(printf '%s\n' "$out" | grep -c .)" ;;
  5) case_ "select reports the tier's model missing, pulls nothing" 5 "$rc" ;;
  *) case_ "select exits 0 or 5" "0 or 5" "$rc $(tail -n 1 "$work/err")" ;;
esac
rc=0; (cd "$work" && bash "$script" select general "$URL" "$work/.env" "" no-such-model:1b </dev/null >/dev/null 2>&1) || rc=$?
case "$rc" in 0|12) case_ "no terminal, differing model: tier pick or 12 ($rc)" ok ok ;; *) case_ "no terminal, differing model" "0 or 12" "$rc" ;; esac
case_ "nothing was pulled or removed" "$before" "$(curl -fsS -m 5 "$URL/api/tags")"

echo "summary: $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
