# http

Probe a JSON service and prove an API key against it.

Functions
---------

- http_probe_json URL PATH [TIMEOUT]
  - Purpose: GET `URL/PATH` once and print the body.
  - Args: `URL` (a trailing `/` is dropped), `PATH` (a leading `/` is added when missing), `TIMEOUT` whole seconds, default 5, used for both the connect and the total deadline.
  - Returns: 0 and the body on a 2xx with a body; 1 when nothing answers, the status is not 2xx or the body is empty, or an argument is missing or bad.
  - Read a field from the body with `json_get_field` (json module).

- http_check_key URL PATH HEADER KEY
  - Purpose: Prove `KEY`, sent as `HEADER: KEY`, against an authenticated read at `URL/PATH`.
  - Returns: 0 accepted (200 with a JSON media type, `application/json` or `application/*+json`); 2 refused (401 or 403); 1 nothing answered, any other status, a 200 that is not JSON (a web app or captive portal answers every path that way), or bad arguments.
  - Behavior: the key reaches curl on stdin as a config line (`-K -`), never in argv, where other users could read it with `ps`. A key containing CR or LF is refused (header injection), and so is a header name that is not `[A-Za-z0-9-]+`.

Example
-------

```bash
source ./helpers.sh
shlib_import logging json http
body="$(http_probe_json "$URL" /v1/info)" || { log_error "not answering"; exit 1; }
echo "version $(json_get_field "$body" version)"
rc=0; http_check_key "$URL" "/v1/items?limit=1" X-API-Key "$KEY" || rc=$?
case $rc in 0) echo ok ;; 2) echo "wrong key" ;; *) echo "not serving" ;; esac
```

Dependencies
------------

- `curl`; `logging` for messages.
