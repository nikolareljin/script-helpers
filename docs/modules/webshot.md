# webshot

Web page screenshots and HTML-to-PDF rendering with Playwright (Chromium). A JSON spec lists the pages;
the driver logs in once per auth profile, runs optional clicks and fills, hides elements, and saves one
PNG per page: the viewport, the whole page, or a single element. `webshot_pdf` prints an HTML file to PDF
with backgrounds and an optional page-number footer.

Playwright runs from a Python venv kept outside the repository
(`${XDG_CACHE_HOME:-$HOME/.cache}/nr-webshot/venv`). `webshot_ensure` creates it. Import with
`shlib_import python webshot`; `logging` is optional.

Exit codes for every function: 0 ok, 1 the run failed (login refused, selector not found, page error),
2 bad arguments or spec, 3 Python or Playwright unavailable.

Functions
---------

- `webshot_venv_dir`
  - Purpose: Print the venv directory webshot uses.
  - Returns: 0.
  - Env: `WEBSHOT_VENV` overrides the default `${XDG_CACHE_HOME:-$HOME/.cache}/nr-webshot/venv`.
  - Example: `ls "$(webshot_venv_dir)/bin"`

- `webshot_python`
  - Purpose: Print a Python interpreter that can import Playwright.
  - Returns: 0 and the path; 3 when none is found.
  - Env: `WEBSHOT_PYTHON`, when set, is the only candidate. Otherwise the webshot venv, then `python3`.
  - Example: `py="$(webshot_python)" || webshot_ensure`

- `webshot_ensure [venv_dir]`
  - Purpose: Create the venv if needed and install the pinned `playwright` package and its Chromium.
    Re-running is cheap: it returns as soon as Playwright imports and Chromium is on disk.
  - Args: `venv_dir` defaults to `webshot_venv_dir`.
  - Returns: 0 and the venv Python path; 3 when Python 3.9+, pip or the browser download is unavailable.
  - Env: `WEBSHOT_PLAYWRIGHT_VERSION` (default `1.63.0`). Browsers go to Playwright's own cache
    (`~/.cache/ms-playwright` on Linux).
  - Dependencies: the `python` module; network access on first run.
  - Example: `webshot_ensure >/dev/null`

- `webshot_capture spec.json out_dir`
  - Purpose: Capture every shot in the spec to `out_dir/<name>.png` and write `out_dir/manifest.json`.
  - Args: path to a spec file (format below) and an output directory, created if missing.
  - Returns: 0; 1 when a login, navigation, action or selector fails; 2 for a missing or invalid spec;
    3 without Playwright.
  - Env: `${VAR}` references in `base_url`, auth profiles, shot `path`/`url` and action `value`s are
    expanded from the environment, so credentials and IDs stay out of spec files. Selectors and `eval`
    code are never expanded, so a JavaScript template literal is left as written.
  - Example: `APP_PASSWORD=... webshot_capture docs/shots.json build/shots`

- `webshot_pdf input.html output.pdf [--format Letter|A4|A3|Legal|Tabloid] [--landscape] [--footer TEXT] [--wait-ms N]`
  - Purpose: Print a local HTML file to PDF with backgrounds. CSS `@page` size and margins win when the
    document sets them. `--footer` adds `TEXT` and `page / total` at the bottom of every page.
  - Returns: 0; 1 when rendering fails; 2 for bad arguments or a missing input; 3 without Playwright.
  - Env: none.
  - Example: `webshot_pdf build/report.html build/report.pdf --footer "Quarterly report"`

Spec format
-----------

```json
{
  "base_url": "http://localhost:8080",
  "viewport": {"width": 1440, "height": 900},
  "device_scale_factor": 2,
  "wait_ms": 600,
  "timeout_ms": 15000,
  "hide": ["[data-dev-banner]"],
  "fail_on_console_error": false,
  "auth": {
    "editor": {
      "type": "api_token",
      "url": "/api/login",
      "body": {"email": "editor@example.com", "password": "${APP_PASSWORD}"},
      "token_path": "access_token",
      "storage_key": "token"
    },
    "viewer": {
      "type": "form",
      "url": "/login",
      "steps": [
        {"fill": "#email", "value": "viewer@example.com"},
        {"fill": "#password", "value": "${APP_PASSWORD}"},
        {"click": "button[type=submit]"},
        {"wait_for": "nav"}
      ]
    }
  },
  "shots": [
    {"name": "home", "path": "/"},
    {"name": "dashboard", "path": "/dashboard", "auth": "editor", "full_page": true},
    {"name": "totals-card", "path": "/dashboard", "auth": "editor",
     "selector": "[data-shot=totals]", "padding": 8},
    {"name": "edit-dialog", "path": "/items/42", "auth": "editor",
     "actions": [{"click": "text=Edit"}, {"wait_for": "[role=dialog]"}]},
    {"name": "home-mobile", "path": "/", "viewport": {"width": 390, "height": 844}}
  ]
}
```

Top-level keys (all optional except `shots`):

| Key | Meaning |
|-----|---------|
| `base_url` | Joined with each shot's `path` and with relative auth URLs. Required when a shot uses `path`. |
| `viewport`, `device_scale_factor` | Defaults for every shot. Use a factor of 2 for print-sharp images. |
| `wait_ms` | Pause after load and actions, before the capture (default 500). |
| `wait_until` | Playwright load state for navigation (default `networkidle`). |
| `timeout_ms` | Timeout for each locator and action (default 15000). |
| `hide` | CSS selectors set to `display: none` on every shot. |
| `color_scheme`, `locale`, `timezone_id` | Browser context options. |
| `fail_on_console_error` | Exit 1 when any page logs a console error (default: record it in the manifest only). |
| `auth` | Named profiles, used by `shot.auth`. |

Auth profiles:

- `none`: no login.
- `api_token`: sends `method` (default `POST`) to `url` with the JSON `body` and optional `headers`,
  reads the value at `token_path` (dot path, list indexes allowed) and writes it to
  `localStorage[storage_key]` before any page script runs. Logs in once per profile.
- `form`: opens `url`, runs `steps` (same actions as shots), then reuses the resulting cookies and
  storage for every shot with that profile.

Shot keys: `name` (required; letters, digits, `.`, `_`, `-`), `path` or `url`, `auth`, `viewport`,
`device_scale_factor`, `full_page`, `selector` (Playwright locator; captures that element),
`padding` (pixels around a `selector` capture), `wait_for` (selector that must be visible first),
`wait_ms`, `hide`, `actions`, `title` (copied to the manifest, handy for captions).

Actions, run in order: `{"click": sel}`, `{"fill": sel, "value": text}`, `{"select": sel, "value": v}`,
`{"press": key, "selector": sel}` (selector optional), `{"hover": sel}`, `{"scroll_to": sel}`,
`{"wait_for": sel}`, `{"wait_ms": n}`, `{"eval": "() => ..."}`. An `eval` that throws fails the run,
which makes it a cheap assertion.

`manifest.json` lists every shot: `name`, `file`, `width`, `height` (pixels), `url`, `title`,
`console_errors`, `http_errors` (responses with status 400 or more).

Command line
------------

`bin/webshot ensure | capture <spec> <out_dir> | pdf <in.html> <out.pdf> [options]` wraps the functions
above with the same exit codes.
