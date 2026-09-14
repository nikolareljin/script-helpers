#!/usr/bin/env bash
# package_publish.sh - Helpers for Debian package builds and PPA publishing.

_pkg_log_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  else
    echo "[INFO] $*" >&2
  fi
}

_pkg_log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  else
    echo "[ERROR] $*" >&2
  fi
}

# Usage: pkg_require_cmds <cmd> [cmd...]
pkg_require_cmds() {
  local missing=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      _pkg_log_error "Missing required command: $cmd"
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    return 2
  fi
  return 0
}

# Usage: pkg_run_prebuild <command>
pkg_run_prebuild() {
  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then
    _pkg_log_info "Running prebuild: $cmd"
    bash -lc "$cmd"
  fi
}

# Usage: pkg_set_series <series>
pkg_set_series() {
  local series="${1:-}"
  if [[ -n "$series" ]]; then
    pkg_require_cmds dch || return 2
    dch --distribution "$series" --no-auto-nmu "Automated PPA build"
  fi
}

# Usage: pkg_build_deb_artifacts <repo_dir> <prebuild_cmd> <build_cmd>
pkg_build_deb_artifacts() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3"
  cd "$repo_dir" || return 1
  pkg_run_prebuild "$prebuild_cmd"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    pkg_require_cmds dpkg-buildpackage || return 2
    dpkg-buildpackage -us -uc
  fi
}

# Usage: pkg_build_source_package <repo_dir> <prebuild_cmd> <build_cmd> <series> <key_id>
pkg_build_source_package() {
  local repo_dir="$1" prebuild_cmd="$2" build_cmd="$3" series="$4" key_id="$5"
  if [[ -z "$build_cmd" ]] && [[ -z "${PPA_GPG_PASSPHRASE:-}" ]]; then
    _pkg_log_error "PPA_GPG_PASSPHRASE is required for signing"
    return 2
  fi
  pkg_require_cmds debuild gpg || return 2
  cd "$repo_dir" || return 1
  pkg_run_prebuild "$prebuild_cmd"
  pkg_set_series "$series"
  if [[ -n "$build_cmd" ]]; then
    _pkg_log_info "Running build: $build_cmd"
    bash -lc "$build_cmd"
  else
    # The passphrase goes to gpg in a 0600 file rather than on its command
    # line, where every local user can read it from the process list for as
    # long as the build runs. A file also survives a passphrase with spaces,
    # which the sign command's word splitting did not. Removed on every path
    # out, including a failed build under `set -e`.
    local pass_file rc=0
    pass_file="$(mktemp)" || return 1
    chmod 600 "$pass_file" || { rm -f "$pass_file"; return 1; }
    printf '%s' "${PPA_GPG_PASSPHRASE}" > "$pass_file" || { rm -f "$pass_file"; return 1; }
    if debuild -S -sa -k"$key_id" -p"gpg --batch --pinentry-mode loopback --passphrase-file ${pass_file}"; then
      rc=0
    else
      rc=$?
    fi
    rm -f "$pass_file"
    return $rc
  fi
}

# Usage: pkg_find_changes_file <repo_dir>
#
# The parent directory is shared: a CI workspace or a packaging directory holds
# every project's builds, so "the first *.changes there" can be another
# package, which is then uploaded. The package's own
# <Source>_<Version>_source.changes, named from debian/changelog, is preferred.
# Without it, a lone *.changes is still taken; more than one is an error rather
# than a guess.
pkg_find_changes_file() {
  local repo_dir="$1"
  local changes_file src_name version count
  if [[ -f "$repo_dir/debian/changelog" ]] && command -v dpkg-parsechangelog >/dev/null 2>&1; then
    src_name="$(dpkg-parsechangelog -l "$repo_dir/debian/changelog" -S Source 2>/dev/null || true)"
    version="$(dpkg-parsechangelog -l "$repo_dir/debian/changelog" -S Version 2>/dev/null || true)"
    # The epoch is not part of a Debian file name.
    version="${version#*:}"
    if [[ -n "$src_name" && -n "$version" && -f "$repo_dir/../${src_name}_${version}_source.changes" ]]; then
      echo "$repo_dir/../${src_name}_${version}_source.changes"
      return 0
    fi
  fi
  changes_file="$(find "$repo_dir/.." -maxdepth 1 -type f -name '*.changes' 2>/dev/null || true)"
  if [[ -z "$changes_file" ]]; then
    _pkg_log_error "No .changes file found."
    return 1
  fi
  count="$(printf '%s\n' "$changes_file" | wc -l | tr -d '[:space:]')"
  if [[ "$count" -ne 1 ]]; then
    _pkg_log_error "Found $count .changes files next to $repo_dir and none named for this package; refusing to pick one:"
    printf '%s\n' "$changes_file" >&2
    return 1
  fi
  echo "$changes_file"
}

# Usage: pkg_upload_ppa <ppa_target> <changes_file>
pkg_upload_ppa() {
  local ppa_target="$1" changes_file="$2"
  pkg_require_cmds dput || return 2
  dput "$ppa_target" "$changes_file"
}
