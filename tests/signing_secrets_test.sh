#!/usr/bin/env bash
# SCRIPT: signing_secrets_test.sh
# DESCRIPTION: Tests scripts/signing_secrets.sh against a stub gh and a
#              throwaway GPG key: values reach gh on stdin and never in its
#              arguments or the output; --check reports missing names and
#              exits 1; bad input is refused before anything is set; the
#              .p12 and the .pfx must open with their password and hold a
#              usable certificate and key before they are stored.
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
fpr="$(gpg --batch --with-colons --list-secret-keys 2>/dev/null | awk -F: '/^fpr/ && !n++{print $10}')"

# Stub gh: "secret|variable set NAME -R REPO" stores stdin; "list" prints the
# names stored for that repo. Every argv is logged.
mkdir -p "$tmp/bin" "$tmp/store"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STORE/argv"
kind="$1"; verb="$2"
if [ "$verb" = "set" ]; then
  [ -n "${GH_HANG:-}" ] && { echo $$ > "$GH_HANG"; exec sleep 30; }
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
# Wrap openssl to log its argv, so a password on its command line shows.
real_openssl="$(command -v openssl 2>/dev/null || true)"
p12_skip=""
if [ -n "$real_openssl" ]; then
  cat > "$tmp/bin/openssl" <<STUB
#!/usr/bin/env bash
echo "\$*" >> "\$STORE/openssl_argv"
# P12_EXTRA_KEY: a key put before the .p12's own, as in a file exported
# with two identities.
case " \$* " in
  *" -nocerts "*) [ -n "\${P12_EXTRA_KEY:-}" ] && cat "\$P12_EXTRA_KEY" ;;
esac
exec "$real_openssl" "\$@"
STUB
  chmod +x "$tmp/bin/openssl"
else
  note "SKIP .p12 checks: openssl not installed"
  p12_skip="--skip-p12-check"
fi
export STORE="$tmp/store" PATH="$tmp/bin:$PATH"
# The script's private directory lands here, so leftovers can be counted.
mkdir -p "$tmp/tmpdir"
export TMPDIR="$tmp/tmpdir"
: > "$STORE/argv"

# A real .p12 (modern PBE), password p12-pw-value. Without openssl the
# runs below pass --skip-p12-check and the fake bytes are stored as they are.
make_p12() { # out password [extra pkcs12 -export args]
  local out="$1" pw="$2"; shift 2
  printf '%s' "$pw" > "$tmp/p12pw"
  "$real_openssl" pkcs12 -export -in "${P12_CERT:-$tmp/p12cert.pem}" -inkey "${P12_KEY:-$tmp/p12key.pem}" \
    -passout "file:$tmp/p12pw" -out "$out" "$@" >/dev/null 2>&1
}
p12_subj="/CN=Developer ID Application: Me (ABCDE12345)/OU=ABCDE12345"
if [ -n "$real_openssl" ]; then
  "$real_openssl" req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/p12key.pem" \
    -out "$tmp/p12cert.pem" -days 365 -subj "$p12_subj" >/dev/null 2>&1 || error "openssl req failed"
  make_p12 "$tmp/cert.p12" p12-pw-value || error "pkcs12 -export failed"
else
  printf 'p12-bytes' > "$tmp/cert.p12"
fi
printf 'ssh-key-body' > "$tmp/lp_key"

# 1. set gpg + apple on two repos, PPA target on one.
out="$(GPG_PASSPHRASE="gpg-pw-value" APPLE_CERTIFICATE_PASSWORD="p12-pw-value" APPLE_APP_PASSWORD="app-pw-value" \
  bash "$SCRIPT" --repos o/a,o/b --group gpg --group apple --gpg-key "$fpr" \
  --ppa o/a=ppa:me/tool --launchpad-ssh-key "$tmp/lp_key" \
  --apple-p12 "$tmp/cert.p12" --apple-identity "Developer ID Application: Me (ABCDE12345)" \
  --apple-team ABCDE12345 --apple-id me@example.invalid $p12_skip 2>&1)" || error "set run failed: $out"
