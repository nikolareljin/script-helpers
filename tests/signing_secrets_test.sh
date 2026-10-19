#!/usr/bin/env bash
# SCRIPT: signing_secrets_test.sh
# DESCRIPTION: Tests scripts/signing_secrets.sh against a stub gh and a
#              throwaway GPG key: values reach gh on stdin and never in its
#              arguments or the output; --check reports missing names and
#              exits 1; bad input is refused before anything is set.
# USAGE: bash tests/signing_secrets_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/signing_secrets_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/signing_secrets.sh"
failures=0
note() { echo "[signing_secrets_test] $*"; }
error() { echo "[signing_secrets_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v gpg >/dev/null 2>&1; then
  note "SKIP: gpg not installed"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then gpgconf --homedir "$tmp/gnupg" --kill all >/dev/null 2>&1 || true; rm -rf "$tmp"; fi' EXIT

export GNUPGHOME="$tmp/gnupg"
mkdir -m 700 "$GNUPGHOME"
gpg --batch --pinentry-mode loopback --passphrase "" \
  --quick-gen-key "CI Test <ci@example.invalid>" ed25519 sign never >/dev/null 2>&1
fpr="$(gpg --batch --with-colons --list-secret-keys | awk -F: '/^fpr/{print $10; exit}')"

# Stub gh: "secret|variable set NAME -R REPO" stores stdin; "list" prints the
# names stored for that repo. Every argv is logged.
mkdir -p "$tmp/bin" "$tmp/store"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STORE/argv"
kind="$1"; verb="$2"
if [ "$verb" = "set" ]; then
  [ -n "${GH_FAIL:-}" ] && { cat >/dev/null; exit 1; }
  name="$3"; repo="$5"
  mkdir -p "$STORE/$repo/$kind"
  cat > "$STORE/$repo/$kind/$name"
  exit 0
fi
if [ "$verb" = "list" ]; then
  repo="$4"
  ls "$STORE/$repo/$kind" 2>/dev/null
  # GH_PAD: a long list after the real names, as on a repository with many
  # secrets; a reader that stops early must not lose the match.
  [ -n "${GH_PAD:-}" ] && seq 1 20000 | sed 's/^/PAD_/'
  exit 0
fi
exit 9
STUB
chmod +x "$tmp/bin/gh"
export STORE="$tmp/store" PATH="$tmp/bin:$PATH"
: > "$STORE/argv"

printf 'p12-bytes' > "$tmp/cert.p12"
printf 'ssh-key-body' > "$tmp/lp_key"

# 1. set gpg + apple on two repos, PPA target on one.
out="$(GPG_PASSPHRASE="gpg-pw-value" APPLE_CERTIFICATE_PASSWORD="p12-pw-value" APPLE_APP_PASSWORD="app-pw-value" \
  bash "$SCRIPT" --repos o/a,o/b --group gpg --group apple --gpg-key "$fpr" \
  --ppa o/a=ppa:me/tool --launchpad-ssh-key "$tmp/lp_key" \
  --apple-p12 "$tmp/cert.p12" --apple-identity "Developer ID Application: Me (ABCDE12345)" \
  --apple-team ABCDE12345 --apple-id me@example.invalid 2>&1)" || error "set run failed: $out"
s="$STORE/o/a"
grep -q "BEGIN PGP PRIVATE KEY BLOCK" "$s/secret/GPG_PRIVATE_KEY" 2>/dev/null || error "GPG_PRIVATE_KEY not an armored key"
[ "$(cat "$s/secret/GPG_PASSPHRASE" 2>/dev/null)" = "gpg-pw-value" ] || error "GPG_PASSPHRASE wrong"
[ "$(cat "$s/variable/GPG_KEY_ID" 2>/dev/null)" = "$fpr" ] || error "GPG_KEY_ID wrong"
[ "$(cat "$s/variable/PPA_TARGET" 2>/dev/null)" = "ppa:me/tool" ] || error "PPA_TARGET wrong on o/a"
[ ! -e "$STORE/o/b/variable/PPA_TARGET" ] || error "PPA_TARGET set on o/b"
[ "$(cat "$s/secret/LAUNCHPAD_SSH_PRIVATE_KEY" 2>/dev/null)" = "ssh-key-body" ] || error "LAUNCHPAD_SSH_PRIVATE_KEY wrong"
[ "$(base64 -d < "$s/secret/APPLE_CERTIFICATE" 2>/dev/null)" = "p12-bytes" ] || error "APPLE_CERTIFICATE is not the base64 of the .p12"
[ "$(cat "$s/secret/APPLE_APP_PASSWORD" 2>/dev/null)" = "app-pw-value" ] || error "APPLE_APP_PASSWORD wrong"
[ "$(cat "$STORE/o/b/variable/APPLE_SIGNING_ENABLED" 2>/dev/null)" = "true" ] || error "APPLE_SIGNING_ENABLED not true on o/b"
for v in gpg-pw-value p12-pw-value app-pw-value ssh-key-body "PRIVATE KEY"; do
  grep -qF -- "$v" "$STORE/argv" && error "value '$v' reached gh's arguments"
  grep -qF -- "$v" <<< "$out" && error "value '$v' printed"
done

# 2. --check: complete repo ok, a repo missing everything reported, exit 1.
rc=0; out="$(bash "$SCRIPT" --repos o/a,o/c --group gpg --group apple --ppa o/a=ppa:me/tool --check 2>&1)" || rc=$?
[ "$rc" = 1 ] || error "--check exit $rc, expected 1"
grep -qx "o/a: ok" <<< "$out" || error "--check: o/a not ok: $out"
grep -q "^o/c: missing GPG_PRIVATE_KEY GPG_PASSPHRASE GPG_KEY_ID APPLE_CERTIFICATE" <<< "$out" || error "--check: o/c missing list wrong: $out"
rc=0; bash "$SCRIPT" --repos o/a --group gpg --check >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] || error "--check of a complete repo exit $rc"

