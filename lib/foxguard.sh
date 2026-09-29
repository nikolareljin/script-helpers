#!/usr/bin/env bash
# foxguard: the pinned static-analysis scanner that scripts/ci_security.sh runs.
#
# `npx foxguard` fetches whatever version is latest. This module runs one
# version, pinned in ci_defaults together with the SHA-256 of each release
# binary, so a scan gives the same answer on every machine and a binary that
# does not match the pin is refused instead of run.
#
# Expected imports by caller (via shlib_import): logging. ci_defaults is sourced
# here when the caller has not imported it.
#
# Return codes, used by every function in this module:
#   0  success
#   1  the operation failed (download, checksum mismatch)
#   3  not installed, a required tool is missing, or the platform has no binary

if [[ -z "${CI_DEFAULT_FOXGUARD_VERSION:-}" ]]; then
  # shellcheck source=/dev/null
  source "$(dirname "${BASH_SOURCE[0]}")/ci_defaults.sh"
fi

# foxguard_asset; the release asset name for this machine, e.g.
# foxguard-linux-x86_64. Returns 3 on a platform with no release binary.
foxguard_asset() {
  local os arch
  case "$(uname -s)" in
    Linux)  os=linux ;;
    Darwin) os=macos ;;
    *) return 3 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) return 3 ;;
  esac
  printf 'foxguard-%s-%s\n' "$os" "$arch"
}

# foxguard_expected_sha256 <asset>; the pinned SHA-256 of that release asset.
foxguard_expected_sha256() {
  case "$1" in
    foxguard-linux-x86_64)  printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64" ;;
    foxguard-linux-aarch64) printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_LINUX_AARCH64" ;;
    foxguard-macos-x86_64)  printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_MACOS_X86_64" ;;
    foxguard-macos-aarch64) printf '%s\n' "$CI_DEFAULT_FOXGUARD_SHA256_MACOS_AARCH64" ;;
    *) return 3 ;;
  esac
}

# foxguard_cache_path; where --install-foxguard puts the pinned binary.
foxguard_cache_path() {
  printf '%s/script-helpers/foxguard/%s/foxguard\n' \
    "${XDG_CACHE_HOME:-$HOME/.cache}" "$CI_DEFAULT_FOXGUARD_VERSION"
}

# foxguard_bin; the foxguard to run: the pinned binary in the cache, else one on
# PATH. Returns 3 when there is neither.
foxguard_bin() {
  local cached
  cached="$(foxguard_cache_path)"
  if [[ -x "$cached" ]]; then
    printf '%s\n' "$cached"
  elif command -v foxguard >/dev/null 2>&1; then
    command -v foxguard
  else
    return 3
  fi
}

# foxguard_sha256 <file>; its SHA-256, with shasum or openssl (both on macOS;
# one or the other on nearly every Linux).
foxguard_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  else
    return 3
  fi
}

# foxguard_install; download the pinned release binary for this machine, check
# it against the pinned SHA-256, and put it at foxguard_cache_path. A mismatch
# deletes the download and returns 1.
foxguard_install() {
  local asset want got dest tmp url
  asset="$(foxguard_asset)" || { log_error "foxguard: no release binary for $(uname -s) $(uname -m)"; return 3; }
  want="$(foxguard_expected_sha256 "$asset")" || return 3
  dest="$(foxguard_cache_path)"
  url="https://github.com/0sec-labs/foxguard/releases/download/v${CI_DEFAULT_FOXGUARD_VERSION}/${asset}"
  mkdir -p "$(dirname "$dest")" || return 1
  tmp="$(mktemp "$(dirname "$dest")/.download.XXXXXX")" || return 1
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tmp" "$url" || { rm -f "$tmp"; log_error "foxguard: download failed: $url"; return 1; }
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$tmp" "$url" || { rm -f "$tmp"; log_error "foxguard: download failed: $url"; return 1; }
  else
    rm -f "$tmp"; log_error "foxguard: curl or wget is needed to download it"; return 3
  fi
  got="$(foxguard_sha256 "$tmp")" || { rm -f "$tmp"; log_error "foxguard: shasum or openssl is needed to check it"; return 3; }
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    log_error "foxguard: $asset $CI_DEFAULT_FOXGUARD_VERSION does not match the pinned SHA-256 (got $got, want $want); not installed"
    return 1
  fi
  chmod +x "$tmp" && mv -f "$tmp" "$dest" || { rm -f "$tmp"; return 1; }
  log_info "foxguard $CI_DEFAULT_FOXGUARD_VERSION installed at $dest"
}
