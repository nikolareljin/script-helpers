# scanner

Which `gitleaks` or `foxguard` found on `PATH` may run. One rule for both: the
pinned version (`CI_DEFAULT_GITLEAKS_VERSION`, `CI_DEFAULT_FOXGUARD_VERSION`) is
the minimum. `lib/gitleaks.sh` and `lib/foxguard.sh` load this module and build
their lookups on it; [Which scanner runs](../security-gates.md#which-scanner-runs)
has the full order.

`tool` is `gitleaks` or `foxguard`; any other name returns 2.

Functions
---------

- scanner_pin tool
  - Purpose: Print the pinned version of that scanner, as `ci_defaults` has it (`v8.30.1`, `0.14.1`).

- scanner_path_version tool
  - Purpose: Print what the `tool` on `PATH` reports: the first line of `gitleaks version`, or of `foxguard --version` without the leading `foxguard `.
  - Behavior: Carriage returns (`gitleaks.exe`) and control characters are removed and the line is cut at 40 characters, so it is safe to print.
  - Returns: 3 when there is none on `PATH`.

- scanner_path_bin tool
  - Purpose: Print the `tool` on `PATH`, when it reports the pinned version or a newer one (`version_at_least`).
  - Returns: 3 when there is none, it is older, or its version is not `[v]X.Y.Z`.

- scanner_path_breaking tool
  - Purpose: Tell whether the `tool` on `PATH` is usable and newer than the pin in a breaking way: another major, or another minor of a `0.x` pin (`version_same_series`).
  - Returns: 0 it is; 1 same series, or no usable `tool` on `PATH`.

- scanner_path_reason tool
  - Purpose: Print one line saying why the `tool` on `PATH` is not used: `<path> is <tool> <version>, older than the minimum <pin>`, or `<path> reports no usable version ('<text>'); the minimum is <tool> <pin>`.
  - Returns: 1, printing nothing, when there is none on `PATH` or it is usable.

- scanner_install_hint tool
  - Purpose: Print the command that installs the pinned `tool` into the cache: `bash <checkout>/scripts/setup-hooks.sh --install-<tool>`.

- scanner_version_warning tool bin
  - Purpose: Print the warning for running `bin` when it is the `tool` on `PATH` and `scanner_path_breaking` holds: `WARNING: <path> is <tool> <version>, a newer major version than the tested pin <pin>; it may break. To use the pinned one: <command>`. Nothing for any other binary.
  - Returns: always 0.

- scanner_may_install
  - Purpose: Tell whether a scanner may be downloaded here: not in CI, and not with `SCRIPT_HELPERS_NO_AUTO_INSTALL=1`.

- scanner_resolve tool
  - Purpose: Print the `tool` to run, as `<tool>_bin` finds it. When there is none because the one on `PATH` is older than the pin (or has no usable version) and `scanner_may_install` allows, install the pinned release into the cache with `<tool>_install` and print that one.
  - Behavior: The copy on `PATH` is not touched. The message about the older version, the install progress and the breaking-series warning go to stderr.
  - Returns: 3 when there is none and none could be installed.
  - Requires: `logging` and the tool's module (`gitleaks` also needs `foxguard`).
  - Used by: `gitleaks_resolve`, `foxguard_resolve`.
