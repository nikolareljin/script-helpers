# foxguard

Find, install and verify the pinned [foxguard](https://github.com/0sec-labs/foxguard)
static-analysis scanner that `scripts/ci_security.sh` runs. `npx foxguard` fetches
the latest version; this module runs the one pinned in `ci_defaults`, and refuses a
downloaded or cached binary whose SHA-256 does not match the pin.

Return codes: `0` success, `1` failed (download, checksum mismatch), `3` the
pinned version not installed, a required tool missing, or no release binary for
this platform.

Functions
---------

- foxguard_asset
  - Purpose: Print the release asset name for this machine, e.g. `foxguard-linux-x86_64`, or `foxguard-windows-x86_64.exe` under Git Bash, MSYS or Cygwin.
  - Returns: 3 on a platform with no release binary (Linux and macOS on x86_64 and aarch64, and Windows on x86_64, have one).

- foxguard_config_in dir
  - Purpose: Print the foxguard config file in that directory, if there is one.
  - Behavior: Looks for each name in `FOXGUARD_CONFIG_NAMES` (`.foxguard.yml .foxguard.yaml foxguard.yml foxguard.yaml`; foxguard 0.14.1 reads all four).
  - Returns: 1 when there is none.
  - Used by: `scripts/ci_security.sh`, which counts findings only where a config is found from the scan directory up to the repository top.

- foxguard_expected_sha256 asset
  - Purpose: Print the pinned SHA-256 of that asset, from `CI_DEFAULT_FOXGUARD_SHA256_*`.

- foxguard_cache_path
  - Purpose: Print where the pinned binary is installed: `${XDG_CACHE_HOME:-~/.cache}/script-helpers/foxguard/<version>/foxguard` (`foxguard.exe` on Windows).

- foxguard_is_pinned file
  - Purpose: Tell whether the file's SHA-256 is the one pinned for this machine's release asset.
  - Returns: 0 it is; 1 it is not (also a file that cannot be read); 3 no release binary for this platform, or no SHA-256 tool.

- foxguard_path_bin
  - Purpose: Print the `foxguard` on `PATH`, when `foxguard --version` reports the pinned version or a newer one.
  - Returns: 3 when there is none, it is older, or its version is not `X.Y.Z`.

- foxguard_bin
  - Purpose: Print the foxguard to run: the cached binary of the pinned version when `foxguard_is_pinned` accepts it, else `foxguard_path_bin`.
  - Behavior: A cached binary of another version is never used, nor one whose SHA-256 is not the pinned one, nor a `foxguard` on `PATH` older than the pin.
  - Returns: 3 when there is no foxguard to run.
  - Used by: `scripts/ci_security.sh`, `scripts/foxguard_report.sh`, `scripts/preflight.sh`, `scripts/setup-hooks.sh` and the pre-push hook (`scripts/security_hooks.sh`).

- foxguard_missing_reason
  - Purpose: Print one line saying why `foxguard_bin` found none: `<path> does not match the pinned SHA-256 of foxguard <version>`, `<path> cannot be checked against the pinned SHA-256 (...)`, `<path> is foxguard <version>, older than the minimum <pin>`, `<path> reports no usable version ('<text>'); the minimum is foxguard <pin>`, or `foxguard is not installed`.
  - Returns: always 0.

- foxguard_version_warning [bin]
  - Purpose: Print the warning for running `bin` (default: `foxguard_bin`) when it is a `foxguard` on `PATH` in a newer breaking series than the pin (another major, or another minor of a `0.x` pin). Nothing otherwise.
  - Returns: always 0.

- foxguard_resolve
  - Purpose: `foxguard_bin`, and when the `foxguard` on `PATH` is older than the pin, install the pinned release into the cache first and print that one.
  - Behavior: Nothing is installed in CI or with `SCRIPT_HELPERS_NO_AUTO_INSTALL=1`, nor when no `foxguard` is on `PATH` at all. The copy on `PATH` is not touched. Messages go to stderr.
  - Returns: 3 when there is none and none could be installed.

- foxguard_sha256 file
  - Purpose: Print the file's SHA-256, with `shasum -a 256`, else `sha256sum`, else `openssl dgst -sha256`.

- foxguard_install
  - Purpose: Download the pinned release binary for this machine, check it against the pinned SHA-256, and install it at `foxguard_cache_path`.
  - Behavior: A mismatch deletes the download and returns 1; nothing is installed.
  - Used by: `scripts/ci_security.sh --install-foxguard`.

Dependencies
------------

- `curl` or `wget`; `shasum`, `sha256sum` or `openssl`.
- `ci_defaults` (sourced when the caller has not imported it) and `logging`.
