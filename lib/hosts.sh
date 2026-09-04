#!/usr/bin/env bash
# /etc/hosts helpers

# Usage: add_to_etc_hosts <domain> <ip>; appends entry if missing.
#
# HOSTS_FILE overrides the target, which is what makes the "already present"
# test above verifiable: it used to be wrong on macOS and nothing could tell,
# because the only way to exercise it was to edit the real /etc/hosts as root.
add_to_etc_hosts() {
  local domain="$1" ip_address="$2"
  local hosts_file="${HOSTS_FILE:-/etc/hosts}"
  # POSIX ERE. \s is a GNU extension that BSD grep does not reject -- it simply
  # never matches, so on macOS this always concluded "absent" and appended a
  # duplicate line on every single call.
  if ! grep -qE "(^|[[:space:]])${domain}([[:space:]]|$)" "$hosts_file" 2>/dev/null; then
    if [[ -w "$hosts_file" ]]; then
      printf '%s    %s\n' "$ip_address" "$domain" >> "$hosts_file"
    else
      echo "$ip_address    $domain" | sudo tee -a "$hosts_file" >/dev/null
    fi
    print_success "Added $domain to $hosts_file"
  else
    print_info "$domain is already present in $hosts_file"
  fi
}
