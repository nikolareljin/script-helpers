#!/usr/bin/env bash
# SCRIPT: signing_secrets.sh
# DESCRIPTION: Set the package-signing secrets and variables (the names in
#              ci-helpers docs/packaging.md) on a list of GitHub repositories,
#              or check which repositories miss which name. Values go to gh on
#              stdin, never on a command line, and are never printed.
# USAGE: ./signing_secrets.sh --repos <owner/a,owner/b> --group <gpg|apple> [--group ...] [options] [--check|--dry-run]
# EXAMPLE: ./signing_secrets.sh --repos me/tool --group gpg --gpg-key <FPR> --ppa me/tool=ppa:me/tool
# EXAMPLE: ./signing_secrets.sh --repos me/a,me/b --group gpg --group apple --check
# PARAMETERS:
#   --repos <list>            Comma-separated owner/name list (required).
#   --group <gpg|apple>       Names to set or check; repeat for both (required).
#   --gpg-key <fingerprint>   gpg: key to export (40 hex characters).
#                             Passphrase: GPG_PASSPHRASE env, else prompted.
#   --ppa <owner/name=ppa:id/name>
#                             gpg: set PPA_TARGET on that repository; repeat.
#   --launchpad-ssh-key <file>
#                             gpg: set LAUNCHPAD_SSH_PRIVATE_KEY (sftp only).
#   --apple-p12 <file>        apple: Developer ID Application .p12.
#   --apple-identity <text>   apple: "Developer ID Application: Name (TEAMID)".
#   --apple-team <id>         apple: 10-character team ID.
#   --apple-id <email>        apple: Apple ID for notarization.
#                             Passwords: APPLE_CERTIFICATE_PASSWORD and
#                             APPLE_APP_PASSWORD env, else prompted.
#   --check                   Report missing names per repository; exit 1 if any.
#   --dry-run                 Print the names that would be set; set nothing.
#   -h, --help                Show help.
# ----------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-${ROOT_DIR}}"
# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { display_help; }

GPG_SECRETS="GPG_PRIVATE_KEY GPG_PASSPHRASE"
GPG_VARS="GPG_KEY_ID"
APPLE_SECRETS="APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_TEAM_ID APPLE_ID APPLE_APP_PASSWORD"
APPLE_VARS="APPLE_SIGNING_ENABLED"

repos_csv=""
groups=""
gpg_key=""
ppa_map=""
lp_ssh_key=""
apple_p12=""
apple_identity=""
apple_team=""
apple_id=""
mode="set"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repos) repos_csv="${2:-}"; shift 2;;
    --group) groups="${groups} ${2:-}"; shift 2;;
    --gpg-key) gpg_key="${2:-}"; shift 2;;
    --ppa) ppa_map="${ppa_map} ${2:-}"; shift 2;;
    --launchpad-ssh-key) lp_ssh_key="${2:-}"; shift 2;;
    --apple-p12) apple_p12="${2:-}"; shift 2;;
    --apple-identity) apple_identity="${2:-}"; shift 2;;
    --apple-team) apple_team="${2:-}"; shift 2;;
    --apple-id) apple_id="${2:-}"; shift 2;;
    --check) mode="check"; shift;;
    --dry-run) mode="dry-run"; shift;;
    -h|--help) usage; exit 0;;
    *) log_error "Unknown argument: $1"; usage; exit 2;;
  esac
done

has_group() { case " ${groups} " in *" $1 "*) return 0;; esac; return 1; }

if [[ -z "$repos_csv" ]] || [[ -z "${groups// /}" ]]; then
  log_error "--repos and --group are required"
  usage
  exit 2
fi
for g in $groups; do
  case "$g" in
    gpg|apple) ;;
    *) log_error "--group must be gpg or apple, got '$g'"; exit 2;;
  esac
