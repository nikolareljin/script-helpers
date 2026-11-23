# fetch

Download one release asset to a file, with retries and a clear error. The
scanner installs (`gitleaks`, `foxguard`), `ollama_install`, `docker_install`,
the Node.js step of `deps` and `scripts/ci_wp_phpunit.sh` download through
`fetch_to_file`. A repository signing key goes through `fetch_verified_gpg_key`. `download_file` and `dialog_download_file` keep
their own `curl`/`wget` calls and return codes, with the same retry and
redirect options.

- `curl` runs with `--retry 3 --retry-delay 2`, and `--retry-all-errors` when it is
  7.71 or newer. Older `curl` does not know that option, so it is left out there.
- `wget` (used when there is no `curl`) runs with `--tries=3 --waitretry=2`, plus
  `--retry-on-http-error=429,500,502,503,504` when it has that option (wget 1.19.1
  or newer). Without it wget does not retry a 503. `FETCH_MAX_TIME` bounds the
  whole download through `timeout` (or `gtimeout`) when one is installed.
- Redirects keep to the URL's scheme: an `https` URL is fetched and redirected
  over `https` only, an `http` URL over `http` or `https`. `curl` does this with
  `--proto` and `--proto-redir`. `wget --https-only` covers recursive mode only,
  so for an `https` URL `fetch_wget_follow` runs `wget --max-redirect=0` and
  follows each redirect itself: to an `https` URL on any host, or a relative
  reference (`/x`, `x`, `//host/x`) resolved over `https`, at most 5. `FETCH_MAX_TIME` is one deadline for all the hops (exit 124 when it
  passes); without `timeout` or `gtimeout`, `wget` has only its per-read `-T`
  and the deadline is checked between hops.
- A failed download deletes the output file, and so does an exit, HUP, INT or
  TERM during the download: a partial file is never left for the caller. The
  temp directory of `fetch_verified_gpg_key` goes the same way. The caller's own
  traps are kept and run after the cleanup; an ignored signal stays ignored
  (see [trap_stack](./trap_stack.md)). Callers still check the SHA-256 of the
  file they get.

A failure prints one line on stderr, for example:

```
[ERROR] gitleaks: download failed from github.com: curl exit 7 (could not connect), after retries; URL https://github.com/...
  curl: (7) Failed to connect to github.com port 443 ...
```

The second line is the tool's last error line, printed once and only when the
whole URL is shown: no user info, no query, no fragment. A signed URL carries its
token in the query, so a query prints as `?(not shown)`.

Return codes: `0` downloaded, `1` the download failed, `2` bad arguments, `3`
no `curl` or `wget`.

PowerShell: `ps/lib/fetch.ps1` has `fetch_to_file -Label -Url -OutFile` and
`fetch_url_host -Url` and `fetch_url_display -Url`. `Invoke-WebRequest` has no retry option in Windows
PowerShell 5.1, so it is a loop: 3 attempts, 2 seconds apart, the file deleted
after each failed one. An HTTP 4xx other than 408 and 429 is not retried.
PowerShell 7 does not follow an `https` URL to `http`; Windows PowerShell 5.1
does, and the SHA-256 each caller checks is what protects the file there.

Functions
---------

- fetch_to_file label url output
  - Purpose: Download `url` to `output` with `curl` (or `wget`), retrying transient errors.
  - Behavior: On failure, deletes `output` and prints the label, the host, the tool, its exit code and a short reason.
  - Env: `FETCH_MAX_TIME` - seconds for the download (`curl --max-time`; `wget` under `timeout`). Default `300`; anything but a whole number from 1 to 9999999 means `300`.
  - Returns: 0 downloaded; 1 failed; 2 an empty argument, a URL that starts with `-`, or output `-`; 3 no `curl` or `wget`.

- fetch_verified_gpg_key label url fingerprint output
  - Purpose: Download an OpenPGP key and write it to `output` only when it is the pinned one.
  - Behavior: The key is fetched with `fetch_to_file` and imported into a throwaway `GNUPGHOME`. It is accepted when the file holds exactly one primary key whose fingerprint is `fingerprint` (40 hex digits, upper case). `output` gets the armored key as `gpg` exports it, not the download. On any failure `output` is not written. The temp directory is always removed.
  - Returns: 0 verified and written; 1 no `gpg`, the download failed, or the key is not the pinned one; 2 an empty argument, an output that starts with `-`, or a fingerprint that is not 40 upper-case hex digits.
  - Dependencies: `gpg`; `curl` or `wget`.
  - Used by: `docker_install` (Docker's apt and rpm keys) and `deps` (NodeSource's apt key).
  - Example: `fetch_verified_gpg_key deps https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key "$CI_DEFAULT_NODESOURCE_APT_FPR" "$dir/key.asc"`

- fetch_curl_retry_args
  - Purpose: Print the retry options this machine's `curl` accepts, one per line.

- fetch_curl_proto_args url
  - Purpose: Print `--proto =https --proto-redir =https` for an `https` URL, `--proto =http,https --proto-redir =http,https` for an `http` URL, nothing for another scheme.

- fetch_wget_args
  - Purpose: Print `--retry-on-http-error=429,500,502,503,504` when this machine's `wget` has it. busybox `wget` gets nothing.

- fetch_wget_follow url output [wget option...]
  - Purpose: `wget` `url` to `output` with `--max-redirect=0`, following each redirect itself: only to an `https` URL (any host) or a relative reference such as `/x`, `x` or `//host/x`, resolved over https, at most 5. Another scheme is refused.
  - Env: `FETCH_MAX_TIME` - one deadline in seconds for all the hops (default `300`).
  - Returns: `wget`'s exit code; 1 when a redirect is refused or there are more than 5; 124 when the deadline passes.

- fetch_url_display url
  - Purpose: Print the URL when it may be shown: an absolute `http` or `https` URL whose authority (from `://` to the first `/`, `?` or `#`) has no `@`, whose host `fetch_url_host` can name, printable ASCII with no space. It prints scheme, authority and path; a query becomes `?(not shown)` and a fragment is left out (`https://h/a?X-Amz-Signature=...#t` prints `https://h/a?(not shown)`). Anything else prints `(URL not shown)`, so user info such as `user:token@host` never reaches a log and a URL cannot forge a log line.

- fetch_url_host url
  - Purpose: Print the host of an `http` or `https` URL, without user info or port. `(unknown host)` for another scheme, an empty host, an unclosed `[`, or an authority with a backslash or anything but printable ASCII (`https://a\@b/` names neither `a` nor `b`). Bash and PowerShell print the same; the shared cases are in `tests/fixtures/fetch_url_cases.txt`.

- fetch_exit_reason tool code
  - Purpose: Print a short reason for a `curl` or `wget` exit code.
