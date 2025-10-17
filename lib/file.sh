#!/usr/bin/env bash
# File/dir and checksum helpers

command_exists() { command -v "$1" >/dev/null 2>&1; }

directory_exists() { [[ -d "$1" ]]; }
file_exists() { [[ -f "$1" ]]; }

create_directory() {
  if ! directory_exists "$1"; then
    mkdir -p "$1" && { echo "Directory $1 created."; return 0; }
    echo "Failed to create directory $1" >&2; return 1
  else
    echo "Directory $1 already exists."; return 0
  fi
}

download_file() {
  local url="$1"; local output="${2:-}"
  if [[ -z "$output" ]]; then
    output=$(basename "$url")
    if [[ "$output" != *.* ]]; then
      output=$(echo "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
    fi
  fi
  print_warning "Downloading $url -> $output ..."
  if command_exists curl; then
    print_info "curl --max-time 3600 -L -o \"$output\" \"$url\""
    curl --max-time 3600 -L -o "$output" "$url"
  elif command_exists wget; then
    print_info "wget --timeout=3600 -O \"$output\" \"$url\""
    wget --timeout=3600 -O "$output" "$url"
  else
    print_error "Neither curl nor wget is installed."
    return 1
  fi
}

is_valid_iso() { file "$1" | grep -q "ISO 9660"; }
is_valid_checksum() { file "$1" | grep -q "ASCII text"; }

verify_checksum() {
  local iso_file="$1"; local checksum_file="$2"; local checksum_type="${3:-sha256sum}"
  if ! is_valid_iso "$iso_file"; then
    print_error "$iso_file is not a valid ISO image."
    return 1
  fi
  if ! is_valid_checksum "$checksum_file"; then
    print_error "$checksum_file is not a valid checksum file."
    return 1
  fi
  if command_exists "$checksum_type"; then
    local out; out=$("$checksum_type" -c "$checksum_file" 2>&1 || true)
    if echo "$out" | grep -q "OK"; then
      print_success "Checksum verification successful for $iso_file."
      return 0
    else
      print_error "Checksum verification failed for $iso_file."
      return 1
    fi
  else
    print_error "$checksum_type is not installed."
    return 1
  fi
}

# Convenience used by burn-iso: expects DISTROS associative array defined by caller
download_iso() {
  local distro_name="$1"
  local url="${DISTROS[$distro_name]}"
  if [[ -z "$url" ]]; then
    print_error "No URL found for $distro_name."
    return 1
  fi
  local output; output=$(basename "$url")
  if [[ "$output" != *.* ]]; then
    output=$(echo "$url" | sed -E 's|.*/([^/]+\.[^/]+)(/.*)?$|\1|')
  fi
  if file_exists "$output"; then
    print_warning "File $output already exists. Skipping download."
  fi
  download_file "$url" "$output" || return 1
  print_success "Download completed: $output"
  if is_valid_iso "$output"; then
    print_success "$output is a valid ISO image."
    return 0
  else
    print_error "$output is not a valid ISO image."
    return 1
  fi
}
