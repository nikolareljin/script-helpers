#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$root/scripts/security_notice.sh"
py="$(security_python)" || exit 2
"$py" -I "$root/tests/scan_output_test.py"
