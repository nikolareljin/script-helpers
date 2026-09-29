# foxguard

Find, install and verify the pinned [foxguard](https://github.com/0sec-labs/foxguard)
static-analysis scanner that `scripts/ci_security.sh` runs. `npx foxguard` fetches
the latest version; this module runs the one pinned in `ci_defaults`, and refuses a
downloaded binary whose SHA-256 does not match the pin.

Return codes: `0` success, `1` failed (download, checksum mismatch), `3` not
installed, a required tool missing, or no release binary for this platform.

Functions
---------

- foxguard_asset
  - Purpose: Print the release asset name for this machine, e.g. `foxguard-linux-x86_64`.
  - Returns: 3 on a platform with no release binary (only Linux and macOS, x86_64 and aarch64, have one).

- foxguard_expected_sha256 asset
  - Purpose: Print the pinned SHA-256 of that asset, from `CI_DEFAULT_FOXGUARD_SHA256_*`.

- foxguard_cache_path
  - Purpose: Print where the pinned binary is installed: `${XDG_CACHE_HOME:-~/.cache}/script-helpers/foxguard/<version>/foxguard`.

- foxguard_bin
  - Purpose: Print the foxguard to run: the pinned binary in the cache, else one on `PATH`.
  - Returns: 3 when there is neither.

- foxguard_sha256 file
  - Purpose: Print the file's SHA-256, with `shasum -a 256`, else `openssl dgst -sha256`.

- foxguard_install
  - Purpose: Download the pinned release binary for this machine, check it against the pinned SHA-256, and install it at `foxguard_cache_path`.
  - Behavior: A mismatch deletes the download and returns 1; nothing is installed.
  - Used by: `scripts/ci_security.sh --install-foxguard`.

Dependencies
------------

- `curl` or `wget`; `shasum` or `openssl`.
- `ci_defaults` (sourced when the caller has not imported it) and `logging`.
