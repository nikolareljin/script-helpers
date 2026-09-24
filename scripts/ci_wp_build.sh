#!/usr/bin/env bash
# SCRIPT: ci_wp_build.sh
# DESCRIPTION: Build a WordPress plugin into a deployable tree and zip, in CI or locally.
# USAGE: scripts/ci_wp_build.sh [options]
# PARAMETERS:
#   --workdir <path>              Plugin source directory (default: .).
#   --slug <name>                 Plugin directory name in the package (default: the workdir's name).
#   --version <version>           Version for the zip name (default: read from the plugin header).
#   --out-dir <path>              Where the tree and zip are written (default: build).
#   --composer-command <command>  Production dependency install. Empty skips it
#                                 (default: composer install --no-dev --optimize-autoloader --prefer-dist).
#   --asset-command <command>     Front-end build, run when package.json exists. Empty skips it
#                                 (default: npm ci && npm run build).
#   --exclude-from <path>         File of rsync-style excludes (default: .distignore when present).
#   --php-image <image>           Run the composer step in this image instead of on the host.
#   --node-image <image>          Run the asset step in this image instead of on the host.
#   --docker-user <user>          User for those images, as uid:gid (default: the invoking user).
#   --zip <true|false>            Also produce <out-dir>/<slug>-<version>.zip (default: true).
#   -h, --help                    Show this help message.
# ----------------------------------------------------
#
# What ships is not what is in the repository. A plugin needs its production
# dependencies vendored, its front-end assets built, and everything that exists
# only to develop it left out: node_modules, tests, CI configuration, the
# dotfiles git needs. Doing that by hand per plugin is how two of them end up
# shipping different things.
#
# Excludes come from .distignore when the plugin has one, which is the
# convention WordPress tooling already uses, so a plugin does not learn a new
# file for this. Without one a default list is applied and named in the log,
# because a silent exclusion is worse than a wrong one.
#
# --php-image and --node-image make a build reproducible on a laptop without
# the toolchains installed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

workdir="."
slug=""
version=""
out_dir="build"
composer_command="composer install --no-dev --optimize-autoloader --prefer-dist"
asset_command="npm ci && npm run build"
exclude_from=""
php_image=""
node_image=""
docker_user="$(id -u):$(id -g)"
make_zip="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir) workdir="$2"; shift 2 ;;
    --slug) slug="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --composer-command) composer_command="$2"; shift 2 ;;
    --asset-command) asset_command="$2"; shift 2 ;;
    --exclude-from) exclude_from="$2"; shift 2 ;;
    --php-image) php_image="$2"; shift 2 ;;
    --node-image) node_image="$2"; shift 2 ;;
    --docker-user) docker_user="$2"; shift 2 ;;
    --zip) make_zip="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

[[ -d "$workdir" ]] || { log_error "--workdir does not exist: ${workdir}"; exit 2; }
abs_workdir="$(cd "$workdir" && pwd -P)"
[[ -n "$slug" ]] || slug="$(basename "$abs_workdir")"

