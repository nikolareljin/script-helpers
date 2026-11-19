# fetch

Download one release asset to a file, with retries and a clear error. The
scanner installs (`gitleaks`, `foxguard`), `ollama_install`, `docker_install`,
`download_file` and `dialog_download_file` all download through it.

- `curl` runs with `--retry 3 --retry-delay 2`, and `--retry-all-errors` when it is
  7.71 or newer. Older `curl` does not know that option, so it is left out there.
- `wget` (used when there is no `curl`) runs with `--tries=3 --waitretry=2`.
- A failed download deletes the output file, so a partial file is never left for
  the caller. Callers still check the SHA-256 of the file they get.

A failure prints one line on stderr, for example:

```
[ERROR] gitleaks: download failed from github.com: curl exit 7 (could not connect), after retries; URL https://github.com/...
```

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
  - Returns: 0 downloaded; 1 failed; 2 an empty argument or a URL that starts with `-`; 3 no `curl` or `wget`.

- fetch_curl_retry_args
  - Purpose: Print the retry options this machine's `curl` accepts, one per line.

- fetch_url_display url
  - Purpose: Print the URL when it may be shown: an absolute `http` or `https` URL whose authority (from `://` to the first `/`, `?` or `#`) has no `@`. Anything else prints `(URL not shown)`, so user info such as `user:token@host` never reaches a log.

- fetch_url_host url
  - Purpose: Print the host of a URL, without user info or port.

- fetch_exit_reason tool code
  - Purpose: Print a short reason for a `curl` or `wget` exit code.
