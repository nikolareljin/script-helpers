# gitleaks

Install the pinned [gitleaks](https://github.com/gitleaks/gitleaks) secret scanner on
a host that has none. A local `preflight` calls it before the secret scan; CI uses
the gitleaks image and never runs preflight. The release archive for this machine is
checked against the SHA-256 pinned in `ci_defaults` before it is unpacked. No sudo.

Return codes: `0` success, `1` failed (download, checksum mismatch, unpack), `3` not
installed, a required tool missing, or no release binary for this platform.

Functions
---------

- gitleaks_asset
  - Purpose: Print the release archive name for this machine, e.g. `gitleaks_8.30.0_linux_x64.tar.gz`, or `gitleaks_8.30.0_windows_x64.zip` under Git Bash, MSYS or Cygwin.
  - Returns: 3 on a platform with no release binary (Linux and macOS on x64 and arm64, and Windows on x64, have one).

- gitleaks_expected_sha256 asset
  - Purpose: Print the pinned SHA-256 of that archive, from `CI_DEFAULT_GITLEAKS_SHA256_*`.

- gitleaks_cache_path
  - Purpose: Print where the binary is installed: `${XDG_CACHE_HOME:-~/.cache}/script-helpers/gitleaks/<version>/gitleaks` (`gitleaks.exe` on Windows).

- gitleaks_bin
  - Purpose: Print the gitleaks to run: one on `PATH` (brew, apt, scoop), else the pinned binary in the cache.
  - Returns: 3 when there is neither.

- gitleaks_install
  - Purpose: Download the pinned release archive, check its SHA-256, and unpack the binary to `gitleaks_cache_path`.
  - Behavior: A mismatch deletes the download and returns 1; nothing is unpacked. A `.zip` is unpacked with `unzip`, else PowerShell's `Expand-Archive`.
  - Requires: `foxguard_sha256` (import `foxguard`), and `curl` or `wget`.
  - Used by: `scripts/preflight.sh`, `scripts/ci_security.sh --install-gitleaks`.
