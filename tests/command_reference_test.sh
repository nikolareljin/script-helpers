#!/usr/bin/env bash
# SCRIPT: command_reference_test.sh
# DESCRIPTION: docs/commands.md matches the script headers it is generated from.
# USAGE: bash tests/command_reference_test.sh
# ----------------------------------------------------
set -uo pipefail
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
py="$(command -v python3 || command -v python || true)"
[[ -n "$py" ]] || { echo "[command_reference_test] SKIP: python not available"; exit 0; }
if "$py" "$root_dir/scripts/gen_command_reference.py" --check; then
  echo "[command_reference_test] PASS: docs/commands.md is up to date"
else
  echo "[command_reference_test][ERROR] run: python3 scripts/gen_command_reference.py" >&2
  exit 1
fi
rc=0; "$py" "$root_dir/scripts/gen_command_reference.py" --bogus 2>/dev/null || rc=$?
[[ $rc -eq 2 ]] || { echo "[command_reference_test][ERROR] bad argument gave $rc, not 2" >&2; exit 1; }
echo "[command_reference_test] PASS: a bad argument is exit 2"

# One file name in scripts/ and in a hook directory: both get an entry. The page used to
# key entries by file name alone, so the second one vanished from it.
tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
mkdir -p "$tmp/scripts/git-hooks" "$tmp/docs"
cp "$root_dir/scripts/gen_command_reference.py" "$tmp/scripts/"
printf '#!/usr/bin/env bash\n# DESCRIPTION: repo hook\nexit 0\n' > "$tmp/scripts/git-hooks/pre-push"
printf '#!/usr/bin/env bash\n# DESCRIPTION: global hook\nexit 0\n' > "$tmp/scripts/pre-push"
"$py" "$tmp/scripts/gen_command_reference.py" || { echo "[command_reference_test][ERROR] generator failed on a minimal tree" >&2; exit 1; }
if grep -q '^### `scripts/git-hooks/pre-push`' "$tmp/docs/commands.md" \
  && grep -q '^### `scripts/pre-push`' "$tmp/docs/commands.md"; then
  echo "[command_reference_test] PASS: one name in two directories gets two entries"
else
  echo "[command_reference_test][ERROR] a script sharing a name with another directory's is missing" >&2; exit 1
fi

# A file that is not UTF-8 (a Latin-1 comment, a binary someone drops in scripts/)
# crashed the generator with a traceback and exit 1, which --check reports as
# "out of date". CRLF headers must parse like LF ones.
printf '#!/usr/bin/env bash\n# DESCRIPTION: caf\xe9 latin1\nexit 0\n' > "$tmp/scripts/latin.sh"
printf '#!/usr/bin/env bash\r\n# DESCRIPTION: crlf header\r\n# USAGE: crlf.sh [-a]\r\nexit 0\r\n' > "$tmp/scripts/crlf.sh"
rc=0; "$py" "$tmp/scripts/gen_command_reference.py" 2>"$tmp/err" || rc=$?
if [[ $rc -eq 0 ]] && grep -q '^### `scripts/latin.sh`' "$tmp/docs/commands.md" \
  && grep -q '^crlf header$' "$tmp/docs/commands.md" && grep -q '^Usage: crlf.sh \[-a\]$' "$tmp/docs/commands.md" \
  && ! grep -q $'\r' "$tmp/docs/commands.md"; then
  echo "[command_reference_test] PASS: a non-UTF-8 file and a CRLF header are read, not a crash"
else
  echo "[command_reference_test][ERROR] non-UTF-8 or CRLF header: rc=$rc $(head -c 300 "$tmp/err")" >&2; exit 1
fi
