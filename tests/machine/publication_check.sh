#!/usr/bin/env bash
# SCRIPT: publication_check.sh
# DESCRIPTION: Probe publication checks with the installed Gitleaks binary and local Git remotes.
# USAGE: bash tests/machine/publication_check.sh
# PARAMETERS: No required parameters.
# EXIT_CODES:
#   0 Passed; 1 failed; 2 required tools unavailable.
# EXAMPLE: bash tests/machine/publication_check.sh
# ----------------------------------------------------
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,/^# ---/p' "$0"; exit 0 ;; esac
for tool in git python3 gitleaks ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || { echo "summary: cannot run, missing $tool"; exit 2; }
done
scratch="$(mktemp -d)" || exit 2
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$scratch"; fi' EXIT
GITLEAKS_BIN="$(command -v gitleaks)" || exit 2
export GITLEAKS_BIN
export XDG_STATE_HOME="$scratch/state"
unset CI GITHUB_ACTIONS
failures=0
check() {
  if [[ "$1" -eq "$2" ]]; then printf 'PASS %s\n' "$3";
  else printf 'FAIL %s\n' "$3"; failures=$((failures + 1)); fi
}
printf 'Ready for review.\n' > "$scratch/clean.txt"
bash "$root/scripts/check_publication.sh" --file "$scratch/clean.txt" > "$scratch/output" 2>&1
check "$?" 0 'clean publication with installed scanner'
ssh-keygen -q -t ed25519 -N '' -f "$scratch/private-key" || exit 2
bash "$root/scripts/check_publication.sh" --file "$scratch/private-key" > "$scratch/output" 2>&1
check "$?" 1 'generated private key refused'
# A valid ELF64 header with one program header, then the payload.
elf_head() { python3 -c 'import struct,sys; sys.stdout.buffer.write(b"\x7fELF\x02\x01\x01" + b"\0" * 9 + struct.pack("<HHIQQQIHHHHHH", 2, 62, 1, 0, 64, 0, 0, 64, 56, 1, 64, 0, 0) + b"\0" * 56)'; }
{ elf_head; cat "$scratch/private-key"; } > "$scratch/app-with-key"
bash "$root/scripts/check_publication.sh" --file "$scratch/app-with-key" > "$scratch/output" 2>&1
check "$?" 1 'private key inside an executable refused'
{ elf_head; printf 'support: %s%s\000' 'anna.weber' '@firma-gmbh.de'; } > "$scratch/app-with-email"
bash "$root/scripts/check_publication.sh" --file "$scratch/app-with-email" > "$scratch/output" 2>&1
check "$?" 0 'email address inside an executable passes'
{ printf '\177ELF'; head -c 60 /dev/zero; cat "$scratch/private-key"; } > "$scratch/blob-with-key"
bash "$root/scripts/check_publication.sh" --file "$scratch/blob-with-key" > "$scratch/output" 2>&1
check "$?" 1 'private key inside an unrecognised binary refused'
python3 - "$scratch/archive.zip" <<'PYTHON'
import secrets, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("gh" + "p_" + secrets.token_hex(18), "")
PYTHON
bash "$root/scripts/check_publication.sh" --file "$scratch/archive.zip" > "$scratch/output" 2>&1
check "$?" 1 'credential pattern in archive filename refused'
git init -q "$scratch/repo" && git init --bare -q "$scratch/remote.git" || exit 2
cd "$scratch/repo" || exit 2
git config user.name Fixture
git config user.email fixture@example.com
printf '[]\n' > gitleaks.json
git add gitleaks.json
git -c core.hooksPath=/dev/null commit -qm fixture || exit 2
oid="$(git rev-parse HEAD)"
git remote add origin "$scratch/remote.git"
git config core.hooksPath "$root/scripts/git-hooks"
git push origin HEAD:refs/heads/fixture > "$scratch/output" 2>&1
check "$?" 1 'report push refused'
if git --git-dir="$scratch/remote.git" cat-file -e "$oid" 2>/dev/null; then
  check 1 0 'remote receives no prohibited commit'
else
  check 0 0 'remote receives no prohibited commit'
fi
printf 'summary: %s failed\n' "$failures"
[[ "$failures" -eq 0 ]]
