#!/usr/bin/env bash
# SCRIPT: local_test_skip_test.sh
# DESCRIPTION: Tests that the local_test_*.sh runners exit 3 when nothing can be checked, and that preflight reports it as SKIP.
# USAGE: bash tests/local_test_skip_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/local_test_skip_test.sh
# ----------------------------------------------------
#
# Each case was a false failure on a real repository: a root go.mod with no
# packages, a frontend with no test script, a clone without pytest. Each is
# "could not check", which preflight lists as SKIP -- apart from passes, never
# counted as one -- instead of FAIL, which blocked every push.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[local_test_skip_test] $*"; }
error() { echo "[local_test_skip_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# expect_rc <label> <want> <command...>
expect_rc() {
  local label="$1" want="$2" rc=0 out; shift 2
  out="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq $want ]]; then note "$label (exit $rc)"; else error "$label: want exit $want, got $rc: $out"; fi
}

# --- go ----------------------------------------------------------------------
if command -v go >/dev/null 2>&1; then
  g="$tmp/go"; mkdir -p "$g/tool" "$g/app"; git init -q "$g"
  printf 'module example.com/tool\n\ngo 1.21\n' > "$g/tool/go.mod"
  printf 'module example.com/app\n\ngo 1.21\n' > "$g/app/go.mod"
  printf 'package app\n\nfunc One() int { return 1 }\n' > "$g/app/app.go"
  printf 'package app\n\nimport "testing"\n\nfunc TestOne(t *testing.T) { if One() != 1 { t.Fatal() } }\n' > "$g/app/app_test.go"
  expect_rc "go: a module without packages is skipped, the other tested" 0 \
    bash scripts/local_test_go.sh --quick --dir "$g"
  expect_rc "go: only modules without packages -> nothing to test" 3 \
    bash scripts/local_test_go.sh --quick --dir "$g/tool"
  printf 'package app\n\nfunc One() int { return "x" }\n' > "$g/app/app.go"
  expect_rc "go: a package that does not compile still fails" 1 \
    bash scripts/local_test_go.sh --quick --dir "$g/app"
else
  note "SKIP go cases: go is not installed"
fi

# --- node --------------------------------------------------------------------
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  n="$tmp/node"; mkdir -p "$n"; git init -q "$n"
  printf '{"name":"x","version":"1.0.0"}\n' > "$n/package.json"
  expect_rc "node: no test script -> nothing to test" 3 \
    bash scripts/local_test_node.sh --quick --dir "$n"
  printf '{"name":"x","version":"1.0.0","scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}}\n' > "$n/package.json"
  expect_rc "node: npm's placeholder test script -> nothing to test" 3 \
    bash scripts/local_test_node.sh --quick --dir "$n"
  printf '{"name":"x","version":"1.0.0","scripts":{"test":"node -e \\"process.exit(0)\\""}}\n' > "$n/package.json"
  expect_rc "node: a real test script runs" 0 \
    bash scripts/local_test_node.sh --quick --dir "$n"
  printf '{"name":"x","version":"1.0.0","scripts":{"test":"node -e \\"process.exit(1)\\""}}\n' > "$n/package.json"
  expect_rc "node: a failing test script still fails" 1 \
    bash scripts/local_test_node.sh --quick --dir "$n"
else
  note "SKIP node cases: node or npm is not installed"
fi

# --- python ------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -m venv "$tmp/venv-probe" >/dev/null 2>&1; then
  p="$tmp/py"; mkdir -p "$p"; git init -q "$p"
  python3 -m venv "$p/.venv"   # a fresh venv: no pytest, no ruff
  printf 'def test_one():\n    assert 1\n' > "$p/test_one.py"
  if "$p/.venv/bin/python" -m pytest --version >/dev/null 2>&1; then
    note "SKIP python case: the fresh venv already has pytest"
  else
    expect_rc "python: pytest not installed -> not run, exit 3" 3 \
      bash scripts/local_test_python.sh --quick --dir "$p"
    printf '[tool.ruff]\n' > "$p/pyproject.toml"
    expect_rc "python: configured ruff not installed -> not run, exit 3" 3 \
      bash scripts/local_test_python.sh --quick --dir "$p"
  fi
else
  note "SKIP python cases: python3 with venv is not available"
fi

# --- preflight ---------------------------------------------------------------
if command -v npm >/dev/null 2>&1 && command -v node >/dev/null 2>&1; then
  r="$tmp/pf"; mkdir -p "$r"; git init -q "$r"
  printf '{"name":"x","version":"1.0.0"}\n' > "$r/package.json"
  rc=0
  out="$(cd "$r" && bash "$ROOT_DIR/scripts/preflight.sh" --quick --skip-security --stack node 2>&1)" || rc=$?
  if [[ $rc -eq 0 && "$out" == *"SKIP  node lint + test — package.json declares no test script"* && "$out" != *"FAIL  node"* ]]; then
    note "preflight: a runner's exit 3 is a SKIP, and preflight passes"
  else
    error "preflight: rc=$rc out='$(printf '%s' "$out" | tail -8)'"
  fi
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