s="$STORE/o/a"
grep -q "BEGIN PGP PRIVATE KEY BLOCK" "$s/secret/GPG_PRIVATE_KEY" 2>/dev/null || error "GPG_PRIVATE_KEY not an armored key"
[ "$(cat "$s/secret/GPG_PASSPHRASE" 2>/dev/null)" = "gpg-pw-value" ] || error "GPG_PASSPHRASE wrong"
[ "$(cat "$s/variable/GPG_KEY_ID" 2>/dev/null)" = "$fpr" ] || error "GPG_KEY_ID wrong"
[ "$(cat "$s/variable/PPA_TARGET" 2>/dev/null)" = "ppa:me/tool" ] || error "PPA_TARGET wrong on o/a"
[ ! -e "$STORE/o/b/variable/PPA_TARGET" ] || error "PPA_TARGET set on o/b"
[ "$(cat "$s/secret/LAUNCHPAD_SSH_PRIVATE_KEY" 2>/dev/null)" = "ssh-key-body" ] || error "LAUNCHPAD_SSH_PRIVATE_KEY wrong"
[ "$(base64 -d < "$s/secret/APPLE_CERTIFICATE" 2>/dev/null | cksum)" = "$(cksum < "$tmp/cert.p12")" ] || error "APPLE_CERTIFICATE is not the base64 of the .p12"
[ "$(cat "$s/secret/APPLE_CERTIFICATE_PASSWORD" 2>/dev/null)" = "p12-pw-value" ] || error "APPLE_CERTIFICATE_PASSWORD wrong"
[ "$(cat "$s/secret/APPLE_APP_PASSWORD" 2>/dev/null)" = "app-pw-value" ] || error "APPLE_APP_PASSWORD wrong"
[ "$(cat "$STORE/o/b/variable/APPLE_SIGNING_ENABLED" 2>/dev/null)" = "true" ] || error "APPLE_SIGNING_ENABLED not true on o/b"
for v in gpg-pw-value p12-pw-value app-pw-value ssh-key-body "PRIVATE KEY"; do
  grep -qF -- "$v" "$STORE/argv" && error "value '$v' reached gh's arguments"
  grep -qF -- "$v" "$STORE/openssl_argv" 2>/dev/null && error "value '$v' reached openssl's arguments"
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
refuse "repo twice" --repos o/a,o/a --group gpg --gpg-key "$fpr"
refuse "no repo in list" --repos , --group gpg --gpg-key "$fpr"
refuse "apple option without apple group" --repos o/a --group gpg --gpg-key "$fpr" --apple-team ABCDEFGHIJ
APPLE_CERTIFICATE_PASSWORD=a APPLE_APP_PASSWORD=b refuse "gpg option without gpg group" --repos o/a --group apple --apple-p12 "$tmp/cert.p12" --apple-identity "Developer ID Application: Me (ABCDEFGHIJ)" --apple-team ABCDEFGHIJ --apple-id me@example.invalid --ppa o/a=ppa:me/x
# "o/*" must not glob to a matching path in the working directory.
mkdir -p "$tmp/globdir/o/a"
# Not in a subshell: refuse counts failures in this shell.
cd "$tmp/globdir" || exit 1
refuse "glob in repos" --repos 'o/*' --group gpg --gpg-key "$fpr"
cd "$OLDPWD" || exit 1

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

# 7. a protected key: a wrong GPG_PASSPHRASE is refused before anything is
# set; the right one is stored. Wrong first, so the agent has nothing cached.
gpg --batch --pinentry-mode loopback --passphrase "right-pw" \
  --quick-gen-key "CI Locked <locked@example.invalid>" ed25519 sign never >/dev/null 2>&1
