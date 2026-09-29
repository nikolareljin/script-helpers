#!/usr/bin/env bash
# SCRIPT: ci_security_foxguard_test.sh
# DESCRIPTION: Tests the foxguard step of scripts/ci_security.sh and lib/foxguard.sh.
# USAGE: bash tests/ci_security_foxguard_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_security_foxguard_test.sh
# ci_security.sh and preflight refuse to run under CI=true, so they run here with CI="".
# ----------------------------------------------------
#
# A stub foxguard records where it ran and with which arguments, and "finds"
# the word FOXBAD in the files under the scan directory that no --exclude
# covers. Its findings count only where the repository has a .foxguard.yml:
# measured on this library, its bash rules flag ordinary lines, so a gate on by
# default would fail correct code. A stub curl serves a known binary, so the
# checksum check is tested without the network.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[ci_security_foxguard_test] $*"; }
error() { echo "[ci_security_foxguard_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin" "$tmp/nobin"
cat > "$tmp/bin/foxguard" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "foxguard ${FOX_VERSION:-0.14.0}"; exit 0; fi
echo "$(basename "$(pwd -P)"): ${FOX_NAME:-path} $*" >> "$FOX_LOG"
[[ -n "${FOX_FAIL:-}" ]] && { echo "Error: stub scan failure" >&2; exit 2; }
out="" ; excludes=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --exclude) excludes+=("$2"); shift 2 ;;
    *) shift ;;
  esac
