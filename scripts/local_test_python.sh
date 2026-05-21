#!/usr/bin/env bash
# SCRIPT: local_test_python.sh
# DESCRIPTION: Use a local virtualenv when available and run pytest.
# USAGE: bash scripts/local_test_python.sh [--quick] [--dir <path>]
#
# Options:
#   --quick   Skip install; run tests against the current environment.
#   --dir     Subdirectory containing pyproject.toml/requirements.txt (default: .).
set -euo pipefail

QUICK=false
TEST_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir) TEST_DIR="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root/$TEST_DIR"

# Locate pytest — prefer venv
PYTEST="pytest"
if [[ -x venv/bin/pytest ]]; then PYTEST="venv/bin/pytest"
elif [[ -x .venv/bin/pytest ]]; then PYTEST=".venv/bin/pytest"
elif [[ -x "$repo_root/venv/bin/pytest" ]]; then PYTEST="$repo_root/venv/bin/pytest"; fi

if [[ "$PYTEST" == */* ]]; then
  if [[ ! -x "$PYTEST" ]]; then
    echo "[local-test-python] pytest is not executable at $PYTEST. Install it in the active environment." >&2
    exit 1
  fi
elif ! command -v "$PYTEST" &>/dev/null; then
  echo "[local-test-python] pytest not found in PATH. Activate a venv or install pytest first." >&2
  exit 1
fi

if [[ "$QUICK" == "false" ]]; then
  PIP="pip"
  if [[ -x venv/bin/pip ]]; then PIP="venv/bin/pip"
  elif [[ -x .venv/bin/pip ]]; then PIP=".venv/bin/pip"
  elif [[ -x "$repo_root/venv/bin/pip" ]]; then PIP="$repo_root/venv/bin/pip"; fi

  if [[ -f pyproject.toml ]]; then
    echo "[local-test-python] pip install -e '.[dev]'"
    "$PIP" install -e '.[dev]' --quiet
  elif [[ -f requirements.txt ]]; then
    echo "[local-test-python] pip install -r requirements.txt"
    "$PIP" install -r requirements.txt --quiet
  fi
fi

echo "[local-test-python] pytest --tb=short -q"
"$PYTEST" --tb=short -q
echo "[local-test-python] Done."