lfpr="$(gpg --batch --with-colons --list-secret-keys locked@example.invalid 2>/dev/null | awk -F: '/^fpr/ && !n++{print $10}')"
before="$(wc -l < "$STORE/argv")"
rc=0; out="$(GPG_PASSPHRASE="wrong-pw" bash "$SCRIPT" --repos o/f --group gpg --gpg-key "$lfpr" 2>&1)" || rc=$?
[ "$rc" = 2 ] || error "wrong passphrase: exit $rc, expected 2: $out"
grep -q "wrong GPG_PASSPHRASE" <<< "$out" || error "wrong passphrase: message: $out"
[ "$(wc -l < "$STORE/argv")" = "$before" ] || error "wrong passphrase: gh was called"
rc=0; out="$(GPG_PASSPHRASE="right-pw" bash "$SCRIPT" --repos o/f --group gpg --gpg-key "$lfpr" 2>&1)" || rc=$?
[ "$rc" = 0 ] || error "right passphrase: exit $rc: $out"
grep -q "BEGIN PGP PRIVATE KEY BLOCK" "$STORE/o/f/secret/GPG_PRIVATE_KEY" 2>/dev/null || error "right passphrase: key not stored"
grep -qF "right-pw" "$STORE/argv" && error "right passphrase: value reached gh's arguments"
# The local agent now has right-pw cached; a wrong one must still be refused.
before="$(wc -l < "$STORE/argv")"
rc=0; out="$(GPG_PASSPHRASE="wrong-pw" bash "$SCRIPT" --repos o/g --group gpg --gpg-key "$lfpr" 2>&1)" || rc=$?
[ "$rc" = 2 ] || error "wrong passphrase after a cached right one: exit $rc, expected 2: $out"
grep -q "wrong GPG_PASSPHRASE" <<< "$out" || error "wrong passphrase after a cached one: message: $out"
[ "$(wc -l < "$STORE/argv")" = "$before" ] || error "wrong passphrase after a cached one: gh was called"

