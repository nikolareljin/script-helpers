#!/usr/bin/env bash
# SCRIPT: publish_homebrew_test.sh
# DESCRIPTION: Tests for scripts/publish_homebrew.sh against a local tap repository.
# USAGE: bash tests/publish_homebrew_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/publish_homebrew_test.sh
# ----------------------------------------------------
set -uo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir" || exit 1

failures=0
note()  { echo "[publish_homebrew_test] $*"; }
error() { echo "[publish_homebrew_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

TOKEN="tok-SECRET-0123456789abcdef"
TOKEN_B64="$(printf 'x-access-token:%s' "$TOKEN" | base64 | tr -d '\n')"
REAL_GIT="$(command -v git)"

# The tap lives in a local bare repository. github.com URLs are redirected to it
# through a throwaway HOME, so the script's real clone and push run unchanged.
# Both URL shapes are mapped so the same fixture also drives older versions of
# the script that put the token in the URL.
mkdir -p "$tmp/home" "$tmp/seed"
"$REAL_GIT" init -q --bare "$tmp/tap.git"
"$REAL_GIT" --git-dir="$tmp/tap.git" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" -C "$tmp/seed" init -q .
printf 'tap\n' > "$tmp/seed/README"
"$REAL_GIT" -C "$tmp/seed" add README
"$REAL_GIT" -C "$tmp/seed" -c user.name=t -c user.email=t@example.com commit -q -m seed
"$REAL_GIT" -C "$tmp/seed" push -q "$tmp/tap.git" HEAD:refs/heads/main
cat > "$tmp/home/.gitconfig" <<EOF
[user]
	name = t
	email = t@example.com
[init]
	defaultBranch = main
[url "$tmp/tap.git"]
	insteadOf = https://github.com/owner/formula-fixture.git
	insteadOf = https://x-access-token:${TOKEN}@github.com/owner/formula-fixture.git
EOF

# A git shim that logs every argv, what git would send as the github.com auth
# header, and the tap clone's .git/config at push time, then runs real git.
# FAKE_GIT_VERSION makes it claim an older git to drive the fallback path.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/git" <<EOF
#!/usr/bin/env bash
log="$tmp/git.log"
if [[ "\${1:-}" == "--version" && -n "\${FAKE_GIT_VERSION:-}" ]]; then
  echo "git version \$FAKE_GIT_VERSION"; exit 0
fi
printf 'ARGV:' >> "\$log"; printf ' %s' "\$@" >> "\$log"; printf '\n' >> "\$log"
case "\${1:-}" in
  clone|push)
    printf 'HEADER[%s]: %s\n' "\$1" "\$("$REAL_GIT" config --get http.https://github.com/.extraheader)" >> "\$log"
    # Every extraheader value in the order git read it (files, then env).
    "$REAL_GIT" config --get-all http.https://github.com/.extraheader | sed "s/^/HEADERS[\$1]: /" >> "\$log"
    ;;
esac
if [[ "\${1:-}" == "push" ]]; then
  printf 'CONFIG:\n' >> "\$log"; cat .git/config >> "\$log"
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$tmp/bin/git"

mkdir -p "$tmp/app/packaging/brew"
printf 'class Myapp < Formula\n  version "1.0.0"\nend\n' > "$tmp/app/packaging/brew/myapp.rb"

run_publish() {
  # run_publish <label> [extra env assignments...]
  local label="$1"; shift
  : > "$tmp/git.log"
  rc=0
  out="$(env HOME="$tmp/home" PATH="$tmp/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 "$@" \
    bash "$root_dir/scripts/publish_homebrew.sh" --repo "$tmp/app" \
      --tap-repo owner/formula-fixture --tap-token "$TOKEN" 2>&1)" || rc=$?
  note "$label: exit $rc"
}

tap_formula() { "$REAL_GIT" --git-dir="$tmp/tap.git" show main:Formula/myapp.rb 2>/dev/null; }

# --- first publish of a formula the tap has never seen --------------------
run_publish "first publish"
if [[ $rc -ne 0 ]]; then
  error "first publish exited $rc: $out"
fi
if tap_formula | grep -q 'version "1.0.0"'; then
  note "first publish: formula landed in the tap"
else
  error "first publish: formula not in the tap (the new file was treated as no change): $out"