# 2b. --check on a repository with a long secret list: still ok, exit 0.
# Under pipefail, `printf | grep -q` fails when grep exits before printf
# finishes writing, which reported present names as missing.
rc=0; out="$(GH_PAD=1 bash "$SCRIPT" --repos o/a --group gpg --group apple --ppa o/a=ppa:me/tool --check 2>&1)" || rc=$?
[ "$rc" = 0 ] || error "--check with a long list: exit $rc, expected 0: $out"
grep -qx "o/a: ok" <<< "$out" || error "--check with a long list: $out"

# 3. dry-run sets nothing.
before="$(wc -l < "$STORE/argv")"
out="$(bash "$SCRIPT" --repos o/d --group gpg --gpg-key "$fpr" --dry-run 2>&1)" || error "dry-run failed: $out"
grep -qx "o/d: would set secret GPG_PRIVATE_KEY" <<< "$out" || error "dry-run output: $out"
[ "$(wc -l < "$STORE/argv")" = "$before" ] || error "dry-run called gh"

# 4. refused input, nothing set.
refuse() { # name args...
  local name="$1" rc=0; shift
  before="$(wc -l < "$STORE/argv")"
  GPG_PASSPHRASE=x bash "$SCRIPT" "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || error "$name: exit $rc, expected 2"
  [ "$(wc -l < "$STORE/argv")" = "$before" ] || error "$name: gh was called"
}
refuse "no group" --repos o/a
refuse "missing value at the end" --repos o/a --group gpg --gpg-key
refuse "missing value before an option" --repos o/a --group --check
refuse "bad group" --repos o/a --group deb
refuse "bad repo" --repos a --group gpg --gpg-key "$fpr"
refuse "short key id" --repos o/a --group gpg --gpg-key ABCD1234
refuse "unknown key" --repos o/a --group gpg --gpg-key 0000000000000000000000000000000000000000
refuse "ppa for other repo" --repos o/a --group gpg --gpg-key "$fpr" --ppa o/z=ppa:me/x
refuse "bad ppa" --repos o/a --group gpg --gpg-key "$fpr" --ppa "o/a=ppa:Me/x;y"
refuse "bad apple team" --repos o/a --group apple --apple-p12 "$tmp/cert.p12" --apple-identity "Developer ID Application: Me (X)" --apple-team short --apple-id me@example.invalid
refuse "unknown option" --repos o/a --group gpg --gpg-key "$fpr" --bogus
refuse "ppa twice for one repo" --repos o/a --group gpg --gpg-key "$fpr" --ppa o/a=ppa:me/x --ppa o/a=ppa:me/y

# 5. a PATH without gpg, then without gh: refused with exit 2, nothing set.
mkdir -p "$tmp/nogpg" "$tmp/nogh"
IFS=: read -r -a path_dirs <<< "$PATH"
for d in "${path_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    [ -e "$f" ] || continue
    b="${f##*/}"
    [ "$b" = gpg ] || [ -L "$tmp/nogpg/$b" ] || ln -s "$f" "$tmp/nogpg/$b"
    [ "$b" = gh ] || [ -L "$tmp/nogh/$b" ] || ln -s "$f" "$tmp/nogh/$b"
  done
done
before="$(wc -l < "$STORE/argv")"
rc=0; out="$(PATH="$tmp/nogpg" GPG_PASSPHRASE=x bash "$SCRIPT" --repos o/a --group gpg --gpg-key "$fpr" 2>&1)" || rc=$?
[ "$rc" = 2 ] || error "no gpg: exit $rc, expected 2"
grep -q "gpg is not installed" <<< "$out" || error "no gpg: message: $out"
[ "$(wc -l < "$STORE/argv")" = "$before" ] || error "no gpg: gh was called"
rc=0; out="$(PATH="$tmp/nogh" bash "$SCRIPT" --repos o/a --group gpg --check 2>&1)" || rc=$?
[ "$rc" = 2 ] || error "no gh: exit $rc, expected 2"
grep -q "gh is not installed" <<< "$out" || error "no gh: message: $out"

# 5b. no passphrase in the environment and no terminal: refused, exit 2.
if command -v setsid >/dev/null 2>&1 && setsid -w true >/dev/null 2>&1; then
  before="$(wc -l < "$STORE/argv")"
  rc=0; out="$(env -u GPG_PASSPHRASE setsid -w bash "$SCRIPT" --repos o/a --group gpg --gpg-key "$fpr" </dev/null 2>&1)" || rc=$?
  [ "$rc" = 2 ] || error "no terminal: exit $rc, expected 2"
  grep -q "no terminal to prompt on" <<< "$out" || error "no terminal: message: $out"
  [ "$(wc -l < "$STORE/argv")" = "$before" ] || error "no terminal: gh was called"
else
  note "SKIP no-terminal case: setsid -w not available"
fi

# 6. gh fails to set a name: reported, exit 1, the value still not printed.
GH_FAIL=1; export GH_FAIL
rc=0; out="$(GPG_PASSPHRASE="gpg-pw-value" bash "$SCRIPT" --repos o/e --group gpg --gpg-key "$fpr" 2>&1)" || rc=$?
unset GH_FAIL
[ "$rc" = 1 ] || error "gh failure: exit $rc, expected 1"
grep -q "could not set secret GPG_PASSPHRASE" <<< "$out" || error "gh failure: message: $out"
grep -qF "gpg-pw-value" <<< "$out" && error "gh failure: value printed"

if [ "$failures" -eq 0 ]; then
  note "ok"
  exit 0
fi
exit 1