# 7b. the .p12 check: a wrong password, a file that is not a .p12, a .p12
# without a key, and no openssl are refused before gh runs; a legacy
# (RC2/3DES) .p12 opens.
apple() { # p12 password [args...]
  local f="$1" pw="$2"; shift 2
  APPLE_CERTIFICATE_PASSWORD="$pw" APPLE_APP_PASSWORD="app-pw-value" bash "$SCRIPT" --repos o/p --group apple \
    --apple-p12 "$f" --apple-identity "Developer ID Application: Me (ABCDE12345)" \
    --apple-team ABCDE12345 --apple-id me@example.invalid "$@" 2>&1
}
p12_refused() { # name expected-message p12 password [args...]
  local name="$1" msg="$2" rc=0; shift 2
  before="$(wc -l < "$STORE/argv")"
  out="$(apple "$@")" || rc=$?
  [ "$rc" = 2 ] || error "$name: exit $rc, expected 2: $out"
  grep -qF -- "$msg" <<< "$out" || error "$name: message: $out"
  [ "$(wc -l < "$STORE/argv")" = "$before" ] || error "$name: gh was called"
}
if [ -n "$real_openssl" ]; then
  p12_refused "wrong p12 password" "wrong APPLE_CERTIFICATE_PASSWORD" "$tmp/cert.p12" wrong-p12-pw
  grep -qF wrong-p12-pw "$STORE/openssl_argv" && error "wrong p12 password reached openssl's arguments"
  printf 'not-a-p12' > "$tmp/junk.p12"
  p12_refused "not a p12" "openssl cannot read --apple-p12" "$tmp/junk.p12" p12-pw-value
  make_p12 "$tmp/nokey.p12" p12-pw-value -nokeys || error "pkcs12 -export -nokeys failed"
  p12_refused "p12 without a key" "holds no private key" "$tmp/nokey.p12" p12-pw-value
  # Without a MAC any password passes -noout; the key decrypt must catch it.
  make_p12 "$tmp/nomac.p12" p12-pw-value -nomac || error "pkcs12 -export -nomac failed"
  p12_refused "p12 without a MAC, wrong password" "wrong APPLE_CERTIFICATE_PASSWORD" "$tmp/nomac.p12" wrong-p12-pw
  long="$(printf '%01100d' 0)"
  p12_refused "password over 1023 bytes" "longer than the 1023 bytes" "$tmp/cert.p12" "$long"
  make_p12 "$tmp/nocert.p12" p12-pw-value -nocerts 2>/dev/null \
    && p12_refused "p12 without a certificate" "holds no certificate" "$tmp/nocert.p12" p12-pw-value
  # The --apple-identity certificate must be in the file, match the key and
  # be in date. A second key and certificate stand in for someone else's.
  "$real_openssl" req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/otherkey.pem" \
    -out "$tmp/othercert.pem" -days 365 -subj "/CN=Developer ID Application: Other (ZZZZZ99999)" >/dev/null 2>&1 \
    || error "openssl req (other) failed"
  P12_CERT="$tmp/othercert.pem" P12_KEY="$tmp/otherkey.pem" make_p12 "$tmp/other.p12" p12-pw-value \
    || error "pkcs12 -export (other) failed"
  p12_refused "p12 for another identity" "holds no certificate named 'Developer ID Application: Me (ABCDE12345)'" "$tmp/other.p12" p12-pw-value
  # The identity certificate rides along as a chain certificate; the key is another's.
  P12_CERT="$tmp/othercert.pem" P12_KEY="$tmp/otherkey.pem" make_p12 "$tmp/mismatch.p12" p12-pw-value -certfile "$tmp/p12cert.pem" \
    || error "pkcs12 -export (mismatch) failed"
  p12_refused "identity certificate without its key" "does not match the private key" "$tmp/mismatch.p12" p12-pw-value
  # A chain after the identity certificate is fine.
  make_p12 "$tmp/chain.p12" p12-pw-value -certfile "$tmp/othercert.pem" || error "pkcs12 -export (chain) failed"
  rc=0; out="$(apple "$tmp/chain.p12" p12-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "p12 with a chain: exit $rc: $out"
  grep -q 'expires on' <<< "$out" && error "p12 valid for a year: warned of expiry: $out"
  # Two identities exported together: the other key comes first.
  rc=0; out="$(P12_EXTRA_KEY="$tmp/otherkey.pem" apple "$tmp/cert.p12" p12-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "p12 with two keys: exit $rc: $out"
  "$real_openssl" req -new -key "$tmp/p12key.pem" -subj "$p12_subj" -out "$tmp/p12.csr" >/dev/null 2>&1
  # Expiring tomorrow: stored, with a warning.
  if ! { "$real_openssl" x509 -req -in "$tmp/p12.csr" -signkey "$tmp/p12key.pem" -days 1 -out "$tmp/soon.pem" >/dev/null 2>&1 \
    && P12_CERT="$tmp/soon.pem" make_p12 "$tmp/soon.p12" p12-pw-value; }; then
    error "pkcs12 -export (soon) failed"
  fi
  rc=0; out="$(apple "$tmp/soon.p12" p12-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "p12 expiring soon: exit $rc: $out"
  grep -q "expires on .*renew it" <<< "$out" || error "p12 expiring soon: no warning: $out"
  # Expired: refused. OpenSSL 3 signs with -days -1; LibreSSL refuses to.
  if "$real_openssl" x509 -req -in "$tmp/p12.csr" -signkey "$tmp/p12key.pem" -days -1 -out "$tmp/old.pem" >/dev/null 2>&1; then
    P12_CERT="$tmp/old.pem" make_p12 "$tmp/old.p12" p12-pw-value || error "pkcs12 -export (expired) failed"
    p12_refused "expired certificate" "expired on" "$tmp/old.p12" p12-pw-value
    # Renewed on the same key, the expired certificate listed first: stored.
    cat "$tmp/old.pem" "$tmp/p12cert.pem" > "$tmp/renewed.pem"
    P12_CERT="$tmp/renewed.pem" make_p12 "$tmp/renewed.p12" p12-pw-value || error "pkcs12 -export (renewed) failed"
    rc=0; out="$(apple "$tmp/renewed.p12" p12-pw-value)" || rc=$?
    [ "$rc" = 0 ] || error "renewed certificate next to the expired one: exit $rc: $out"
  else
    note "SKIP expired .p12: this openssl cannot write a certificate in the past"
  fi
  # Names are compared as written: parentheses, a comma, quotes and a
  # backslash in the name are not escaped away.
  odd_id='Developer ID Application: A "Q" \\ B, Zo\xc3\xab (EU) Ltd (ABCDE12345)'
  odd_id="$(printf '%b' "$odd_id")"
  odd_subj="/CN=$(printf '%s' "$odd_id" | sed 's/[\\/=+,]/\\&/g')"
  if "$real_openssl" req -x509 -utf8 -new -key "$tmp/p12key.pem" -out "$tmp/odd.pem" -days 365 -subj "$odd_subj" >/dev/null 2>&1 \
    && P12_CERT="$tmp/odd.pem" make_p12 "$tmp/odd.p12" p12-pw-value; then
    rc=0
    out="$(APPLE_CERTIFICATE_PASSWORD=p12-pw-value APPLE_APP_PASSWORD="app-pw-value" bash "$SCRIPT" --repos o/p --group apple \
      --apple-p12 "$tmp/odd.p12" --apple-identity "$odd_id" --apple-team ABCDE12345 --apple-id me@example.invalid 2>&1)" || rc=$?
    [ "$rc" = 0 ] || error "identity with a backslash and parentheses: exit $rc: $out"
  else
    error "pkcs12 -export (odd name) failed"
  fi
  # --skip-p12-check stores a .p12 that would not open.
  rc=0; out="$(apple "$tmp/cert.p12" wrong-p12-pw --skip-p12-check)" || rc=$?
  [ "$rc" = 0 ] || error "--skip-p12-check: exit $rc: $out"
  # Legacy RC2/3DES, as older Keychain exports are. OpenSSL 3 writes it
  # with -legacy; LibreSSL and OpenSSL 1.1 write it by default.
  if make_p12 "$tmp/legacy.p12" legacy-pw -legacy || make_p12 "$tmp/legacy.p12" legacy-pw -certpbe PBE-SHA1-RC2-40 -keypbe PBE-SHA1-3DES; then
    rc=0; out="$(apple "$tmp/legacy.p12" legacy-pw)" || rc=$?
    [ "$rc" = 0 ] || error "legacy p12: exit $rc: $out"
    # OpenSSL 3 opens it only through the -legacy retry.
    if grep -q '^OpenSSL 3' <<< "$("$real_openssl" version 2>/dev/null)"; then
      grep -q -- '-legacy' "$STORE/openssl_argv" || error "legacy p12: openssl never ran with -legacy"
    fi
    [ "$(cat "$STORE/o/p/secret/APPLE_CERTIFICATE_PASSWORD" 2>/dev/null)" = "legacy-pw" ] || error "legacy p12: password not stored"
    p12_refused "legacy p12, wrong password" "wrong APPLE_CERTIFICATE_PASSWORD" "$tmp/legacy.p12" wrong-legacy-pw
  else
    note "SKIP legacy .p12: this openssl cannot write one"
  fi