fi
if [[ "$out" == *"already up to date"* ]]; then
  error "first publish: reported 'already up to date' for a new formula"
fi

# --- the token stays out of argv, the clone's config, and the log ---------
if grep -F -q "$TOKEN" "$tmp/git.log" || grep -F -q "$TOKEN_B64" <(grep -v '^HEADER' "$tmp/git.log"); then
  error "token visible in git argv or the tap clone's .git/config"
else
  note "token absent from git argv and .git/config"
fi
if grep -F -q "HEADER[clone]: AUTHORIZATION: basic $TOKEN_B64" "$tmp/git.log" &&
   grep -F -q "HEADER[push]: AUTHORIZATION: basic $TOKEN_B64" "$tmp/git.log"; then
  note "clone and push both receive the auth header"
else
  error "auth header not passed to clone and push: $(cat "$tmp/git.log")"
fi
if [[ "$out" == *"$TOKEN"* || "$out" == *"$TOKEN_B64"* ]]; then
  error "token appears in the script output"
fi
# Tracing must not be switched on for a caller that never asked for it.
if printf '%s\n' "$out" | grep -q '^+'; then
  error "xtrace was turned on inside the script: $out"
else
  note "xtrace stays off"
fi

# --- re-publishing the same formula is a no-op ----------------------------
before="$("$REAL_GIT" --git-dir="$tmp/tap.git" rev-parse main)"
run_publish "unchanged publish"
after="$("$REAL_GIT" --git-dir="$tmp/tap.git" rev-parse main)"
if [[ $rc -eq 0 && "$out" == *"already up to date"* && "$before" == "$after" ]]; then
  note "unchanged formula: reported up to date, no commit"
else
  error "unchanged formula: rc=$rc before=$before after=$after out=$out"
fi

# --- a changed formula is committed ----------------------------------------
printf 'class Myapp < Formula\n  version "1.1.0"\nend\n' > "$tmp/app/packaging/brew/myapp.rb"
run_publish "updated publish"
if [[ $rc -eq 0 ]] && tap_formula | grep -q 'version "1.1.0"'; then
  note "updated formula: committed"
else
  error "updated formula not published: rc=$rc out=$out"
fi

# --- git older than 2.31 still gets the header, still no token in argv -----
printf 'class Myapp < Formula\n  version "1.2.0"\nend\n' > "$tmp/app/packaging/brew/myapp.rb"
run_publish "old git" FAKE_GIT_VERSION=2.30.0
if [[ $rc -eq 0 ]] && tap_formula | grep -q 'version "1.2.0"' &&
   grep -F -q "HEADER[push]: AUTHORIZATION: basic $TOKEN_B64" "$tmp/git.log" &&
   ! grep -F -q "$TOKEN" "$tmp/git.log"; then
  note "old git: header passed, token kept out of argv"
else
  error "old git path failed: rc=$rc out=$out log=$(cat "$tmp/git.log")"
fi