# The staging tree is removed and rebuilt, and out_dir is caller input. Refuse
# anything that would take the source with it.
abs_out="$(mkdir -p "$out_dir" && cd "$out_dir" && pwd -P)"
if [[ "$abs_out" == "/" || "$abs_out" == "$abs_workdir" || "$abs_workdir" == "$abs_out"/* ]]; then
  log_error "--out-dir must not be the plugin directory or contain it: ${abs_out}"
  exit 2
fi

# ---------------------------------------------------------------------------
# Version. The plugin header is the source of truth: it is what WordPress
# reads, and a zip named from anything else can disagree with what installs.
# ---------------------------------------------------------------------------
read_header_version() {
  # The plugin file is the one carrying "Plugin Name:". Taking the first
  # Version: header in the directory instead picks up a bundled library's
  # header and names the zip after it -- a shim reading 0.1.0 beat the
  # plugin's 3.4.1 when this looked at *.php in glob order.
  local f candidates=()
  [[ -f "${abs_workdir}/${slug}.php" ]] && candidates=("${abs_workdir}/${slug}.php")
  for f in "${abs_workdir}"/*.php; do
    [[ -f "$f" ]] || continue
    candidates+=("$f")
  done

  local pass
  for pass in plugin any; do
    for f in ${candidates[@]+"${candidates[@]}"}; do
      if [[ "$pass" == "plugin" ]]; then
        grep -qiE '^[[:space:]]*\*?[[:space:]]*Plugin Name:' "$f" 2>/dev/null || continue
      fi
      local v
      v="$(grep -m1 -iE '^[[:space:]]*\*?[[:space:]]*Version:[[:space:]]*' "$f" 2>/dev/null \
           | sed -E 's/.*[Vv]ersion:[[:space:]]*//; s/[[:space:]]*$//')"
      if [[ -n "$v" ]]; then printf '%s' "$v"; return 0; fi
    done
  done
  return 1
}

if [[ -z "$version" ]]; then
  if ! version="$(read_header_version)"; then
    log_error "No Version: header found in ${abs_workdir}; pass --version."
    exit 2
  fi
fi
log_info "Building ${slug} ${version}"

# ---------------------------------------------------------------------------
# Toolchain steps, optionally in a container so a laptop needs neither.
# ---------------------------------------------------------------------------
run_step() {   # <label> <image-or-empty> <command>
  local label="$1" image="$2" command="$3"
  [[ -n "$command" ]] || { log_info "${label}: skipped (no command)"; return 0; }

  if [[ -z "$image" ]]; then
    log_info "${label} (host): ${command}"
    ( cd "$abs_workdir" && eval "$command" )
    return
  fi

  # As the invoking user, or the build leaves root-owned files in the caller's
  # repository that they cannot delete without Docker. HOME with it: a uid the
  # image does not know has no home, and composer and npm both want one.
  local user_args=()
  [[ -n "$docker_user" ]] && user_args=(-u "$docker_user" -e HOME=/tmp)
  log_info "${label} (${image}): ${command}"
  # bash -c, not -lc: a login shell sources /etc/profile and replaces PATH.
  docker run --rm -t \
    ${user_args[@]+"${user_args[@]}"} \
    -v "${abs_workdir}":/work -w /work \
    "$image" bash -c "$command"
}

run_step "Production dependencies" "$php_image" "$composer_command"

if [[ -f "${abs_workdir}/package.json" ]]; then
  run_step "Front-end assets" "$node_image" "$asset_command"
else
  log_info "Front-end assets: skipped (no package.json)"
fi

# ---------------------------------------------------------------------------
# Stage the tree that ships.
# ---------------------------------------------------------------------------
if [[ -z "$exclude_from" && -f "${abs_workdir}/.distignore" ]]; then
  exclude_from="${abs_workdir}/.distignore"
fi

excludes=()
if [[ -n "$exclude_from" ]]; then
  [[ -f "$exclude_from" ]] || { log_error "--exclude-from not found: ${exclude_from}"; exit 2; }
  log_info "Excludes from ${exclude_from}"
  excludes=(--exclude-from="$exclude_from")
else
  # Named rather than silent: a reader can see what was dropped and override
  # it with a .distignore. node_modules is here because the built assets are
  # what ships, not the tree they were built from.
  default_excludes=(".git" ".github" ".gitignore" ".gitattributes" ".editorconfig"
                    ".distignore" "node_modules" "tests" "test" ".phpunit.cache"
                    ".phpunit.result.cache" "phpunit.xml" "phpunit.xml.dist"
                    "phpcs.xml" "phpcs.xml.dist" "composer.lock" "package-lock.json"
                    "build")
  log_info "No .distignore; excluding: ${default_excludes[*]}"
  for e in "${default_excludes[@]}"; do excludes+=(--exclude="$e"); done
fi

stage="${abs_out}/${slug}"
rm -rf "$stage"
mkdir -p "$stage"

# An out-dir inside the plugin is copied into the package by the rsync below:
# --out-dir dist produced dist/<slug>/dist. The default list happens to carry
# "build", so the default out-dir hides it; any other name, or a .distignore,
# does not. Exclude it by its path relative to the source, whatever it is.
if [[ "$abs_out" == "$abs_workdir"/* ]]; then
  excludes+=(--exclude="/${abs_out#"$abs_workdir"/}")
fi

# A trailing slash on the source copies its contents, not the directory.
rsync -a ${excludes[@]+"${excludes[@]}"} "${abs_workdir}/" "${stage}/"

files="$(find "$stage" -type f | wc -l | tr -d ' ')"
log_info "Staged ${files} file(s) in ${stage}"

if [[ ! -f "${stage}/${slug}.php" ]] && ! ls "${stage}"/*.php >/dev/null 2>&1; then
  log_error "The staged tree has no PHP file at its root; it would not load as a plugin."
  exit 1
fi

# vendor/ is what makes the package installable without composer, which is what
# a VIP-style deploy needs. Its absence is worth saying out loud rather than
# discovering at deploy time.
if [[ -n "$composer_command" && ! -d "${stage}/vendor" ]]; then
  log_warn "No vendor/ in the staged tree: the package needs composer at its destination."
fi

# ---------------------------------------------------------------------------
# Zip, named from the header version so the archive and what installs agree.
# ---------------------------------------------------------------------------
if [[ "$make_zip" == "true" ]]; then
  zip_path="${abs_out}/${slug}-${version}.zip"
  rm -f "$zip_path"
  ( cd "$abs_out" && zip -qr "$zip_path" "$slug" )
  log_info "Wrote ${zip_path} ($(du -h "$zip_path" | cut -f1))"
fi

log_info "Build complete: ${stage}"