fi
# No openssl: refused, naming the flag, before the password is asked for.
mkdir -p "$tmp/noopenssl"
for d in "${path_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    [ -e "$f" ] && [ "$b" != openssl ] && [ ! -L "$tmp/noopenssl/$b" ] && ln -s "$f" "$tmp/noopenssl/$b"
  done
done
before="$(wc -l < "$STORE/argv")"
rc=0; out="$(PATH="$tmp/noopenssl" apple "$tmp/cert.p12" p12-pw-value)" || rc=$?
[ "$rc" = 2 ] || error "no openssl: exit $rc, expected 2: $out"
grep -q "openssl is not installed.*--skip-p12-check" <<< "$out" || error "no openssl: message: $out"
[ "$(wc -l < "$STORE/argv")" = "$before" ] || error "no openssl: gh was called"
APPLE_CERTIFICATE_PASSWORD=a APPLE_APP_PASSWORD=b refuse "identity of another team" --repos o/a --group apple --apple-p12 "$tmp/cert.p12" \
  --apple-identity "Developer ID Application: Me (ZZZZZ99999)" --apple-team ABCDE12345 --apple-id me@example.invalid --dry-run
refuse "skip-p12-check without apple group" --repos o/a --group gpg --gpg-key "$fpr" --skip-p12-check

