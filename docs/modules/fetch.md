# fetch

Download one release asset to a file, with retries and a clear error. The
scanner installs (`gitleaks`, `foxguard`), `ollama_install` and `docker_install`
download through `fetch_to_file`. `download_file` and `dialog_download_file` keep
their own `curl`/`wget` calls and return codes, with the same retry options.

- `curl` runs with `--retry 3 --retry-delay 2`, and `--retry-all-errors` when it is
  7.71 or newer. Older `curl` does not know that option, so it is left out there.
- `wget` (used when there is no `curl`) runs with `--tries=3 --waitretry=2`.
- A failed download deletes the output file, so a partial file is never left for
  the caller. Callers still check the SHA-256 of the file they get.

A failure prints one line on stderr, for example:

```
[ERROR] gitleaks: download failed from github.com: curl exit 7 (could not connect), after retries; URL https://github.com/...
  curl: (7) Failed to connect to github.com port 443 ...
```

The second line is the tool's last error line, printed once and only when the URL
is shown.

Return codes: `0` downloaded, `1` the download failed, `2` bad arguments, `3`
no `curl` or `wget`.

PowerShell: `ps/lib/fetch.ps1` has `fetch_to_file -Label -Url -OutFile` and
`fetch_url_host -Url` and `fetch_url_display -Url`. `Invoke-WebRequest` has no retry option in Windows
PowerShell 5.1, so it is a loop: 3 attempts, 2 seconds apart, the file deleted
after each failed one.

Functions
---------

- fetch_to_file label url output
  - Purpose: Download `url` to `output` with `curl` (or `wget`), retrying transient errors.
  - Behavior: On failure, deletes `output` and prints the label, the host, the tool, its exit code and a short reason.
  - Env: `FETCH_MAX_TIME` - seconds per `curl` attempt (default `300`).
  - Returns: 0 downloaded; 1 failed; 2 an empty argument, a URL that starts with `-`, or output `-`; 3 no `curl` or `wget`.

- fetch_curl_retry_args
  - Purpose: Print the retry options this machine's `curl` accepts, one per line.

- fetch_url_display url
  - Purpose: Print the URL when it may be shown: an absolute `http` or `https` URL whose authority (from `://` to the first `/`, `?` or `#`) has no `@`, whose host `fetch_url_host` can name, printable ASCII with no space. Anything else prints `(URL not shown)`, so user info such as `user:token@host` never reaches a log and a URL cannot forge a log line.

- fetch_url_host url
  - Purpose: Print the host of an `http` or `https` URL, without user info or port. `(unknown host)` for another scheme, an empty host, an unclosed `[`, or an authority with a backslash or anything but printable ASCII (`https://a\@b/` names neither `a` nor `b`). Bash and PowerShell print the same; the shared cases are in `tests/fixtures/fetch_url_cases.txt`.

- fetch_exit_reason tool code
  - Purpose: Print a short reason for a `curl` or `wget` exit code.
