#!/usr/bin/env bash
# SCRIPT: ssh_keepalive.sh
# DESCRIPTION: Sourced by the pre-push hook and the hook dispatcher: warn, before the checks, when an SSH push can be cut off while they run.
# USAGE: source scripts/ssh_keepalive.sh; ssh_keepalive_note <remote-url> <prefix>
# PARAMETERS:
#   <remote-url>  The URL git passes to pre-push as its second argument.
#   <prefix>      The tag for the lines, e.g. "[pre-push]".
# EXAMPLE: ssh_keepalive_note "git@github.com:owner/repo.git" "[pre-push]"
# ----------------------------------------------------
# Why: git opens the push's connection before pre-push runs and keeps it open,
# idle, until the hooks pass. Over SSH the server closes an idle connection
# (GitHub after a few minutes), and the push exits 141 with "Connection to
# <host> closed by remote host" after every check passed. A keepalive fixes it.
# The note is shown once per push (SCRIPT_HELPERS_SSH_NOTE_SHOWN), never for
# HTTPS or local remotes, and not when a keepalive is already set.

# ssh_host_of <url>: the host of an SSH remote URL (ssh://[user@]host[:port]/path
# or the scp form [user@]host:path), else nothing.
ssh_host_of() {
  local url="$1" rest
  case "$url" in
    ssh://*|git+ssh://*|ssh+git://*) rest="${url#*://}"; rest="${rest#*@}"; rest="${rest%%/*}"; echo "${rest%%:*}" ;;
    *://*|/*|./*|../*) ;;
    *:*) rest="${url%%:*}"; echo "${rest#*@}" ;;
  esac
}

# ssh_keepalive_set <host>: 0 when a keepalive is set in GIT_SSH_COMMAND,
# core.sshCommand, or the ssh config for that host (ssh -G reads it, aliases
# and Match blocks included, without connecting).
ssh_keepalive_set() {
  local v
  [[ "${GIT_SSH_COMMAND:-} $(git config --get core.sshCommand 2>/dev/null || true)" == *[Ss]erver[Aa]live[Ii]nterval* ]] && return 0
  v="$(ssh -G "$1" 2>/dev/null | awk '$1 == "serveraliveinterval" { print $2; exit }')"
  [[ -n "$v" && "$v" != 0 ]]
}

# ssh_keepalive_note <url> <prefix>: print the note on stderr when it applies.
# Yellow on a terminal; plain in CI, with NO_COLOR, or when stderr is a file.
ssh_keepalive_note() {
  local url="$1" p="$2" host on="" off=""
  [[ -z "${SCRIPT_HELPERS_SSH_NOTE_SHOWN:-}" ]] || return 0
  host="$(ssh_host_of "$url")"
  [[ -n "$host" ]] && command -v ssh >/dev/null 2>&1 || return 0
  ssh_keepalive_set "$host" && return 0
  export SCRIPT_HELPERS_SSH_NOTE_SHOWN=1
  if [[ -t 2 && -z "${CI:-}" && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then
    on=$'\033[1;33m'; off=$'\033[0m'
  fi
  {
    printf '%s%s The push waits for these checks with its SSH connection to %s idle; a long\n' "$on" "$p" "$host"
    printf '%s run can be cut off (exit 141, "closed by remote host"). Keep the connection alive:\n' "$p"
    printf '%s   every repository: add to ~/.ssh/config   Host %s\n' "$p" "$host"
    printf '%s                                               ServerAliveInterval 20\n' "$p"
    printf '%s   this repository:  git config core.sshCommand "ssh -o ServerAliveInterval=20"\n' "$p"
    printf '%s   this push only:   GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push\n' "$p"
    printf '%s An HTTPS remote is not affected.%s\n' "$p" "$off"
  } >&2
}