# 7c. --group windows: the .pfx must open with its password, hold a private
# key and a code-signing certificate for it, in date. Values reach gh on
# stdin; the password also comes from --windows-password-file.
windows() { # pfx password [args...]
  local f="$1" pw="$2"; shift 2
  WINDOWS_CERTIFICATE_PASSWORD="$pw" bash "$SCRIPT" --repos o/w --group windows --windows-pfx "$f" "$@" 2>&1
}
pfx_refused() { # name expected-message pfx password [args...]
  local name="$1" msg="$2" rc=0; shift 2
  before="$(wc -l < "$STORE/argv")"
  out="$(windows "$@")" || rc=$?
  [ "$rc" = 2 ] || error "$name: exit $rc, expected 2: $out"
  grep -qF -- "$msg" <<< "$out" || error "$name: message: $out"
  [ "$(wc -l < "$STORE/argv")" = "$before" ] || error "$name: gh was called"
}
if [ -n "$real_openssl" ]; then
  # -config/-extensions, not -addext: LibreSSL has no -addext.
  cat > "$tmp/pfx.cnf" <<'CNF'
[req]
distinguished_name = dn
[dn]
[cs]
extendedKeyUsage = codeSigning
[srv]
extendedKeyUsage = serverAuth
CNF
  pfx_cert() { # out-cert ext days
    "$real_openssl" x509 -req -in "$tmp/pfx.csr" -signkey "$tmp/pfxkey.pem" -days "$3" \
      -extfile "$tmp/pfx.cnf" -extensions "$2" -out "$1" >/dev/null 2>&1
  }
  "$real_openssl" req -new -newkey rsa:2048 -nodes -keyout "$tmp/pfxkey.pem" -subj "/CN=Me Windows Signing" \
    -config "$tmp/pfx.cnf" -out "$tmp/pfx.csr" >/dev/null 2>&1 || error "openssl req (pfx) failed"
  pfx_cert "$tmp/pfxcert.pem" cs 365 || error "x509 (pfx) failed"
  P12_CERT="$tmp/pfxcert.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/sign.pfx" pfx-pw-value || error "pkcs12 -export (pfx) failed"
  : > "$STORE/argv"; : > "$STORE/openssl_argv"
  rc=0; out="$(windows "$tmp/sign.pfx" pfx-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "good pfx: exit $rc: $out"
  w="$STORE/o/w/secret"
  [ "$(base64 -d < "$w/WINDOWS_CERTIFICATE" 2>/dev/null | cksum)" = "$(cksum < "$tmp/sign.pfx")" ] || error "WINDOWS_CERTIFICATE is not the base64 of the .pfx"
  [ "$(wc -l < "$w/WINDOWS_CERTIFICATE" 2>/dev/null | tr -d ' ')" = 0 ] || error "WINDOWS_CERTIFICATE is wrapped"
  [ "$(cat "$w/WINDOWS_CERTIFICATE_PASSWORD" 2>/dev/null)" = "pfx-pw-value" ] || error "WINDOWS_CERTIFICATE_PASSWORD wrong"
  grep -qF -- "pfx-pw-value" "$STORE/argv" && error "pfx password reached gh's arguments"
  grep -qF -- "pfx-pw-value" "$STORE/openssl_argv" && error "pfx password reached openssl's arguments"
  grep -qF -- "pfx-pw-value" <<< "$out" && error "pfx password printed"
  grep -qx "secret set WINDOWS_CERTIFICATE -R o/w" "$STORE/argv" || error "gh not called as 'secret set WINDOWS_CERTIFICATE -R o/w': $(cat "$STORE/argv")"
  grep -q "windows_sign_mode: pfx" <<< "$out" || error "good pfx: no next step: $out"
  grep -q "ci-helpers docs/windows-signing.md" <<< "$out" || error "good pfx: no docs pointer: $out"
  grep -q 'expires on' <<< "$out" && error "pfx valid for a year: warned of expiry: $out"
  # The password from a file; its trailing newline is not part of it.
  printf 'file-pw\n' > "$tmp/pfxpwfile"
  P12_CERT="$tmp/pfxcert.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/sign2.pfx" file-pw || error "pkcs12 -export (pfx2) failed"
  rc=0; out="$(env -u WINDOWS_CERTIFICATE_PASSWORD bash "$SCRIPT" --repos o/w2 --group windows --windows-pfx "$tmp/sign2.pfx" \
    --windows-password-file "$tmp/pfxpwfile" </dev/null 2>&1)" || rc=$?
  [ "$rc" = 0 ] || error "pfx password file: exit $rc: $out"
  [ "$(cat "$STORE/o/w2/secret/WINDOWS_CERTIFICATE_PASSWORD" 2>/dev/null)" = "file-pw" ] || error "pfx password file: password not stored as written"
  grep -qF -- "file-pw" "$STORE/argv" && error "pfx password file: password reached gh's arguments"
  # Written on Windows: CRLF.
  printf 'file-pw\r\n' > "$tmp/pfxpwcrlf"
  rc=0; out="$(env -u WINDOWS_CERTIFICATE_PASSWORD bash "$SCRIPT" --repos o/w3 --group windows --windows-pfx "$tmp/sign2.pfx" \
    --windows-password-file "$tmp/pfxpwcrlf" </dev/null 2>&1)" || rc=$?
  [ "$rc" = 0 ] || error "pfx password file with CRLF: exit $rc: $out"
  [ "$(cat "$STORE/o/w3/secret/WINDOWS_CERTIFICATE_PASSWORD" 2>/dev/null)" = "file-pw" ] || error "pfx password file with CRLF: CR stored"
  # A CR without a LF is part of the password, so this one does not open.
  printf 'file-pw\r' > "$tmp/pfxpwcr"
  rc=0; out="$(env -u WINDOWS_CERTIFICATE_PASSWORD bash "$SCRIPT" --repos o/w4 --group windows --windows-pfx "$tmp/sign2.pfx" \
    --windows-password-file "$tmp/pfxpwcr" </dev/null 2>&1)" || rc=$?
  [ "$rc" = 2 ] || error "pfx password file ending in a lone CR: CR dropped, exit $rc: $out"
  pfx_refused "wrong pfx password" "wrong WINDOWS_CERTIFICATE_PASSWORD" "$tmp/sign.pfx" wrong-pfx-pw
  grep -qF wrong-pfx-pw "$STORE/openssl_argv" && error "wrong pfx password reached openssl's arguments"
  P12_CERT="$tmp/pfxcert.pem" make_p12 "$tmp/nokey.pfx" pfx-pw-value -nokeys || error "pkcs12 -export (pfx nokey) failed"
  pfx_refused "pfx without a key" "holds no private key" "$tmp/nokey.pfx" pfx-pw-value
  pfx_cert "$tmp/srvcert.pem" srv 365 || error "x509 (server) failed"
  P12_CERT="$tmp/srvcert.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/srv.pfx" pfx-pw-value || error "pkcs12 -export (server) failed"
  pfx_refused "pfx without code signing" "no code-signing (1.3.6.1.5.5.7.3.3)" "$tmp/srv.pfx" pfx-pw-value
  # A code-signing certificate for another key does not count.
  P12_CERT="$tmp/othercert.pem" P12_KEY="$tmp/otherkey.pem" make_p12 "$tmp/mismatch.pfx" pfx-pw-value -certfile "$tmp/pfxcert.pem" \
    || error "pkcs12 -export (pfx mismatch) failed"
  pfx_refused "code-signing certificate without its key" "no code-signing (1.3.6.1.5.5.7.3.3)" "$tmp/mismatch.pfx" pfx-pw-value
  pfx_cert "$tmp/pfxsoon.pem" cs 1 || error "x509 (pfx soon) failed"
  P12_CERT="$tmp/pfxsoon.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/soon.pfx" pfx-pw-value || error "pkcs12 -export (pfx soon) failed"
  rc=0; out="$(windows "$tmp/soon.pfx" pfx-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "pfx expiring soon: exit $rc: $out"
  grep -q "expires on .*renew it" <<< "$out" || error "pfx expiring soon: no warning: $out"
  # OpenSSL 3.0 refuses -days -1; "ca" takes explicit past dates.
  pfx_old() {
    pfx_cert "$tmp/pfxold.pem" cs -1 && return 0
    mkdir -p "$tmp/ca" && : > "$tmp/ca/index.txt"
    printf '[ca]\ndefault_ca = c\n[c]\ndatabase = %s\nnew_certs_dir = %s\nserial = %s\ndefault_md = sha256\npolicy = p\n[p]\ncommonName = supplied\n[cs]\nextendedKeyUsage = codeSigning\n' \
      "$tmp/ca/index.txt" "$tmp/ca" "$tmp/ca/serial" > "$tmp/ca.cnf"
    echo 01 > "$tmp/ca/serial"
    "$real_openssl" ca -batch -config "$tmp/ca.cnf" -selfsign -keyfile "$tmp/pfxkey.pem" -in "$tmp/pfx.csr" \
      -startdate 20200101000000Z -enddate 20210101000000Z -extensions cs -out "$tmp/pfxold.pem" >/dev/null 2>&1
  }
  if pfx_old; then
    P12_CERT="$tmp/pfxold.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/old.pfx" pfx-pw-value || error "pkcs12 -export (pfx old) failed"
    pfx_refused "expired pfx" "expired on" "$tmp/old.pfx" pfx-pw-value
  else
    note "SKIP expired .pfx: this openssl cannot write a certificate in the past"
  fi
  if P12_CERT="$tmp/pfxcert.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/legacy.pfx" legacy-pw -legacy \
    || P12_CERT="$tmp/pfxcert.pem" P12_KEY="$tmp/pfxkey.pem" make_p12 "$tmp/legacy.pfx" legacy-pw -certpbe PBE-SHA1-RC2-40 -keypbe PBE-SHA1-3DES; then
    rc=0; out="$(windows "$tmp/legacy.pfx" legacy-pw)" || rc=$?
    [ "$rc" = 0 ] || error "legacy pfx: exit $rc: $out"
  fi
  rc=0; out="$(windows "$tmp/srv.pfx" wrong-pfx-pw --skip-pfx-check)" || rc=$?
  [ "$rc" = 0 ] || error "--skip-pfx-check: exit $rc: $out"
