#!/usr/bin/env bash
# SCRIPT: make_test_all_test.sh
# DESCRIPTION: `make test` runs every test file after a failure and lists each failed one.
# USAGE: bash tests/make_test_all_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/make_test_all_test.sh
# ----------------------------------------------------
# Copies the real Makefile next to three test files (fail, pass, fail) and
# checks that all three ran, both failures are named, and the exit is 1.
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[make_test_all_test] $*"; }
error() { echo "[make_test_all_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v make >/dev/null 2>&1 || { note "SKIP: make not available"; exit 0; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/repo/tests"
cp Makefile "$tmp/repo/Makefile"
printf '#!/usr/bin/env bash\necho a-ran\nexit 1\n' > "$tmp/repo/tests/a_test.sh"
printf '#!/usr/bin/env bash\necho b-ran\n' > "$tmp/repo/tests/b_test.sh"
printf '#!/usr/bin/env bash\necho c-ran\nexit 2\n' > "$tmp/repo/tests/c_test.sh"

out="$(make -C "$tmp/repo" test 2>&1)"; rc=$?
if [[ "$rc" -ne 0 ]]; then note "a failing file fails the target (exit $rc)"
else error "make test passed with two failing files: $out"; fi
for t in a b c; do
  if grep -q "^$t-ran$" <<<"$out"; then note "${t}_test.sh ran"
  else error "${t}_test.sh did not run: $out"; fi
done
if grep -q '^FAILED: 2 of 3 test file(s):$' <<<"$out"; then note "summary counts 2 of 3"
else error "no 'FAILED: 2 of 3' summary: $out"; fi
if grep -q '^  tests/a_test.sh$' <<<"$out" && grep -q '^  tests/c_test.sh$' <<<"$out" \
   && ! grep -q '^  tests/b_test.sh$' <<<"$out"; then note "summary names a and c, not b"
else error "summary does not list exactly the failed files: $out"; fi

# All green: exit 0 and a pass line.
printf '#!/usr/bin/env bash\necho a-ran\n' > "$tmp/repo/tests/a_test.sh"
printf '#!/usr/bin/env bash\necho c-ran\n' > "$tmp/repo/tests/c_test.sh"
out="$(make -C "$tmp/repo" test 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q '^All 3 test file(s) passed.$' <<<"$out"; then note "all passing: exit 0, 'All 3 test file(s) passed.'"
else error "all passing: rc=$rc: $out"; fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
