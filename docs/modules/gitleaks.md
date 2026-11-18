# gitleaks

Find the gitleaks to run, and install the pinned
[gitleaks](https://github.com/gitleaks/gitleaks) secret scanner on a host that has
none or an older one. A local `preflight` calls it before the secret scan; CI uses
the gitleaks image and never runs preflight. The release archive for this machine is
checked against the SHA-256 pinned in `ci_defaults` before it is unpacked. No sudo.

Return codes: `0` success, `1` failed (download, checksum mismatch, unpack), `3` not
installed, a required tool missing, or no release binary for this platform.

Functions
---------

- gitleaks_asset
  - Purpose: Print the release archive name for this machine, e.g. `gitleaks_8.30.1_linux_x64.tar.gz`, or `gitleaks_8.30.1_windows_x64.zip` under Git Bash, MSYS or Cygwin.
  - Returns: 3 on a platform with no release binary (Linux and macOS on x64 and arm64, and Windows on x64, have one).

- gitleaks_expected_sha256 asset
  - Purpose: Print the pinned SHA-256 of that archive, from `CI_DEFAULT_GITLEAKS_SHA256_*`.

- gitleaks_cache_path
  - Purpose: Print where the binary is installed: `${XDG_CACHE_HOME:-~/.cache}/script-helpers/gitleaks/<version>/gitleaks` (`gitleaks.exe` on Windows).

- gitleaks_bin
  - Purpose: Print the gitleaks to run. In this order: one on `PATH` (brew, apt, scoop) that reports the pinned version or a newer one of the same major; the pinned binary in the cache; one on `PATH` of a newer major.
  - Behavior: A `gitleaks` on `PATH` older than `CI_DEFAULT_GITLEAKS_VERSION`, or one whose `gitleaks version` output is not `[v]X.Y.Z`, is never used. `GITLEAKS_BIN` is not read here: the scripts that honor it run it as given.
  - Returns: 3 when there is none.
  - Used by: `scripts/check_sensitive.sh`, `scripts/ci_security.sh`, `scripts/preflight.sh`, `scripts/setup-hooks.sh`, `scripts/install-publication-hooks.sh` and the pre-push hook.

- gitleaks_missing_reason
  - Purpose: Print one line saying why `gitleaks_bin` found none: `<path> is gitleaks <version>, older than the minimum <pin>`, `<path> reports no usable version ('<text>'); the minimum is gitleaks <pin>`, or `gitleaks is not installed`.
  - Returns: always 0.

- gitleaks_version_warning [bin]
  - Purpose: Print the warning for running `bin` (default: `gitleaks_bin`) when it is a `gitleaks` on `PATH` of a newer major than the pin: the found version, the pin and the command that installs the pinned release. Nothing otherwise.
  - Returns: always 0.

- gitleaks_resolve
  - Purpose: `gitleaks_bin`, and when the `gitleaks` on `PATH` is older than the pin, install the pinned release into the cache first and print that one.
  - Behavior: Nothing is installed in CI or with `SCRIPT_HELPERS_NO_AUTO_INSTALL=1`, nor when no `gitleaks` is on `PATH` at all. The copy on `PATH` is not touched. The message about the older version, the install progress and the newer-major warning go to stderr.
  - Returns: 3 when there is none and none could be installed.
  - Requires: `logging` and `foxguard` (for the install).

- gitleaks_install
  - Purpose: Download the pinned release archive, check its SHA-256, and unpack the binary to `gitleaks_cache_path`.
  - Behavior: A mismatch deletes the download and returns 1; nothing is unpacked. A `.zip` is unpacked with `unzip`, else PowerShell's `Expand-Archive`.
  - Requires: `foxguard_sha256` (import `foxguard`), and `curl` or `wget`.
  - Used by: `scripts/preflight.sh`, `scripts/ci_security.sh --install-gitleaks`.