done
n=0
while IFS= read -r f; do
  f="${f#./}"; skip=false
  for e in "${excludes[@]+"${excludes[@]}"}"; do [[ "$f" == "$e"/* ]] && skip=true; done
  [[ "$skip" == "false" ]] && grep -q FOXBAD "$f" && n=$((n+1))
done < <(find . -type f -not -path './.git/*')
[[ -n "$out" ]] && printf '{"finding_counts": {"total": %s}}\n' "$n" > "$out"
[[ $n -gt 0 ]] && { echo "$n issues"; exit 1; }
exit 0
EOF
chmod +x "$tmp/bin/foxguard"
export FOX_LOG="$tmp/fox.log"
# Hermetic: no real cached foxguard from this machine.
export XDG_CACHE_HOME="$tmp/cache"

git_c() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}"; }
new_repo() {
  local r="$tmp/$1"
  git init -q "$r"
  git_c "$r" commit -q --allow-empty -m init
  echo "$r"
}
# sec <repo> [args]; ci_security.sh with only foxguard, findings failing the run.
sec() {
  local r="$1"; shift
  : > "$FOX_LOG"; RC=0
  OUT="$(cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker \
    --skip-python --skip-node --skip-gitleaks "$@" 2>&1)" || RC=$?
}

# 1. No .foxguard.yml: a finding is reported with its count, not counted.
r="$(new_repo plain)"; echo FOXBAD > "$r/a.py"
sec "$r" --fail-on-findings
if [[ $RC -eq 0 && "$OUT" == *"foxguard: 1 finding(s), reported, not counted"* ]]; then
  note "no .foxguard.yml: finding reported with its count, exit 0"
else
  error "plain: rc=$RC out='$OUT'"
fi

# 2. A .foxguard.yml opts in: the finding fails the run.
echo 'scan: {}' > "$r/.foxguard.yml"
sec "$r" --fail-on-findings
if [[ $RC -eq 1 && "$OUT" == *".foxguard.yml found; findings count"* && "$OUT" == *"1 issues"* ]]; then
  note ".foxguard.yml: finding counts, listing shown, exit 1"
else
  error "opted: rc=$RC out='$OUT'"
fi

# 3. Opted in, no findings: exit 0.
echo clean > "$r/a.py"
sec "$r" --fail-on-findings
[[ $RC -eq 0 ]] && note ".foxguard.yml, clean: exit 0" || error "opted clean: rc=$RC out='$OUT'"

# 4. Opted in but without --fail-on-findings (the pre-push run): reported only.
echo FOXBAD > "$r/a.py"
sec "$r"
[[ $RC -eq 0 && "$OUT" == *"foxguard reported findings"* ]] && note "pre-push run: opted-in finding reported, exit 0" \
  || error "report-only opted: rc=$RC out='$OUT'"

# 5. A submodule is excluded: its finding is the vendored project's.
src="$(new_repo libsrc)"; echo FOXBAD > "$src/lib.py"; git_c "$src" add -A; git_c "$src" commit -q -m lib
r="$(new_repo withsub)"; echo 'scan: {}' > "$r/.foxguard.yml"
git_c "$r" -c protocol.file.allow=always submodule --quiet add "$src" vendor/lib >/dev/null 2>&1
sec "$r" --fail-on-findings
if [[ -f "$r/vendor/lib/lib.py" && $RC -eq 0 ]] && grep -q -- "--exclude vendor/lib" "$FOX_LOG"; then
  note "submodule: passed as --exclude, its finding not counted"
else
  error "submodule: rc=$RC log='$(cat "$FOX_LOG")' out='$OUT'"
fi

# 6. --workdir below the top: .foxguard.yml found upward; submodule paths made
#    relative to the scan directory, and one outside it not passed.
r="$(new_repo workdir)"; echo 'scan: {}' > "$r/.foxguard.yml"; mkdir -p "$r/backend"; echo x > "$r/backend/a.py"
git_c "$r" -c protocol.file.allow=always submodule --quiet add "$src" backend/third >/dev/null 2>&1
git_c "$r" -c protocol.file.allow=always submodule --quiet add "$src" other >/dev/null 2>&1
echo FOXBAD > "$r/backend/b.py"
sec "$r" --workdir backend --fail-on-findings
if [[ $RC -eq 1 && "$OUT" == *".foxguard.yml found"* ]] && grep -q "^backend: .*--exclude third " "$FOX_LOG" \
   && ! grep -q -- "--exclude other" "$FOX_LOG"; then
  note "--workdir backend: config found upward, excludes relative to backend"
else
  error "workdir: rc=$RC log='$(cat "$FOX_LOG")' out='$OUT'"
fi

# 7. A scan error without .foxguard.yml: reported with foxguard's message, not counted.
r="$(new_repo failing)"
: > "$FOX_LOG"; RC=0
OUT="$(cd "$r" && FOX_FAIL=1 CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker --skip-python --skip-node --skip-gitleaks --fail-on-findings 2>&1)" || RC=$?
[[ $RC -eq 0 && "$OUT" == *"stub scan failure"* && "$OUT" == *"could not scan (exit 2)"* ]] \
  && note "scan error, not opted in: message shown, exit 0" || error "failing: rc=$RC out='$OUT'"

# 8. A foxguard that is not the pinned version: a warning, and it still runs.
r="$(new_repo version)"
: > "$FOX_LOG"; RC=0
OUT="$(cd "$r" && FOX_VERSION=0.13.1 CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --no-docker --skip-python --skip-node --skip-gitleaks 2>&1)" || RC=$?
[[ $RC -eq 0 && "$OUT" == *"is not the pinned 0.14.0"* && -s "$FOX_LOG" ]] && note "other version: warned, still runs" \
  || error "version: rc=$RC out='$OUT'"

# 9. The pinned binary in the cache is preferred over one on PATH.
cache_bin="$XDG_CACHE_HOME/script-helpers/foxguard/0.14.0/foxguard"
mkdir -p "$(dirname "$cache_bin")"
sed 's/\${FOX_NAME:-path}/cache/' "$tmp/bin/foxguard" > "$cache_bin"; chmod +x "$cache_bin"
sec "$r"
grep -q "^version: cache " "$FOX_LOG" && note "cached pinned binary preferred over PATH" || error "cache: log='$(cat "$FOX_LOG")'"
rm -f "$cache_bin"

# 10. Not installed: skipped with the install command; preflight lists it as SKIP.
for c in bash git env dirname basename mktemp head rm cat grep sed awk tr uname find sort date mkdir id tail; do
  p="$(command -v "$c")" && ln -sf "$p" "$tmp/nobin/$c"
done
: > "$FOX_LOG"; RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/nobin" "$(command -v bash)" "$ROOT_DIR/scripts/ci_security.sh" --no-docker --skip-python --skip-node --skip-gitleaks --fail-on-findings 2>&1)" || RC=$?
[[ $RC -eq 0 && "$OUT" == *"foxguard not found; skipping"*"--install-foxguard"* ]] && note "not installed: skipped, says how to install" \
  || error "not installed: rc=$RC out='$OUT'"
RC=0; (cd "$r" && CI="" PATH="$tmp/nobin" "$(command -v bash)" "$ROOT_DIR/scripts/ci_security.sh" --check-foxguard) || RC=$?
[[ $RC -eq 3 ]] && note "--check-foxguard without foxguard: exit 3" || error "check missing: rc=$RC"
RC=0; (cd "$r" && CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --check-foxguard) || RC=$?
[[ $RC -eq 0 ]] && note "--check-foxguard with foxguard: exit 0" || error "check present: rc=$RC"
RC=0
OUT="$(cd "$r" && CI="" PATH="$tmp/nobin" "$(command -v bash)" "$ROOT_DIR/scripts/preflight.sh" --security-only 2>&1)" || RC=$?
[[ "$OUT" == *"SKIP  foxguard code scan"* ]] && note "preflight: missing foxguard listed as SKIP" \
  || error "preflight skip: rc=$RC out='$(printf '%s' "$OUT" | tail -5)'"

# 11. --install-foxguard: a binary that does not match the pin is refused and
#     removed; one that matches is installed at the cache path.
asset="$(uname -s)-$(uname -m)"
case "$asset" in Linux-x86_64|Linux-amd64|Linux-aarch64|Linux-arm64|Darwin-x86_64|Darwin-arm64) ;; *) asset="";; esac
if [[ -n "$asset" ]]; then
  printf '#!/bin/sh\necho "foxguard 0.14.0"\n' > "$tmp/served"
  cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do [[ "\$1" == "-o" ]] && { cp "$tmp/served" "\$2"; exit 0; }; shift; done
exit 1
EOF
  chmod +x "$tmp/bin/curl"
  RC=0
  OUT="$(CI="" PATH="$tmp/bin:$PATH" bash "$ROOT_DIR/scripts/ci_security.sh" --install-foxguard 2>&1)" || RC=$?
  left="$(find "$XDG_CACHE_HOME/script-helpers/foxguard" -type f 2>/dev/null)"
  if [[ $RC -eq 1 && "$OUT" == *"does not match the pinned SHA-256"* && -z "$left" ]]; then
    note "--install-foxguard: checksum mismatch refused, nothing left behind"
  else
    error "install mismatch: rc=$RC left='$left' out='$OUT'"
  fi
  sum="$(bash -c 'source "$1/helpers.sh" && shlib_import foxguard && foxguard_sha256 "$2"' _ "$ROOT_DIR" "$tmp/served")"
  # The openssl fallback (no shasum) gives the same digest.
  if command -v openssl >/dev/null 2>&1; then
    mkdir -p "$tmp/ossl"
    for c in bash openssl awk dirname cat; do p="$(command -v "$c")" && ln -sf "$p" "$tmp/ossl/$c"; done
    s2="$(PATH="$tmp/ossl" "$(command -v bash)" -c 'source "$1/helpers.sh" && shlib_import foxguard && foxguard_sha256 "$2"' _ "$ROOT_DIR" "$tmp/served" 2>/dev/null)"
    [[ -n "$sum" && "$s2" == "$sum" ]] && note "foxguard_sha256: openssl fallback matches shasum" || error "sha256 fallback: '$s2' vs '$sum'"
  fi
  RC=0
  OUT="$(CI="" PATH="$tmp/bin:$PATH" CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="$sum" CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64="$sum" \
    CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64="$sum" CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64="$sum" \
    bash "$ROOT_DIR/scripts/ci_security.sh" --install-foxguard 2>&1)" || RC=$?
  if [[ $RC -eq 0 && -x "$cache_bin" ]] && cmp -s "$cache_bin" "$tmp/served"; then
    note "--install-foxguard: matching binary installed at the cache path"
  else
    error "install match: rc=$RC out='$OUT'"
  fi
  rm -f "$tmp/bin/curl"
else
  note "SKIP install cases: no release binary for $(uname -s) $(uname -m)"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
