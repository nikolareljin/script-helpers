# Stacks

Which scripts run which kind of project. Each one takes `-h` or `--help` and
prints its options and exit codes. The full list is in the
[command reference](commands.md).

Two kinds of runner:

- **CI runners** (`ci_wp_*`, `ci_laravel.sh`, `ci_django.sh`,
  `ci_pimcore_bundle_check.sh`, `ci_gitleaks_report.sh`) run the same way in CI
  and on a laptop. ci-helpers workflows call them.
- **Local runners** (`ci_node.sh`, `ci_go.sh`, `ci_python.sh`, `ci_flutter.sh`,
  `ci_gradle.sh`, `ci_security.sh`) run the steps in a pinned Docker image for
  local use. They exit 1 under `CI=true`. The `local_test_*.sh` scripts run the
  same checks on the host, and the git hooks call them.

| Stack | Scripts | Guide |
|---|---|---|
| WordPress | `ci_wp_build.sh`, `ci_wp_phpunit.sh`, `ci_wp_plugin_check.sh` | [below](#wordpress) |
| Laravel and PHP | `ci_laravel.sh`, `local_test_php.sh` | [Usage](usage.md#reusable-workflow-helper-scripts) |
| Pimcore | `ci_pimcore_bundle_check.sh` | [below](#pimcore) |
| Django | `ci_django.sh` | [Usage](usage.md#reusable-workflow-helper-scripts) |
| Python | `ci_python.sh`, `local_test_python.sh`, `ps/scripts/ci_python.ps1` | [Usage](usage.md#reusable-workflow-helper-scripts) |
| Node | `ci_node.sh`, `local_test_node.sh`, `ps/scripts/ci_node.ps1` | [below](#node-go-and-rust) |
| Go | `ci_go.sh`, `local_test_go.sh`, `ps/scripts/ci_go.ps1` | [below](#node-go-and-rust) |
| Rust | `local_test_rust.sh`, `ps/scripts/ci_rust.ps1` | [below](#node-go-and-rust) |
| Flutter | `ci_flutter.sh`, `local_test_flutter.sh` | [below](#mobile) |
| Android and Gradle | `ci_gradle.sh`, `local_test_gradle.sh`, `generate-android-keystore.sh` | [below](#mobile) |
| iOS | `ci_ios.sh` | [macOS, iOS and bash 3.2](usage.md#macos-ios-and-bash-32) |
| Security scans | `ci_security.sh`, `ci_gitleaks_report.sh`, `foxguard_report.sh` | [Security gates](security-gates.md) |
| Packages | `build_deb_artifacts.sh`, `build_rpm_artifacts.sh`, `build_arch_artifacts.sh`, `build_brew_tarball.sh` | [Packaging](packaging.md) |

## WordPress

Three scripts cover a plugin: build the package, run its PHPUnit suite, and run
WordPress plugin-check against it. They run unchanged in CI and on a laptop.

### Build the package: `ci_wp_build.sh`

Stages what ships into `<out-dir>/<slug>/` and zips it as
`<out-dir>/<slug>-<version>.zip`.

```bash
scripts/ci_wp_build.sh --workdir . --out-dir build
scripts/ci_wp_build.sh --workdir . --slug my-plugin --zip false
```

- Production dependencies: `composer install --no-dev --optimize-autoloader
  --prefer-dist` (`--composer-command`, empty skips it).
- Front-end assets: `npm ci && npm run build` when `package.json` exists
  (`--asset-command`, empty skips it).
- Excludes come from `.distignore` (or `--exclude-from`). Without one, a default
  list drops `.git`, `node_modules`, `tests`, PHPUnit and PHPCS config, lock
  files and `build`, and the log names it. `.git` and `.distignore` are always
  excluded.
- The version comes from the `Version:` header of the file with `Plugin Name:`,
  unless `--version` is given.
- `--php-image` and `--node-image` run those steps in a container, so a laptop
  needs neither toolchain. The image must have bash.
- A symlink that leaves the plugin or points at nothing fails the build (exit 1).
  Links inside the plugin become regular files.
- `--out-dir` may be inside the plugin; it is left out of the package. It may
  not be the plugin directory or contain it (exit 2).

Exit codes: 0 built; 1 a packaging step failed; 2 bad arguments; N a failing
composer or asset command's own code.

### Run the tests: `ci_wp_phpunit.sh`

Provisions the WordPress test library and core from one `wordpress-develop`
release, writes `wp-tests-config.php`, and runs the plugin's tests. A plugin
needs no `bin/install-wp-tests.sh` of its own.

```bash
# start a database in Docker, and remove it afterwards
scripts/ci_wp_phpunit.sh --workdir . --db-image mysql:8.0 --wp-version 6.5

# a database that already exists, as in a CI service container
scripts/ci_wp_phpunit.sh --workdir . --db-host 127.0.0.1 --db-port 3306
```

- `--wp-version` takes `X.Y.Z`, `X.Y` (the newest release of that minor) or
  `latest`.
- `--wp-tests-dir` and `--wp-core-dir` are removed and rewritten, so they must
  be absolute paths outside the plugin. Defaults: `/tmp/wordpress-tests-lib`,
  `/tmp/wordpress`.
- `--skip-provision true` reuses a library already there.
- `--php-image` runs the tests in that image. The database must then be one a
  container can reach.
- `--multisite 1` runs the suite as multisite.

Exit codes: 0 passed; 1 the database did not start or provisioning failed;
2 bad arguments; N the test command's own code.

### Run plugin-check: `ci_wp_plugin_check.sh`

Starts WordPress from the caller's Docker Compose file, installs it, activates
the plugin, installs the
[plugin-check](https://wordpress.org/plugins/plugin-check/) plugin, and runs
`wp plugin check`. Reports land in `--out-dir` as `plugin-check.json` and
`meta-check.json`.

```bash
scripts/ci_wp_plugin_check.sh \
  --compose-file test/docker-compose.yml \
  --plugin-slug my-plugin \
  --plugin-src . \
  --exclude-directories "vendor,node_modules,test" \
  --fail-on-findings true
```

- The compose file is the caller's. It needs a database, a WordPress and a
  WP-CLI service (`--db-service`, `--wordpress-service`, `--wpcli-service`).
  The plugin source path reaches it in the `PLUGIN_SRC` variable
  (`--plugin-src-env`).
- `--php-lint-command`, `--phpcs-warning-command` and `--phpunit-command` run on
  the host first. PHPCS warnings never fail the run.
- Findings fail the run only with `--fail-on-findings true` (exit 4). The
  default reports them and exits 0.
- `--multisite` and `--activate-network` default to `true`.
- `--cleanup false` keeps the containers for inspection.

Exit codes: 0 clean or report-only; 1 the database did not become ready;
2 bad arguments; 4 errors found, or plugin-check unavailable, with
`--fail-on-findings true`; 5 a report could not be parsed; N a failing lint,
PHPUnit or setup command's own code. More on the excludes in
[Usage](usage.md#reusable-workflow-helper-scripts).

## Pimcore

`ci_pimcore_bundle_check.sh` checks a Pimcore bundle. Optional host-side lint,
PHPCS and PHPUnit commands run first, after `composer install` on the host.
Then `composer install`, PHPCS, PHPStan and PHPUnit run inside the PHP service
of the caller's compose file.

```bash
scripts/ci_pimcore_bundle_check.sh \
  --compose-file test/docker-compose.yml \
  --phpstan-command "vendor/bin/phpstan analyse"
```

Findings fail the run by default (`--fail-on-findings true`, exit 1).

## Node, Go and Rust

```bash
scripts/ci_node.sh --workdir web          # install, lint, test, build in Docker
scripts/ci_go.sh --skip-build             # lint and test in Docker
bash scripts/local_test_node.sh --quick   # the same checks on the host
bash scripts/local_test_go.sh --quick
bash scripts/local_test_rust.sh --quick   # rustup's stable, not the first cargo on PATH
```

Each `--skip-*` flag drops one step, and `--no-docker` runs on the host. There
is no Bash `ci_rust.sh`: `local_test_rust.sh` is the Rust gate.
`ps/scripts/ci_node.ps1`, `ci_go.ps1` and `ci_rust.ps1` run the same checks
natively on Windows, or in Docker Desktop with `-UseDocker`. More in
[Git hook setup and local test runners](usage.md#git-hook-setup-and-local-test-runners).

## Mobile

```bash
scripts/ci_flutter.sh --workdir app                   # analyze, test, build
scripts/ci_gradle.sh --workdir android                # build, test, lint, detekt
bash scripts/local_test_gradle.sh --dir android --android
bash scripts/generate-android-keystore.sh ./release.jks
scripts/ci_ios.sh --skip-build                        # macOS with Xcode only
```

`ci_ios.sh` runs on the host and exits 3 anywhere without Xcode. The `adb`,
`android`, `flutter`, `gradle`, `ios` and `screencap` modules hold the functions
these scripts use; see the [API index](api.md).