# --- a header the caller already configured is reset, not duplicated -------
# extraheader is multi-valued and an empty value clears the list, so what git
# sends is every value after the last empty one. A caller header left in place
# (actions/checkout leaves one) made git send two Authorization headers, which
# GitHub rejects with 400. The reset entry must come before our header, and
# after the caller's, in every place a caller can set one.
WRONG_HDR="AUTHORIZATION: basic $(printf 'x-access-token:wrong' | base64 | tr -d '\n')"
effective_headers() {
  # effective_headers <verb>: the values git would send for that git verb.
  awk -v p="HEADERS[$1]: " '
    index($0, p) == 1 { v = substr($0, length(p) + 1); if (v == "") n = 0; else list[++n] = v }
    END { for (i = 1; i <= n; i++) print list[i] }' "$tmp/git.log"
}
check_single_header() {
  local label="$1" verb got
  for verb in clone push; do
    got="$(effective_headers "$verb")"
    if [[ "$got" == "AUTHORIZATION: basic $TOKEN_B64" ]]; then
      note "$label: $verb sends exactly our header"
    else
      error "$label: $verb would send [$got] (want exactly our header); log=$(grep '^HEADERS' "$tmp/git.log")"
    fi
  done
  if grep -F -q "HEADERS[push]: $WRONG_HDR" "$tmp/git.log" &&
     ! awk -v w="HEADERS[push]: $WRONG_HDR" -v r="HEADERS[push]: " '
         $0 == w { seen = 1; next } seen && $0 == r { ok = 1 } END { exit ok ? 0 : 1 }' "$tmp/git.log"; then
    error "$label: no reset entry after the caller's header"
  fi
}
pre_set_version=2
for git_ver in "" 2.30.0; do
  ver_label="${git_ver:-real git}"
  pre_set_version=$((pre_set_version + 1))
  printf 'class Myapp < Formula\n  version "%s.1"\nend\n' "$pre_set_version" > "$tmp/app/packaging/brew/myapp.rb"
  run_publish "caller GIT_CONFIG_COUNT header ($ver_label)" FAKE_GIT_VERSION="$git_ver" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader "GIT_CONFIG_VALUE_0=$WRONG_HDR"
  [[ $rc -eq 0 ]] || error "caller GIT_CONFIG_COUNT header ($ver_label): exit $rc: $out"
  check_single_header "caller GIT_CONFIG_COUNT header ($ver_label)"

  printf 'class Myapp < Formula\n  version "%s.2"\nend\n' "$pre_set_version" > "$tmp/app/packaging/brew/myapp.rb"
  run_publish "caller GIT_CONFIG_PARAMETERS header ($ver_label)" FAKE_GIT_VERSION="$git_ver" \
    "GIT_CONFIG_PARAMETERS='http.https://github.com/.extraheader=$WRONG_HDR'"
  [[ $rc -eq 0 ]] || error "caller GIT_CONFIG_PARAMETERS header ($ver_label): exit $rc: $out"
  check_single_header "caller GIT_CONFIG_PARAMETERS header ($ver_label)"

  printf 'class Myapp < Formula\n  version "%s.3"\nend\n' "$pre_set_version" > "$tmp/app/packaging/brew/myapp.rb"
  cp "$tmp/home/.gitconfig" "$tmp/gitconfig.bak"
  printf '[http "https://github.com/"]\n\textraheader = %s\n' "$WRONG_HDR" >> "$tmp/home/.gitconfig"
  run_publish "global gitconfig header ($ver_label)" FAKE_GIT_VERSION="$git_ver"
  mv "$tmp/gitconfig.bak" "$tmp/home/.gitconfig"
  [[ $rc -eq 0 ]] || error "global gitconfig header ($ver_label): exit $rc: $out"
  check_single_header "global gitconfig header ($ver_label)"
done

# --- bash -x never prints the token ----------------------------------------
# Argument parsing and the empty-token check used to trace the raw token.
for how in env flag; do
  printf 'class Myapp < Formula\n  version "9.%s"\nend\n' "$how" > "$tmp/app/packaging/brew/myapp.rb"
  : > "$tmp/git.log"
  xrc=0
  if [[ "$how" == env ]]; then
    xout="$(env HOME="$tmp/home" PATH="$tmp/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 HOMEBREW_TAP_TOKEN="$TOKEN" \
      bash -x "$root_dir/scripts/publish_homebrew.sh" --repo "$tmp/app" --tap-repo owner/formula-fixture 2>&1)" || xrc=$?
  else
    xout="$(env HOME="$tmp/home" PATH="$tmp/bin:$PATH" GIT_CONFIG_NOSYSTEM=1 \
      bash -x "$root_dir/scripts/publish_homebrew.sh" --repo "$tmp/app" --tap-repo owner/formula-fixture --tap-token "$TOKEN" 2>&1)" || xrc=$?
  fi
  if [[ "$xout" == *"$TOKEN"* || "$xout" == *"$TOKEN_B64"* ]]; then
    error "bash -x ($how): token printed: $(printf '%s\n' "$xout" | grep -F -e "$TOKEN" -e "$TOKEN_B64")"
  else
    note "bash -x ($how): token not printed"
  fi
  if [[ $xrc -eq 0 ]] && printf '%s\n' "$xout" | grep -q '^+* git clone'; then
    note "bash -x ($how): publish succeeded and tracing resumed after the header"
  else
    error "bash -x ($how): rc=$xrc or tracing not restored: $xout"
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "[publish_homebrew_test] FAILED with $failures error(s)" >&2
  exit 1
fi
echo "[publish_homebrew_test] OK"
