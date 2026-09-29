#!/usr/bin/env bash
# SCRIPT: dev_scan_test.sh
# DESCRIPTION: Tests `./dev scan` / `preflight.sh --security-only` and ci_security.sh --fail-on-findings.
# USAGE: bash tests/dev_scan_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_scan_test.sh
# preflight refuses to run under CI=true, so it runs here with CI="" (as tests/preflight_test.sh does).
# ----------------------------------------------------
#
# ci_security.sh ended every check in `|| true`, so a committed secret still
# gave "PASS  security scan". The scan now fails on findings, and gitleaks then
# scans what git tracks: a secret in an ignored .env is not the repository's.
# A stub gitleaks records its arguments and "finds" the word LEAKME in the files
# its mode covers, so these cases do not depend on gitleaks' rules.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_scan_test] $*"; }
error() { echo "[dev_scan_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gitleaks" <<'EOF'
#!/usr/bin/env bash
echo "gitleaks $*" >> "$GL_LOG"
if [[ " $* " == *" --no-git "* ]]; then
  files="$(find . -type f -not -path './.git/*')"
else
  files="$(git ls-files)"
fi
# shellcheck disable=SC2086
if [[ -n "$files" ]] && grep -l LEAKME $files >/dev/null 2>&1; then echo "leaks found: 1"; exit 1; fi
echo "no leaks found"
EOF
chmod +x "$tmp/bin/gitleaks"
export GL_LOG="$tmp/gitleaks.log"

new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  git -C "$r" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  echo "$r"
}
commit() { git -C "$1" add -A && git -C "$1" -c user.name=t -c user.email=t@example.com commit -q -m c; }

# scan <repo> [extra args]; runs preflight --security-only, sets OUT and RC.
scan() {
  local r="$1"; shift
  : > "$GL_LOG"; RC=0
  OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/preflight.sh" --security-only "$@" 2>&1)" || RC=$?
}

# 1. No stack needed; a clean repository passes; gitleaks runs in git mode.
r="$(new_repo clean)"
scan "$r"
if [[ $RC -eq 0 && "$OUT" == *"PASS  security scan"* ]] && grep -q "^gitleaks detect --source \.$" "$GL_LOG"; then
  note "clean repository: PASS, gitleaks in git mode, no stack needed"
else
  error "clean: rc=$RC log='$(cat "$GL_LOG")' out='$(printf '%s' "$OUT" | tail -4)'"
fi

# 2. A committed secret fails the scan.
printf 'token = LEAKME\n' > "$r/creds.txt"; commit "$r"
scan "$r"
if [[ $RC -eq 1 && "$OUT" == *"FAIL  security scan"* ]]; then
  note "committed secret: FAIL, exit 1"
else
  error "committed: rc=$RC out='$(printf '%s' "$OUT" | tail -4)'"
fi

# 2b. From a subdirectory (--workdir sub): git mode still applies there. A fresh
# repository: real gitleaks in git mode reads the whole history, so the secret
# committed above would be found from any subdirectory.
r="$(new_repo subdir)"
mkdir -p "$r/backend"; printf 'x\n' > "$r/backend/a.txt"; commit "$r"
: > "$GL_LOG"; RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker --workdir backend --skip-python --skip-node --fail-on-findings 2>&1)" || RC=$?
if [[ $RC -eq 0 ]] && grep -q "^gitleaks detect --source \.$" "$GL_LOG"; then
  note "--workdir subdirectory: gitleaks in git mode"
else
  error "subdirectory: rc=$RC log='$(cat "$GL_LOG")' out='$(printf '%s' "$OUT" | tail -3)'"
fi
printf 'token = LEAKME\n' > "$r/backend/c.txt"; commit "$r"
RC=0
(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker --workdir backend --skip-python --skip-node --fail-on-findings >/dev/null 2>&1) || RC=$?
[[ $RC -eq 1 ]] && note "--workdir subdirectory: a committed secret there fails" \
  || error "subdirectory secret: rc=$RC"

# 3. A secret only in an ignored file does not.
r="$(new_repo ignored)"
printf '.env\n' > "$r/.gitignore"; commit "$r"
printf 'KEY=LEAKME\n' > "$r/.env"
scan "$r"
if [[ $RC -eq 0 && "$OUT" == *"PASS  security scan"* ]]; then
  note "secret only in an ignored .env: PASS"
else
  error "ignored: rc=$RC out='$(printf '%s' "$OUT" | tail -4)'"
fi

# 4. No package.json: npm audit is skipped, not counted as a finding.
if [[ "$OUT" == *"No package.json; skipping npm audit"* ]]; then
  note "no package.json: npm audit skipped"
else
  error "npm audit was not skipped without package.json"
fi

# 5. Without gitleaks: a SKIP line, not a silent PASS for secrets.
mkdir -p "$tmp/nogl"
for c in bash git env dirname basename mktemp head rm cat grep sed awk tr uname find sort date mkdir id; do
  p="$(command -v "$c")" && ln -sf "$p" "$tmp/nogl/$c"
done
RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/nogl" "$(command -v bash)" "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || RC=$?
if [[ "$OUT" == *"SKIP  gitleaks secret scan — gitleaks is not installed"* ]]; then
  note "no gitleaks: reported as SKIP in the summary"
else
  error "no gitleaks: rc=$RC out='$(printf '%s' "$OUT" | tail -4)'"
fi

# 6. --skip-security and --security-only together are refused.
RC=0
(cd "$r" && CI="" bash "$ROOT_DIR/scripts/preflight.sh" --security-only --skip-security >/dev/null 2>&1) || RC=$?
[[ $RC -eq 2 ]] && note "--skip-security with --security-only: exit 2" \
  || error "conflicting flags: rc=$RC"

# 7. The pre-push run stays report-only and says so.
if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
  r="$(new_repo prepush)"
  printf '{"name":"x","version":"1.0.0","scripts":{"test":"node -e \\"process.exit(0)\\""}}\n' > "$r/package.json"
  printf 'token = LEAKME\n' > "$r/creds.txt"; commit "$r"
  : > "$GL_LOG"; RC=0
  OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/preflight.sh" --quick --stack node 2>&1)" || RC=$?
  if [[ $RC -eq 0 && "$OUT" == *"PASS  security scan (report only)"* ]] && grep -q -- "--no-git" "$GL_LOG"; then
    note "pre-push preflight: report only, labelled so, exit 0"
  else
    error "pre-push: rc=$RC log='$(cat "$GL_LOG")' out='$(printf '%s' "$OUT" | tail -4)'"
  fi
else
  note "SKIP pre-push case: node or npm is not installed"
fi

# 8. ./dev scan runs the security-only preflight; help lists it.
d="$(new_repo devcli)"
mkdir -p "$d/scripts"
cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$d/scripts/"
ln -s "$ROOT_DIR" "$d/scripts/script-helpers"
RC=0
OUT="$(cd "$d" && CI="" PATH="$tmp/bin:$PATH" bash scripts/cli.sh scan 2>&1)" || RC=$?
if [[ $RC -eq 0 && "$OUT" == *"security scan only"* && "$OUT" == *"PASS  security scan"* ]]; then
  note "./dev scan: security-only preflight"
else
  error "./dev scan: rc=$RC out='$(printf '%s' "$OUT" | tail -4)'"
fi
OUT="$(cd "$d" && bash scripts/cli.sh help 2>&1)"
[[ "$OUT" == *"scan          Secret and dependency scan only"* ]] && note "help lists scan" \
  || error "help does not list scan"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