fi
rc=0; out="$(windows "$tmp/cert.p12" x --dry-run)" || rc=$?
[ "$rc" = 0 ] || error "windows dry-run: exit $rc: $out"
grep -qx "o/w: would set secret WINDOWS_CERTIFICATE_PASSWORD" <<< "$out" || error "windows dry-run output: $out"
grep -q "windows_sign_mode: pfx" <<< "$out" || error "windows dry-run: no next step: $out"
rc=0; out="$(bash "$SCRIPT" --repos o/c --group windows --check 2>&1)" || rc=$?
[ "$rc" = 1 ] || error "windows --check exit $rc, expected 1"
grep -qx "o/c: missing WINDOWS_CERTIFICATE WINDOWS_CERTIFICATE_PASSWORD" <<< "$out" || error "windows --check: $out"
WINDOWS_CERTIFICATE_PASSWORD=x refuse "windows without --windows-pfx" --repos o/a --group windows
WINDOWS_CERTIFICATE_PASSWORD=x refuse "missing pfx file" --repos o/a --group windows --windows-pfx "$tmp/none.pfx"
refuse "windows option without windows group" --repos o/a --group gpg --gpg-key "$fpr" --windows-pfx "$tmp/cert.p12"
refuse "skip-pfx-check without windows group" --repos o/a --group gpg --gpg-key "$fpr" --skip-pfx-check
WINDOWS_CERTIFICATE_PASSWORD=x refuse "missing password file" --repos o/a --group windows --windows-pfx "$tmp/cert.p12" --windows-password-file "$tmp/none"

# 8. TERM while gh runs: the private directory and its values are removed.
hang="$tmp/hang"
GH_HANG="$hang" GPG_PASSPHRASE="right-pw" bash "$SCRIPT" --repos o/h --group gpg --gpg-key "$lfpr" >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 100); do [ -s "$hang" ] && break; sleep 0.1; done
[ -s "$hang" ] || error "TERM: gh was never reached"
# As on Ctrl-C: the script and the gh it runs both get the signal.
kill -TERM "$pid" 2>/dev/null
kill -TERM "$(cat "$hang")" 2>/dev/null
rc=0; wait "$pid" || rc=$?
[ "$rc" = 143 ] || error "TERM: exit $rc, expected 143"

# Every run above, refused, failed or killed, removed its private directory.
left="$(ls -A "$TMPDIR")"
[ -z "$left" ] || error "private directories left behind: $left"

if [ "$failures" -eq 0 ]; then
  note "ok"
  exit 0
fi
exit 1
