# package_publish

Helpers for Debian package builds and Launchpad PPA publishing.

## Example

```
source ./helpers.sh
shlib_import logging package_publish

pkg_build_deb_artifacts "." "make man" ""
```

## Functions

### `pkg_require_cmds`

Usage: `pkg_require_cmds <cmd> [cmd...]`

Checks that required commands exist, logs missing commands, returns non-zero on failure.

### `pkg_run_prebuild`

Usage: `pkg_run_prebuild <command>`

Runs a prebuild command via `bash -lc` when provided.

### `pkg_set_series`

Usage: `pkg_set_series <series>`

Updates `debian/changelog` to the provided distro series using `dch`.

### `pkg_build_deb_artifacts`

Usage: `pkg_build_deb_artifacts <repo_dir> <prebuild_cmd> <build_cmd>`

Builds Debian package artifacts via `dpkg-buildpackage -us -uc` or a provided build command.

### `pkg_build_source_package`

Usage: `pkg_build_source_package <repo_dir> <prebuild_cmd> <build_cmd> <series> <key_id>`

Builds a signed Debian source package using `debuild -S -sa` and a GPG key ID.

Environment:
- `PPA_GPG_PASSPHRASE`: passphrase for non-interactive GPG signing.

The passphrase is written to a private (0600) temp file and handed to gpg with `--passphrase-file`, never placed on a command line where other local users could read it from the process list. The file is removed when `debuild` returns, whether it succeeded or failed. Returns `debuild`'s exit status.

### `pkg_find_changes_file`

Usage: `pkg_find_changes_file <repo_dir>`

Prints the path of the package's `.changes` file in the parent directory. When `debian/changelog` exists and `dpkg-parsechangelog` is available, `<Source>_<Version>_source.changes` (epoch removed) is preferred. Otherwise a single `.changes` file in the parent directory is taken. The parent is often shared with other projects' builds, so when there are several and none is named for this package it returns 1 and lists them instead of picking one.

### `pkg_upload_ppa`

Usage: `pkg_upload_ppa <ppa_target> <changes_file>`

Uploads the `.changes` file to a Launchpad PPA using `dput`.
