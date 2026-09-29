#!/usr/bin/env bash
# SCRIPT: dev_scan_audits_test.sh
# DESCRIPTION: Tests that ./dev scan audits dependencies in each project, and reports an audit that could not run as SKIP.
# USAGE: bash tests/dev_scan_audits_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_scan_audits_test.sh
# preflight refuses to run under CI=true, so it runs here with CI="".
# ----------------------------------------------------
#
# The audits used to run only at the repository root. A repository with its
# projects in backend/ (pyproject.toml) and frontend/ (package-lock.json) got
# gitleaks alone, and "PASS  security scan". Stub tools record the directory
# they ran in and their arguments; *_FAIL variables make one report a finding.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_scan_audits_test] $*"; }
error() { echo "[dev_scan_audits_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin"
stub() {
  local name="$1" fail_var="$2"
  cat > "$tmp/bin/$name" <<EOF
#!/usr/bin/env bash
echo "$name \$(basename "\$(pwd -P)") \$*" >> "\$AUDIT_LOG"
[[ -n "\${$fail_var:-}" ]] && { echo "$name: 1 finding"; exit 1; }
exit 0
EOF
  chmod +x "$tmp/bin/$name"
}
stub pip-audit PIPAUDIT_FAIL
stub safety SAFETY_FAIL
stub bandit BANDIT_FAIL
stub npm NPM_FAIL
stub gitleaks GITLEAKS_FAIL
export AUDIT_LOG="$tmp/audit.log"
# Hermetic: no real foxguard from this machine's cache.
export XDG_CACHE_HOME="$tmp/cache"

new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  git -C "$r" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  echo "$r"
}
# two_projects <repo> [python manifest]; backend/ Python, frontend/ Node with a lockfile.
two_projects() {
  mkdir -p "$1/backend" "$1/frontend"
  case "${2:-pyproject}" in
    pyproject) printf '[project]\nname = "b"\nversion = "0.1.0"\n' > "$1/backend/pyproject.toml" ;;
    requirements) printf 'requests==2.32.3\n' > "$1/backend/requirements.txt" ;;
  esac
  printf '{"name":"f","version":"1.0.0"}\n' > "$1/frontend/package.json"
  printf '{"lockfileVersion":3}\n' > "$1/frontend/package-lock.json"
  printf 'python backend\nnode frontend\n' > "$1/.preflight"
}
# scan <repo> [PATH]; ./dev scan (preflight --security-only); sets OUT and RC.
scan() {
  : > "$AUDIT_LOG"; RC=0
  OUT="$(cd "$1" && CI="" PATH="${2:-$tmp/bin:$PATH}" "$(command -v bash)" "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || RC=$?
}
summary() { printf '%s\n' "$OUT" | sed -n '/^preflight summary/,$p'; }

# 1. pyproject.toml in backend/, a lockfile in frontend/: each audited where it is.
r="$(new_repo pyproj)"; two_projects "$r"
scan "$r"
if [[ $RC -eq 0 ]] && summary | grep -q "PASS  python (backend/) dependency audit" \
   && summary | grep -q "PASS  node (frontend/) dependency audit" \
   && grep -q "^pip-audit backend \.$" "$AUDIT_LOG" && grep -q "^npm frontend audit --audit-level=high$" "$AUDIT_LOG" \
   && ! grep -q "^safety" "$AUDIT_LOG"; then
  note "backend/ and frontend/: pip-audit . and npm audit run in each; safety not run for pyproject.toml"
else
  error "pyproject: rc=$RC log='$(cat "$AUDIT_LOG")' summary='$(summary)'"
fi

# 2. bandit leaves the virtualenv and build output out.
grep -qE "^bandit backend -r \. -ll -x \./\.venv,\./venv,\./node_modules,\./build,\./dist$" "$AUDIT_LOG" \
  && note "bandit excludes .venv, venv, node_modules, build, dist" || error "bandit args: $(grep '^bandit' "$AUDIT_LOG")"

# 3. A requirements file: pip-audit -r and safety both run.
r="$(new_repo reqs)"; two_projects "$r" requirements
scan "$r"
if [[ $RC -eq 0 ]] && grep -q "^pip-audit backend -r requirements.txt$" "$AUDIT_LOG" \
   && grep -q "^safety backend check -r requirements.txt --full-report$" "$AUDIT_LOG"; then
  note "requirements.txt: pip-audit -r and safety"
else
  error "requirements: rc=$RC log='$(cat "$AUDIT_LOG")'"
fi

# 4. A finding in one project fails the scan, and the summary names the project.
r="$(new_repo finding)"; two_projects "$r"
: > "$AUDIT_LOG"; RC=0
OUT="$(cd "$r" && NPM_FAIL=1 CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || RC=$?
if [[ $RC -eq 1 ]] && summary | grep -q "FAIL  node (frontend/) dependency audit" \
   && summary | grep -q "PASS  python (backend/) dependency audit"; then
  note "npm audit finding in frontend/: that step fails, exit 1"
else
  error "finding: rc=$RC summary='$(summary)'"
