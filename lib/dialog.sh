#!/usr/bin/env bash
# Dialog helpers: sizing and input utilities.

# Initialize dialog dimensions based on terminal size.
dialog_init() {
  local cols lines
  cols=$(tput cols 2>/dev/null || echo 120)
  lines=$(tput lines 2>/dev/null || echo 40)
  DIALOG_WIDTH=$((cols * 70 / 100))
  DIALOG_HEIGHT=$((lines * 70 / 100))
  (( DIALOG_WIDTH < 60 )) && DIALOG_WIDTH=60
  (( DIALOG_HEIGHT < 20 )) && DIALOG_HEIGHT=20
  export DIALOG_WIDTH DIALOG_HEIGHT
}

# Ensure `dialog` CLI exists.
check_if_dialog_installed() {
  if ! command -v dialog >/dev/null 2>&1; then
    print_error "Dialog is not installed. Please install it and try again."
    return 1
  fi
  # Also initialize dialog dimensions for compatibility with callers
  dialog_init
}

# Prompt for a value using dialog; prints the value to stdout.
# Usage: get_value "Title" "Message" "Default"
get_value() {
  local title="$1" message="$2" default_value="${3:-}"
  dialog_init
  check_if_dialog_installed || return 1

  local tmp
  tmp=$(mktemp "/tmp/$(basename "$0").XXXXXXXXXX")
  local cancel_msg="User pressed Cancel. Exiting."

  dialog --title "$title" --inputbox "$message" 10 60 "$default_value" 2>"$tmp"
  local status=$?
  if [[ $status -ne 0 ]]; then
    print_error "$cancel_msg"
    rm -f "$tmp"
    return 1
  fi

  if [[ -z "$(cat "$tmp")" ]]; then
    print_error "$cancel_msg"
    rm -f "$tmp"
    return 1
  fi

  cat "$tmp"
  rm -f "$tmp"
}

# Selection helpers used by burn-iso project. Expect an associative array DISTROS to be defined by the caller.
select_multiple_distros() {
  dialog_init; check_if_dialog_installed || return 1
  local selected_distros options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  selected_distros=$(dialog --stdout --title "Select Linux Distro" --checklist "Choose Linux distributions to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}")
  if [[ $? -ne 0 ]]; then
    print_error "No distro selected. Exiting..."
    return 1
  fi
  echo "$selected_distros"
}

select_distro() {
  dialog_init; check_if_dialog_installed || return 1
  local selected_distro options=() d
  for d in "${!DISTROS[@]}"; do
    options+=("$d" "${DISTROS[$d]}")
  done
  selected_distro=$(dialog --stdout --title "Select Linux Distro" --menu "Choose a Linux distribution to download:" "$DIALOG_HEIGHT" "$DIALOG_WIDTH" 0 "${options[@]}")
  if [[ $? -ne 0 ]]; then
    print_error "No distro selected. Exiting..."
    return 1
  fi
  echo "$selected_distro"
}
