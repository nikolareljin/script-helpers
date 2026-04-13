#!/usr/bin/env bash
# SCRIPT: ci_wp_plugin_check.sh
# DESCRIPTION: Run WordPress plugin-check and optional standalone PHP checks for CI workflows.
# USAGE: scripts/ci_wp_plugin_check.sh [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help docker

usage() { show_help "${BASH_SOURCE[0]}"; }

compose_file="test/docker-compose.yml"
plugin_slug=""
plugin_src="."
plugin_src_env="PLUGIN_SRC"
wpcli_service="wpcli"
db_service="db"
wordpress_service="wordpress"
host_port="8080"
out_dir="test/tmp"
db_wait_seconds="30"
multisite="true"
activate_network="true"
admin_user="admin"
admin_password="admin"
admin_email="admin@example.com"
site_title="WP Test Site"
meta_check_script=""
php_lint_command=""
phpcs_warning_command=""
phpunit_command=""
phpunit_working_directory="."
fail_on_findings="false"
cleanup="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) compose_file="$2"; shift 2 ;;
    --plugin-slug) plugin_slug="$2"; shift 2 ;;
    --plugin-src) plugin_src="$2"; shift 2 ;;
    --plugin-src-env) plugin_src_env="$2"; shift 2 ;;
    --wpcli-service) wpcli_service="$2"; shift 2 ;;
    --db-service) db_service="$2"; shift 2 ;;
    --wordpress-service) wordpress_service="$2"; shift 2 ;;
    --host-port) host_port="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --db-wait-seconds) db_wait_seconds="$2"; shift 2 ;;
    --multisite) multisite="$2"; shift 2 ;;
    --activate-network) activate_network="$2"; shift 2 ;;
    --admin-user) admin_user="$2"; shift 2 ;;
    --admin-password) admin_password="$2"; shift 2 ;;
    --admin-email) admin_email="$2"; shift 2 ;;
    --site-title) site_title="$2"; shift 2 ;;
    --meta-check-script) meta_check_script="$2"; shift 2 ;;
    --php-lint-command) php_lint_command="$2"; shift 2 ;;
    --phpcs-warning-command) phpcs_warning_command="$2"; shift 2 ;;
    --phpunit-command) phpunit_command="$2"; shift 2 ;;
    --phpunit-working-directory) phpunit_working_directory="$2"; shift 2 ;;
    --fail-on-findings) fail_on_findings="$2"; shift 2 ;;
    --cleanup) cleanup="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [[ -z "$plugin_slug" ]]; then
  log_error "--plugin-slug is required"
  exit 2
fi

cleanup_stack() {
  if [[ "$cleanup" == "true" ]]; then
    docker_compose -f "$compose_file" down -v
  fi
}
trap cleanup_stack EXIT

if [[ -n "$php_lint_command" || -n "$phpcs_warning_command" || -n "$phpunit_command" ]]; then
  if [[ -n "$php_lint_command" ]]; then
    bash -lc "$php_lint_command"
  fi
  if [[ -n "$phpcs_warning_command" ]]; then
    bash -lc "$phpcs_warning_command" || true
  fi
  if [[ -n "$phpunit_command" ]]; then
    (
      cd "$phpunit_working_directory"
      bash -lc "$phpunit_command"
    )
  fi
fi

mkdir -p "$out_dir"
cat > "${out_dir}/wp-cli.yml" <<WPCLI
path: /var/www/html
url: http://localhost:${host_port}
color: false
disable_wp_cron: true
apache_modules:
  - mod_rewrite
WPCLI

export "$plugin_src_env"="$plugin_src"
docker_compose -f "$compose_file" up -d "$db_service" "$wordpress_service"

db_ready="false"
for ((i=0; i<db_wait_seconds; i++)); do
  if docker_compose -f "$compose_file" exec -T "$db_service" sh -lc 'mysqladmin ping -h 127.0.0.1 -uwordpress -pwordpress --silent' >/dev/null 2>&1; then
    db_ready="true"
    break
  fi
  sleep 1
done

if [[ "$db_ready" != "true" ]]; then
  log_error "Timed out waiting for database service '$db_service' to become ready after ${db_wait_seconds}s."
  exit 1
fi

docker_compose -f "$compose_file" run --rm "$wpcli_service" sh -lc 'test -f wp-config.php || wp config create --dbname=wordpress --dbuser=wordpress --dbpass=wordpress --dbhost=db:3306 --skip-check'

