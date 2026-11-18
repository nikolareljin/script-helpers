# version

Semantic version helpers.

Functions
---------

- version_bump bump_type [-f VERSION_FILE]
  - Purpose: Increment the semantic version stored in a file.
  - Args:
    - bump_type - `major` | `minor` | `patch`.
    - `-f`, `--file`: path to the version file; a relative path is relative to the current directory. Without it: `VERSION` at `version_project_root`, never in a vendored script-helpers copy.
  - Behavior:
    - Creates the file with `0.1.0` when missing.
    - Preserves a leading `v`/`V` prefix and any suffix after the first `-` when writing the bumped value.
    - `-h/--help` will render script-level help when available (falls back to function usage).
  - Returns: 0 on success; 1 on invalid input or write errors.
  - Dependencies: logging for output; git, when present, to find the project root.

- version_project_root
  - Purpose: The caller's project root, where `version_bump` writes by default.
  - Behavior: the top of the git work tree holding the current directory, or the current directory outside git. When that work tree is a script-helpers checkout vendored as a submodule, the superproject is returned instead, so a vendored copy never bumps its own `VERSION`.
  - Returns: 0; prints the absolute directory.

- version_at_least version minimum
  - Purpose: Tell whether `version` is `minimum` or newer.
  - Behavior: Both must be exactly `[v]X.Y.Z`. A prerelease (`8.31.0-rc1`), build metadata, a two- or four-part number or any other text is not a version here, so it is never "at least" anything. Needs no other module.
  - Returns: 0 at least the minimum; 1 older; 3 either one is not `[v]X.Y.Z`.

- version_same_series version_a version_b
  - Purpose: Tell whether semver promises no breaking change between the two: the same major from `1.0.0` on, the same minor below it (`0.14.1` and `0.14.9`, not `0.15.0`).
  - Returns: 0 same series; 1 another series; 3 either one is not `[v]X.Y.Z`.

- version_compare version_a version_b
  - Purpose: Compare two versions shaped like `[v]X.Y.Z[-suffix]` using numeric segments.
  - Behavior: Ignores a leading `v`/`V` and anything after the first `-` (e.g., `-rc1`).
  - Returns (exit codes; note that `-1` is reported as `255` in shells):
    - `-1` (exit status `255`) when `version_a` is lower than `version_b`.
    - `0` when equal.
    - `1` when `version_a` is greater than `version_b`.
    - `2` on missing args; `3` on invalid version format.
  - Notes: Supports multi-digit segments (e.g., `1.14.100`). Segments are compared as decimal numbers, so leading zeros are allowed: `2026.08.1` is lower than `2026.9.0`.

- version_offer_update [--label TEXT] [--hint TEXT] RUNNING LATEST COMMAND [ARG...]
  - Purpose: Offer, to a person, to run an updater when `RUNNING` is older than `LATEST`.
  - Behavior: newer or equal or an empty version: nothing, 0. With `ui_mode` `none`: one line, `<label> RUNNING is running; LATEST is available: <hint>`, nothing run. Otherwise asks with `ui_yesno`; yes runs `COMMAND ARG...` in the calling shell and returns its status (a command that `exec`s replaces the caller), no prints the hint and returns 0. `--hint` defaults to the command line.
  - Returns: 0, the command's status, or 1 for missing arguments or a bad `SHLIB_UI`.
  - Dependencies: dialog module (`ui_mode`, `ui_yesno`).

Examples
--------

```bash
shlib_import logging env version

# Bump the minor version in VERSION at the project root
version_bump minor

# Compare versions
version_compare "v1.10.0-rc1" "1.9.9"
case $? in
  0) echo "Same";;
  1) echo "Left is newer";;
  255) echo "Left is older";;  # exit status 255 encodes -1
  2) echo "Missing args";;
  3) echo "Invalid input";;
esac
```
