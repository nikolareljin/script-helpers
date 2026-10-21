#!/usr/bin/env bash
# SCRIPT: signing_secrets_test.sh
# DESCRIPTION: Tests scripts/signing_secrets.sh against a stub gh and a
#              throwaway GPG key: values reach gh on stdin and never in its
#              arguments or the output; --check reports missing names and
#              exits 1; bad input is refused before anything is set; the
#              .p12 must open with its password before it is stored.
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
  "$real_openssl" req -new -key "$tmp/p12key.pem" -subj "$p12_subj" -out "$tmp/p12.csr" >/dev/null 2>&1
  # Expiring tomorrow: stored, with a warning.
  "$real_openssl" x509 -req -in "$tmp/p12.csr" -signkey "$tmp/p12key.pem" -days 1 -out "$tmp/soon.pem" >/dev/null 2>&1 \
    && P12_CERT="$tmp/soon.pem" make_p12 "$tmp/soon.p12" p12-pw-value || error "pkcs12 -export (soon) failed"
  rc=0; out="$(apple "$tmp/soon.p12" p12-pw-value)" || rc=$?
  [ "$rc" = 0 ] || error "p12 expiring soon: exit $rc: $out"
  grep -q "expires on .*renew it" <<< "$out" || error "p12 expiring soon: no warning: $out"
  # Expired: refused. OpenSSL 3 signs with -days -1; LibreSSL refuses to.
  if "$real_openssl" x509 -req -in "$tmp/p12.csr" -signkey "$tmp/p12key.pem" -days -1 -out "$tmp/old.pem" >/dev/null 2>&1; then
    P12_CERT="$tmp/old.pem" make_p12 "$tmp/old.p12" p12-pw-value || error "pkcs12 -export (expired) failed"
    p12_refused "expired certificate" "expired on" "$tmp/old.p12" p12-pw-value
  else
    note "SKIP expired .p12: this openssl cannot write a certificate in the past"
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
