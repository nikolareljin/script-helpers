#!/usr/bin/env bash
# SCRIPT: docs_site_test.sh
# DESCRIPTION: Tests for lib/docs_site.sh, scripts/site_verify.py and port_choose in lib/ports.sh.
# USAGE: ./tests/docs_site_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/docs_site_test.sh
# ----------------------------------------------------
# No network and no MkDocs: the generator here is a command that writes HTML,
# so the checks run wherever the suite runs, bash 3.2 included. The MkDocs
# path is exercised by running `scripts/docs_site.sh check` on a real site.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)"
cd "$root_dir"

failures=0
note()  { echo "[docs_site_test]   ok  $*"; }
error() { echo "[docs_site_test][ERROR] $*" >&2; failures=$((failures+1)); }
check() { # check <description> <expected> <actual>
  if [[ "$2" == "$3" ]]; then note "$1"; else error "$1: expected [$2], got [$3]"; fi
}
said() { # said <description> <file> <text>...
  local d="$1" f="$2" t; shift 2
  for t in "$@"; do
    grep -qF -- "$t" "$f" || { error "$d: '$t' not in: $(tr '\n' ' ' <"$f")"; return; }
  done
  note "$d"
}

# shellcheck source=/dev/null
source ./helpers.sh
shlib_import logging python ports serve docs_site