fi

# 5. No lockfile: the npm audit is a SKIP with its reason, not a PASS.
rm -f "$r/frontend/package-lock.json"
scan "$r"
if [[ $RC -eq 0 ]] && summary | grep -q "SKIP  node (frontend/) dependency audit — No package-lock.json; npm audit needs one and did not run." \
   && ! grep -q "^npm" "$AUDIT_LOG"; then
  note "no package-lock.json: SKIP with the reason, npm not run"
else
  error "no lockfile: rc=$RC summary='$(summary)'"
fi

# 6. pip-audit not installed: SKIP, not PASS, even though bandit ran.
mkdir -p "$tmp/nopa"
for c in bash git env dirname basename mktemp head rm cat grep sed awk tr uname find sort date mkdir id tail; do
  p="$(command -v "$c")" && ln -sf "$p" "$tmp/nopa/$c"
done
for c in bandit npm gitleaks; do ln -sf "$tmp/bin/$c" "$tmp/nopa/$c"; done
r="$(new_repo nopipaudit)"; two_projects "$r"
scan "$r" "$tmp/nopa"
if [[ $RC -eq 0 ]] && summary | grep -q "SKIP  python (backend/) dependency audit — pip-audit is not installed" \
   && grep -q "^bandit backend" "$AUDIT_LOG"; then
  note "pip-audit missing: SKIP with the reason (bandit alone is not an audit)"
else
  error "no pip-audit: rc=$RC log='$(cat "$AUDIT_LOG")' summary='$(summary)'"
fi

# 7. A Python project with neither requirements.txt nor pyproject.toml: SKIP.
r="$(new_repo nomanifest)"; two_projects "$r" none; printf 'from setuptools import setup\nsetup()\n' > "$r/backend/setup.py"
scan "$r"
summary | grep -q "SKIP  python (backend/) dependency audit — No requirements.txt or pyproject.toml" \
  && note "no Python manifest pip-audit reads: SKIP with the reason" || error "no manifest: summary='$(summary)'"

# 8. Without .preflight, detected projects are audited the same way.
r="$(new_repo detected)"; two_projects "$r"; rm -f "$r/.preflight"
scan "$r"
if [[ $RC -eq 0 ]] && grep -q "^pip-audit backend \.$" "$AUDIT_LOG" && grep -q "^npm frontend audit" "$AUDIT_LOG"; then
  note "detected projects (no .preflight): audited in their directories"
else
  error "detected: rc=$RC log='$(cat "$AUDIT_LOG")' summary='$(summary)'"
fi

# 9. The repository-wide step no longer runs the audits at the root.
r="$(new_repo rootonly)"; two_projects "$r"
scan "$r"
[[ "$(grep -c "^npm \|^pip-audit " "$AUDIT_LOG")" -eq 2 ]] && ! grep -q "^pip-audit rootonly\|^npm rootonly" "$AUDIT_LOG" \
  && note "the repository-wide step runs no audit at the root" || error "root audits: log='$(cat "$AUDIT_LOG")'"

# 10. Called directly, outside preflight, a run that checked nothing still exits 0
#     with its warnings: the exit-3 skip is preflight's protocol only.
r="$(new_repo direct)"
RC=0; OUT="$(cd "$r" && CI="" PATH="$tmp/nopa" "$(command -v bash)" "$ROOT_DIR/scripts/ci_security.sh" --no-docker --skip-gitleaks --skip-foxguard --skip-node 2>&1)" || RC=$?
[[ $RC -eq 0 && "$OUT" == *"No requirements.txt or pyproject.toml"* ]] && note "direct call, nothing to check: warning, exit 0" \
  || error "direct: rc=$RC out='$OUT'"

# 11. The pre-push run (--quick, report only) does not audit: pip-audit goes to
#     the network per project on every push. It says so in one SKIP line; a full
#     preflight audits, and labels it report only.
r="$(new_repo quick)"; mkdir -p "$r/frontend"
printf '{"name":"f","version":"1.0.0"}\n' > "$r/frontend/package.json"; printf '{}\n' > "$r/frontend/package-lock.json"
printf 'node frontend\n' > "$r/.preflight"
: > "$AUDIT_LOG"; RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/preflight.sh" --quick 2>&1)" || RC=$?
if summary | grep -q "SKIP  dependency audits — not run with --quick; ./dev scan runs them" && ! grep -q " audit --audit-level" "$AUDIT_LOG"; then
  note "--quick (pre-push): no audit, one SKIP line naming ./dev scan"
else
  error "quick: rc=$RC log='$(cat "$AUDIT_LOG")' summary='$(summary)'"
fi
: > "$AUDIT_LOG"; RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/preflight.sh" 2>&1)" || RC=$?
if summary | grep -q "node (frontend/) dependency audit (report only)" && grep -q "^npm frontend audit" "$AUDIT_LOG"; then
  note "full preflight: audits, labelled report only"
else
  error "full: rc=$RC log='$(cat "$AUDIT_LOG")' summary='$(summary)'"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
