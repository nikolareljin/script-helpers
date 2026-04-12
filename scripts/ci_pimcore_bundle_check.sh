#!/usr/bin/env bash
# SCRIPT: ci_pimcore_bundle_check.sh
# DESCRIPTION: Run Pimcore bundle standalone and Docker-based checks for CI workflows.
# USAGE: scripts/ci_pimcore_bundle_check.sh [options]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_HELPERS_DIR="${SCRIPT_HELPERS_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=/dev/null
source "${SCRIPT_HELPERS_DIR}/helpers.sh"
shlib_import logging help

usage() { show_help "${BASH_SOURCE[0]}"; }

compose_file="test/docker-compose.yml"
bundle_src="."
bundle_src_env="BUNDLE_SRC"
php_service="php"
db_service="db"
db_wait_seconds="20"
out_dir="test/tmp"
php_version=""
composer_command="composer install --no-interaction --prefer-dist"
php_lint_command=""
phpcs_standalone_command=""
phpunit_standalone_command=""
phpunit_working_directory="."
phpcs_command="vendor/bin/phpcs --standard=PSR12 --extensions=php src/"
phpstan_command=""
phpunit_command="vendor/bin/phpunit --testdox"
phpunit_coverage_command=""
fail_on_findings="true"
cleanup="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose-file) compose_file="$2"; shift 2 ;;
    --bundle-src) bundle_src="$2"; shift 2 ;;
    --bundle-src-env) bundle_src_env="$2"; shift 2 ;;
    --php-service) php_service="$2"; shift 2 ;;
    --db-service) db_service="$2"; shift 2 ;;
    --db-wait-seconds) db_wait_seconds="$2"; shift 2 ;;
    --out-dir) out_dir="$2"; shift 2 ;;
    --php-version) php_version="$2"; shift 2 ;;
    --composer-command) composer_command="$2"; shift 2 ;;
    --php-lint-command) php_lint_command="$2"; shift 2 ;;
    --phpcs-standalone-command) phpcs_standalone_command="$2"; shift 2 ;;
    --phpunit-standalone-command) phpunit_standalone_command="$2"; shift 2 ;;
    --phpunit-working-directory) phpunit_working_directory="$2"; shift 2 ;;
    --phpcs-command) phpcs_command="$2"; shift 2 ;;
    --phpstan-command) phpstan_command="$2"; shift 2 ;;
    --phpunit-command) phpunit_command="$2"; shift 2 ;;
    --phpunit-coverage-command) phpunit_coverage_command="$2"; shift 2 ;;
    --fail-on-findings) fail_on_findings="$2"; shift 2 ;;
    --cleanup) cleanup="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

cleanup_stack() {
  if [[ "$cleanup" == "true" ]]; then
    docker compose -f "$compose_file" down -v --remove-orphans
    log_info "Test stack torn down."
  fi
}
trap cleanup_stack EXIT

if [[ -n "$php_lint_command" || -n "$phpcs_standalone_command" || -n "$phpunit_standalone_command" ]]; then
  if [[ -n "$composer_command" ]]; then
    bash -lc "$composer_command"
  fi
  if [[ -n "$php_lint_command" ]]; then
    bash -lc "$php_lint_command"
  fi
  if [[ -n "$phpcs_standalone_command" ]]; then
    bash -lc "$phpcs_standalone_command"
  fi
  if [[ -n "$phpunit_standalone_command" ]]; then
    (
      cd "$phpunit_working_directory"
      bash -lc "$phpunit_standalone_command"
    )
  fi
fi

mkdir -p "$out_dir"
export "$bundle_src_env"="$(realpath "$bundle_src")"
docker compose -f "$compose_file" up -d "$db_service" "$php_service"

elapsed=0
until docker compose -f "$compose_file" exec -T "$db_service" mysqladmin ping -h 127.0.0.1 --silent 2>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if [[ "$elapsed" -ge "$db_wait_seconds" ]]; then
    log_error "Database did not become healthy within ${db_wait_seconds}s."
    docker compose -f "$compose_file" logs "$db_service"
    exit 1
  fi
done

docker compose -f "$compose_file" exec -T "$php_service" sh -lc "$composer_command"

if [[ -n "$phpcs_command" ]]; then
  if docker compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpcs_command} --report=checkstyle --report-file=/tmp/phpcs.xml"; then
    log_info "PHPCS: no violations."
  else
    docker compose -f "$compose_file" cp "${php_service}:/tmp/phpcs.xml" "${out_dir}/phpcs.xml" 2>/dev/null || true
    log_error "PHPCS: violations found. Report saved to ${out_dir}/phpcs.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpstan_command" ]]; then
  if docker compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpstan_command} --error-format=checkstyle > /tmp/phpstan.xml 2>&1"; then
    log_info "PHPStan: no issues."
  else
    docker compose -f "$compose_file" cp "${php_service}:/tmp/phpstan.xml" "${out_dir}/phpstan.xml" 2>/dev/null || true
    log_error "PHPStan: issues found. Report saved to ${out_dir}/phpstan.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpunit_command" ]]; then
  if docker compose -f "$compose_file" exec -T "$php_service" sh -lc "${phpunit_command} --log-junit /tmp/phpunit.xml"; then
    log_info "PHPUnit: all tests passed."
  else
    docker compose -f "$compose_file" cp "${php_service}:/tmp/phpunit.xml" "${out_dir}/phpunit.xml" 2>/dev/null || true
    log_error "PHPUnit: test failures. Report saved to ${out_dir}/phpunit.xml"
    [[ "$fail_on_findings" == "true" ]] && exit 1
  fi
fi

if [[ -n "$phpunit_coverage_command" ]]; then
  docker compose -f "$compose_file" exec -T "$php_service" sh -lc "mkdir -p /tmp/coverage && ${phpunit_coverage_command} --coverage-clover /tmp/coverage/clover.xml"
  docker compose -f "$compose_file" cp "${php_service}:/tmp/coverage/clover.xml" "${out_dir}/coverage-clover.xml" 2>/dev/null || true
  log_info "Coverage report saved to ${out_dir}/coverage-clover.xml"
fi