tmp="$(mktemp -d)"
holder=""
cleanup() {
  [[ -z "$holder" ]] || kill "$holder" 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT

# --- site_verify.py: crawl ---------------------------------------------------
site="$tmp/site"
mkdir -p "$site/guide" "$site/img"
cat >"$site/index.html" <<'EOF'
<html><body><h1 id="top">Home</h1>
<a href="guide/">Guide</a> <a href="guide/#setup">Setup</a> <a href="#top">Top</a>
<a href="https://example.com/">out</a> <a href="mailto:a@b.c">mail</a>
<img src="img/logo.svg"></body></html>
EOF
printf '<html><body><h2 id="setup">Setup</h2><a href="../">home</a></body></html>\n' >"$site/guide/index.html"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$site/img/logo.svg"

rc=0; python3 scripts/site_verify.py "$site" 2>"$tmp/err" || rc=$?
check "a site whose every link answers passes; external links are not fetched" "0" "$rc"

printf '<html><body><h2 id="setup">Setup</h2><a href="../missing/">x</a><a href="../#nowhere">y</a><img src="gone.png"></body></html>\n' >"$site/guide/index.html"
rc=0; python3 scripts/site_verify.py "$site" 2>"$tmp/err" || rc=$?
check "a broken link, a missing asset and a missing fragment fail" "1" "$rc"
said "each is named with the page that links to it" "$tmp/err" \
  "/guide/: links to /missing/, which answers 404" \
  "/guide/: links to /guide/gone.png, which answers 404" \
  "/guide/: links to /#nowhere, and that page has no such id"
check "and the fragment the page does have is not reported" "0" "$(grep -c '#setup' "$tmp/err" || true)"

rm "$site/index.html"
rc=0; python3 scripts/site_verify.py "$site" 2>"$tmp/err" || rc=$?
check "no index.html at the root fails" "1" "$rc"
said "and says the site would serve 404" "$tmp/err" "no index.html at the site root"

rc=0; python3 scripts/site_verify.py "$tmp/nope" 2>/dev/null || rc=$?
check "not a directory is usage (2)" "2" "$rc"

# --- site_verify.py: fences --------------------------------------------------
mkdir -p "$tmp/docs/sub"
printf '# ok\n\n````md\n```\nshown\n```\n````\n\n~~~\nx\n~~~\n' >"$tmp/docs/ok.md"
rc=0; python3 scripts/site_verify.py --fences "$tmp/docs" 2>"$tmp/err" || rc=$?
check "balanced fences, a shorter fence inside a longer one, and tildes pass" "0" "$rc"
printf '# t\n\n```bash\necho\n```python\n\n## swallowed\n' >"$tmp/docs/sub/open.md"
rc=0; python3 scripts/site_verify.py --fences "$tmp/docs" 2>"$tmp/err" || rc=$?
check "an unclosed fence fails (a fence with an info string does not close one)" "1" "$rc"
said "it names the file and the line the fence opens on" "$tmp/err" "sub/open.md:3: code fence"

# --- generator and output ----------------------------------------------------
repo="$tmp/repo"
mkdir -p "$repo"
rc=0; (unset DOCS_SITE_BUILD_CMD DOCS_SITE_GENERATOR; docs_site_generator "$repo") >/dev/null 2>"$tmp/err" || rc=$?
check "no mkdocs.yml and no build command: no site (2)" "2" "$rc"
said "and it says what was looked for" "$tmp/err" "no mkdocs.yml" "DOCS_SITE_BUILD_CMD"
printf 'site_name: x\nsite_dir: "public"  # built here\n' >"$repo/mkdocs.yml"
check "a mkdocs.yml means mkdocs" "mkdocs" "$(unset DOCS_SITE_BUILD_CMD DOCS_SITE_GENERATOR; docs_site_generator "$repo")"
check "site_dir is read, quotes and comment off" "$repo/public" "$(unset DOCS_SITE_BUILD_CMD DOCS_SITE_GENERATOR; docs_site_out "$repo")"
rm "$repo/mkdocs.yml"
rc=0; (DOCS_SITE_GENERATOR=hugo docs_site_generator "$repo") >/dev/null 2>&1 || rc=$?
check "an unknown generator is refused (2)" "2" "$rc"

# --- check with a command generator -----------------------------------------
mkdir -p "$repo/tools"
cat >"$repo/tools/build.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p out
printf '<html><body><a href="page.html">p</a></body></html>\n' >out/index.html
printf '<html><body><a href="%s">back</a></body></html>\n' "${LINK:-index.html}" >out/page.html
EOF
export DOCS_SITE_BUILD_CMD="bash tools/build.sh" DOCS_SITE_OUT=out
rc=0; docs_site_check "$repo" >"$tmp/out" 2>&1 || rc=$?
check "a command generator builds and is verified over HTTP" "0" "$rc"
said "and the result is said" "$tmp/out" "every link answers"
rc=0; LINK=broken.html docs_site_check "$repo" >"$tmp/out" 2>&1 || rc=$?
check "its broken link fails the check" "1" "$rc"
said "naming it" "$tmp/out" "links to /broken.html, which answers 404"
rc=0; DOCS_SITE_BUILD_CMD="false" docs_site_check "$repo" >"$tmp/out" 2>&1 || rc=$?
check "a failing build command fails the check" "1" "$rc"
unset DOCS_SITE_BUILD_CMD DOCS_SITE_OUT

# --- port_choose -------------------------------------------------------------
# A listener of our own, on a port the OS picked, stands for a taken port.
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
python3 -c 'import socket,sys,time; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(); time.sleep(120)' "$port" &
holder=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do port_is_free "$port" || break; sleep 0.2; done

some_free="$(port_next_free 40000)"
check "a free port is printed as it is, nobody asked" "$some_free" "$(port_choose "$some_free" </dev/null 2>/dev/null)"
rc=0; port_choose 0 >/dev/null 2>&1 || rc=$?
check "0 is not a port (2)" "2" "$rc"
rc=0; port_choose abc >/dev/null 2>&1 || rc=$?
check "abc is not a port (2)" "2" "$rc"

real_can_ask="$(declare -f _ports__can_ask)"
_ports__can_ask() { return 1; }
rc=0; port_choose "$port" "--port N" >"$tmp/out" 2>"$tmp/err" || rc=$?
check "a taken port with nobody to ask fails (1) and prints no port" "1:" "$rc:$(cat "$tmp/out")"
said "it names the port, the owner and the way to choose another" "$tmp/err" "Port ${port} is taken by:" "--port N"
# The owner is python3 where lsof, ss or netstat can see it, and said as unseen
# where none can (the bash 3.2 image has only BusyBox lsof): never a stranger.
if grep -qF "python3" "$tmp/err" || grep -qF "a process this user cannot see" "$tmp/err"; then
  note "the owner is the listener, or said to be unseen"
else
  error "the owner is someone else: $(cat "$tmp/err")"
fi

_ports__can_ask() { return 0; }
check "on a terminal, Enter takes the suggested free port" "$(port_next_free "$port")" "$(port_choose "$port" <<<"" 2>/dev/null)"
free="$(port_next_free "$port")"
check "a typed free port is used" "$free" "$(port_choose "$port" <<<"$free" 2>/dev/null)"
check "a typed taken port is asked about again" "$free" "$(printf '%s\n%s\n' "$port" "$free" | port_choose "$port" 2>/dev/null)"
check "a typed non-port is said and asked again" "$free" "$(printf 'eighty\n%s\n' "$free" | port_choose "$port" 2>"$tmp/err")"
said "with what was wrong" "$tmp/err" "Not a port: 'eighty'"
rc=0; port_choose "$port" </dev/null >/dev/null 2>&1 || rc=$?
check "no answer at all (stdin closed) fails (1)" "1" "$rc"
eval "$real_can_ask"

# BusyBox lsof ignores its options and lists every open file. A stand-in
# prints what it prints; none of it may be read as this port's listener.
mkdir -p "$tmp/bb"
printf '#!/bin/sh\nprintf "1\\t/bin/busybox\\t0\\t/dev/null\\n11\\t/bin/busybox\\t1\\tpipe:[1]\\n"\n' >"$tmp/bb/lsof"
chmod +x "$tmp/bb/lsof"
# ss, netstat and fuser are stood down, so only the lsof stand-in answers.
busybox_only() { ( PATH="$tmp/bb:$PATH"; ss() { :; }; netstat() { :; }; fuser() { :; }; "$@" 2>/dev/null || true ); }
check "BusyBox lsof gives no owner" "" "$(busybox_only list_port_usage_details 4555)"
check "and no PIDs, so a kill-port caller kills nothing" "" "$(busybox_only list_port_listener_pids 4555)"

if [[ "$failures" -eq 0 ]]; then
  echo "[docs_site_test] ALL PASSED"
else
  echo "[docs_site_test] FAILED: $failures"
  exit 1
fi
