#!/usr/bin/env bash
# SCRIPT: local_test_python.sh
# DESCRIPTION: Use a local virtualenv when available and run pytest.
# USAGE: bash scripts/local_test_python.sh [--quick] [--dir <path>]
#
# PARAMETERS:
#   --quick   Skip install; run tests against the current environment.
#   --dir     Subdirectory containing pyproject.toml/requirements.txt (default: .).
# ----------------------------------------------------
set -euo pipefail

QUICK=false
TEST_DIR="."

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) QUICK=true ;;
    --dir)
      if [[ $# -lt 2 ]]; then
        echo "[local-test-python] --dir requires a path." >&2
        exit 1
      fi
      TEST_DIR="$2"
      shift
      ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [[ ! -d "$repo_root/$TEST_DIR" ]]; then
  echo "[local-test-python] Directory not found: $repo_root/$TEST_DIR" >&2
  exit 1
fi
cd "$repo_root/$TEST_DIR"

# Resolve one Python interpreter for both dependency installs and test runs.
PYTHON=""
if [[ -x venv/bin/python ]]; then PYTHON="venv/bin/python"
elif [[ -x .venv/bin/python ]]; then PYTHON=".venv/bin/python"
elif [[ -x "$repo_root/venv/bin/python" ]]; then PYTHON="$repo_root/venv/bin/python"
elif [[ -x "$repo_root/.venv/bin/python" ]]; then PYTHON="$repo_root/.venv/bin/python"
elif command -v python3 &>/dev/null; then PYTHON="python3"
elif command -v python &>/dev/null; then PYTHON="python"; fi

if [[ -z "$PYTHON" ]]; then
  echo "[local-test-python] Python not found. Activate a venv or install Python first." >&2
  exit 1
fi

# A project with no venv falls back to the system interpreter, and on a modern
# Debian or Ubuntu that interpreter is PEP 668 "externally managed": installing
# into it is refused by design. Rather than pass --break-system-packages, which
# is what the error message tempts you into and which can damage the OS Python,
# create a project-local venv and use that. Reuses lib/python.sh's helper rather
# than repeating the logic.
if [[ "$PYTHON" == "python3" || "$PYTHON" == "python" ]] \
   && [[ -f requirements.txt || -f pyproject.toml ]] \
   && "$PYTHON" -c 'import os,sys,sysconfig; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)' 2>/dev/null; then
  _sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [[ -f "$_sh_dir/helpers.sh" ]]; then
    # shellcheck source=/dev/null
    source "$_sh_dir/helpers.sh"
    shlib_import python >/dev/null 2>&1 || true
  fi
  echo "[local-test-python] system Python is externally managed (PEP 668); using a project venv at .venv"
  if declare -f python_ensure_venv >/dev/null 2>&1 && python_ensure_venv "$PYTHON" ".venv" >/dev/null 2>&1 \
     && [[ -x .venv/bin/python ]]; then
    PYTHON=".venv/bin/python"
  elif "$PYTHON" -m venv .venv >/dev/null 2>&1 && [[ -x .venv/bin/python ]]; then
    PYTHON=".venv/bin/python"
  else
    echo "[local-test-python] Could not create .venv. Install python3-venv, or create a venv yourself." >&2
    exit 1
  fi
fi

if [[ "$QUICK" == "false" ]]; then
  if [[ -f requirements.txt ]]; then
    if ! "$PYTHON" -m pip --version &>/dev/null; then
      echo "[local-test-python] pip not found for $PYTHON. Install pip in the selected Python environment." >&2
      exit 1
    fi

    echo "[local-test-python] $PYTHON -m pip install -r requirements.txt"
    "$PYTHON" -m pip install -r requirements.txt --quiet
  elif [[ -f pyproject.toml ]]; then
    echo "[local-test-python] pyproject.toml found without requirements.txt; using the selected Python environment."
  fi

  # requirements.txt is runtime dependencies; the test tools usually are not in
  # it. A project that declares a `dev` extra is stating where they live, so
  # honour it rather than making the caller install pytest by hand. This is the
  # same shape ci-helpers' documented install_command uses.
  if [[ -f pyproject.toml ]] && grep -qE '^\s*dev\s*=' pyproject.toml; then
    echo "[local-test-python] $PYTHON -m pip install -e '.[dev]'"
    "$PYTHON" -m pip install -e '.[dev]' --quiet \
      || echo "[local-test-python] the dev extra did not install; continuing" >&2
  fi
fi

if ! "$PYTHON" -m pytest --version &>/dev/null; then
  echo "[local-test-python] pytest not found for $PYTHON. Install it in the selected Python environment." >&2
  exit 1
fi

echo "[local-test-python] $PYTHON -m pytest --tb=short -q"
"$PYTHON" -m pytest --tb=short -q
echo "[local-test-python] Done."
