# serve

Serve a static site directory locally for preview/testing (e.g. a GitHub Pages build output).

Functions
---------

- serve_static_site dir [port=8000]
  - Purpose: Start a static HTTP server rooted at `dir` for local preview.
  - Behavior: Auto-selects the first free TCP port at/after `port` (tries up to 20 ports above it). Prefers `python3 -m http.server`, falls back to `python -m SimpleHTTPServer`, then `npx http-server`. Prints the URL and blocks (serves until Ctrl-C).
  - Returns: `2` if `dir` is missing or not a directory; `3` if no supported server runtime (`python3`/`python`/`npx`) is found; otherwise runs until interrupted.

CLI wrapper
-----------

- `bin/serve-pages <dir> [port]` — sources this module and calls `serve_static_site "$@"`.

  ```bash
  bin/serve-pages ./site 8000
  ```

Dependencies
------------

- `python3` (preferred), or `python` (SimpleHTTPServer), or `npx` (http-server) — first one found is used.
- `/dev/tcp` (bash built-in) for the free-port probe.
