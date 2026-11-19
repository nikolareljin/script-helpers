#!/usr/bin/env bash
# SCRIPT: fetch_test.sh
# DESCRIPTION: Tests lib/fetch.sh: scanner downloads retry transient errors, and a failed one says why and leaves no file.
# USAGE: bash tests/fetch_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/fetch_test.sh
# ----------------------------------------------------
#
# A stub curl (and wget) fails the first FAIL_FIRST attempts across the run,
# writing a partial file each time, then serves the asset. It retries only as
# often as its --retry/--tries option allows, the way the real tools do, and a
# stub curl older than 7.71 rejects --retry-all-errors as real curl does.
# Nothing goes to the network. A last case runs the real curl against a local
# server that answers 503 twice, when python3 and curl are there.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[fetch_test] $*"; }
error() { echo "[fetch_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
server_pid=""
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$tmp"; fi' EXIT

# A PATH with no real curl or wget: tools linked one by one.
mkdir -p "$tmp/bin" "$tmp/stub" "$tmp/u"
for c in bash sh env dirname basename mktemp head tail rm cat grep sed awk tr \
         find sort mkdir chmod mv cp tar gzip shasum openssl ls wc cut \
         printf touch sha256sum xargs; do
  p="$(command -v "$c" 2>/dev/null)" && [[ "$p" == /* ]] && ln -sf "$p" "$tmp/bin/$c"
done
printf '#!/usr/bin/env bash\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; *) echo Linux;; esac\n' > "$tmp/u/uname"
chmod +x "$tmp/u/uname"

# The fake releases: a gitleaks archive and a foxguard binary.
mkdir -p "$tmp/rel"
printf '#!/usr/bin/env bash\necho 8.30.1\n' > "$tmp/rel/gitleaks"; chmod +x "$tmp/rel/gitleaks"
tar -czf "$tmp/rel/gitleaks.tar.gz" -C "$tmp/rel" gitleaks
printf '#!/usr/bin/env bash\necho 0.14.1\n' > "$tmp/rel/foxguard"
GL_SHA="$(source "$ROOT_DIR/lib/foxguard.sh" && foxguard_sha256 "$tmp/rel/gitleaks.tar.gz")"
FG_SHA="$(source "$ROOT_DIR/lib/foxguard.sh" && foxguard_sha256 "$tmp/rel/foxguard")"
[[ ${#GL_SHA} -eq 64 ]] || { note "SKIP: no shasum, sha256sum or openssl"; exit 0; }

# Stub curl. STUB_VERSION is what --version reports. STUB_FAIL_FIRST attempts
# fail with exit 7 (across calls, counted in $tmp/count); STUB_FAIL_FIRST=all
# fails every one.
cat > "$tmp/stub/curl" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == --version ]]; then echo "curl \${STUB_VERSION:-8.5.0} (x86_64-pc-linux-gnu)"; exit 0; fi
echo "curl \$*" >> "$tmp/calls.log"
out=""; url=""; retries=0
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    --retry) retries="\$2"; shift 2 ;;
    --retry-delay|--connect-timeout|--max-time) shift 2 ;;
    --retry-all-errors)
      case "\${STUB_VERSION:-8.5.0}" in 7.[0-6]*|7.70*) echo "curl: option --retry-all-errors: is unknown" >&2; exit 2 ;; esac
      shift ;;
    --) shift; url="\$1"; shift ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in *gitleaks*) src="$tmp/rel/gitleaks.tar.gz" ;; *) src="$tmp/rel/foxguard" ;; esac
attempt=0
while [[ \$attempt -le \$retries ]]; do
  attempt=\$((attempt+1))
  n=\$(cat "$tmp/count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$tmp/count"
  if [[ "\${STUB_FAIL_FIRST:-0}" == all || \$n -le \${STUB_FAIL_FIRST:-0} ]]; then
    printf 'partial' > "\$out"
    [[ -n "\${STUB_ERR_EACH:-}" ]] && echo "curl: (7) Failed to connect" >&2
    continue
  fi
  cp "\$src" "\$out"; exit 0
done
echo "curl: (7) Failed to connect" >&2
exit 7
EOF
# Stub wget: the same, with --tries=N attempts in all and exit 4.
cat > "$tmp/stub/wget" <<EOF
#!/usr/bin/env bash
echo "wget \$*" >> "$tmp/calls.log"
out=""; url=""; tries=1
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -O) out="\$2"; shift 2 ;;
    -T) shift 2 ;;
    --tries=*) tries="\${1#--tries=}"; shift ;;
    --) shift; url="\$1"; shift ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in *gitleaks*) src="$tmp/rel/gitleaks.tar.gz" ;; *) src="$tmp/rel/foxguard" ;; esac
attempt=0
while [[ \$attempt -lt \$tries ]]; do
  attempt=\$((attempt+1))
  n=\$(cat "$tmp/count" 2>/dev/null || echo 0); n=\$((n+1)); echo "\$n" > "$tmp/count"
  if [[ "\${STUB_FAIL_FIRST:-0}" == all || \$n -le \${STUB_FAIL_FIRST:-0} ]]; then
    printf 'partial' > "\$out"
    continue
  fi
  cp "\$src" "\$out"; exit 0
done
exit 4
EOF
chmod +x "$tmp/stub/curl" "$tmp/stub/wget"

# run <tools dir> <code>: runs code with logging, foxguard and gitleaks loaded,
# on a fresh cache and attempt count. Output and rc go to $tmp/out, $rc.
rc=0
run() {
  local tools="$1"; shift
  rm -rf "$tmp/cache"; rm -f "$tmp/count" "$tmp/calls.log"
  rc=0
  # A subshell, so the libraries and PATH do not leak into this script. The
  # function is named literally, never run from a string.
  (
    export PATH="$tmp/u:$tools:$tmp/bin" XDG_CACHE_HOME="$tmp/cache" \
      CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64="$GL_SHA" CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64="$FG_SHA"
    source "$ROOT_DIR/lib/logging.sh"; source "$ROOT_DIR/lib/foxguard.sh"; source "$ROOT_DIR/lib/gitleaks.sh"
    case "$1" in
      gitleaks_install) gitleaks_install ;;
      foxguard_install) foxguard_install ;;
      *) exit 99 ;;
    esac
  ) >"$tmp/out" 2>&1 || rc=$?
}
cached_files() { find "$tmp/cache" -type f 2>/dev/null | wc -l | tr -d ' '; }

# 1. Two transient failures, then the release: both scanners install.
for tool in gitleaks foxguard; do
  STUB_FAIL_FIRST=2 run "$tmp/stub" "${tool}_install"
  if [[ $rc -eq 0 && "$(cat "$tmp/count")" == 3 ]] && grep -q -- "--retry 3" "$tmp/calls.log" \
     && grep -q -- "--retry-all-errors" "$tmp/calls.log"; then
    note "$tool: two failed attempts, installed on the third"
  else
    error "$tool after two failures: rc=$rc attempts=$(cat "$tmp/count" 2>/dev/null) out='$(cat "$tmp/out")' calls='$(cat "$tmp/calls.log" 2>/dev/null)'"
  fi
done

# 2. Every attempt fails: rc 1, a message naming the host, the tool and its
#    exit code, and no file left in the cache (the partial one is deleted).
for tool in gitleaks foxguard; do
  STUB_FAIL_FIRST=all run "$tmp/stub" "${tool}_install"
  if [[ $rc -eq 1 && "$(cat "$tmp/count")" == 4 && "$(cached_files)" == 0 ]] \
     && grep -q "$tool: download failed from github.com: curl exit 7 (could not connect)" "$tmp/out"; then
    note "$tool: always failing -> rc 1, clear reason, nothing left behind"
  else
    error "$tool always failing: rc=$rc attempts=$(cat "$tmp/count" 2>/dev/null) files=$(cached_files) out='$(cat "$tmp/out")'"
  fi
done

# 3. curl older than 7.71: no --retry-all-errors (it would reject it), still
#    --retry 3, and the install still gets past a failure.
STUB_VERSION=7.68.0 STUB_FAIL_FIRST=1 run "$tmp/stub" "gitleaks_install"
if [[ $rc -eq 0 ]] && grep -q -- "--retry 3" "$tmp/calls.log" && ! grep -q -- "--retry-all-errors" "$tmp/calls.log"; then
  note "curl 7.68: --retry 3 without --retry-all-errors, installed"
else
  error "old curl: rc=$rc out='$(cat "$tmp/out")' calls='$(cat "$tmp/calls.log" 2>/dev/null)'"
fi
for v in 7.71.0 7.88.1 8.5.0; do
  got="$(STUB_VERSION=$v PATH="$tmp/stub:$tmp/bin" bash -c "source '$ROOT_DIR/lib/fetch.sh'; fetch_curl_retry_args" | tr '\n' ' ')"
  [[ "$got" == "--retry 3 --retry-delay 2 --retry-all-errors " ]] && note "curl $v: --retry-all-errors" || error "curl $v: '$got'"
done
got="$(STUB_VERSION=7.70.0 PATH="$tmp/stub:$tmp/bin" bash -c "source '$ROOT_DIR/lib/fetch.sh'; fetch_curl_retry_args" | tr '\n' ' ')"
[[ "$got" == "--retry 3 --retry-delay 2 " ]] && note "curl 7.70.0: no --retry-all-errors" || error "curl 7.70.0: '$got'"

# 4. wget when there is no curl: --tries=3, and a clear reason when all fail.
mkdir -p "$tmp/wgetonly"; ln -sf "$tmp/stub/wget" "$tmp/wgetonly/wget"
STUB_FAIL_FIRST=2 run "$tmp/wgetonly" "foxguard_install"
if [[ $rc -eq 0 ]] && grep -q -- "--tries=3" "$tmp/calls.log"; then
  note "wget: two failed attempts, installed on the third"
else
  error "wget retry: rc=$rc out='$(cat "$tmp/out")' calls='$(cat "$tmp/calls.log" 2>/dev/null)'"
fi
STUB_FAIL_FIRST=all run "$tmp/wgetonly" "foxguard_install"
if [[ $rc -eq 1 && "$(cached_files)" == 0 ]] && grep -q "foxguard: download failed from github.com: wget exit 4 (network failure)" "$tmp/out"; then
  note "wget: always failing -> rc 1, clear reason, nothing left behind"
else
  error "wget always failing: rc=$rc files=$(cached_files) out='$(cat "$tmp/out")'"
fi

# 5. Neither curl nor wget: rc 3 and says so.
run "$tmp/u" "gitleaks_install"
[[ $rc -eq 3 ]] && grep -q "curl or wget is needed" "$tmp/out" && note "no curl or wget: rc 3" \
  || error "no downloader: rc=$rc out='$(cat "$tmp/out")'"

# 6. fetch_to_file argument checks and the host in the message.
rc=0; bash -c "source '$ROOT_DIR/lib/fetch.sh'; fetch_to_file x -bad '$tmp/o'" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && note "a URL starting with - is refused (2)" || error "dash URL: rc=$rc"
for row in "https://user:pw@example.com:8443/a/b example.com" "http://[::1]:8000/x [::1]" \
           "https://github.com/o/r/releases/download/v1/a github.com" "https://example.org?q=1 example.org"; do
  read -r u want <<<"$row"
  got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_host "$u")"
  [[ "$got" == "$want" ]] && note "host of $u: $want" || error "host of $u: got '$got', want $want"
done

# 6b. A URL with user info: the host is named, the credentials are not printed.
rc=0
out="$(PATH="$tmp/stub:$tmp/bin" STUB_FAIL_FIRST=all bash -c 'source "$1/lib/fetch.sh"; fetch_to_file t "https://user:s3cr3t@example.com/a" "$2/o"' _ "$ROOT_DIR" "$tmp" 2>&1)" || rc=$?
if [[ $rc -eq 1 && "$out" == *"from example.com"* && "$out" != *s3cr3t* ]]; then
  note "user info in the URL is not printed"
else
  error "user info: rc=$rc out='$out'"
fi

# 6c. Which URLs are printed: only absolute http(s) with no "@" in the authority.
N="(URL not shown)"
while IFS='|' read -r u want; do
  got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_display "$u")"
  [[ "$got" == "$want" ]] && note "display of '$u': $want" || error "display of '$u': got '$got', want '$want'"
done <<EOF2
https://user:pass@example.com/a|$N
https://token@example.com/a|$N
HTTPS://tok@Example.com|$N
user:pass@example.com/a|$N
example.com/a|$N
ftp://example.com/a|$N
https://|$N
https://:@/x|$N
https://example.com/a@b|https://example.com/a@b
https://example.com/a?u=x@y|https://example.com/a?u=x@y
https://example.com#x@y|https://example.com#x@y
https://github.com/o/r/releases/download/v1/a|https://github.com/o/r/releases/download/v1/a
EOF2

# 6d. Fail closed on the host too: a string that is not an http(s) URL names
# no host, so a bare token passed as the URL is never printed.
for u in "ghp_s3cr3t" "tok:s3cr3t" "file:///etc/passwd" "https://"; do
  got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_host "$u")"
  [[ "$got" == "(unknown host)" ]] && note "no host for '$u'" || error "host of '$u': got '$got', want (unknown host)"
done

# 6e. A URL with a control character or a space is not printed: it could forge
# a log line.
got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_display $'https://example.com/a\n[ERROR] forged')"
[[ "$got" == "$N" ]] && note "URL with a newline not shown" || error "newline URL shown: '$got'"
got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_display 'https://example.com/a b')"
[[ "$got" == "$N" ]] && note "URL with a space not shown" || error "space URL shown: '$got'"
# In a UTF-8 locale [:graph:] matches a bidi override, a no-break space and a
# zero-width space, so the check must run in the C locale (printable ASCII).
if locale -a 2>/dev/null | grep -ix 'c\.utf-\?8' >/dev/null; then
  for u in $'https://example.com/a\xe2\x80\xaeb' $'https://example.com/a\xc2\xa0b' $'https://ex\xe2\x80\x8bample.com/a'; do
    got="$(export LC_ALL=C.UTF-8; source "$ROOT_DIR/lib/fetch.sh"; fetch_url_display "$u"; fetch_url_host "$u")"
    [[ "$got" == "$N"$'\n'"example.com" || "$got" == "$N"$'\n'"(unknown host)" ]] \
      && note "UTF-8 locale: non-ASCII URL not shown" || error "UTF-8 locale shows '$got'"
  done
else
  note "SKIP UTF-8 locale case: no C.UTF-8 locale"
fi

# 6g. The shared table in tests/fixtures/fetch_url_cases.txt: ps/tests/fetch_test.ps1
# runs the same rows, so bash and PowerShell print the same host and URL.
while IFS='|' read -r raw want_h want_d; do
  [[ -z "$raw" || "$raw" == \#* ]] && continue
  u="$(printf '%b' "$raw")"
  [[ "$want_d" == "=" ]] && want_d="$u"
  got="$(source "$ROOT_DIR/lib/fetch.sh"; fetch_url_host "$u"; printf '|'; fetch_url_display "$u")"
  [[ "$got" == "$want_h"$'\n|'"$want_d" ]] && note "shared case '$raw'" \
    || error "shared case '$raw': got '$got', want '$want_h|$want_d'"
done < "$ROOT_DIR/tests/fixtures/fetch_url_cases.txt"

# 6f. Output "-" is refused: curl would write the asset to stdout, and the
# failure path would delete a file named "-" in the working directory.
rc=0; bash -c "source '$ROOT_DIR/lib/fetch.sh'; fetch_to_file x https://example.com/a -" >/dev/null 2>&1 || rc=$?
[[ $rc -eq 2 ]] && note "output - is refused (2)" || error "output -: rc=$rc"

# 6g. curl's own error text is printed once, not once per attempt, and not at
# all when the URL is hidden.
rc=0
out="$(PATH="$tmp/stub:$tmp/bin" STUB_FAIL_FIRST=all STUB_ERR_EACH=1 bash -c 'source "$1/lib/fetch.sh"; fetch_to_file t "https://example.com/a" "$2/o"' _ "$ROOT_DIR" "$tmp" 2>&1)" || rc=$?
n="$(printf '%s\n' "$out" | grep -c 'curl: (7)')"
[[ $rc -eq 1 && $n -eq 1 ]] && note "curl error text shown once" || error "curl error text count $n: '$out'"
out="$(PATH="$tmp/stub:$tmp/bin" STUB_FAIL_FIRST=all STUB_ERR_EACH=1 bash -c 'source "$1/lib/fetch.sh"; fetch_to_file t "https://u:pw@example.com/a" "$2/o"' _ "$ROOT_DIR" "$tmp" 2>&1)" || true
[[ "$out" != *"curl: (7)"* ]] && note "curl error text hidden with the URL" || error "curl text shown with hidden URL: '$out'"
rm -f "$tmp/count"

# 7. The real curl against a local server that answers 503 twice, then 200.
real_curl="$(command -v curl 2>/dev/null || true)"
if [[ -n "$real_curl" ]] && command -v python3 >/dev/null 2>&1; then
  cat > "$tmp/server.py" <<'EOF'
import http.server, sys
fails = [2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if fails[0] > 0:
            fails[0] -= 1
            self.send_response(503); self.send_header("Content-Length", "0"); self.end_headers(); return
        body = b"asset"
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
  python3 "$tmp/server.py" "$tmp/port" &
  server_pid=$!
  for _ in $(seq 1 150); do [[ -s "$tmp/port" ]] && break; sleep 0.2; done
  if [[ -s "$tmp/port" ]]; then
    rc=0
    bash -c "source '$ROOT_DIR/lib/fetch.sh'; fetch_to_file real 'http://127.0.0.1:$(cat "$tmp/port")/a' '$tmp/real.out'" >"$tmp/out" 2>&1 || rc=$?
    [[ $rc -eq 0 && "$(cat "$tmp/real.out" 2>/dev/null)" == asset ]] \
      && note "real curl: two 503s, then the file" || error "real curl: rc=$rc out='$(cat "$tmp/out")'"
  else
    error "the local server did not start"
  fi
else
  note "SKIP real curl case: needs curl and python3"
fi

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