if [[ "$multisite" == "true" ]]; then
  docker_compose -f "$compose_file" run --rm "$wpcli_service" sh -lc 'wp config set WP_ALLOW_MULTISITE true --raw || true'
  docker_compose -f "$compose_file" run --rm \
    -e WP_SITE_TITLE="$site_title" \
    -e WP_ADMIN_USER="$admin_user" \
    -e WP_ADMIN_PASSWORD="$admin_password" \
    -e WP_ADMIN_EMAIL="$admin_email" \
    "$wpcli_service" \
    sh -lc 'wp core is-installed || wp core multisite-install --url=localhost:'"${host_port}"' --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL" --skip-email --subdomains=0'
else
  docker_compose -f "$compose_file" run --rm \
    -e WP_SITE_TITLE="$site_title" \
    -e WP_ADMIN_USER="$admin_user" \
    -e WP_ADMIN_PASSWORD="$admin_password" \
    -e WP_ADMIN_EMAIL="$admin_email" \
    "$wpcli_service" \
    sh -lc 'wp core is-installed || wp core install --url=localhost:'"${host_port}"' --title="$WP_SITE_TITLE" --admin_user="$WP_ADMIN_USER" --admin_password="$WP_ADMIN_PASSWORD" --admin_email="$WP_ADMIN_EMAIL" --skip-email'
fi

if [[ "$activate_network" == "true" ]]; then
  docker_compose -f "$compose_file" run --rm \
    -e WP_PLUGIN_SLUG="$plugin_slug" \
    "$wpcli_service" \
    sh -lc 'wp plugin activate "$WP_PLUGIN_SLUG" --network || wp plugin activate "$WP_PLUGIN_SLUG"'
else
  docker_compose -f "$compose_file" run --rm \
    -e WP_PLUGIN_SLUG="$plugin_slug" \
    "$wpcli_service" \
    sh -lc 'wp plugin activate "$WP_PLUGIN_SLUG"'
fi

docker_compose -f "$compose_file" run --rm "$wpcli_service" sh -lc "wp plugin install plugin-check --activate || true"

plugin_check_available="false"
if docker_compose -f "$compose_file" run --rm "$wpcli_service" sh -lc "wp help plugin | grep -q '\\<check\\>'"; then
  plugin_check_available="true"
  docker_compose -f "$compose_file" run --rm \
    -e WP_PLUGIN_SLUG="$plugin_slug" \
    "$wpcli_service" \
    sh -lc 'wp plugin check "$WP_PLUGIN_SLUG" --format=json' > "${out_dir}/plugin-check.json" || true
elif [[ "$fail_on_findings" == "true" ]]; then
  log_error "wp plugin check is unavailable in strict mode; cannot evaluate plugin findings."
  exit 4
fi

if [[ -n "$meta_check_script" ]]; then
  docker_compose -f "$compose_file" run --rm \
    -e WP_META_CHECK_SCRIPT="$meta_check_script" \
    "$wpcli_service" \
    sh -lc 'wp eval-file "/workspace/$WP_META_CHECK_SCRIPT"' > "${out_dir}/meta-check.json"
fi

if [[ "$fail_on_findings" == "true" ]]; then
  OUT_DIR="$out_dir" PLUGIN_CHECK_AVAILABLE="$plugin_check_available" python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

out_dir = Path(os.environ["OUT_DIR"])
plugin_check = out_dir / "plugin-check.json"
meta_check = out_dir / "meta-check.json"
plugin_check_available = os.environ["PLUGIN_CHECK_AVAILABLE"] == "true"

error_count = 0
parse_errors = []

def load_json(path: Path, label: str):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        parse_errors.append(f"{label} is not valid JSON: {exc}")
    except OSError as exc:
        parse_errors.append(f"{label} could not be read: {exc}")
    return None

if plugin_check.exists():
    data = load_json(plugin_check, "plugin-check.json")
    if isinstance(data, dict):
        if isinstance(data.get("errors"), int):
            error_count += data.get("errors", 0)
        for key in ("results", "issues", "messages"):
            items = data.get(key)
            if isinstance(items, list):
                for item in items:
                    if isinstance(item, dict):
                        level = str(item.get("severity") or item.get("level") or item.get("type") or "").lower()
                        if level in {"error", "critical", "fatal"}:
                            error_count += 1
                    else:
                        error_count += 1
    elif isinstance(data, list):
        error_count += len(data)
elif plugin_check_available:
    parse_errors.append("plugin-check.json was not created even though wp plugin check is available")

if meta_check.exists():
    data = load_json(meta_check, "meta-check.json")
    checks = data.get("checks") if isinstance(data, dict) else None
    if isinstance(checks, dict):
        for value in checks.values():
            if isinstance(value, dict) and value.get("ok") is False:
                error_count += 1

if parse_errors:
    for message in parse_errors:
        print(message, file=sys.stderr)
    sys.exit(5)

if error_count > 0:
    print(f"Plugin checks reported {error_count} error(s)")
    sys.exit(4)

print("No plugin-check errors detected.")
PY
fi
