#!/usr/bin/env bash
# serve.sh — serve a static site directory locally for preview/testing.
# Part of script-helpers. Source via helpers.sh, or run bin/serve-pages.

# serve_static_site <dir> [port]
# Serves <dir> over HTTP on the first free port at/after [port] (default 8000).
# Prefers python3, then python2, then npx http-server. Blocks until Ctrl-C.
serve_static_site() {
  local dir="${1:-}"
  local port="${2:-8000}"

  if [[ -z "$dir" || ! -d "$dir" ]]; then
    echo "serve_static_site: directory not found: '${dir}'" >&2
    return 2
  fi

  # find a free port (try up to 20 above the requested one)
  local p="$port" tries=0
  while (( tries < 20 )); do
    if ! { exec 3<>"/dev/tcp/127.0.0.1/${p}"; } 2>/dev/null; then
      break                      # connect failed => port is free
    fi
    exec 3>&- 3<&- 2>/dev/null || true
    p=$(( p + 1 )); tries=$(( tries + 1 ))
  done
  exec 3>&- 3<&- 2>/dev/null || true

  local url="http://localhost:${p}/"
  echo "Serving '${dir}' at ${url}  (Ctrl-C to stop)"

  if command -v python3 >/dev/null 2>&1; then
    exec python3 -m http.server "${p}" --directory "${dir}"
  elif command -v python >/dev/null 2>&1; then
    ( cd "${dir}" && exec python -m SimpleHTTPServer "${p}" )
  elif command -v npx >/dev/null 2>&1; then
    exec npx --yes http-server "${dir}" -p "${p}"
  else
    echo "serve_static_site: need python3, python, or npx to serve" >&2
    return 3
  fi
}