done
repos=""
for r in ${repos_csv//,/ }; do
  if [[ ! "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    log_error "Repository '$r' is not owner/name"
    exit 2
  fi
  repos="${repos} ${r}"
done
for m in $ppa_map; do
  if [[ ! "$m" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+=ppa:[a-z0-9][a-z0-9.+-]*/[a-z0-9][a-z0-9.+-]*$ ]]; then
    log_error "--ppa '$m' is not owner/name=ppa:<id>/<name>"
    exit 2
  fi
  case " ${repos} " in
    *" ${m%%=*} "*) ;;
    *) log_error "--ppa names ${m%%=*}, which is not in --repos"; exit 2;;
  esac
done

# Names expected on one repository, one per line: "secret NAME" or "variable NAME".
expected_names() {
  local repo="$1" n
  if has_group gpg; then
    for n in $GPG_SECRETS; do echo "secret $n"; done
    for n in $GPG_VARS; do echo "variable $n"; done
    for m in $ppa_map; do
      [[ "${m%%=*}" == "$repo" ]] && echo "variable PPA_TARGET"
    done
    [[ -n "$lp_ssh_key" ]] && echo "secret LAUNCHPAD_SSH_PRIVATE_KEY"
  fi
  if has_group apple; then
    for n in $APPLE_SECRETS; do echo "secret $n"; done
    for n in $APPLE_VARS; do echo "variable $n"; done
  fi
  return 0
}

if [[ "$mode" == "check" ]]; then
  missing_total=0
  for repo in $repos; do
    have_s="$(gh secret list -R "$repo" --json name -q '.[].name')" || { log_error "$repo: cannot list secrets"; missing_total=$((missing_total+1)); continue; }
    have_v="$(gh variable list -R "$repo" --json name -q '.[].name')" || { log_error "$repo: cannot list variables"; missing_total=$((missing_total+1)); continue; }
    missing=""
    while read -r kind name; do
      [[ -z "$name" ]] && continue
      if [[ "$kind" == "secret" ]]; then have="$have_s"; else have="$have_v"; fi
      printf '%s\n' "$have" | grep -qxF -- "$name" || missing="${missing} ${name}"
    done <<< "$(expected_names "$repo")"
    if [[ -n "$missing" ]]; then
      echo "${repo}: missing${missing}"
      missing_total=$((missing_total+1))
    else
      echo "${repo}: ok"
    fi
  done
  [[ "$missing_total" -eq 0 ]]
  exit $?
fi

# Values are read once and kept in files under a private directory, so each
# reaches gh on stdin.
work="$(mktemp -d)"
chmod 700 "$work"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$work"; fi' EXIT

ask() { # var-name prompt
  local val="${!1:-}"
  if [[ -z "$val" ]]; then
    if [[ "$mode" == "dry-run" ]]; then
      val="(prompted)"
    else
      read -r -s -p "$2: " val </dev/tty
      echo >&2
    fi
  fi
  [[ -n "$val" ]] || { log_error "$1 is empty"; exit 2; }
  printf '%s' "$val" > "$work/$1"
}

if has_group gpg; then
  if [[ ! "$gpg_key" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    log_error "--gpg-key must be the 40-character fingerprint"
    exit 2
  fi
  if [[ "$mode" != "dry-run" ]]; then
    gpg --batch --list-secret-keys "$gpg_key" >/dev/null 2>&1 \
      || { log_error "no secret key $gpg_key in the local keyring"; exit 2; }
    gpg --armor --export-secret-keys "$gpg_key" > "$work/GPG_PRIVATE_KEY"
    [[ -s "$work/GPG_PRIVATE_KEY" ]] || { log_error "gpg exported nothing for $gpg_key"; exit 2; }
  fi
  ask GPG_PASSPHRASE "GPG passphrase for $gpg_key"
  printf '%s' "$gpg_key" > "$work/GPG_KEY_ID"
  if [[ -n "$lp_ssh_key" ]]; then
    [[ -s "$lp_ssh_key" ]] || { log_error "--launchpad-ssh-key $lp_ssh_key is missing or empty"; exit 2; }
    cp "$lp_ssh_key" "$work/LAUNCHPAD_SSH_PRIVATE_KEY"
  fi
fi

if has_group apple; then
  [[ -s "$apple_p12" ]] || { log_error "--apple-p12 is missing or empty"; exit 2; }
  [[ "$apple_identity" == "Developer ID Application: "* ]] || { log_error "--apple-identity must start with 'Developer ID Application: '"; exit 2; }
  [[ "$apple_team" =~ ^[A-Z0-9]{10}$ ]] || { log_error "--apple-team must be the 10-character team ID"; exit 2; }
  [[ "$apple_id" == *@* ]] || { log_error "--apple-id must be an e-mail address"; exit 2; }
  base64 < "$apple_p12" | tr -d '\n' > "$work/APPLE_CERTIFICATE"
  printf '%s' "$apple_identity" > "$work/APPLE_SIGNING_IDENTITY"
  printf '%s' "$apple_team" > "$work/APPLE_TEAM_ID"
  printf '%s' "$apple_id" > "$work/APPLE_ID"
  ask APPLE_CERTIFICATE_PASSWORD "Password of $apple_p12"
  ask APPLE_APP_PASSWORD "App-specific password for $apple_id"
  printf '%s' "true" > "$work/APPLE_SIGNING_ENABLED"
fi

failed=0
for repo in $repos; do
  for m in $ppa_map; do
    [[ "${m%%=*}" == "$repo" ]] && printf '%s' "${m#*=}" > "$work/PPA_TARGET.${repo//\//__}"
  done
  while read -r kind name; do
    [[ -z "$name" ]] && continue
    src="$work/$name"
    [[ "$name" == "PPA_TARGET" ]] && src="$work/PPA_TARGET.${repo//\//__}"
    if [[ "$mode" == "dry-run" ]]; then
      echo "${repo}: would set ${kind} ${name}"
      continue
    fi
    if gh "$kind" set "$name" -R "$repo" < "$src" >/dev/null; then
      echo "${repo}: set ${kind} ${name}"
    else
      log_error "${repo}: could not set ${kind} ${name}"
      failed=$((failed+1))
    fi
  done <<< "$(expected_names "$repo")"
done
[[ "$failed" -eq 0 ]]
