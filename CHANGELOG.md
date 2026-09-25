## [Unreleased]

### Added

- **`ci_python.sh` can start a database, and carry extra environment.**
  `--db-image` starts one through `lib/ci_stack.sh` and exports the connection
  as `DATABASE_URL` plus the discrete `DB_*` variables; `--env NAME=VALUE` is
  repeatable and is how `FLASK_APP` or anything else reaches the steps.

  **No database is started unless asked for**, and that default came from
  counting rather than from symmetry. Of the six Flask applications in this
  fleet, one uses a database and five do not; their entry points are named
  `web.py`, `app.py`, `web_app.py` and `lesson_web.py`, and Flask has no
  universal CLI like `artisan` or `manage.py`. A runner that started postgres by
  default would have been wrong five times in six.

  Which is also why there is no `ci_flask.sh`. A Flask-specific runner would
  have duplicated this script's install-and-test machinery and differed only by
  exporting `FLASK_APP`, so the framework got an option rather than a script.
  `ci_django.sh` remains separate because Django genuinely has more: `.env`, a
  migration step and `manage.py`.

  In Docker mode the steps join a network with the database and reach it by
  container name; with `--no-docker` the port is published to loopback. Both
  modes get the same environment, passed as `-e` pairs and through `env`
  respectively rather than interpolated into a command string, so a password
  containing a quote cannot break the quoting or run as code.

## 2026-09-25 — v0.40.0

### Added

- **`ci_stack_command_program` and `ci_stack_command_available` in
  `lib/ci_stack.sh`.** The step-command probe, as two functions a script can
  call rather than a copy each script keeps. `ci_stack_command_program` answers
  which program a step command would run -- stepping over environment prefixes
  and `env FOO=1`, and declining to guess at a pipeline, chain, subshell,
  redirect or quoted path. `ci_stack_command_available` answers whether it can
  be run, probing **with the workdir as its current directory**.

  They exist because the fix below had to land in two scripts at once, and a
  rule written twice is a rule that drifts: the two copies had already diverged
  on how they treated an environment prefix, and one of those behaviours reached
  a ci-helpers preset. Documented in `docs/modules/ci_stack.md`.

### Fixed

- **A step command naming a path inside the project was refused before it
  ran.** The probe ran `command -v` in the script's own directory, not the
  workdir, so `bin/thing`, `.venv/bin/python` and `vendor/bin/phpunit` were all
  reported as "not on PATH" while the step itself would have `cd`-ed to the
  workdir and run them. A check that fires on correct input is worse than no
  check, because it gets switched off.

  An environment prefix was handled differently in each script, which is how it
  reached a preset: `ci_laravel.sh` skipped the check entirely for anything
  containing `=`, so `FOO=bar definitely-not-real` was accepted; `ci_django.sh`
  read `FOO=bar` as the program name and refused the command outright. The
  second cost a ci-helpers self-test leg a full CI cycle -- the database had
  already started and the migration already run when the test step was refused
  for a program called `EXPECT_DB_NAME=fixture_db`.

  Both now use `ci_stack_command_program` and `ci_stack_command_available` from
  `lib/ci_stack.sh`: one implementation, which steps over environment prefixes,
  declines to guess at a pipeline or a chain, and probes with the workdir as its
  current directory.

  It also declines a quoted program path. Splitting
  `"/opt/my tools/python" manage.py test` on whitespace yields `"/opt/my`, and
  probing that is a bash syntax error -- an unbalanced quote -- which reads as
  "not available" and refuses a command that works. The space is what breaks it;
  a quoted path without one survives either way.

- **`ci_django.sh --python-image` lost every installed package between
  steps.** Each step is its own `docker run --rm`, so `pip install` put packages
  in a container that was then discarded and the next step failed with
  `ModuleNotFoundError` -- after the install step had reported success.
  Composer never had this problem because it writes into the mounted `vendor/`.

  `PIP_TARGET` and `PYTHONPATH` now point at `.ci-python-packages` inside the
  mounted workdir, and it is removed on the way out. Verified with the run that
  first failed: `pip install "psycopg[binary]"` in one container, used by the
  migrate and test containers after it, against a real postgres.


## 2026-09-25 — v0.39.0

### Added

- **`lib/ci_stack.sh`: one copy of the disposable-database machinery.**
  `ci_laravel.sh` and `ci_wp_phpunit.sh` each carried their own
  `start_database` and `cleanup`. The two had drifted far enough that one
  guarded its EXIT trap against inherited subshells and the other did not,
  which removes the caller's database container mid-run. Adding a third and
  fourth copy for Drupal and Django would have made that worse.

  `ci_stack_start_database`, `ci_stack_remove`, `ci_stack_engine_for_image` and
  `ci_stack_default_port` take their inputs as arguments rather than reading a
  caller's variables, so a caller can be read without reading this file.

  `ci_laravel.sh` and `ci_wp_phpunit.sh` move onto it next. They are untouched
  here on purpose: a separate change has their trap lines open, and rebasing one
  onto the other would have meant stacking two pull requests.

- **`ci_django.sh`: a Django project's tests, in CI or on a laptop.** The first
  consumer of `ci_stack`, rather than a module with no caller.

  `ci_python.sh` installs and runs pytest. Django needs two things it has no
  notion of: a database its settings can reach, and the migrations applied
  before the suite runs.

  ```
  [INFO] Starting postgres:16 as django-db-2939605 on the django-net-2939605 network
  [INFO] Database ready after 8s
  [INFO] Schema (python:3.12-slim): python manage.py migrate --noinput
    Applying app.0001_initial... OK
  [INFO] Tests (python:3.12-slim): python manage.py test
    Ran 2 tests  OK  [engine=pgsql]
  [INFO] Removing database container django-db-2939605
  ```

  The connection is exported as environment -- `DATABASE_URL` and the discrete
  `DJANGO_DB_*` variables -- not written into a settings file. A settings module
  that reads `os.environ` works unchanged in both places; one that CI rewrites
  works only where CI rewrote it.

  sqlite is the default, so it is useful with no infrastructure at all, and it
  is a file rather than `:memory:` for the reason `ci_laravel.sh` learned the
  hard way: each step is its own process, and an in-memory database dies with
  the step that migrated it.

### Changed

- **`ci_laravel.sh` and `ci_wp_phpunit.sh` use `lib/ci_stack.sh` instead of
  carrying their own copies.** Both had their own `start_database` and
  `cleanup`, and the two had drifted until only one guarded its EXIT trap --
  the difference between a signalled subshell removing the caller's database
  container mid-run and not. The module shipped with `ci_django.sh` as its first
  consumer; these are the second and third.

  | | before | after |
  |---|---|---|
  | `ci_laravel.sh` | 488 | 424 |
  | `ci_wp_phpunit.sh` | 368 | 328 |
  | `lib/ci_stack.sh` | — | 167, once |

  Neither script now contains `docker run -d`, `docker rm -f`,
  `docker network create`, `mysqladmin ping` or `pg_isready`. Engine inference
  and the default port come from the module too, so `postgres` means 5432 in one
  place rather than four.

  No behaviour change is intended, and the existing suites are the evidence:
  both pass unchanged. Beyond that, run against real containers -- sqlite,
  MySQL with a non-default root password, and postgres -- with the volume count
  identical before and after, and the database container removed even on the run
  that refused for a missing PDO driver.

### Fixed

- **`ci_wp_phpunit_test.sh` asserted through a path that always failed.** Four
  cases passed `--db-wait-seconds 0`, where the readiness loop runs no polls at
  all: the old inline `start_database` fell straight through to "did not become
  ready" and exit 1, and the assertions passed anyway because they read the argv
  `docker run` had already recorded on the way to a guaranteed failure.

  `ci_stack_start_database` refuses 0 outright, which is what exposed it. The
  cases now use 2, and the file records why. `ci_laravel_test.sh` already
  carried this lesson.

- **Every EXIT trap in shipped code is guarded against running in an inherited
  subshell.** A subshell inherits an EXIT trap, and bash runs it there when the
  subshell is signalled. Fourteen traps had no guard, and several of them do
  real damage from a subshell:

  | Script | What the trap does |
  |---|---|
  | `ci_wp_phpunit.sh` | `docker rm -f -v` the database container, and `rm -rf` the WordPress download the run is still reading |
  | `ci_wp_plugin_check.sh`, `ci_pimcore_bundle_check.sh` | `docker compose down -v --remove-orphans` against the caller's stack, volumes included |
  | `lib/ollama.sh` | `rm -f` a log file, installed immediately before `"$@" &` -- a background job inherits it and would delete the file it is writing |
  | `publish_homebrew.sh`, `docs_site.sh`, `check_private_names.sh`, `refresh_private_names.sh`, `git-hooks/pre-push` | `rm -rf` or `rm -f` a working directory |

  This is the same defect that made this repository's own test suite flaky: a
  watchdog `kill` made bash run the inherited `rm -rf "$tmp"` and the suite
  deleted its own working tree. That was fixed in `tests/`; the shipped scripts
  carried it untouched.

  `${BASHPID-$$}` rather than `$BASHPID`: bash 3.2, which macOS ships, does not
  define `BASHPID`, and `$$` is the top-level shell's pid in every subshell, so
  the comparison degrades to always-true there rather than silently disabling
  cleanup.

- **`tests/run_bounded_test.sh` now scans `scripts/`, `lib/` and `bin/`, not
  only `tests/`.** It reported the rule enforced while ten unguarded traps sat
  in shipped code, because it read the practice files and not the shipping
  ones. It also fails when it finds no EXIT traps at all, since a scan that
  matches nothing otherwise reports success having examined nothing.


## 2026-09-25 — v0.38.1

### Fixed

- **`ci_laravel.sh` and `ci_wp_phpunit.sh` left the database's data directory
  behind on every run.** The `mysql` and `postgres` images declare a `VOLUME`,
  so `docker run -d` creates an anonymous volume per container, and `docker rm
  -f` removes the container without it. Seven runs on one laptop left 1.4 GB of
  orphaned MySQL data directories, referenced by nothing and invisible unless
  someone goes looking with `docker volume ls -qf dangling=true`.

  Both now remove with `docker rm -f -v`, which takes anonymous volumes and
  leaves a named one alone. Found by running `ci_laravel.sh` against a real
  application three times; the stub tests could not see it, because a stub
  records the argv it is given rather than what Docker does with it.

## 2026-09-25 — v0.38.0

### Added

- **`ci_laravel.sh --db-root-password`: the MySQL root account is the caller's
  to choose.** It was hard-coded to `root`, so a caller that asked for another
  one got `root` and was told nothing. ci-helpers' `laravel.yml` declares
  `db_root_password` and will forward it here, which is how the gap was found.

  Empty means `MYSQL_ALLOW_EMPTY_PASSWORD=yes`, not an empty
  `MYSQL_ROOT_PASSWORD` -- the image rejects the latter. Either way the failure
  it prevents is remote from its cause: without one of the two the container
  exits during its entrypoint, so what a caller sees is the readiness poll
  timing out after `--db-wait-seconds` with nothing about a password in it.

  postgres ignores the option rather than refusing it, because a preset
  forwards its inputs whatever engine the caller picked.

### Fixed

- **`ci_laravel.sh`: an option written last with no value is an argument error,
  not a bash crash.** Every one of the sixteen read `"$2"` unchecked, so
  `--db-name` at the end of a command line died with
  `ci_laravel.sh: line 82: $2: unbound variable` and exit 1 -- where the
  script's own `EXIT_CODES` promise 2 for a bad argument, and where nothing
  names the option.

  The guard checks that the argument exists, not that it is non-empty: several
  of these options take an empty value on purpose, `--install-command ''` to
  skip the install among them.

### Documentation

- **`ci_laravel.sh`, `ci_wp_build.sh` and `ci_wp_phpunit.sh` in `docs/usage.md`.**
  All three shipped with no entry there, so the only way to find their options
  was to read the script. `make lint-docs` does not catch this: it checks the
  header block inside each script, not whether the manual mentions it.

## 2026-09-25 — v0.37.0

### Added

- **`ci_laravel.sh`: a Laravel application's tests, in CI or on a laptop.** The
  same command in both places, which is the point: a failure on a runner can be
  reproduced without guessing at what CI did differently.

  Laravel needs three things a generic PHP runner does not provide -- a `.env`,
  an `APP_KEY` in it, and a database its config can reach. Without the key every
  test fails with "No application encryption key has been specified", which says
  nothing about the real problem. The script creates `.env` from `.env.testing`
  or `.env.example` when there is none, generates a key only when one is
  missing, and leaves an existing file alone.

  sqlite is the default, so the script is useful with no infrastructure at all.
  It is a file inside the application rather than `:memory:`, because each step
  is its own process -- a separate container when `--php-image` is used -- and
  an in-memory database dies with the step that made it. `migrate` reported
  every migration DONE and the next step answered "Migration table not found".
  The file is named for the run and removed on the way out.

  `--db-image` swaps in a real server:

  ```
  [INFO] Starting mysql:8.0 as laravel-db-875660 on the laravel-net-875660 network
  [INFO] Database ready after 12s
  [INFO] Schema (local/php84-mysql): php artisan migrate --force
    0001_01_01_000000_create_users_table ......................... 152.02ms DONE
  Tests:    2 passed (2 assertions)
  [INFO] Removing database container laravel-db-875660
  ```

  The engine is read from the image name, so `postgres:16` brings `pgsql`,
  `POSTGRES_*` variables and `pg_isready` without the caller saying so twice.

  The database settings are passed as real environment rather than written into
  `.env`: Laravel's `env()` reads the process environment first, so a developer's
  own file survives the run unedited.

  Three refusals are worth naming, because the official `php` images ship
  neither composer nor any database driver, and without either the run dies at
  the first step with exit 127 and a message that names the step rather than the
  cause. `php`, the install command and the PDO driver are each checked in the
  environment the step will actually run in, before anything uses them:

  ```
  [ERROR] Dependencies: 'composer' is not on PATH in php:8.4-cli.
  [ERROR] The official php images ship no composer. Use an image that has it,
  [ERROR] install the dependencies beforehand and pass --install-command '',
  [ERROR] or build one:  FROM php:8.4-cli
  [ERROR]                COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
  ```

  `--env-file` is resolved as given and then relative to the application. It was
  resolved only against the application, so an absolute path was refused with
  "not found" naming a path nobody had passed.

## 2026-09-24 — v0.36.0

### Fixed

- **The test suite deleted its own working tree, intermittently.** Every suite
  ends with `trap 'rm -rf "$tmp"' EXIT`, and nine of them bound a call with a
  watchdog:

  ```
  ( sleep "$secs"; kill -9 "$pid" ) & w=$!
  wait "$pid"; kill "$w"
  ```

  A subshell inherits that trap, and bash runs it there when `kill "$w"`
  arrives as SIGTERM -- so the suite removed `$tmp` while still using it.
  Everything after that failed for unrelated-looking reasons:
  `gradle_assemble release ran ''` in `android_test`, a write to a vanished
  directory in `manifest_test`. About 26 runs in 40 in isolation, 1 in 5 under
  load, which is why a re-run always cleared it.

  Cleanup traps are guarded with `${BASHPID-$$}`, so only the shell that set
  one runs it, and the watchdogs use `kill -9`, which cannot run a trap on any
  bash.

  It is a bash 4+ race. bash 3.2, which macOS ships and which
  `local_test_bash32.sh` runs the suite under, does not run an inherited EXIT
  trap when the subshell is signalled at all: 0 in 20 there against 10 in 20 on
  5.2. So `${BASHPID-$$}` degrading to "always the owner" on 3.2 costs nothing
  -- there is nothing to refuse -- and cleanup still happens there.

  `tests/run_bounded_test.sh` covers it: the mechanism reproduced as a control,
  the guard, and a scan of `tests/` so a new suite copying the old idiom fails.

### Added

- **`ci_wp_build.sh`: the package a plugin ships, built the same way everywhere.**
  What ships is not what is in the repository. A plugin needs its production
  dependencies vendored and its front-end assets built, and everything that
  exists only to develop it left out. Doing that per plugin is how two of them
  end up shipping different things.

  It reads the version from the plugin header, runs `composer install --no-dev`
  and an asset build when there is a `package.json`, stages the tree with rsync
  and writes `<slug>-<version>.zip`:

  ```
  [INFO] Building my-plugin 1.1.0
  [INFO] Production dependencies (php:8.3-cli): composer install --no-dev --optimize-autoloader --prefer-dist
  [INFO] Front-end assets: skipped (no package.json)
  [INFO] No .distignore; excluding: .git .github .gitignore ... composer.lock package-lock.json build
  [INFO] Staged 56 file(s) in /src/build/my-plugin
  [INFO] Wrote /src/build/my-plugin-1.1.0.zip (56K)
  ```

  Excludes come from `.distignore` when the plugin has one, which is what
  WordPress tooling already reads, so a plugin does not learn a new file for
  this. Without one a default list applies and is named in the log, because a
  silent exclusion is worse than a wrong one. `.distignore` replaces that list
  rather than adding to it, except for `.git` and the exclude file itself,
  which are excluded either way: a `.distignore` that forgets `.git` ships the
  repository history inside the plugin, and that is never what was meant.

  What is refused rather than shipped: a staged tree with no PHP file at its
  root, which installs and does nothing because WordPress reads the header from
  a file directly inside the plugin directory; an `--out-dir` that is or
  contains the plugin, a `--slug` that is a path or starts with a dash, and a
  version carrying a path, all of which reach `rm -rf`, `rm -f` or an argument
  position where `zip` reads a name as an option; and a `--zip` value that is
  neither `true` nor `false`, which previously produced no archive and still
  reported success.

  `rsync` and `zip` are checked up front, because a slim PHP image ships
  neither and finding out after the dependency install says only
  `command not found`.

  Symlinks are refused when they leave the plugin or point at nothing, and
  resolved into regular files when they do not. `zip` follows a link and
  stores the target's content, and skips a broken one without a message, so a
  package left as-is is a different plugin from the staged tree it was made
  from -- a link to a file outside the plugin put that file's content in the
  archive. WordPress extracts with `ZipArchive`, which writes a symlink entry
  as a regular file holding the target path, so a package containing symlinks
  is broken there regardless.

  The scan is NUL-delimited: a newline in a file name made `find` print what
  looked like two paths, `readlink` failed on the fragment, and `set -e` ended
  the build with exit 1 and no message while the link that should have been
  refused went unexamined.

  A failing step names itself and keeps the command's exit code:
  `[ERROR] Production dependencies failed (exit 3): composer install ...`.
  Before, `set -e` ended the run on the line that announced the command and
  nothing said it had failed.

  `--php-image` and `--node-image` run the toolchain steps in containers, as the
  invoking user, so a laptop needs neither installed and the build leaves no
  root-owned `vendor/` in the caller's repository.

## 2026-09-23 — v0.35.0

### Added

- **`ci_wp_phpunit.sh`: a WordPress plugin's tests, in CI or on a laptop.** A
  plugin's `tests/bootstrap.php` is written against the WordPress test library,
  which expects `WP_TESTS_DIR` to hold `includes/functions.php` and a
  `wp-tests-config.php` naming a real database. Plugins carry a
  `bin/install-wp-tests.sh` to provide that; this replaces it, so the same
  provisioning runs in both places rather than once in CI and once by hand.

  Library and core come from one `wordpress-develop` tarball, so they cannot
  disagree about the version under test. Those tags are always `X.Y.Z`, so a
  bare minor like `7.1` is resolved to its newest patch: requesting it as a tag
  answers 404 with a message about a missing ref, which says nothing about
  versions.

  `--db-image` starts the database in Docker and removes it on exit.
  `--php-image` runs the tests in a PHP container. With both, nothing is needed
  on the machine but Docker:

  ```
  PHPUnit 9.6.37
  ..                                    2 / 2 (100%)
  OK (2 tests, 2 assertions)
  ```

  That is a real run with no PHP and no MySQL on the host. The two containers
  share a user-defined network and the database is addressed by container name,
  rather than `--network host`, which would only work on Linux. The config
  therefore names the database differently depending on where the tests run;
  writing `127.0.0.1` and then running them in a container points them at the
  container itself.

  `--wp-tests-dir` and `--wp-core-dir` reach `rm -rf`, so they must be absolute
  and `/` and the working directory are refused: `--wp-tests-dir .` would
  otherwise delete the plugin under test. `--skip-provision` refuses to proceed
  when the library it is told to reuse is absent, because reporting success
  over a missing test library is how a green run comes to mean nothing.

  Readiness is polled rather than slept for. A fixed sleep is either too short
  on a loaded machine or wasted time on a fast one.

  Two defects found reviewing it, neither visible on the machine it was written
  on. `"${arr[@]}"` on an empty array is an unbound variable under `set -u` in
  bash 3.2, which macOS ships, and that array is empty whenever `--db-image` is
  used without `--php-image` -- so it would have failed on macOS only. The
  repository's own `${arr[@]+"${arr[@]}"}` idiom fixes it, and the bash 3.2
  gate now covers that path: the earlier cases never reached `start_database`.

  And `--php-image` with a database that is not ours wrote `127.0.0.1` into the
  config, which inside a container is that container. The combination is
  refused with what to pass instead, rather than failing later as a connection
  refused with nothing to say why.

  The test container runs as the invoking user. PHPUnit writes
  `.phpunit.cache` into the working directory, and owned by root it cannot be
  deleted afterwards without Docker -- the same undeletable tree this session
  produced twice by other means. `--docker-user ""` restores the image default
  for an image that needs root to install extensions.

  A third: the database port was published to the host even when the tests run
  in a container and reach it by name. Anything else holding that port then
  failed the whole run with `port is already allocated`, for a port nothing was
  going to use. It is published only for a host run now.

- **`webshot` module and `bin/webshot`: screenshots of a web app and
  HTML-to-PDF, with Playwright.** `webshot_capture <spec.json> <out_dir>` reads a
  list of pages from a JSON spec, logs in once per auth profile (an API token
  written to `localStorage`, or a form filled in), runs clicks and fills, hides
  elements such as dev banners, and saves the viewport, the whole page or one
  element as a PNG, plus a `manifest.json` with sizes and any console errors.
  `webshot_pdf` prints an HTML file to PDF with backgrounds and an optional
  page-number footer. Playwright lives in a venv under
  `~/.cache/nr-webshot`, created by `webshot_ensure`, never in the repository.
  `${VAR}` in URLs, auth profiles and filled-in values is expanded from the
  environment so credentials stay out of spec files; selectors and `eval` code
  are left as written. Exit codes follow the library: 2 for a bad spec, 3 when Playwright
  is missing. `tests/webshot_test.sh` checks arguments and the spec everywhere
  and, where Playwright is installed, renders a fixture page and checks the
  element clip size, the hide rule, an action's effect and a PDF.

## 2026-09-23 — v0.34.0

### Added

- **`ci_wp_plugin_check.sh` takes `--exclude-directories` and `--exclude-files`,
  passed through to `wp plugin check`.** The check runs against whatever is in
  the plugin directory, and for a repository checkout that is more than the
  plugin. `ci-helpers`' `wp-plugin-check.yml` clones this library to
  `.script-helpers` inside the caller's workspace, which is usually the plugin
  source, so every file of it was scanned and `hidden_files` fired once each:

  ```
  without .script-helpers   1 error,   10 files
  with .script-helpers      146 errors, 155 files
  with it, excluded         0 errors,    9 files
  ```

  Measured on a real plugin. The middle row is exactly what that plugin's CI
  reported, so the reproduction is the same defect and not a lookalike.

  Both default to empty: a caller scanning a packaged plugin wants everything
  checked. The flags are built as an array, so an empty value passes no flag at
  all -- `--exclude-files=` with nothing after it makes plugin-check treat the
  empty string as a filename and skip nothing, which reads as working. A test
  asserts both the flag reaching `docker` and its absence when nothing was
  asked for, and both were checked by breaking them.

  Reviewing that test found it asserted `--exclude-directories` only, so the
  `--exclude-files` passthrough could be deleted outright with the suite still
  green. Verified by deleting it. Both flags are asserted separately now, and
  removing either fails.

  `docs/usage.md` gains them on the `--plugin-src .` example, which is the case
  that produces the finding.

  The same review found the negative case could pass vacuously: asserting a
  flag is absent is equally true when the helper died before reaching
  `wp plugin check`, and `[[ -n "$x" ]] && arr+=(...)` under `set -e` is that
  shape. Both cases now assert the run got there, checked by making it exit
  early.

## 2026-09-22 — v0.33.0

### Changed

- **Node default 20-bullseye -> 24-bookworm, Python default 3.11-slim ->
  3.12-slim.** Both were set 2026-01-29 and Node 20 left active LTS since.
  Node 24 is the current LTS line; `node:24` ships no bullseye variant, so the
  base moves to bookworm with it.

  Verified end to end through the helpers, not only by pulling the images:

  ```
  ci_node.sh   --test-cmd 'node --version'    -> v24.21.0     exit 0
  ci_python.sh --test-cmd 'python --version'  -> Python 3.12.14  exit 0
  ```

  A consumer needing the old versions sets `CI_DEFAULT_NODE_VERSION` or
  `CI_DEFAULT_PYTHON_VERSION`, or passes `--version`; both defaults have always
  been overridable and neither helper gained a floor. Node 20 and Python 3.11
  remain supported, they are simply no longer what you get by default.

  Four of the six comments the Docker login-shell audit added, each naming the
  image its helper was measured against, move with the defaults: in
  `ci_node.sh`, `ci_python.sh` and both legs of `ci_security.sh`. The `gradle`
  and `flutter` ones name images this change does not touch. A comment
  recording a measurement against an image the helper no longer uses is worse
  than none: it reads as evidence.

### Fixed

- **`ci_wp_plugin_check.sh` threw away every plugin-check result (#88).**
  `wp plugin check --format=json` does not emit one JSON document. It emits one
  section per file:

  ```
  FILE: includes/foo.php
  [{"line":33,"column":13,"type":"WARNING","code":"...","message":"..."}]
  FILE: includes/bar.php
  [...]
  ```

  The report block read the whole file with `json.loads`, so every run that had
  findings ended with `plugin-check.json is not valid JSON` and exit 5. The
  checks had run and produced results; the helper reported a parse failure
  instead of them. Both the plugin slug and the plugin basename produce this
  format, so no caller could avoid it.

  Second defect in the same block: the whole-document fallback did
  `error_count += len(data)`, counting every entry as an error. On the plugin
  this was reproduced against that is 58 errors where there are 8; the other 50
  are warnings. Entries are now counted by severity, and warnings are reported
  without failing the build.

  Against that plugin the helper now exits 4 with

  ```
  Plugin checks reported 8 error(s), 50 warning(s) across 12 file(s)
  ```

  where it previously exited 5 having parsed nothing.

  `tests/ci_wp_plugin_check_report_test.sh` extracts the report block from the
  script rather than retyping it, and asserts against a fixture of real output
  from a twelve-file plugin, with the names replaced. It also asserts that
  malformed input is still a parse failure: a parser that swallows everything
  would be worse than the bug it replaces.

  Two more found reviewing this change. Parsing sections lazily turned an empty
  `plugin-check.json` into `No plugin-check errors detected` and exit 0, where
  reading the whole file as JSON had exited 5: a checker that produced nothing
  would have read as a clean run. And `out_dir` was only created, never
  cleared, so a run whose check produced no output left the previous run's
  report in place to be parsed and reported as its own. Both now fail, and both
  have a test that was checked by breaking it.

  Two smaller ones from the same review. A section body that is not a list was
  counted by iterating it, so a three-key object reported three errors; it is
  refused by name instead. And a section that failed to parse fell through to
  the whole-document branch, printing a second, misleading message about the
  first line not being JSON; one failure now reports once.


- **`ci_wp_plugin_check.sh` passed WP-CLI an argument it does not have (#81).**
  Four `wp` invocations used `wp --config=<path>`, which WP-CLI refuses before
  running anything:

  ```
  $ wp --config=/tmp/wp-cli.yml core version
  Error: Parameter errors:
   unknown --config parameter
  ```

  The supported mechanism is `WP_CLI_CONFIG_PATH`, which the helper already
  exported on every `docker run` while also passing the argument that broke it.
  Dropping the argument is the whole fix.

  Not every command surfaces it: `wp cli version` accepts `--config` without
  complaint, which is why this survived and why the new smoke test runs
  `wp core version`.

  `tests/ci_wp_plugin_check_test.sh` extracts the payload the helper actually
  ships and runs it in `wordpress:cli`, so editing the helper cannot leave the
  test passing against old text. It also asserts every invocation that writes a
  config file exports the path to it: removing `--config` without that would
  trade a loud failure for a silent one, with WP-CLI quietly using defaults.

  Two defects in that test, both found by CI rather than by reading it. It
  failed the macOS leg, which has no Docker daemon, where the repository's
  convention is to skip; the smoke test is still enforced on the Linux leg,
  which has one. And it matched the expected error with a BRE using `\|`,
  which BSD grep reads literally rather than as alternation, so on macOS the
  assertion could never have matched and would have passed on any output.

- **Every other Docker helper handed the container a login shell too.**
  `ci_go.sh` was fixed alone; this is the audit of the rest. Each was run
  against its real default image on 2026-09-22 and the result recorded:

  | helper | image | survived `-lc` |
  |---|---|---|
  | `ci_node.sh` | `node:20-bullseye` | yes |
  | `ci_python.sh` | `python:3.11-slim` | yes |
  | `ci_gradle.sh` | `gradle:8.7-jdk17` | yes |
  | `ci_flutter.sh` | `ghcr.io/cirruslabs/flutter:3.38.8` | yes |
  | `ci_security.sh` | both of the above | yes |

  None were broken, so nothing was on fire. All are switched to `bash -c`
  anyway: they survived because their toolchains happen to sit in directories
  `/etc/profile` keeps, which is luck, and every one of these helpers takes an
  `--image` override where that luck does not apply. A container already has
  the environment its image set; a login shell there can only replace it.

  The audit's own list was short. It named four helpers, found by grepping for
  the `DOCKER_CMD+=(...)` shape. `ci_security.sh` builds its `docker run` inline
  and carries two more, which that grep could not see. Six call sites, not four.

  `tests/ci_docker_shell_test.sh` now reads the argv handed to `docker` rather
  than the command string, which is what let this survive the first time. It
  checks statically across every `scripts/ci_*.sh`, so a helper added later is
  covered without anyone remembering to add it, and dynamically per helper
  against a `docker` stand-in. An empty recording is a failure, not a pass.

  Reviewing that test found two holes in it. Its static check keyed on the
  literal `DOCKER_CMD`, so a helper assembling its argv under any other array
  name evaded it and the test still reported OK; it now keys on any `DOCKER`
  token. And it grepped for `bash` and for `-c` separately, which passes on an
  argv where the two are unrelated; it now requires `-c` to be the argument
  immediately after `bash`.

- **`ci_go.sh` could not run in Docker mode at all, in any consumer.** Two
  defects in one `docker run`, each hiding the next.

  It passed the command to `bash -lc`. A login shell sources `/etc/profile`,
  which replaces `PATH` with its own default, and the `golang` image keeps the
  toolchain in `/usr/local/go/bin` -- not in that default. Every run exited 127:

  ```
  docker run --rm golang:1.22 bash -c  'go version'  -> go version go1.22.12
  docker run --rm golang:1.22 bash -lc 'go version'  -> bash: go: command not found
  ```

  A container takes its environment from the image, so the login shell had
  nothing to add and one thing to destroy. The host path still uses `-l`, where
  a developer's own profile is what puts `go` on `PATH`.

  Fixing that revealed the second: the container runs as the host user, who has
  no home inside it, so `HOME` is `/` and Go's build cache lands at `/.cache`.

  ```
  failed to initialize build cache at /.cache/go-build: mkdir /.cache: permission denied
  ```

  `GOMODCACHE` had been redirected for this reason years ago; `GOCACHE` was
  missed, so the failure moved rather than went away. Both now point under
  `/tmp`, and both are mounted from the host: the build cache is the one that
  costs time, since compiling the dependency graph is most of a Go lint or test
  run. On a real module here, 13s with a cold build cache against 2s with a warm
  one.

  `tests/ci_go_test.sh` reads the argv handed to `docker`, not just the command
  string, and asserts the shell flag and both cache variables. No test read the
  argv before, which is why a helper that could never work looked fine.

## 2026-09-21 — v0.32.0

### Fixed

- **The check read the dictionary by column position, and the format grew a column.**
  The name list now carries `namespace`, so a positional parser matched namespaces
  instead of repository names — and reported *"no private repository is named"* over
  text that named one. A silent pass is the worst failure this check has. Columns are
  now located by the file's own `# visibility<TAB>namespace<TAB>…` header, which makes
  that particular mistake unrepresentable; a file without one is read as the documented
  v1 order, and a second header cannot redefine the columns (a generator briefly emitted
  two, and the later one shifted every field). Three regression tests pin all of it.

  The same bug was in the `--only-public` lookup, where it was worse than mis-reporting:
  that lookup decides whether the check runs at all, so it would have skipped every
  public repository whose name was not also a namespace.

- **Substring matching is gone; every name matches as a whole token.** Measured against a
  real dictionary of 1,488 names, substring matching produced **508 hits in one public
  repository** — almost all from an organisation repository named `.github`, which is
  GitHub's own convention for org-level files and a string in every workflow path. A
  token is not preceded or followed by a letter or digit, so `/` and `-` are still
  boundaries and a name is still caught inside a path, a URL or a possessive; what stops
  matching is a name inside a longer word. Same subject, zero hits.

- **Matching is two-stage, because one stage is unusably slow at that size.** A fixed-string
  filter first (0.58s over one repository, 86 candidate lines), then the real rule applied
  to the candidates in `awk`. The single-stage form — one `grep -E` with a boundary-anchored
  pattern per name — gives identical answers and took **over two minutes** on the same
  repository, because the cost is compiling 1,488 regexes rather than scanning.

- **`refresh_private_names.sh` no longer guesses whose repositories to list.** It took the
  owner from the current repository's `origin`, so a refresh run inside a third party's
  repository would rebuild the machine-wide dictionary from *their* namespace and silently
  drop your own names from every check. It now requires `--owner` (repeatable) or
  `PRIVATE_NAMES_OWNERS`, and covers any number of namespaces in one file.

- **The dictionary is written atomically, and `0600`.** It ended in `cp`, which truncates
  before writing: a reader in that window got a partial file, and one truncated mid-row
  reads as a short, complete list — the gate exits 0 over a list it never finished. It is
  now written to a temp file *beside* the destination (a rename across filesystems is a
  copy, and not atomic) and renamed, which also removes any need for a lock. It was being
  created at the ambient umask, world-readable on most systems, while listing private
  repositories.

- **The commit-message check read the wrong exit code.** `… | bash "$gate" --stdin` with
  `set -o pipefail` gave the *pipeline's* status: when `git log` failed — a shallow clone,
  or a remote ref never fetched — that was git's 128, the "found something" branch never
  fired, and the check silently did nothing while the push proceeded. The messages now go
  to a file and the gate is called on the file, and a failure to read them says so.

- **A non-numeric age no longer reads as "fresh".** `[[ "$age" -ge 5 ]]` resolves a
  non-numeric operand as a variable name, finds nothing and evaluates 0.

### Changed

- **The dictionary lives in the config directory, not the cache** —
  `${XDG_CONFIG_HOME:-~/.config}/script-helpers/private-names.tsv`. A cache is regenerable
  and disposable; this file may be maintained by hand, and it is the single documented
  location. The machine-level allowlist moves with it.

- **The format is v1 with five columns**: `visibility`, `namespace`, `name`, `code`,
  `flags`. `flags` is space-separated and carries `ambiguous` (also an everyday word),
  `never-name` (no acceptable public reference exists at all — the refusal says to remove
  it rather than offering a code) and `qualified-only` (a bare mention is not a reference;
  only `namespace/name` matches). A row whose `name` is `*` marks the namespace itself.

- **The agent hook now sees a command that is not first on the line.** It
  matched a publishing command only at the start of the shell line, so
  `cd repo && gh pr create --body ...` — the ordinary shape, not an exotic one —
  was never examined. The line is split on `&&`, `||`, `;`, `|` and `&`, and
  each command judged on its own, so a `--repo` belonging to a different command
  cannot be mistaken for the destination either. Its lexer also keeps `#`,
  which a body legitimately contains and which the default would have treated as
  a comment, reading half the text and calling the rest clean.

- **The baseline is gone, rather than fixed.** It existed to absorb the noise
  from names that are also everyday words, and became unnecessary once those
  are matched only as `namespace/name`. It was also wrong while it lasted:
  `--write-baseline` exited 0 with an unambiguous private name present, so the
  command a person runs to clear noise would have reported success over a real
  leak. A feature that now covers nothing invites being used for the one thing
  it must never do — grandfathering a live disclosure — so it was removed.

- **The name list is no longer read with `read`.** `IFS` set to a tab still
  collapses runs of delimiters, because a tab is whitespace, so a row with an
  empty column shifted every later field and could land a name in the wrong
  tier. `awk` splits on tabs without collapsing them.

- **A refusal names a repository by the same rule that matched it.** Attribution
  was a substring test even for the token tier, so it could name a repository
  whose name merely appears inside a longer word — the distinction that tier
  exists to draw.

- **Messages no longer print an absolute home path.** Paths are rendered with
  `$HOME` collapsed to `~`; these end up in CI logs and pasted into issues.

- **A missing `python3` makes the age unknowable, and the check says so.** It
  is what parses the `# generated:` header, so without it the dictionary's age
  cannot be read — which is reported as "could not check" rather than treated
  as fresh.

- **`lib/env.sh` parses a large value in about a second instead of five.**
  bash 3.2 -- the floor this library supports -- is quadratic in
  `${var%pattern}`. Measured on a 40KB value, stripping a trailing carriage
  return cost 4 seconds, the four stray-quote trims 8 seconds between them, and
  cutting a quoted value at its closing quote another 4. None of that work was
  necessary: a glob test and a substring say the same thing for nothing, and the
  one genuinely scanning step -- finding the closing quote -- goes to `awk`,
  whose `index()` is C-level, for values over 2KB. End to end that is 4-5
  seconds down to 0-1.

  The first attempt at this read `awk`'s output through `< <(...)`. Process
  substitution combined with `read` **hangs in a background job under bash 3.2**,
  so the parse never returned -- only from a background caller, only on the old
  shell. A here-document has neither problem.

- **`tests/env_test.sh`'s timeout could expire before any time passed.** It
  counted 50 iterations of `sleep 0.1`, and busybox's `sleep` ignores the
  fraction, so on the bash 3.2 image the whole budget elapsed instantly. It also
  tested liveness with `kill -0`, which **succeeds on a child that has exited
  and not been reaped** -- so a command that finished immediately still looked
  alive. Whether the test passed depended on when the shell happened to reap the
  child, which is what made it come and go. It now blocks on `wait` with a
  watchdog, and the failing direction is exercised: a 30-second command under a
  3-second budget returns the timeout status in 3 seconds.

  This mattered beyond the flake. With the budget honest, the original parser
  fails all three assertions -- the slowness was real, and the test that was
  supposed to catch it had been reporting whatever the scheduler decided.

### Added

- **`scripts/check_private_names.sh` — refuse text that names one of your
  private repositories, before it is published.** A public repository must never
  carry the name of a private one, and not only in its tree: commit messages,
  pull request and issue bodies and review replies all land publicly around it.
  Unlike most mistakes this one cannot be undone — GitHub keeps the edit history
  of every pull request and issue body publicly, and rewriting commits changes
  every tag — so the only version of the fix that works happens before the push.

  **The rule is about what becomes public**, so `--only-public` makes the check
  a no-op in a repository your list marks private: a private repository naming
  another private repository is fine. A repository the list has never heard of
  is checked rather than assumed private, since an unknown repository is most
  likely a new one, and that is exactly where a wrong guess would hide a leak.

  Matching is `grep -iF` and deliberately **not** `-w`: a hyphen is a word
  boundary, so `-w` misses a name inside a longer path or a possessive, which is
  how a name travels in real text. A name flagged `ambiguous` — one that is also
  an ordinary word — must appear as a whole token instead, so `beaconed` stops
  matching while `owner/beacon` still does. Measured on two real public
  repositories that is 8 matches rather than 28, all of them the English word,
  and one line in `.git/private-names-allow` silences them per repository.

  The first version of this instead skipped ambiguous names in the tree
  entirely. That was wrong in the direction that matters: the exemption
  swallowed a real leak — a path naming a private repository, written into the
  gate's own source, which the gate then declared the tree clean of. An
  exemption you cannot see is not a quieter gate, it is a blind one.

  A missing or empty list exits `2`, never `0`. A check that scanned nothing and
  reported success is worse than no check, because the green line is taken as
  evidence. A *stale* list still checks and merely says its age: refusing a push
  because a file is old punishes the wrong thing.

- **`scripts/refresh_private_names.sh` — build that list from your own account.**
  `gh repo list <owner>` into
  `${XDG_CACHE_HOME:-~/.cache}/script-helpers/private-names.tsv`: one file per
  machine, outside every working tree, because a file listing your private
  repositories is precisely what the gate exists to keep out of public ones.
  Exit `3` when `gh` is missing or unauthenticated, distinctly from exit `2`
  when the account has no private repositories — in which case nothing is
  written, rather than leaving a list that would check for nothing.

  This is the only part that touches the network. A check that called GitHub
  would add a round trip to every commit and push to catch an event — a
  repository created, or its visibility changed — that happens deliberately a
  few times a month.

- **Three hooks that call it, covering three different surfaces.** A new
  `commit-msg` hook checks the message: a `pre-commit` hook runs before the
  message exists and cannot see it. The shared `pre-push` hook checks the
  tracked tree and the messages of the commits actually being pushed, reading
  the ref lines from a captured copy since git only offers them once.

  And `scripts/claude-hooks/pretooluse_private_names.sh`, which is not a git
  hook: `gh pr create --body ...` never touches git, so no git hook can see a
  pull request body — the surface where this goes wrong in practice. It is a
  Claude Code `PreToolUse` hook that reads the title, body and message arguments
  of a publishing command and blocks the call before it runs. It inspects only
  the text being published, not the whole command line, so a pull request *into*
  a private repository — where its name belongs — is unaffected. It also refuses
  `--no-verify` on commit and push: an agent has no legitimate reason to skip a
  local gate, and a human at a terminal never sees this hook at all.

- **A name that is also an everyday word is matched only when qualified.** Matching those
  bare produced **50 hits in this repository alone** — prose and identifiers alike — and
  blocked a commit whose only sin was a shell function called `search()`. Requiring
  `namespace/name` takes the same tree to zero, and the coverage given up never existed: a
  bare "search" in English cannot be told from a reference to a repository of that name,
  which is precisely why it fired fifty times. The matcher applies the same rule to names
  of four characters or fewer, names beginning with a dot, and well-known directory names,
  **whatever the dictionary says** — whether a bare mention can be a reference is a
  property of the name, and a generator that forgot to flag a one-character repository
  should not be able to turn this check into noise.

  This removed the need for the baseline that an earlier draft of this change added, so
  the baseline is gone: it existed to absorb exactly those false positives, it now covers
  nothing, and a feature that covers nothing invites being used for the one thing it must
  never do — grandfathering a real private name, which would make a live disclosure
  permanent and quiet. The three overrides remain for genuine false positives.

- **An override, because the check will sometimes be wrong.**
  `PRIVATE_NAMES_ALLOW="term,term"` allows named terms for one run and prints
  which it allowed, so an override is never silent; `.git/private-names-allow`
  does the same per repository and lives inside `.git`, where it cannot be
  committed anywhere; and a file of the same name beside the cached list covers
  every repository on the machine. That last one is not a convenience: a name
  that is also everyday English recurs in prose everywhere, and a gate that must
  be re-appeased in every fresh clone is one somebody eventually removes. `--no-verify` remains
  git's own escape for a human.

  A refusal names only the repositories that actually matched. Printing the
  whole list on every hit would put your entire private inventory into a
  terminal, a CI log or a pasted error — publishing by accident the thing the
  gate exists to keep unpublished.

## 2026-09-19 — v0.31.0

### Fixed

- **This repository could not cut a release candidate.** `release-version-check.yml`
  validated the branch name with its own inline pattern, `^[0-9]+\.[0-9]+\.[0-9]+$`,
  which rejects `release/X.Y.Z-rcN`. Every other definition in the repository
  accepts one — `scripts/check_release_version.sh`, the pre-commit hook,
  `check_release_tag.sh`, `check_changelog_section.sh`, and the version pattern
  ci-helpers tags from. The gate that blocked candidates was the single copy
  that had drifted, and it only surfaced when a candidate was first cut here.

  The workflow now calls `scripts/check_release_version.sh` instead of
  restating the rules, so there is one definition. The script also checks more
  than the inline copy did: that the tag does not already exist, and that an rc
  whose base tag exists is flagged.

- **A malformed release branch asserted nothing and reported success.**
  `check_release_version.sh` put every assertion inside its
  `release/X.Y.Z[-rcN]` match, so `release/oops` fell through the whole script
  and exited 0. The inline workflow copy happened to reject it, so replacing
  that copy would have silently removed the only check on it. A branch that
  announces itself as a release and then does not parse now fails, in CI and in
  the pre-commit hook alike.

### Fixed

- **The `production` branch would have followed a release candidate.** The
  version pattern accepts `release/X.Y.Z-rcN`, and the job that moves
  `production` was gated only on the version being non-empty — so cutting a
  candidate here would have moved the branch onto it. Consumers track that
  branch directly (`git submodule add -b production`), so a candidate would
  have reached every consumer that updated its submodule.

  This is the same defect ci-helpers just fixed for its floating `production`
  tag. That fix does not cover this, because this repository moves the branch
  itself, in its own job, rather than delegating it — so it needed the rule in
  both places. It was found by preparing to cut a candidate here, which no
  release in this repository has ever done.

  A candidate merge now tags and emits a `::notice::` naming the promotion
  branch, leaving `production` where it is.

### Fixed

- **`actions/checkout` was unpinned, on a runtime that is being removed.** All
  five uses across four workflows said `@v4` — a mutable tag, so what actually
  ran was whatever that tag pointed at on the day. `v4` also declares
  `using: node20`, and Node 20 actions are removed as of September 2026.

  Pinned to `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1`
  (`v7.0.1`, `node24`) with a dated comment, matching the convention and the
  exact SHA already in use in ci-helpers.

  The `nikolareljin/ci-helpers/...@production` references are deliberately left
  floating: consumers track that ref by design, and pinning it to a SHA is the
  opposite of what it is for.

- **`scripts/pin_production.sh` could not roll back, and said it had.** Rolling
  `production` back to an earlier tag was documented in two places as a
  supported use. The move was `git merge --ff-only "$TAG"`, and when the target
  is an *ancestor* of `production` that reports `Already up to date` and exits
  `0`. The script pushed nothing of consequence and printed
  `production now points to tag <tag>`. Exit 0, success message, `production`
  untouched — the operator had to notice unaided that the rollback had not
  happened.

  A backward or diverged move is now named rather than silently attempted:

  ```bash
  scripts/pin_production.sh 0.9.0 --allow-rewind
  ```

  Without the flag such a move is **refused**, with a message saying which case
  it is and what to pass. The rewind pushes with
  `--force-with-lease=refs/heads/production:<sha just read>`, so a concurrent
  move by someone else aborts this one instead of being overwritten by it.

  **Release automation never passes `--allow-rewind`.** Rolling `production`
  back is a deliberate act by a person in the repository that needs it, not
  something an unattended release run can decide to do.

  Also here, because the same lines were involved:

  - **The result is read back from the remote before anything claims success.**
    `git push` exiting `0` is not evidence that the branch arrived where it was
    asked to go.
  - **`.github/workflows/auto-tag-release.yml` now calls the script** instead of
    repeating the move inline. The two copies had already drifted into carrying
    the same `--ff-only` defect in two places.
  - **The move no longer touches the working tree.** It is a refspec push, so
    the script no longer runs `git checkout -B production`, which left the
    caller standing on a local `production` branch as a side effect, and no
    longer needs to refuse a dirty tree.
  - **It acts on the repository the caller is standing in**, not on the one the
    script lives in, and says which repository and remote it is about to touch
    before it touches them. Consumers vendor script-helpers as a submodule, so
    resolving the target from the script's own path meant running the vendored
    copy from a consumer repository targeted *script-helpers itself* — which,
    now that `--allow-rewind` can force-move a branch, would have rewound the
    library's own `production` and broken every downstream consumer while
    reporting success. `--repo <path>` overrides.
  - **An option given without a value is a usage error.** `--remote` or
    `--branch` as the last argument hit `shift 2` with one argument left, which
    returns non-zero and, under `set -e`, ended the script with exit 1 and *no
    output whatsoever* — indistinguishable from a deliberate refusal.
  - **A refused move exits `3`**, distinct from `1` (an error) and `2` (bad
    arguments), so a wrapper can tell "this needs a human decision" from
    "something is broken".
  - The move summary labels the pre-move SHA `before` rather than `is now`. On
    the moving path it was printing a stale value in the present tense — the
    same class of defect as the one above.
  - New options `--dry-run`, `--remote`, `--branch`, `--repo`; `main`, `master`
    and `HEAD` are refused as targets.
  - `tests/pin_production_test.sh` covers all of it in 13 cases. **16
    assertions fail against the previous implementation**, including one that
    names the silent no-op directly. Several of those failures are downstream
    of the old implementation checking out `production`, which in the fixture
    predates the script's own commit and so removed the script from the working
    tree mid-run — a vivid demonstration of the side effect this change
    removes. Assertions are on observed state and on the message text, not on
    exit codes alone: a test that checked only the forward move, or only a
    non-zero exit, passes against the bug.

- **An upstream git submodule was detected as a project to lint, test and
  install into.** Sibling detection removed the clause that had been hiding
  them, and the two filters in place did not cover a submodule: `_is_pruned`
  does not name it, and `check-ignore` correctly answers "not ignored" because
  a submodule path is *tracked*.

  One repository began reporting an upstream library as a Python project. Since
  `preflight` is the pre-push hook, that means building a virtualenv **inside
  the submodule working tree** and installing upstream's dependencies, then
  linting and testing code that is not ours — dirtying the superproject, taking
  minutes and failing, so the push is refused on a repository whose own code is
  fine. The predictable response is `--no-verify`, which disarms the gate
  entirely.

  A submodule worktree has `.git` as a *file* rather than a directory, so the
  test needs no subprocess.

- **A Flutter app at the repository root swallowed every Gradle project in the
  tree.** The Flutter/Gradle pass carried the same `"$other" == "."` clause that
  was removed from the same-stack pass — so a standalone `wear/` or
  `automotive/` module was never linted, tested or assembled, and the run still
  reported PASS. A Flutter app owns its own `android/` tree and nothing else.

- **The ignore filter reached one detection loop but not the other.** Podfiles
  were filtered only by `_is_pruned`, so a gitignored stale copy returned as an
  `ios` project — and an `ios` check is an Xcode build, the slowest step in a
  run. This was a regression: before sibling detection was fixed, the buggy
  clause happened to drop it.

- **`"workspaces"` appearing as a value was read as a workspace declaration.**
  The test was a substring `grep`, so `"keywords": ["monorepo", "workspaces"]`
  in a repository with no workspace at all would drop every sibling package
  silently — the exact failure the sibling fix exists to prevent. It is now a
  top-level-key test that reads depth at the key's position, which also handles
  compact single-line JSON. The Cargo equivalent now accepts an indented
  `[workspace]`, which cargo accepts, and ignores the table name inside a
  string.

### Changed

- **`./dev` now detects once per invocation in Flutter repositories too.** The
  previous entry's "five down to one" held only where the repository root was
  *not* a Flutter app. `dev_is_flutter` tested for `pubspec.yaml` first, so at a
  Flutter root it short-circuited, the detector never ran in the parent shell,
  and the first call landed inside a command substitution — the subshell the
  code's own comment warns about — where the cache is discarded. Measured 2
  detections where the entry claimed 1. Asking the detector first makes the
  invariant unconditional; measured at 1 in both repository shapes.

### Fixed

- **`preflight.sh` silently dropped sibling projects, so whole services were
  never checked.** The dedupe pass removes a project that another one builds —
  right for a Cargo workspace member or a package inside an npm workspace. Its
  condition also contained `"$odir" == "."`, which dropped **every** project of
  a stack whenever one of them sat at the repository root, nesting or not.

  Measured across the fleet it affected **twelve repositories**. In the worst
  case a repository with a root `requirements.txt`, a Django admin, a FastAPI
  service and a frontend reported two projects out of four: the admin and the
  API were never linted or tested, and the run reported PASS. Another reported
  one Go module where five exist.

  A project is now dropped only when the outer project's build system genuinely
  builds it — a pnpm or npm workspace root, a Cargo `[workspace]`. Nothing else
  qualifies: a directory merely containing another is not a build relationship,
  and Go modules are independent build units however they nest.

  The distinction matters in both directions. Six of those twelve are real
  workspaces, and simply deleting the faulty clause would have turned one
  repository's single Node check into twenty-one and another's single Rust check
  into nine — running the same tests many times over. The workspace test is
  deliberately loose: it asks whether the outer project declares a workspace at
  all, not whether the inner one matches its globs, because every workspace here
  nests its members, so the looser rule leaves them behaving exactly as before.

  Both directions are asserted: the fixture that reproduces the bug and the
  workspace fixtures that must still collapse. Four of the new cases fail
  against the previous implementation.

- **A directory the repository ignores is no longer detected as a project.**
  Once sibling projects stopped being dropped, a stale copy left beside a real
  one became visible — one repository has a gitignored duplicate of itself
  holding a second `go.mod`. Detection now asks git, and treats every answer
  other than "ignored" as "not ignored", so a missing or failing git detects one
  project too many rather than silently dropping a real one.

### Changed

- **`./dev` detects once per invocation instead of once per question.**
  `dev_projects` was re-running the detector for every caller: `./dev install`
  alone spawned **five** `preflight.sh` subprocesses — `dev_is_flutter`, then
  `dev_has_stack` and `dev_stack_dir` for python and node — to answer one
  question. It is now detected once and cached, measured at five invocations
  down to one.

  The cache required changing the two callers, not just adding the cache.
  `dev_has_stack` piped `dev_projects` into `grep` and `dev_stack_dir` captured
  it in a command substitution — both run it in a subshell, where the cache it
  fills is discarded on exit, so the memoization would have done nothing. They
  now match the cached value in the current shell, which also removes the `grep`
  and `awk` each call used to spawn.

## 2026-09-17 — v0.30.0

### Added

- **A documentation site, built from `docs/` in place.** MkDocs Material renders
  the existing markdown tree — there is no second copy of the content to rot.
  `make docs-serve` for live reload while writing, `make docs-preview` to serve
  the built output, `make docs-check` to validate without a server.

  `preview` and `serve` are deliberately different things. lunr fetches
  `search_index.json` over HTTP, so opening `site/index.html` from a `file://`
  URL gives a site whose search silently finds nothing. Only `preview` — a real
  HTTP server over the built output, through the existing `bin/serve-pages` —
  exercises the link rewriting and the search index the way a visitor does.
  That finally makes `docs/modules/serve.md`'s claim about previewing "a GitHub
  Pages build output" literally true.

- **`mkdocs build --strict` is the link checker.** A moved page, a dead anchor,
  or a new `docs/modules/*.md` that nobody added to the nav all fail the build.
  `make lint-docs` checks that every module is documented; it cannot see the
  nav, so the two gates cover different halves and `AGENTS.md` now says so.

- **A `cloudflare` module, and `./dev deploy cloudflare`.** Deploying a Worker
  needs the same eight steps every time -- prove the credentials, resolve the
  account, build, derive the generated deploy config, compute a version string,
  run wrangler, then check what is actually live -- and every project that has
  done it has written those steps twice: once in a shell script for a laptop
  and once in a CI job. The two copies then drift, and the drift is invisible
  until a release goes out with the wrong version stamped on it.

  `cloudflare_deploy` is the one sequence. `./dev deploy cloudflare` passes its
  options straight through, and a CI job runs the same function as its deploy
  command. Where CI has already decided a value it exports it -- `CF_DEPLOY_VERSION`,
  `CF_DEPLOY_BASE_URL` -- and the matching function returns it verbatim rather
  than computing a second answer. A single run never holds two live definitions.

- **The account id is checked, not assumed.** An empty account id is not an
  error to wrangler: it falls back to resolving the account from the token,
  which is correct for a token scoped to one account and a coin toss otherwise.
  A deploy that lands on the wrong account looks exactly like a deploy that
  worked, so `cloudflare_account_id` fails loudly and names both places it
  looked.

- **The smoke test asserts a version, not a status code.** Reachability proves
  something answers; it does not prove the deploy took effect. Without the
  version assertion a smoke test passes against the previous release, which is
  the one failure it exists to catch -- so a reachability-only run says so in a
  warning rather than reporting a clean pass.

- **A protected environment refuses rather than waits.** `production` asks the
  operator to type its name. With no terminal on stdin it returns `5`
  immediately instead of blocking on a read nobody can answer: an unattended
  job that hangs to its timeout is worse than one that says what it needed.
  `--yes` or `CLOUDFLARE_DEPLOY_YES=1` is the deliberate way past it.

- **Two safety properties, each with a test that fails without them.** A
  value-taking option with nothing after it returns `2` and says which option
  needed a value: `shift 2` when only one positional remains returns non-zero
  and shifts nothing, so the naive parser spun forever — and under
  `set -euo pipefail`, which is what `./dev` runs, died with no message at all.
  And the protected-environment list is read with globbing disabled, so it is
  matched literally; unquoted, a list entry was subject to pathname expansion
  and the same configuration gave different answers depending on what files
  happened to be in the working directory. A safety gate whose behaviour
  depends on the current directory is worse than no gate.

- **`CI_DEFAULT_WRANGLER_VERSION`**, the version handed to `npx` when a project
  has no wrangler of its own. A project with a lockfile gets the version it was
  tested against instead, which is always the better answer; this is the floor
  for projects that have none.

### Fixed

- **`docs/README.md`'s links were broken on GitHub, not only on the site.** Six
  references were written `./docs/installation.md` from inside `docs/`, which
  resolves to `docs/docs/installation.md`. They were plain text rather than
  links, which is the only reason nobody had clicked one and noticed.
- **`docs/api.md` was an index with no links.** All 36 entries are now markdown
  links. That required widening the pattern in `scripts/lint_docs.sh`: the
  original demanded whitespace between the module name and the path, and every
  markdown link form puts `](` there instead — there was no link syntax that
  satisfied it. Both forms are accepted now, and `tests/lint_docs_test.sh`
  pins that, including that the linter still *rejects* non-entries. A linter
  that matches everything is indistinguishable from one that works, right up
  until something ships undocumented.
- **`docs/modules/git_branches.md` linked outside the docs tree** (`../../scripts/…`),
  which a site build cannot resolve. It points at the file on GitHub now.

### Notes

- Cloudflare Pages is reachable as an input combination
  (`--command "pages deploy"`), not as a separate code path. The Workers path is
  the one exercised end to end, and the module doc says so rather than implying
  parity.
- No PowerShell mirror ships for this module. Nothing in the suite enforces
  Bash/PowerShell parity, `ps/lib/` already omits several modules, and a second
  wrangler invocation for a platform nobody deploys Workers from would be two
  implementations of the thing this module exists to stop being two
  implementations.

## 2026-09-15 — v0.29.1

### Fixed
- **`android_package_name` returns the package under `pipefail`.** 0.29.0 read
  the badging dump with `grep -m1`, which exits at the first match while
  `aapt2` is still writing. `aapt2` then died of SIGPIPE, a caller running with
  `pipefail` (the dev-CLI template does) saw the pipeline fail, and the package
  came back empty, so the build-file fallback -- which ignores
  `applicationIdSuffix` -- was used and `./dev deploy` verified the wrong
  package. The whole dump is now read. The test uses a dump long enough to fill
  the pipe buffer, so the failure is deterministic instead of an occasional
  macOS CI failure.

## 2026-09-14 — v0.29.0

A security and correctness pass over the library, the scripts and the dev-CLI
template. No function, script option, environment variable or output format was
removed or renamed. Where a function now refuses input it used to accept, that
input was already producing a wrong or unsafe result; those cases are listed
under **Changed**.

### Security
- **`hub_write_env` can no longer be made to write shell code.** The file it
  writes is sourced by `load_env`, and `HUB_INSTANCE_ID` comes from the remote
  hub's `/v1/service` reply, so a reply of `"instance_id": "i1;touch x"` ran
  that command on the next load. Values went to awk with `-v`, which also turned
  a literal `\n` into a real newline. Values now travel through `ENVIRON`; a
  value made of URL, key, id and path characters is written bare exactly as
  before, anything else is quoted so the shell and dotenv read it literally, and
  a value neither can read the same way is refused. `hub_setup_dialog` does not
  record an `instance_id` outside `[A-Za-z0-9._:-]`. A new env file is created
  `0600`.
- **API keys and signing passwords are kept out of the process list.**
  `hub_check_key` hands the key to curl on stdin (`-K -`), `android_sign` passes
  jarsigner's passwords as `-storepass:env`/`-keypass:env`, and
  `pkg_build_source_package` gives gpg a `0600` passphrase file that is removed
  on every exit. A passphrase containing spaces now works.
- **`publish_homebrew.sh` keeps the tap token out of the clone URL, argv of git
  and the trace.** The token was in `git clone`'s arguments, and a `set -x`
  meant to restore tracing switched it on for the rest of the script. The token
  now reaches git as an HTTP header in git's environment config, sent exactly
  once even when the caller already configured one (a second Authorization
  header is rejected); tracing is paused while the token is read and restored to
  the caller's state. Prefer `HOMEBREW_TAP_TOKEN` over `--tap-token`, which is
  visible in `ps`.
- **`add_to_etc_hosts` validates the hostname and address** (and so do the
  PowerShell `add_hosts_entry`/`remove_hosts_entry`). A newline in either wrote
  a second hosts entry, often through `sudo` or an elevated shell.
- **`build_brew_tarball.sh` never packs `.git`, `.env` files or its own earlier
  tarballs.** Committed templates (`.env.example`, `.sample`, `.template`,
  `.dist`) are still included.
- **`verify_checksum` checks the file it was given.** It ran `-c` over the whole
  list and passed if any entry said OK, including a list that did not mention
  the file.
- **`download_file` fails on an HTTP error** instead of saving the error page as
  the download. It downloads to a temporary file beside the destination, so a
  failed download leaves an existing file untouched, and a successful one over an
  existing file keeps its mode and a symlink.
- **`ollama_update_env` keeps the file's mode and a symlinked `.env`** (a `0600`
  `.env` came back `0644`, and a symlink was replaced by a regular file), matches
  the key literally, and refuses a newline in the key or value.
- **The pre-commit hook's `.env` block reads paths unquoted,** so a `.env` under a
  directory with non-ASCII characters, a tab or a quote is blocked too.

### Fixed
- **`git_branches_merge_state` no longer calls a branch squash-merged when a
  whitespace-only commit landed after the merge.** `git cherry` ignores
  whitespace, so a re-indent (which changes Python or YAML) was treated as
  already on the base and `prune_branches.sh` deleted it. The match is now
  confirmed byte for byte: with `git patch-id --verbatim` on git 2.39+, and by
  hashing normalised patches on older git. Only base commits touching the
  branch's paths are compared, so a repository with a long, binary-heavy history
  is not diffed commit by commit. A match `git cherry` finds but the byte-exact
  check does not confirm is `unknown` (kept), not `unmerged`.
- **`prune_branches.sh --remote --apply` leases every deletion on the tip it
  classified, and refuses to run on refs it did not fetch** (`--no-fetch`, or a
  failed fetch). A branch that gained commits on the remote is kept.
- **`manifest_sync_version` no longer rewrites a vendored submodule's
  `VERSION`.** Anything below a directory with its own `.git`, or below a path
  in `.gitmodules`, is skipped.
- **`manifest_write_version`** writes a pubspec `1.4.0+46` as given instead of
  `1.4.0+46+45`, escapes `&`, `|` and `\` in the version, validates `--build`,
  and warns when a Flutter Gradle file (`flutter.versionName`) has no literal to
  rewrite. `manifest_sync_version` logs when no manifest was found.
- **`android_package_name` returns the package name on current build-tools.**
  It returned the compileSdk codename (`15`, `16`, …), the last `name='…'` on
  the badging line. SDK roots with
  spaces in the path are found.
- **The port checks work under mawk and BSD awk.** They used gawk's
  three-argument `match()`, a syntax error elsewhere, so where the `ss` parser
  was reached (no usable `lsof` or `netstat`, e.g. a non-root check of a root
  listener without net-tools) a port in use was reported free. `fuser` output
  with several PIDs is split, and a port range is refused instead of matching
  every listener.
- **`ollama_prepare_models_index` and `ollama_runtime_type` print only their
  result on stdout.** Progress and warnings were captured as part of the path.
  A failed sort of the index fails instead of leaving a `.tmp` behind.
- **`resolve_env_value`** keeps everything after the first `=` (base64 padding
  and URL query strings were cut), keeps `#` inside quotes and in `ab#cd`, and
  no longer loses `-n`, backslashes or apostrophes.
- **`load_env` leaves `allexport` on when the caller had it on.**
- **`json_escape`** escapes double quotes (it never did) and every control
  character, and prints `-n` and `-e`.
- **`wait_for_service` sees a running service on Compose v2,** which says `Up`,
  not `running`.
- **`changelog_extract`** ignores `##` lines inside fenced code blocks
  (CommonMark fences; an unclosed fence is plain text, so it cannot hide every
  older section) and uses only the first version in a header, skipping a dotted
  date; two-part versions such as `## [1.2]` still match.
- **`version_compare`** reads `08` and `010` as decimal.
- **`publish_homebrew.sh` publishes a formula the tap has never had.** An
  untracked file was invisible to `git diff`, so the first publish reported
  "already up to date".
- **`preflight.sh`** exits 2 on a misspelled stack in `.preflight` (valid lines
  before it used to run and the rest was dropped) and on `--stack` or `--dir`
  with no value, which looped forever; a last `.preflight` line without a
  trailing newline is read.
- **Options with no value no longer hang.** `adb_install_verified`,
  `android_sign`, `android_emulator_start`, the `screencap_*` functions,
  `changelog_new_section`, `manifest_*` and `flutter_build` return 2 when a
  value-taking option is the last argument.
- **Empty arrays under `set -u` on bash 3.2** in `screencap`, `flutter`,
  `run_docker_compose_command` and the `pkg_*` list helpers.
- **The dev-CLI template** keeps an option's value with its flag
  (`./dev preflight --stack ios` no longer takes `ios` as the target), does not
  take a following option as the value (`--stack --help`), and finds nested
  projects under `CI=true`.
- **The pre-commit hook allows `.env.example`, `.env.sample`, `.env.template`
  and `.env.dist`**; real `.env` files are still blocked.
- **`packaging_init.sh` and `render_brew_formula.sh`** substitute values
  literally, so `&` and `\` survive; `render_brew_formula.sh` refuses an empty
  or placeholder `sha256`.
- **`packaging_init.sh` and `render_brew_formula.sh` run on macOS.** Their
  awk values went in with `-v`, which the original awk macOS ships rejects
  for a multi-line value (`newline in string`), and `packaging_init.sh` used
  `date -R`, which BSD `date` does not have. Values now reach awk through
  `ENVIRON`, and the changelog date is formatted explicitly (RFC 2822, UTC,
  C locale).
- **`gen_brew_formula.sh`** puts each `depends_on` on its own line (the formula
  was invalid Ruby with more than one).
- **`ci_python.sh`** joins its Docker steps with `&&`.
- **`android_sign`** removes the decoded keystore when signing fails.
- **`pkg_find_changes_file`** picks the package's own
  `<source>_<version>_source.changes`, refuses another package's `.changes` when
  the source name is known, and refuses to guess between several. The passphrase
  file is also removed on INT/TERM.
- **`gradle_assemble`** capitalizes the variant (in the C locale).
- **`add_hosts_entry` and `remove_hosts_entry` (PowerShell)** require a
  non-blank domain; an empty one removed every aligned hosts line.
- **`python_pick_3`** no longer overwrites the caller's `candidate`.
- **`verify_checksum` with `shasum`** picks the algorithm from the digest length;
  plain `shasum` is SHA-1, so SHA-256/512 lists failed.
- **`hub_check_key`** accepts whitespace before a Content-Type parameter
  (`application/json ; charset=utf-8`).
- **`resolve_env_value`** parses a long quoted value in linear time.

### Changed
- **Inputs that used to produce a wrong result and now return an error:** a
  hub reply without `name` or `version`, or a non-JSON 200 to the key check
  (`hub_setup_dialog` also returns 1 when the env file's directory does not
  exist); a hosts entry with an invalid name or address; a `hub_write_env` value
  that the shell, dotenv and Compose would not read the same way (for example a
  trailing backslash or `${`); a newline in an `ollama_update_env` key or value;
  an invalid port (empty, `0`, above 65535, a range) passed to the port
  functions, which return 1; an invalid `manifest_write_version --build` (2); an
  ambiguous or foreign `.changes` file; `render_brew_formula.sh` without a real
  `sha256`; `download_file` returns curl's error on an HTTP error (for example
  22 on a 404).
- **Scripts that now stop instead of continuing:** `prune_branches.sh --remote
  --apply` exits 1 with `--no-fetch` or after a failed fetch; `preflight.sh`
  exits 2 on a misspelled `.preflight` stack.
- **Different output:** `build_brew_tarball.sh` leaves out `.git`, `.env` and
  `.env.*` other than committed templates, so a tarball built without excludes
  changes (and its sha256); `resolve_env_value` returns the full value where it
  used to truncate (after the last `=`, at a `#`, or through `xargs`);
  `git_branches_merge_state` reports `unknown` instead of `unmerged` for a patch
  that landed apart from whitespace; `./dev` build/install/clean act on nested
  projects under `CI=true`.
- **`flutter.md`** documents the SDK lookup order the code actually uses:
  `PATH`, then `FLUTTER_ROOT`, then `FLUTTER_HOME`.

## 2026-09-12 — v0.28.0

### Fixed
- **`changelog_extract` returned the wrong version's section.** The header match
  was `index(line, want) > 0`, a plain substring test, so asking for `0.2.0`
  selected a `## 2026-09-10 — v10.2.0` header — `10.2.0` contains `0.2.0` — and
  the release notes for one version were silently the body of another. A version
  now has to match whole: the character before it must not be a digit or a dot,
  and the character after it must not be anything a version continues with — a
  digit, a letter, `.`, `-` or `+` — so `0.2.0` also no longer selects a
  `v0.2.0-rc.1` section. Every regex metacharacter in the version is escaped, not
  only the dots, so `1.0.0+build.1` matches its own header. The pattern reaches
  awk through `ENVIRON` rather than `-v`, because `-v` processes escape sequences
  and turned `0\.2\.0` back into `0.2.0` — unescaped, plus a warning on every run.
  `YYYY-MM-DD — vX.Y.Z`, `[X.Y.Z] - YYYY-MM-DD` and a bare version all still
  match.

  Finding a section and extracting it are now one awk pass. They were two
  regexes, and the second only accepted a bare `## X.Y.Z` header because GNU grep
  lets `^` match mid-pattern.

- **`changelog_new_section` skipped a version it was a substring of.** Its "already
  has a section" test was the same substring match, so with a `v10.2.0` section
  present, adding `0.2.0` logged success, returned 0 and wrote nothing. It uses the
  same whole-version rule as `changelog_extract`.

- **The PowerShell mirror had both bugs, and CI could not see them.**
  `ps/lib/changelog.ps1` still matched with `$line.Contains($bare)`, and its
  `changelog_new_section` check had no leading boundary, so `0.2.0` selected and
  was shadowed by `v10.2.0` there too. It now uses the same whole-version rule.
  CI only parsed and imported the PowerShell files, so it now also runs
  `ps/tests/*_test.ps1`; `ps/tests/changelog_test.ps1` fails on the old mirror.

### Added
- **`scripts/release_notes.sh` — one implementation of the release body.**
  The CHANGELOG section for the version if there is one; otherwise the commit
  subjects since the **previous** tag; otherwise, for a first release, the whole
  history.

  The previous tag is found with `git describe --tags --abbrev=0 --exclude
  "$TAG"`, restricted to version-shaped tags, and that `--exclude` is the whole
  point. `ci-helpers` inlined the same generator into three workflows, each
  resolving the start of the range with a bare `git describe --tags --abbrev=0`
  run from a checkout **of the tag being released** — which returns the tag it is
  standing on. The range was always
  `X..X`, always empty, and every release body was the literal
  `* No changes listed.`; nine repositories and four years of releases say so.
  The composite action those three were inlined from took a `since_tag` input and
  did not have the bug. `--exclude` rather than `"$TAG^"`: `^` fails on a tag at a
  root commit and silently follows only the first parent of a merge.

  There is no bare placeholder. When nothing is found the body names the version
  and the source that was consulted, because "this release changed nothing", "the
  range was computed wrongly" and "nobody wrote a changelog entry" must not print
  the same sentence.

  The ways the range could still come out empty or wrong are closed too. Floating
  tags such as `production`, which sit on the release commit, are not taken for
  the previous release. A `vX.Y.Z` tag is used when `--tag` is not given. A
  shallow clone, which `actions/checkout` produces by default, makes the commit
  fallback exit 1 and name `fetch-depth: 0` instead of presenting one commit as a
  first release, and a failing `git log` is an error rather than an empty body.
  `--output` is relative to the caller, not to `--repo`. An option with no value
  or a malformed `--version` returns 2 with a message, in both scripts.

  A CHANGELOG section with no entries is not used as the body; the commits are,
  with a warning. For a final release, pre-release tags are not the previous
  release, so `0.2.0` is described from `0.1.0` rather than from `0.2.0-rc.1`; a
  pre-release is still described from the nearest version tag. A clone with no
  tags other than the release tag lists the whole history with a warning that
  the tags may not have been fetched, instead of calling it a first release.

- **`changelog_has_entries` — a section existing is not a release written up.**
  Returns 0 only when a section body has a line that is neither blank nor a
  heading. The template `changelog_new_section` writes, a header over four empty
  `###` headings, returns 1. That template is what `./dev release X` produces in
  consumer repositories.

- **`scripts/check_changelog_section.sh` — a release must have been written up.**
  On a `release/X.Y.Z` branch, fail when the CHANGELOG has no section for that
  version, or a section with no entries; a no-op anywhere else, so it is safe on
  every pull request. Checked only for existence, the untouched template passed
  and was then published as the release body: four headings and nothing else. Wired into
  `make lint-docs` beside `changelog_check_header`, which only ever inspected the
  newest header and so passed a release branch whose version was never described.

- **`tests/release_notes_test.sh`.** Fixture repositories covering a tag on HEAD
  (the regression, pinned directly), notes generated before the tag exists, the
  changelog winning over the range, a version absent from the changelog falling
  back, the prefix collision in both directions, a first release, an empty result,
  `--output` (including a relative path with `--repo`), floating tags, `v`-prefixed
  tags, a shallow clone, a clone without tags, pre-release tags before a final
  release, an empty template section, a failing `git log` (through a `git` shim,
  since nothing else reaches that branch), malformed arguments, and the gate's
  states including a pre-release section offered for the final version. Each
  guard was reverted in turn and the suite confirmed to fail on it; the `git log`
  guard had survived that until the shim test was added.

## 2026-09-10 — v0.27.0

### Fixed
- **`tests/portability_test.sh` — the portability gate could not see a non-Bash
  script.** Candidate files were filtered with `head -n1 "$f" | grep -q bash`,
  so a script whose first line did not contain the word never reached any check.
  That is exactly the set the shebang check below it exists to catch: `#!/bin/sh`,
  `#!/bin/zsh` and a file with no shebang at all were dropped before it ran, and
  the `shebang is not '#!/usr/bin/env bash'` branch could only ever fire on a
  shebang that already said bash. A gate blind to its own subject reports PASS
  for the case it was written for. Files are now classified by shebang, with a
  `*.sh` name standing in when there is none. The interpreter is compared by
  name rather than by a `*sh` suffix, because `pwsh` ends in one and this
  repository ships a PowerShell library — so do `tclsh` and `wish`. Anything the
  classifier cannot resolve to an interpreter — a bare `#!`, `#!/usr/bin/env`
  with no command, `env` carrying options (`-S`, `-i`, `-u VAR`,
  `--ignore-environment`, an assignment such as `env FOO=bar bash`) — is
  *included* rather than dropped, so the shebang check names it. A file with no
  shebang is included when its name says `.sh` *or* when it lives where the
  entry points live (`bin/`, the git hooks, `templates/dev-cli/dev`), since
  those are collected on purpose and were still being dropped — and the shebang
  check now errors on a file that has none at all, which is what those files
  were being kept for. The same locations are kept when the shebang names
  something else entirely: `templates/dev-cli/dev` as `#!/usr/bin/env python3`
  was dropped before the check that exists to say so. `rbash` counts
  as bash; `#! /bin/sh` with a space after the magic is a shebang, not an empty
  interpreter; and a `.sh` file whose shebang names python or perl is reported
  rather than dropped, since the name and the shebang disagree. Failing toward inspection is the whole point: every narrower
  version of this filter opened a new hole somewhere else. The scanned
  set is unchanged today (114 files) — the defect was latent, and would have
  been paid by whoever added the first `#!/bin/sh` script.

- **`lib/help.sh` — rendering help left a dozen variables in the caller.**
  `get_script_metadata` writes its results with `printf -v "${prefix}_${key}"`,
  which creates a *global* unless some frame already declares the name. Callers
  that pass their own prefix are choosing that; `_help__render` passes a fixed
  `_shlib_help_meta` prefix nobody asked for, so any script calling `show_help`,
  `display_help` or `print_help` silently gained `_shlib_help_meta_name`,
  `_shlib_help_meta_usage` and ten more — plus `line`, from an undeclared loop
  variable in `_help__print_block`. These libraries are sourced into other
  people's scripts, so each of those is a name that can quietly clobber theirs.
  Fixed by declaring the fixed field set `local` one frame above the call:
  bash locals are dynamically scoped, so the assignments land in that frame and
  disappear on return — no cleanup path to forget, and nothing newer than bash
  3.2, with the name list built from `_HELP_META_FIELDS` at both ends so a field
  added later cannot quietly start leaking again. `tests/scope_test.sh` now
  exercises the three renderers, not just the collector, which is why the leak
  survived a test written to catch exactly it.

- **`helpers.sh` — the bash-3 advisory told Linux hosts to use Homebrew.** The
  one-time note printed when the library loads under bash 3.x ended with
  "On macOS: brew install bash" regardless of where it was running, so a
  minimal container or an old enterprise Linux with a dated bash was pointed at
  a tool it does not have. The remedy is chosen by `$OSTYPE` now: Homebrew on
  macOS, the package manager elsewhere.

- **Three runners resolved the library root after `cd`-ing into the project.**
  `local_test_gradle.sh`, `local_test_python.sh` and `local_test_rust.sh` built
  a path from `${BASH_SOURCE[0]}` *after* changing directory. That variable
  holds whatever the caller typed — `scripts/local_test_rust.sh` for the
  documented invocation — so with any `--dir` the lookup went to
  `<project>/scripts/..` and the helper could not be sourced at all
  (`cd: scripts/..: No such file or directory`). Each resolves `SH_ROOT` before
  the first `cd` now.

- **`scripts/preflight.sh --dir <sub>` resolved its own later paths as
  `sub/sub/...`.** `PROJECT_DIR` was kept exactly as given, so after `cd`-ing
  into `sub` every later `"$PROJECT_DIR/$dir"` — the iOS stack's `pubspec.yaml`
  test, `in_dir`, the runner arguments — was built from a relative value that
  no longer meant anything from the new working directory. The runners happened
  to survive because they re-anchor a relative path on the git root; nothing
  else did, so a valid nested project was skipped or failed. `PROJECT_DIR` is
  absolute from the `cd` onward.

- **`scripts/local_test_bash32.sh` — the offline skip map named one test that
  needs git while four others use it.** `needs_for` was kept by hand, so
  `hub_test.sh`, `install_dev_cli_test.sh`, `portability_test.sh`,
  `runner_dir_test.sh` and `adb_wireless_test.sh` ran without git when the
  bootstrap could not reach the network and failed for a missing tool — under
  exactly the name this runner exists to keep off bash 3.2. The requirement is
  read out of each test file now, with comments stripped first so a tool named
  in prose is not mistaken for a dependency — a skipped test is lost coverage,
  the same failure pointed the other way. The hand-written case adds only what
  a scan cannot see: `apt-get`, which no test invokes but `docker_install`
  requires, and an opt-out for the portability gate, which runs git when it is
  there and falls back to `find` when it is not.

- **`scripts/install_dev_cli.sh` — `--shims dev` replaced the entry point with
  a shim that ran itself.** Every compatibility shim delegates to `./dev`, so a
  shim *named* `dev` moved the real entry point to `dev.pre-dev-cli` and wrote
  `exec "$(dirname "$0")/dev" dev "$@"` in its place: an exec loop, with the
  file it needed already moved aside. A name containing a path separator would
  likewise have written outside the repository root. Shim names are now
  validated as a whole list before the first write of any kind — `dev`,
  `dev.ps1`, `scripts`, `.`, `..` and anything with a `/` are refused with exit
  2 — so a rejected invocation leaves the repository exactly as it found it;
  the first version of this check ran after the entry point had already been
  installed. The pre-write pass also refuses a destination that is a symlink
  (`-e` is false for a dangling one, so the write would have followed it and
  created the shim wherever it pointed, outside the repository included), an
  existing directory (`--shims .git` moved `.git` to `.git.pre-dev-cli` and
  replaced it with a file), and the reserved `*.pre-dev-cli` suffix (which
  would have displaced the caller's original backup). The message uses
  `readlink` is called without `--`, the form both GNU and BSD accept; BSD
  `readlink` on macOS is the one that rejects GNU's `--`. The same guard
  covers the installer's own destinations (`dev`, `scripts/cli.sh`, the
  PowerShell counterparts): a dangling symlink at one of those is neither `-f`
  nor `-e`, so `install_file` reached `cp`, which followed it and wrote the
  template outside the repository. The guard walks the parent components too: a
  consumer whose `scripts/` is a symlink out of the tree left
  `scripts/cli.sh` neither a symlink nor a directory, so the check passed and
  the `mkdir -p` and `cp` followed the parent link — measured, the old
  installer exited 0 having written outside the repository.

- **`lib/ios.sh` — a simulator was reported as unbootable moments after being
  booted.** `simctl boot` returns when the boot *starts*; the device then sits
  in `Booting` for several seconds and does not appear in
  `simctl list devices booted` until it reaches `Booted`. `ios_boot_simulator`
  returned at the same moment, so `ios_resolve_device`'s very next lookup found
  nothing and printed "'X' is not a booted simulator" about a simulator it had
  just successfully started — worse on a cold simulator, which is when the
  caller most needed it. It now waits for the state the caller is about to ask
  for (`IOS_BOOT_TIMEOUT`, default 60s). The wait checks the listing's exit
  status before its output, so a `simctl` that breaks after the boot command is
  reported as that rather than as a timeout, and it checks once *at* the
  deadline, so a device that boots on the last second counts. `tests/ios_test.sh`
  models the `Booting` window and the broken listing, and fails without either.
  `IOS_BOOT_TIMEOUT` is validated as a whole number before the loop and refused
  with exit 2: `10s` in an arithmetic test errors on every iteration, so the
  deadline was never reached. All-digit is not sufficient either — bash reads a
  leading zero as octal, so `08` and `09` were the same error — and the value is
  normalised to base 10.

- **`templates/dev-cli/cli.sh` — a relative export-options plist named two
  different files in a nested project.** `./dev deploy ios --release` validates
  `IOS_EXPORT_OPTIONS_PLIST` from the repository root, then hands it to
  `ios_build_release`, which re-checks it after `cd`-ing into the Flutter
  project. In the layout the shared dev CLI assumes — the app under `mobile/`
  or `app/` — those are different directories, so a relative path either died on
  a path that had just validated, or resolved to whichever plist sat inside the
  project and signed with that. The path is now made absolute at the point it is
  validated.

- **`scripts/preflight.sh --dir <sub>` looked for every stack under the git
  root instead of under `<sub>`.** Stack directories are detected relative to
  the directory preflight was pointed at, but the `local_test_*` runners resolve
  `--dir` against `git rev-parse --show-toplevel`, so `preflight --dir sub` in
  a repository reported `Directory not found: <root>/app` for a stack that was
  at `sub/app`. preflight now hands the runners an absolute path, and all seven
  runners (`flutter`, `gradle`, `node`, `python`, `go`, `rust`, `php`) honour
  one as given; a relative `--dir` still means what it always meant. The first
  version of this change updated four of the seven, which would have broken
  every ordinary Flutter, Gradle and PHP preflight with `<root>/<root>/<stack>`;
  caught in review, and each runner is now probed with both forms.

- **`scripts/preflight.sh` — `--quick` reported an iOS build that never ran.**
  `check_ios` already passes `--skip-analyze --skip-test`, because those belong
  to the flutter check for the same directory, so the build *is* the step. Under
  `--quick` it added `--skip-build` as well and still called the result a passed
  "ios build" — `ci_ios.sh` was left running `flutter pub get` and nothing else.
  `--quick` now skips the step and says why.

- **`scripts/preflight.sh` — a Rust project failed the run on unactionable
  advice.** `check_rust` gated on `cargo` being on `PATH`, but
  `local_test_rust.sh` runs against *rustup's* toolchain, because that is what
  CI compiles with. On a machine with a distribution cargo and no rustup it
  refused, advising `--any-cargo` — which preflight had no way to pass on. And
  `cargo` on `PATH` is not a precondition at all in the default case: the runner
  resolves rustup's toolchain before it looks at `PATH`, prepending
  `~/.cargo/bin` itself, so demanding cargo up front turned away a machine the
  runner handles unaided. `cargo` is now required only for `--any-cargo`;
  otherwise the precondition is rustup, and either one missing is a skip naming
  both remedies, the way every other absent toolchain here is handled.
  `PREFLIGHT_RUST_ANY_CARGO=true` turns the skip back into a real check against
  `PATH`'s cargo. rustup being installed with no cargo for the selected toolchain
  (`stable` never added) is the same kind of state and is the same skip, naming
  both remedies — the `rustup toolchain install` to run and the
  `PREFLIGHT_RUST_ANY_CARGO` opt-in — rather than a failed step.

- **`scripts/local_test_bash32.sh` — `--test` ignored the tool-skip rules the
  suite relies on.** The single-test path ran the file directly rather than
  through the runner, so `--test tests/docker_install_test.sh` failed for want
  of `apt-get`, and `--test tests/git_branches_test.sh` failed for want of git
  whenever the bootstrap could not reach the network — reporting a missing tool
  as a bash 3.2 defect, which is what the skip rules exist to prevent. Both
  paths now share one runner, and the path is normalised before the skip lookup
  so `--test ./tests/x.sh` is treated the same as `--test tests/x.sh`. A stopped daemon and a missing image are also
  reported as themselves -- with the command to run, and the documented exit
  code 3 -- instead of surfacing a registry error that reads like the suite is
  broken. `--shell` gets those checks too; it used to reach `docker run`
  directly and answer an unpullable image with `cannot attach stdin to a
  TTY-enabled container`.

## 2026-09-09 — v0.26.0

### Added
- **`lib/rust.sh` — the Rust toolchain a gate compiles with.** CI installs Rust
  through `dtolnay/rust-toolchain@stable`, which is rustup's stable. A
  workstation often also carries a distribution cargo that comes first on
  `PATH` and is years older, and the errors that produces name the lockfile
  rather than the compiler:

      error: lock file version 4 requires `-Znext-lockfile-bump`
      feature `edition2024` is required

  So the search goes to the dependency tree while the toolchain is the
  problem — and a local gate saying "this is what CI would have run" is saying
  something false, which is worse than having no gate.

  `rust_toolchain_ci_uses [toolchain]` puts that rustup toolchain's cargo first —
  `stable` by default, asked for **by name** rather than through `rustup which
  cargo`, which follows a developer's default or override and may be nightly —
  and **says so when that differs from what `PATH` offered**, naming both versions; it refuses with an
  actionable message rather than falling back to the older one silently.
  `rust_toolchain_report` prints the same facts without touching `PATH`.

  Promoted from a consumer that had solved it privately, so every Rust
  repository can have it. Same shape as a snap Flutter resolving `.dart_tool`
  for a project the dev SDK was building.

### Changed
- **`scripts/local_test_rust.sh` resolves the toolchain before it looks for
  cargo.** It previously took whatever `command -v cargo` returned. New
  `--any-cargo` opts out for a repository that genuinely targets the system
  toolchain.

## 2026-09-09 — v0.25.0

### Fixed
- macOS support, which had never worked and which no test could have caught.
  The audit behind this release found three independent problems, none of which
  fails loudly: `/bin/bash` on macOS is 3.2, BSD userland is not GNU userland,
  and the iOS half of this library had no callers.

- **bash 3.2.** The library now runs unchanged on the shell macOS ships. The 13
  `mapfile` calls became the while-read loop already used in `lib/ports.sh`; the
  associative arrays in `lib/ports.sh` and `lib/ollama.sh` became indexed ones,
  which is what they always were in effect; and `get_script_metadata` no longer
  returns its result through a bash 4.3 nameref. That last one mattered most:
  every `--help` path in this library was dead on a stock Mac, with no fallback.

  The `lib/ollama.sh` lookup was keyed by a `printf '%04d'` tag. As an array
  subscript `"0010"` is an arithmetic expression read as **octal**, so model
  selection collided from the tenth model on. It is keyed by the integer now.

  `templates/dev-cli/dev` ran `exec bash`, which resolves bash from `PATH` and
  discards the file's own `#!/usr/bin/env bash`. It now prefers a bash 4+ where
  one exists and falls back to 3.2 where none does. Generated shims delegate to
  `./dev` instead of duplicating that resolver into every consuming repo.

  `helpers.sh` refuses anything older than 3.2 and, on 3.x, prints a one-time
  advisory to stderr — never stdout, and only to a terminal, so it cannot
  corrupt a helper whose output is parsed or fill a CI log.

  Three functions still require bash 4 because they take an associative array
  *from the caller* — `select_distro`, `select_multiple_distros`, `download_iso`.
  They now say so through `require_bash4` rather than returning wrong values.

  A ninth of the same shape sat in a bash regex rather than in grep:
  `[[ $line =~ ^#( |\t)(.*) ]]` in `lib/help.sh`. Bash's ERE has no `\t`
  escape, so a tab-indented script header lost every continuation line and
  rendered no `Parameters:` block at all -- no error, no match, exactly like the
  grep patterns. It is `[[:space:]]` now, one character wide, because the rest
  of a block's indentation is reproduced as written. `portability_test.sh` bans
  `\t` inside `[[ =~ ]]`, and `help_test.sh` carries a tab-indented fixture
  written with printf so no reformatting can quietly make it pass.

- **BSD userland.** Eight `grep` patterns used GNU `\s` or `\b`. BSD grep does
  not reject those; it simply never matches them, so each one silently did
  nothing on macOS. `add_to_etc_hosts` therefore concluded "absent" every time
  and appended a duplicate `/etc/hosts` line on every call, and the docs linter
  reported every function as undocumented, which made `make lint-docs`
  impossible to pass on a Mac. Also fixed: `md5sum` in a test (absent on macOS),
  `base64 -d` (older macOS spells it `-D`, and the failure blamed the caller's
  input), `mktemp --suffix` (whose fallback dropped the extension that ffmpeg's
  `palettegen` infers its format from), and a generated Homebrew wrapper that
  hardcoded `#!/bin/bash` — on the one platform where that is always 3.2.

- **Empty arrays under `set -u`.** bash 3.2 treats `"${arr[@]}"` on an empty
  array as an unbound variable; bash 4.4 made it safe. `scripts/preflight.sh`
  aborted on its own argument parsing, and `scripts/lint_docs.sh` on any module
  with no functions. Both now use the `"${arr[@]+"${arr[@]}"}"` form already
  present elsewhere in this repo, as do the Homebrew packaging scripts, which
  by definition only ever run on a Mac.

- `get_os` matched only `linux-gnu*`, so it returned `unknown` on Alpine
  (`linux-musl`) and Termux (`linux-android`), sending `docker_install`, `deps`
  and `certs` down their do-nothing branches. It now matches any `linux*`, and
  reads `$OSTYPE` defensively so a caller under `set -u` is not aborted.

- Everything released in 0.24.1 is carried forward here, so 0.25.0 is a
  superset of it. `scripts/install_dev_cli.sh` no longer destroys the caller's
  original script when `--shims` runs twice: the backup was an unconditional
  `mv "$dest" "$dest.pre-dev-cli"`, and on a second run `$dest` is the shim the
  previous run wrote, so the move replaced the original -- the only copy -- with
  our generated three-line shim. An existing `.pre-dev-cli` is now kept and the
  current file removed instead, and that removal is guarded on the
  `# Compatibility shim. Use ./dev ...` marker so only a shim this script wrote
  is ever discarded. `rm`, `mv`, `cp` and `chmod` pass `--` before the path, so
  a shim name beginning with a dash cannot be read as an option. Covered by
  `tests/install_dev_cli_test.sh`, whose cases fail on the respective unfixed
  code and which asserts the installer's exit status rather than discarding it.
  That test's shim assertion keys on the `# Compatibility shim. Use ./dev ...`
  marker the installer's own re-run guard greps for, not on `scripts/cli.sh`:
  the shim this release writes delegates to `./dev`, so the original assertion
  passed on 0.24.1 and failed the moment the two changes met.

### Added
- `lib/os.sh`: `is_macos`, `is_linux`, `bash_major`, `bash_at_least` and
  `require_bash4`. The library branched on `get_os` in five modules without ever
  having a predicate for it, and had no bash-version guard anywhere at all.

- `./dev deploy ios --release` requires `IOS_EXPORT_OPTIONS_PLIST`, and says so
  before it starts building. Without a plist `ios_build_release` falls back to
  `flutter build ios --release --no-codesign`, which writes an unsigned `.app`
  and nothing at all under `build/ios/ipa`. The install step globs that
  directory newest-first, so an `.ipa` from an earlier signed build was picked
  up and pushed to the device -- a stale binary installed with every step
  reporting success. Gated by `tests/dev_deploy_ios_test.sh`, which watches the
  build and install steps rather than the exit status, since nothing on that
  path ever returned non-zero.

- `get_script_metadata` refuses an unreadable script file up front, returning 2
  and naming the path. Left to the redirection on its read loop, a missing file
  failed inside `lib/help.sh`, so a caller under `set -e` was aborted with a
  raw "No such file or directory" citing this library and a line number rather
  than the path it passed in. A directory was worse: the redirection succeeds,
  `read` fails without assigning, and the loop condition then aborted on
  `line: unbound variable` under `set -u`. `line` is initialised for that
  reason too. `display_help` already guarded this; `get_script_metadata` is
  public API and is called directly.

- **iOS is reachable.** `lib/ios.sh` and `scripts/ci_ios.sh` were complete,
  correct and called by nothing: `ios_install` and `ios_launch` had no callers,
  `preflight` had no `ios` stack, and `verb_deploy` was hard-wired to `adb`, so
  `./dev deploy ios` silently built and installed an Android APK.

  `deploy`, `run` and `build` now branch on the target word. `deploy ios`
  resolves a booted simulator, builds, installs and launches; `build ios
  --release` goes through `ios_build_release`, so the signed-IPA path is
  reachable from `./dev` for the first time. New: `ios_resolve_device`,
  `ios_resolve_physical_device`, `ios_bundle_id` and `ios_artifact` — the last
  two are what `ios_install` and `ios_launch` needed to be callable at all, and
  the two resolvers exist separately because a debug deploy installs a simulator
  `.app` through simctl while a release deploy installs a signed `.ipa` through
  devicectl onto real hardware. Resolving a simulator for the latter cannot work. `flutter_build` gained
  `--simulator`, because `flutter build ios` targets a physical device and the
  `.app` it produces cannot be installed on a simulator.

  `preflight` gained an `ios` stack, detected from a Flutter project with an
  `ios/` directory or a `Podfile`, which finally gives `ci_ios.sh` a caller. Off
  macOS it reports SKIP with a reason rather than failing. `check_flutter` no
  longer builds an APK unconditionally: without an `android/` directory or an
  Android SDK it skips that step, so preflight on a Mac stops demanding a
  toolchain the repository never asked for.

- The portability gate also refuses an unescaped `*(` in a parameter expansion.
  It is not a bash-4 problem but the same silent shape: `*(` is the extglob
  "zero or more" operator, so `${line##*(}` parses differently in a caller that
  ran `shopt -s extglob` and returns the wrong text with no error to notice.

- `tests/scope_test.sh`: these helpers are sourced into other people's scripts,
  so an undeclared loop variable becomes a global in the caller. The while-read
  loops that replaced `mapfile` introduced exactly that across five modules;
  every affected variable is now declared, and the test asserts a call leaves no
  trace behind.

- `tests/dev_shim_test.sh`, covering which bash the shim selects: it prefers 4+,
  accepts 3.2, and refuses 3.0 and 3.1 rather than committing to an interpreter
  helpers.sh will reject a moment later. The rule is impossible to exercise from
  Linux by hand, where every candidate is bash 5.

- `tests/portability_test.sh`, a blocking static gate for GNU-only utilities and
  bash-4-only syntax. CI has always run shellcheck with `|| true`, so nothing
  here could fail a build; every rule in this gate was verified to fire by
  introducing the construct it bans and watching it fail.

- `scripts/local_test_bash32.sh` and `make test-bash32`: the whole suite under a
  real bash 3.2 in Docker, so the constraint is verifiable from a Linux box.
  Tests whose subject is a missing tool are reported as SKIPPED, because a test
  that fails for want of `git` says nothing about bash 3.2.

- A macOS CI job (`.github/workflows/ci-macos.yml`) running the suite explicitly
  under `/bin/bash`. GitHub's macOS runners also carry a modern bash, so the
  legacy shell has to be named or the job proves nothing. It is path-filtered to
  shell changes: GitHub bills macOS runners at a 10x minute multiplier, and
  the absence of any macOS job is why all of the above stood for 23 releases.

- Tests for `lib/help.sh`, `lib/os.sh`, `lib/hosts.sh` and preflight detection.
  `lib/help.sh` had none, and it is the file this release changes most.

### Changed
- **`get_script_metadata` takes a variable-name prefix, not an associative array.**
  `get_script_metadata ./x.sh meta` now sets `meta_name`, `meta_usage` and so on
  instead of filling `meta[...]` through a nameref. Callers of `show_help`,
  `print_help` and `display_help` are unaffected, and their output is unchanged.
  Only direct callers of `get_script_metadata` need to move from `${meta[usage]}`
  to `$meta_usage`. It returns `2` when the prefix is missing or is not a valid
  shell variable name, rather than emitting one `printf` error per field and
  leaving the caller half-populated state to diagnose. Its arguments, and
  `add_to_etc_hosts`', are defaulted rather than bare: under `set -u` a bare
  `"$2"` aborts the caller on the expansion itself, before the function can
  return the error code it documents.

- `add_to_etc_hosts` compares whitespace-separated tokens exactly instead of
  interpolating the domain into a `grep` pattern, and skips comment lines. A
  hostname carries its own dots into a regex, where `.` matches any character,
  so `demo.local` was "found" in a file holding only `demoXlocal` and the real
  entry was then never added. It also honours `HOSTS_FILE` and writes directly
  when the file is writable, falling back to `sudo tee`. The presence test was wrong on macOS and
  nothing could demonstrate it, because exercising it meant editing the real
  `/etc/hosts` as root.

- `Makefile` uses the `bash` on `PATH` rather than `/bin/bash`, which on macOS is
  3.2 whatever the developer has installed. Bash 3.2 coverage is now an explicit
  target rather than an accident of platform.

- preflight's "tool is not installed" skips name a platform-appropriate fix, so a
  Mac is no longer told to run `apt install`.

## 2026-09-08 — v0.24.1

### Fixed
- `scripts/install_dev_cli.sh` no longer destroys the original script when
  `--shims` is run twice. The backup was an unconditional
  `mv "$dest" "$dest.pre-dev-cli"`, but on a second run `$dest` is the shim the
  previous run wrote, so the move replaced the caller's original — the only
  copy of it — with our generated three-line shim. An existing
  `.pre-dev-cli` backup is now kept and the current file removed instead.

  That removal is guarded: only a shim this script wrote is discarded, matched
  on its `# Compatibility shim. Use ./dev ...` marker. If `.pre-dev-cli` exists
  for some other reason and the root file is a real script, the backup slot
  that would have saved it is already taken, so there is no move that does not
  lose a file -- the shim is skipped with a warning and both files are left
  alone. `rm`, `mv`, `cp` and `chmod` now also pass `--` before the path, so a
  shim name that begins with a dash cannot be read as an option. Covered by
  `tests/install_dev_cli_test.sh`, whose cases fail on the respective unfixed
  code and which asserts the installer's exit status rather than discarding it.

## 2026-09-02 — v0.24.0

### Added
- `lib/git_branches.sh` and `scripts/prune_branches.sh`: branch maintenance that
  any repository vendoring these helpers can run. `git branch --merged` only sees
  merges that produced a merge commit, so a repository that squash-merges
  accumulates branches it will never list and people delete by hand. The
  squash case is detected by rebuilding the commit a squash merge would have
  produced and asking `git cherry` whether that patch is already upstream.

  The costly mistake is the other one: a branch whose work landed and which
  then received new commits still has something to lose. Both tests look at
  the branch tip as it stands, so a commit added after the merge fails both —
  the protection falls out of the check rather than being a rule to remember.
  It is a dry run by default, refuses the base branch, the current branch, a
  branch checked out in another worktree, protected names including
  `release/*`, and anything holding commits its upstream does not. `--base`
  accepts `main`, `origin/main` or a full ref and normalises before comparing,
  because an un-normalised base matches no local branch and stops being
  recognised as the base. The squash probe carries its own throwaway identity:
  `git commit-tree` refuses to run without one, and where there is none the
  probe would fail silently and report every squash-merged branch as unmerged.
  A probe that cannot run now reports `unknown` rather than `unmerged` — both
  keep the branch, but only one of them means the question was answered.
- `tests/git_branches_test.sh`: a fixture repository covering merge-commit,
  squash, never-merged and unrelated histories — and the case the file exists
  for, a branch squash-merged and then committed to again, which must survive.

### Changed
- `scripts/git-hooks/pre-push` returns immediately when a push contains only
  ref deletions. There are no new commits for a test suite to have an opinion
  about, and running one is the kind of latency that teaches people to reach
  for `--no-verify` — pruning three merged branches otherwise ran the full
  gate three times. Skipped only when every ref in the push is a deletion.
- Comments and module docs name `iso-forge` rather than `burn-iso`, following the
  rename of the repository these helpers were first written for. No behavior changed.

## 2026-08-22 — v0.23.0

- Added: `lib/hub.sh`, corpus-hub setup for capture clients. Every client of
  the corpus hub was told to reach it at a typed `HUB_URL` and nothing
  checked the key, told anyone the hub was behind, or made a hub exist on a
  fresh machine beyond printing "clone the other repository". One module
  both clients import: `hub_setup_dialog` asks whether the hub is **local**
  (clone it when absent and run the hub's own `./start --configure-superuser`
  and `./install-service` -- never compose) or **remote** (URL and key),
  proves the answer (`hub_probe` on `/v1/service`; `hub_check_key` on an
  authenticated read, where a 401 is reported as a wrong key and not as a
  missing hub), and writes `HUB_MODE`, `HUB_URL`, `HUB_API_KEY` and the hub's
  `HUB_INSTANCE_ID` with an in-place, symlink-safe `hub_write_env`.
  `hub_offer_update` compares the running version with the newest tag and,
  to a person and in local mode only, offers to exec the hub's own
  `./update`. Three renderers behind one set of prompts: `dialog` when
  installed on a terminal, plain `read -p` otherwise, and no prompt at all
  without a terminal -- a systemd unit or CI run fails naming the variable it
  wanted instead of waiting on a read forever. The clone URL is an argument;
  the library names no repository. `tests/hub_test.sh` runs it against a
  fake hub and stubbed hub scripts.

## 2026-08-09 — v0.22.0

- Added: wireless-adb helpers in `lib/adb.sh`. A phone on the desk is not always
  a phone on a cable, and `adb connect` has three sharp edges that every project
  rediscovers separately — tcpip mode is lost on reboot and the failure looks
  identical to a wrong address; Android 11+ "Wireless debugging" allocates a
  random port per session so a hard-coded 5555 quietly stops working; and
  `adb connect` exits 0 on a bare TCP handshake, so success is not evidence a
  device is usable.
  The address comes from `DEV_DEVICE` — the existing dev-cli convention for
  which device, and what `--device` sets, so one variable covers both which
  device and where to connect; a USB serial there has no colon and is correctly
  not treated as an address. `ANDROID_DEVICE_IP` / `_PORT` stay supported as an
  explicit split form.
  `adb_wireless_addr`, `adb_wireless_attached`, `adb_wireless_connect`,
  `adb_wireless_disconnect`, `adb_wireless_enable`, `adb_wireless_setup`,
  `adb_wireless_write_env` and `adb_wireless_recovery_hint`.
  `adb_wireless_connect` confirms against `adb devices` rather than trusting the
  exit status, and treats `offline` / `unauthorized` as not attached.
  `adb_wireless_setup` does the whole cable-to-wireless handover in one call and
  prints the address for a caller to store; `adb_wireless_write_env` upserts it
  into a gitignored env file as `DEV_DEVICE` without disturbing anything else
  in that file.
- Security: `adb_wireless_write_env` validates the host and port before writing.
  An env file is SOURCED by the shell that reads it, so whatever lands in it is
  executed. A newline in the value injected an extra line —
  `adb_wireless_write_env .env "$(printf '203.0.113.1\nFOO=$(id)')"` wrote a
  literal `FOO=$(id)` line, and sourcing ran it. The value is not always
  hand-typed: `adb_wireless_setup` takes it from `adb shell ip ...`, i.e. from
  whatever the attached device prints. Validation is at the sink, so every
  caller is covered. `adb_wireless_valid_host` / `adb_wireless_valid_port` are
  exported for callers that want to check earlier.
- Added: `scripts/check_no_private_ips.sh`. Wireless adb makes a device's LAN
  address part of daily work, and it then wants to end up in a README, a test
  fixture or a CI file. This fails on any RFC 1918 literal in a **tracked** file.
  Boundaries are spelled `(^|[^0-9.])` rather than `\b`, which is a GNU/PCRE
  extension and not POSIX ERE — under BSD grep the pattern would quietly match
  nothing and the gate would report success while checking for nothing at all.
  It scans tracked files and ignores untracked and gitignored files, so the env
  file the address is supposed to live in is never flagged — a gate that fired
  there would only teach people to skip it. RFC 5737 documentation ranges,
  loopback and `.local` names are allowed, because those are what a tracked
  example should use.

## 2026-08-09 — v0.21.0

- Fixed: `CHANGELOG.md`'s release headers did not match the format this library
  itself defines and checks. `lib/changelog.sh` exists because `ci-helpers`
  extracts release notes by finding a `## YYYY-MM-DD — vX.Y.Z` heading and
  silently falls back to an auto-generated commit list when it cannot — and
  every heading in this file was `## [X.Y.Z] - YYYY-MM-DD`, so every release
  published here has been getting the fallback. The twenty existing headings
  are converted and `make lint-docs` now runs `changelog_check_header`, since
  nothing ran it, which is how a checker shipped by this repository came to be
  failing on this repository.

- Changed: comments and examples now describe what a helper does rather than
  naming the project a convention was taken from. Several compatibility
  shims were labelled with the name of the codebase whose call shape they
  match, and one example invocation and one changelog line named specific
  projects. None of it was load-bearing — no code read those names — and a
  reader of this repository learns more from "takes a single combined command
  string" than from the name of a codebase they cannot see. This library is
  meant to be self-contained and readable on its own terms.

## 2026-07-31 — v0.20.0
- Fixed: `local_test_python.sh` ran only pytest, while `preflight` labelled the step "lint + test". A repo that moved its CI local therefore lost its Python lint gate without a word about it — the shape of failure this family exists to prevent. It now runs `ruff check .` whenever the project configures ruff (`[tool.ruff]` in `pyproject.toml`, or `ruff.toml`/`.ruff.toml`), and treats configured-but-not-installed as a failure rather than a skip: a gate the project declared and that never ran must not report green. A full (non-`--quick`) run installs ruff first.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` did not configure git hooks. In a repo that has deleted its build workflows the `pre-push` hook is the only remaining gate, and `core.hooksPath` lives in the untracked `.git/config` — so every clone but the one the migration was done on had no gate at all. `install` now runs `setup-hooks.sh`, in both shells.
- Fixed: `templates/dev-cli/cli.sh` `verb_install` ran `python3 -m pip install -r requirements.txt` against the system interpreter, which a PEP 668 host refuses outright, aborting `./dev install`. It now resolves the same project-local `.venv` that `local_test_python.sh` uses, and installs the `dev` extra so preflight's tools are present.
- Fixed: `dev_stack_dir` returned success with empty output when a stack was absent — awk exits 0 when it matches nothing — so the `|| echo .` fallback at every call site was dead code and an empty directory reached `android_build`/`flutter_build`. It now returns 1.
- Fixed: `--device` / `--user` as the final argument killed `./dev` silently. `shift 2` with one argument left returns non-zero and `set -e` ended the process before the validation below could name the missing value. Both options now check for an operand first.
- Fixed: `templates/dev-cli/cli.ps1` could throw before doing anything. `[string[]]$Rest` is `$null` rather than an empty array when nothing follows the verb, and `Set-StrictMode -Version Latest` makes `$Rest.Count` a terminating error. Also `Verb-Devices` referenced `$IsMacOS`, which does not exist in Windows PowerShell 5.1 (same StrictMode rule), and imported an `ios` module that has no PowerShell implementation — a hard error on macOS instead of the "no simulators" notice it intended. All three are guarded, and PowerShell `Verb-Install` gained the python/node parity the Bash verb already had.
- Added: PowerShell parity for the Windows story. `ps/lib/docker_install.ps1` mirrors the Bash module function-for-function (`install_docker`, `ensure_docker`, `docker_ready`, `docker_install_status`, `docker_report_state`, `docker_start_daemon`, `wait_for_docker_daemon`), with switch parameters (`-Yes`, `-DryRun`, `-NoStart`, `-TimeoutSec`) in place of the flags and identical exit codes. Plus `ps/scripts/install_docker.ps1`, the counterpart to `bin/install-docker`. Windows is the primary target — Docker Desktop is the mechanism there, not a convenience — so it gets full support (`winget` → Chocolatey → official installer, TLS 1.2 forced for Windows PowerShell 5.1, `$ProgressPreference` silenced so the download is not ~10× slower, and a non-elevated warning rather than an opaque UAC failure). macOS is Homebrew-cask only and Linux defers to the Bash module by design, rather than maintaining two implementations of package-manager detection and the `docker` group.
- Added: `ps/lib/serve.ps1` and `ps/lib/svg.ps1` — PowerShell counterparts for the modules added in 0.17.0 and 0.18.0, which shipped Bash-only. `serve_static_site` uses `TcpClient` for the free-port probe (`Get-NetTCPConnection` is Windows-only) and keeps the same python3 → python → `npx http-server` preference and return codes. `svg_rasterizer` prefers `magick` over the legacy `convert` on Windows and refuses to match `convert.exe` from the system directory — that is the FAT-to-NTFS conversion utility, not ImageMagick.
- Fixed: `ps/scripts/tag_release.ps1` could not be parsed, so the script was unusable. `"Invalid version in $File: $version"` parses `$File:` as a scoped variable reference (the `$env:PATH` form); it needs `${File}`. Pre-existing on `main`.
- Added: a `powershell` CI job that parses every `ps/**/*.ps1` and imports every module. PowerShell had never been built or linted in CI, which is how the `tag_release.ps1` syntax error shipped unnoticed. The Bash `lint-and-examples` job now also runs `make test`, which it previously did not.
- Note: `ios` remains Bash-only on purpose. It drives Xcode, `xcrun` and `simctl`, which exist only on macOS; the Bash module already no-ops elsewhere via its `ios_available` gate, so a PowerShell mirror would be a file full of stubs. `ollama` and `package_publish` are also still Bash-only, but predate this change and were left alone.

- Added: `docker_install` module (`lib/docker_install.sh`) — gets Docker onto a bare machine, so a project bootstrap can go from nothing to a working `docker compose` without sending the operator off to read platform-specific install docs. Companion to `docker`, which assumes Docker already exists. Installs Docker Engine + the compose v2 plugin on Linux (Docker's official `apt`/`dnf`/`yum` repositories; distribution packages on openSUSE and Arch), Docker Desktop on macOS (Homebrew cask, else the official `.dmg` for the detected CPU) and on Windows (`winget` → Chocolatey → official silent installer, from Git Bash/MSYS2), and detects WSL explicitly, explaining Docker Desktop-with-integration versus Engine-in-distro before installing either. Detection helpers (`docker_cli_installed`, `docker_daemon_running`, `docker_compose_v2_available`, `docker_ready`, `docker_install_status`, `docker_report_state`), the installer (`install_docker`, `ensure_docker`), and the reusable pieces (`docker_start_daemon`, `docker_add_user_to_group`, `wait_for_docker_daemon`). Plus a CLI wrapper `bin/install-docker` (adds `--check`) and `tests/docker_install_test.sh`, which is detection- and dry-run-only so `make test` never installs anything.

  Behaviour worth knowing: `install_docker` is **idempotent** — a working Docker returns 0 having changed nothing. When the CLI exists but the daemon does not answer it **starts what is already installed** before considering an install, because a closed Docker Desktop is the common case and reinstalling is the wrong fix. It prints its plan and asks before modifying the system (`--yes` skips, `--dry-run` shows without doing, `--no-start` and `--no-group` narrow the scope). Exit `3` means installed-but-daemon-not-up, which on Linux is almost always the `docker` group change not applying to the current shell — the module says so rather than leaving the caller guessing. Apt derivatives are mapped onto their upstream (Mint/Pop!_OS/neon/Zorin/elementary → `ubuntu`, Raspbian/Kali/Parrot → `debian`) and the repository line prefers `UBUNTU_CODENAME` over `VERSION_CODENAME`, since the latter is the derivative's own release name and 404s against Docker's repository.
- Added: `android` module (`lib/android.sh`) — the build side of Android, counterpart to `adb`, which owns everything that happens on an already-running device. SDK discovery (`android_sdk_root`, `android_available`, `android_sdk_tool`, searching the SDK's several layouts and versioned `build-tools` newest-first), bootstrap (`android_ensure_sdk` accepting licenses and installing platform-tools/platform/build-tools), building (`android_gradlew`, `android_build` — one spelling of the debug/release toggle where consuming repos had four, and `android_artifact`, which distinguishes "not built yet" from "built and here it is"), signing (`android_sign` via `apksigner` or `jarsigner`, with the keystore from a file or base64-decoded out of an environment variable, and an opt-in `--allow-unsigned` debug-signed fallback so a local build proceeds without release credentials), and emulators (`android_avd_list`, `android_avd_create`, `android_emulator_start` waiting on boot completion, `android_emulator_stop`). Loads the `gradle` and `adb` modules itself, so `shlib_import android` is sufficient.
- Added: `flutter` module (`lib/flutter.sh`) — `flutter_resolve_sdk` finds Flutter in the places a non-interactive shell's PATH misses (a snap, a tarball under `$HOME`, fvm), which consuming repos had solved by pasting the same candidate-path loop into every script that needed it. Plus `flutter_available`, `flutter_run_cmd` (the single point where SDK resolution lives), `flutter_pub_get`, `flutter_analyze`, `flutter_format_check`, `flutter_test`, `flutter_build` (defaulting to `--release`, since a mode-less Flutter build is a debug build and that is rarely what a build function's caller means), `flutter_devices` (with a `jq`-free fallback), and `flutter_resolve_device`, which refuses to guess between two connected devices.
- Added: `gradle` module (`lib/gradle.sh`) — `gradle_available`, `gradle_wrapper`, `gradle_run`, `gradle_lint`, `gradle_test`, `gradle_assemble`, `gradle_clean`. Prefers the project's `./gradlew` over a system `gradle`, because the wrapper pins the version and a system `gradle` does not. Kept separate from `android` so a plain JVM host component need not import an Android toolchain to run `test`.
- Added: `screencap` module (`lib/screencap.sh`) — screenshots and screen video from a device, emulator or simulator, for README media, store listings and bug reports. `screencap_available`, `screencap_shot`, `screencap_record`, `screencap_record_stop`, `screencap_frame` and `screencap_gif` (two-pass with a generated palette, because a single-pass GIF from video is visibly dithered). Two device limits are reported rather than hidden: `screenrecord` caps a clip at 180 seconds, so longer requests are chunked and concatenated instead of silently truncated; and a physical iOS device cannot be recorded without Xcode driving it, which returns 3 with an explanation rather than appearing to succeed. Generated names land in `docs/screenshots/`, overridable with `SCREENCAP_DIR`.
- Added: `manifest` module (`lib/manifest.sh`) — `manifest_kind`, `manifest_detect`, `manifest_read_version`, `manifest_write_version`, `manifest_android_version_code` and `manifest_sync_version`, across `pubspec.yaml`, `build.gradle[.kts]`, `VERSION`, `package.json` and `pyproject.toml`. A phone app states its version in three places at once and they drift; `manifest_sync_version` is the "one release, one number" operation. A pubspec's `+build` counter is preserved and the Play Store `versionCode` is recomputed from semver; a non-semver input returns 2 rather than emitting a wrong `versionCode`, which the Play Store rejects only after the upload.
- Added: `changelog` module (`lib/changelog.sh`) — `changelog_check_header`, `changelog_extract` and `changelog_new_section`. The `## YYYY-MM-DD — vX.Y.Z` header is load-bearing: `ci-helpers` extracts release notes by finding that section, and any other shape silently falls back to an auto-generated commit list. The checker calls out an ASCII hyphen where the em-dash belongs, which is the common near-miss.
- Added: `scripts/preflight.sh` — one command that runs every check CI would have run: lint, format, tests, build and a secret scan. It detects `(stack, directory)` pairs rather than a single stack at the repo root, which is what lets it replace a multi-job workflow in a repo with an app in `android/` and a host in `host/`; a repo can pin the list with a `.preflight` file when autodetection picks up a directory CI never built. A skipped check is reported separately from a passing one, so an absent toolchain cannot look green. Carries the same local-only guard as the other `ci_*.sh` runners.
- Added: `scripts/local_test_gradle.sh` — the missing member of the `local_test_*` family, autodetecting Android task names from the applied Gradle plugin.
- Added: `scripts/install_dev_cli.sh` and `templates/dev-cli/` — one `./dev` verb set for every consuming repo: `install build run test preflight deploy devices screenshot record logs clean update release`. A verb a repo cannot honour prints why and exits 0 rather than being absent, because a missing verb is indistinguishable from a typo. `_bootstrap.sh` is copied rather than sourced from the library, since locating the library is the thing it does, and it self-heals an uninitialized submodule. Repo-specific behaviour goes in `scripts/project.sh`, so `cli.sh` stays refreshable from the template. The installer leaves old root scripts as thin shims.
- Added: `adb_install` takes `--user <id>`, defaulting to `0` (the device owner), and passes it through to `adb`. Plus `adb_installed_for_user` and `adb_install_verified`. An unqualified `adb install` can land a package in a profile the shell cannot subsequently read: on a device with a work profile or Samsung Secure Folder the install prints `Success` and exits 0, `pm list packages` fails with `SecurityException: Shell does not have permission to access user <id>`, and the app is absent from the launcher and unstartable by `am start`. Every signal says the install worked, so the symptom reads as an app fault rather than a deploy fault. Pinning the user prevents the common case; `adb_install_verified` prevents the class, because an installer's exit code asserts that adb accepted the command, not that the app is usable. Note that `adb shell` exits 0 even when the command inside it failed, so the check reads the output rather than the status. `android_package_name` supplies the package name to verify, preferring `aapt` on the built artifact since that is the only source accounting for `applicationIdSuffix` and flavors.
- Changed: `scripts/git-hooks/pre-push` now detects Gradle and Android projects — whose absence previously produced "No test runner detected" and a green push — and delegates to `preflight --quick` when it is available. It distinguishes "preflight is not installed" from "preflight failed", so a failing check can never fall through to a weaker one and let the push pass.
- Added: PowerShell companions for every new module (`ps/lib/{android,flutter,gradle,screencap,manifest,changelog}.ps1`) plus `ps/scripts/preflight.ps1` and `ps/scripts/local_test_gradle.ps1`. The PowerShell preflight is native rather than shelling out, so the same verbs work in Windows PowerShell with no Git Bash present.

## 2026-07-26 — v0.19.0
- Added: `ios` module (`lib/ios.sh`) — an iOS device/simulator toolkit, the counterpart to `adb`. Discover hardware and simulators (`ios_list_devices`, `ios_list_simulators`, `ios_booted_simulators`), control simulators (`ios_boot_simulator`, `ios_shutdown_simulators`), install and launch builds (`ios_install` for `.app`/`.ipa`, `ios_launch`), and build a Flutter release (`ios_build_release`: a signed IPA with an ExportOptions plist, otherwise an unsigned iOS app). macOS-only: every function no-ops on other hosts (`ios_available` gate) so callers degrade cleanly. Plus `scripts/ci_ios.sh`, a host-based analyze/test/build runner (Apple's toolchain runs only on macOS, so unlike the Docker-based `ci_*.sh` helpers it has no image and exits early elsewhere).

## 2026-07-25 — v0.18.0
- Added: `svg` module (`lib/svg.sh`) to rasterize SVG art to PNG for app logos and launcher icons. `svg_rasterize <in.svg> <out.png> [size]` renders a square PNG (default 1024px), preferring Inkscape and falling back to ImageMagick (`magick`/`convert`); `svg_rasterize_sizes` emits one PNG per size for icon sets; `svg_rasterizer` reports the available tool. Plus a CLI wrapper `bin/svg-rasterize` and a `tests/svg_test.sh` smoke test (auto-picked up by `make test`). Extracted from an application's icon-generation flow so the rasterizing step is defined once here rather than per project.

## 2026-07-21 — v0.17.0
- Added: `serve` module (`lib/serve.sh`) with `serve_static_site <dir> [port]` to preview a static/GitHub-Pages directory locally — auto-picks a free port (default `8000`), prefers `python3 -m http.server`, falls back to `python` (`http.server` on Python 3 or `SimpleHTTPServer` on Python 2) then `npx http-server`. Plus a CLI wrapper `bin/serve-pages` and a `tests/serve_test.sh` smoke test (also runnable via new `make test` target).
- Added: PHP/Laravel support for the local test runner and `pre-push` hook. New `scripts/local_test_php.sh` runs `composer install` (skipped with `--quick`), Laravel Pint style checks when available, and the suite via `php artisan test` (falling back to `vendor/bin/phpunit`); `SKIP_PHP_TESTS=1` gives a style-only run for pre-push without a local database. In the `pre-push` hook, `composer.json` is authoritative so Laravel apps that also ship a `package.json` for Vite run their PHP suite instead of falling through to the Node runner.
- Changed: release automation now reuses the shared ci-helpers reusable workflows instead of hand-rolled logic. `auto-tag-release.yml` (on merge of a `release/X.Y.Z` PR to `main`) calls `ci-helpers/auto-tag-release.yml@production` to detect+tag the version, `create-github-release.yml@production` to publish the Release in the same run, and moves the `production` branch. Removes the bespoke `release-tag.yml` and `auto-tag.yml`.
- Added: `adb` module — a multi-device-safe Android Debug Bridge toolkit (Bash `lib/adb.sh` + PowerShell `ps/lib/adb.ps1`). Inspect devices (`adb_list_devices` table of serial/model/Android OS/API level/IP; `adb_device_status`, `adb_device_api`, `adb_android_version`, `adb_device_ip`), install apps (`adb_install`, `adb_install_all`, `adb_uninstall`), copy files (`adb_push`, `adb_pull`), and debug (`adb_shell`, `adb_logcat`, `adb_clear_logcat`, `adb_battery_level`, `adb_screen_on`). Every command targets `adb -s <serial>` so it works with more than one device attached. Plus a reusable CLI wrapper `scripts/adb_tool.sh`.
- Added: CI helper scripts for Node, Python, Flutter, Gradle, Go, and basic security checks.
- Added: `scripts/pin_production.sh` to fast-forward the production branch to a release tag.
- Added: `scripts/check_release_version.sh` to verify release versions before tagging or publishing.
- Added: `--version` and `--image` parameters to all `ci_*.sh` scripts for Docker image tag and full image override.

## 2026-06-12 — v0.14.0
- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpers` now always loads `logging` first unconditionally; previously it skipped the pre-load when `logging` appeared anywhere in the caller's list, leaving other modules without logging if they were listed before it.
- Fixed: `ps/lib/help.ps1` — `get_script_metadata` and `_Help_Render` now guard against empty/null `$ScriptFile` (interactive use with no `SHLIB_CALLER_SCRIPT`) instead of throwing on `Test-Path` and `Path::GetFileName(null)`.
- Fixed: `ps/lib/traps.ps1` — `enable_strict_mode` uses `Set-Variable -Scope 1` to write `ErrorActionPreference` into the immediate caller's scope rather than `$Global:`, so it no longer leaks strict mode into the wider PowerShell session.
- Fixed: `ps/scripts/ci_go.ps1`, `ci_node.ps1`, `ci_python.ps1`, `ci_rust.ps1` — `-UseDocker` mode now calls `check_docker` before invoking Docker; previously a missing/stopped Docker daemon produced a generic "command not found" error instead of the structured diagnostic from the helper.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now unregisters and re-registers by `SourceIdentifier` instead of storing the `PSEventJob.Id` as a subscription ID; `PSEventJob.Id` is the job ID, not the subscription ID expected by `Unregister-Event -SubscriptionId`, so the previous code could leave duplicate exit handlers on repeated calls.
- Fixed: `ps/lib/logging.ps1` — stderr path in `_Shlib_WriteColor` now guards ANSI codes with `[Console]::IsErrorRedirected`; previously `2>file` or `2>&1` captured raw escape codes even though the stdout path was already guarded.
- Fixed: `ps/lib/logging.ps1` — `_Shlib_WriteColor` now checks `[Console]::IsOutputRedirected` before the ANSI flag; previously the redirect branch was unreachable when ANSI was enabled, so redirected streams (files, pipelines) received raw escape codes instead of plain text.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` now passes the handler via `-MessageData` and reads it as `$event.MessageData` inside the action block; the previous approach stored the handler in a `$script:` variable that is invisible in the separate runspace used by event actions.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the Bash API: takes a variable *name* and an optional default, returning the env var's value or the default when unset/empty. The internal `$VAR`/`${VAR}` expansion logic used by `load_env` is extracted into `expand_env_refs`.
- Fixed: `ps/lib/version.ps1` — `version_bump` now throws explicitly when `BumpType` is empty and creates the parent directory of `VersionFile` when it does not exist.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` now throws on an empty `$Cmd`, and uses splatting (`@rest`) to forward arguments so the call works correctly for both native executables and PowerShell functions.
- Fixed: `ps/lib/env.ps1` — `load_env` now uses `foreach`/`continue` instead of `ForEach-Object`/`return`; the old form exited the function on the first blank line or comment instead of skipping only that line.
- Fixed: `ps/lib/packaging.ps1` — `pkg_load_metadata` same fix: `ForEach-Object { return }` was exiting the function early on blank/comment lines.
- Fixed: `ps/lib/docker.ps1` — `check_docker` normalises each element of `docker info 2>&1` output to a string before joining, so ErrorRecord objects in mixed-type arrays do not produce a garbled error message in PS 5.1.
- Fixed: `ps/lib/certs.ps1` — `generate_self_signed_cert` no longer exports a PFX by default. PFX export is now opt-in: pass `-PfxPassword <SecureString>` to write the private-key bundle; the public `.cer` is always written. Prevents accidental unprotected private-key files on disk.
- Fixed: `ps/lib/traps.ps1` — `$_SHLIB_EXIT_SOURCE` now holds the literal string `'PowerShell.Exiting'` instead of `[PsEngineEvent]::Exiting`; the enum stringifies to `"Exiting"` which does not match the engine event's actual `SourceIdentifier`, so the exit handler would never fire (and could not be unregistered).
- Fixed: `ps/lib/env.ps1` — `get_project_root` now checks the filesystem root itself for `.git` after the traversal loop exits; previously the root path was never evaluated, causing incorrect fallback to `$StartDir` on drive-root repos.
- Fixed: `ps/lib/version.ps1` — `version_bump` success message now logs the original version string (including prefix/suffix like `v1.2.0-rc1`) instead of the stripped core after prefix/suffix mutation.
- Fixed: `ps/lib/file.ps1` — `create_directory` now returns `$true` on success and `$false` on failure (via `try/catch` with `-ErrorAction Stop`); previously it returned `$null` on all paths, making success checks unreliable.
- Fixed: `ps/lib/env.ps1` — `expand_env_refs` now expands unset `$VAR`/`${VAR}` references to empty string instead of leaving the literal placeholder, matching Bash `load_env` behaviour.
- Removed: `ps/lib/file.ps1` — `ensure_dir` helper removed; it was undocumented, absent from the Bash `lib/file.sh` API, and fully covered by `create_directory`.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` now mirrors the full Bash API with an optional third `$EnvFile` parameter; when the process env var is unset it falls back to reading the key from that file (default `.env`), matching the Bash `resolve_env_value(key, default, env_file)` signature.
- Fixed: `ps/helpers.ps1` — `Import-ScriptHelpersAll` now loads `logging` first before iterating `Get-ChildItem` output; filesystem ordering is non-deterministic so the previous code could load other modules before `logging`, breaking any module that logs during import.
- Fixed: `ps/lib/help.ps1` — `show_usage` now uses `Write-Output` instead of `Write-Host` so help text can be redirected or captured by callers.
- Fixed: `ps/lib/file.ps1` — `download_file` now marks `$Url` as mandatory and wraps `Invoke-WebRequest` in `try/catch` returning `$true`/`$false`, consistent with `create_directory` and `verify_checksum`.
- Fixed: `ps/lib/hosts.ps1` — `add_hosts_entry` now checks only active (non-comment) lines when testing whether an entry already exists; previously a commented-out domain (`# 127.0.0.1 example.com`) would falsely prevent adding a real entry. `remove_hosts_entry` likewise now preserves comment lines even when they mention the domain.
- Fixed: `ps/lib/env.ps1` — `resolve_env_value` env-file fallback now uses the same parsing logic as `load_env` (handles `export` prefix, whitespace around `=`, and quote stripping) instead of a bare `StartsWith` that missed all those forms.
- Fixed: `ps/lib/help.ps1` — `_Help_PrintInline` and `_Help_PrintBlock` now use `Write-Output` for the non-colored fallback path so all help output is redirectable, consistent with the earlier `show_usage` fix.
- Fixed: `ps/lib/file.ps1` — `download_file` now pipes `Invoke-WebRequest` to `Out-Null` and suppresses the PS progress bar (`$ProgressPreference = 'SilentlyContinue'`) for the duration of the call; previously the response object leaked into the pipeline and the progress UI was noisier than the Bash equivalent.
- Fixed: `ps/lib/dialog.ps1` — `dialog_download_file` now pipes `Invoke-WebRequest` to `Out-Null`; previously the response object was emitted to the pipeline, potentially interfering with callers.
- Fixed: `ps/lib/ports.ps1` — `get_port_conflicts_json` wraps `$conflicts` in `@()` before `ConvertTo-Json` so a single-conflict result is always a JSON array `[{...}]` instead of a bare object `{...}`; without this PS unwraps a one-element array to a scalar.
- Fixed: `ps/lib/file.ps1` — `verify_checksum` now guards against missing/unreadable files with an explicit `Test-Path` check and `try/catch` around `Get-FileHash`, returning `$false` with a structured error message instead of surfacing raw cmdlet exceptions.
- Fixed: `ps/scripts/ci_rust.ps1` — in `-UseDocker` mode, `-Manifest` paths are now translated to container-relative `/work/<rel>` paths; passing an absolute Windows path or a path outside `-Workdir` now fails with a clear error rather than silently breaking cargo inside the container.

- Added: PowerShell companion library (`ps/`) for native Windows support without WSL.
  - `ps/helpers.ps1` — loader with `Import-ScriptHelpers` function (mirrors `helpers.sh` / `shlib_import`).
  - 19 PowerShell modules in `ps/lib/` mirroring all core Bash lib modules:
    `logging`, `os`, `env`, `file`, `deps`, `help`, `version`, `docker`, `ports`, `json`,
    `browser`, `traps`, `python`, `clipboard`, `dialog`, `certs`, `hosts`, `ci_defaults`, `packaging`.
  - `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — CI runners that work natively on Windows (no Docker required); pass `-UseDocker` for Docker Desktop mode. `-UseDocker` honours `-Quick` and `-SkipTest` in Python CI.
  - `ps/scripts/bump_version.ps1`, `tag_release.ps1` — version management for Windows.
  - `ps/scripts/example_logging.ps1` — demonstration script.
  - PS 5.1 (Windows built-in) and PS 7+ both supported.
  - `deps.ps1` uses `winget` → `choco` → `scoop` for package installation.
  - `ports.ps1` uses `Get-NetTCPConnection` replacing `lsof`/`ss`/`netstat`.
  - `certs.ps1` uses Windows Certificate Store (`New-SelfSignedCertificate`, `Import-Certificate`).
  - `hosts.ps1` targets `C:\Windows\System32\drivers\etc\hosts` (requires admin elevation).
  - `dialog.ps1` uses `Read-Host`-based prompts (Windows has no ncurses `dialog` binary).
- Fixed: `ps/helpers.ps1` — imported functions now survive into the caller's scope (`New-Module + Import-Module -Global`; previously dot-source inside a function discarded them on return).
- Fixed: `ps/scripts/*.ps1` — `SCRIPT_HELPERS_DIR` auto-detection now resolves to the repo root correctly (scripts live two levels below root, not one).
- Fixed: `ps/scripts/ci_node.ps1` — removed PS 7-only `??` null-coalescing operator; defaults to `node:22-alpine` when `CI_NODE_IMAGE` is unset.
- Fixed: `ps/scripts/ci_rust.ps1` — replaced `Invoke-Expression` with splatted `cargo` args to prevent injection from paths with spaces.
- Fixed: `ps/scripts/tag_release.ps1` — version regex now rejects trailing garbage while accepting pre-release suffixes (e.g. `1.2.3-rc1`).
- Fixed: `ps/lib/docker.ps1` — `docker_compose` now correctly invokes `docker-compose` binary when the plugin form is unavailable; `2>/dev/null` replaced with `2>$null`; CRLF-safe output splitting.
- Fixed: `ps/lib/os.ps1` — `run_with_optional_sudo` no longer passes a null arg when the command is a single token.
- Fixed: `ps/lib/traps.ps1` — `setup_exit_trap` unregisters the previous subscription before registering a new one, preventing duplicate exit handlers.
- Fixed: `ps/lib/file.ps1`, `ps/lib/dialog.ps1` — `-UseBasicParsing` gated to PS 5.1 only (removed deprecation warning on PS 7+).
- Fixed: `ps/lib/python.ps1` — `py` launcher now always passes `-3` when detecting version and creating venvs.
- Fixed: `ps/lib/deps.ps1`, `ps/lib/json.ps1` — replaced `command_exists` calls with `Get-Command` to remove hidden cross-module dependency.
- Fixed: `ps/lib/hosts.ps1` — domain existence checks and removal now use word-boundary regex to avoid false matches on substrings.
- Fixed: `ps/lib/help.ps1` — `show_usage` and `parse_common_args` now recognise `-h`/`--help`, `-v`/`--verbose`, `-d`/`--debug` aliases matching the Bash `help.sh` API; header-separator regex updated from `^#-{3,}` to `^#\s*-{3,}` to match the spaced `# ----` form used by all PS scripts.
- Fixed: `ps/lib/env.ps1` — `load_env` now calls `resolve_env_value` so `FOO=$BAR` references in `.env` files are expanded (the function existed but was never wired up).
- Fixed: `ps/lib/logging.ps1` — `log_info`/`log_warn`/`log_error`/`log_debug` now emit ANSI colour on stderr when the terminal supports it (`$_SHLIB_ANSI`); previously colour was silently dropped on the stderr path.
- Fixed: `ps/lib/dialog.ps1` — `dialog_menu` marks `$Items` as `[Parameter(Mandatory)]` to fail fast instead of infinite-looping when omitted; `dialog_input` return uses `$(if …)` subexpression for PS 5.1 compatibility.
- Fixed: `ps/lib/docker.ps1` — `get_docker_compose_cmd` now pre-checks Docker CLI existence before probing plugin availability.
- Fixed: `ps/lib/packaging.ps1` — `to_camel_case` guards empty parts and single-char segments; `pkg_join_list` uses `-join` operator instead of `Join-String` (PS 5.1 compatible; `Join-String` requires PS 6.2+).
- Fixed: `ps/lib/deps.ps1` — `winget install` uses query form (no `--id`) so generic names like `curl`, `git`, `jq` work without vendor-qualified IDs.
- Fixed: `ps/lib/browser.ps1` — `check_port_open` calls `EndConnect()` after `WaitOne` to surface refused connections; `WaitOne` alone returns `$true` on any completion, including failure.
- Fixed: `ps/lib/version.ps1` — `Set-Content` uses `-Encoding ascii` so the `VERSION` file stays Bash-readable (PS 5.1 default encoding is UTF-16 LE).
- Fixed: `ps/lib/hosts.ps1` — `Add-Content` and `Set-Content` use `-Encoding ascii` to preserve the ANSI format required by the Windows hosts parser.
- Fixed: `ps/scripts/ci_node.ps1`, `ci_python.ps1`, `ci_go.ps1`, `ci_rust.ps1` — Docker mode invokes executables directly (no `sh -c`) eliminating shell injection from user-controlled parameters.
- Fixed: `ps/scripts/ci_node.ps1` — `*Cmd` parameters changed to `string[]` token arrays for correct handling of arguments containing spaces or quotes.
- Fixed: `ps/scripts/ci_python.ps1` — `$TestCmd` changed to `string[]`; Docker pip install now skips when `requirements.txt` is absent, matching native mode behaviour.
- Fixed: `ps/scripts/bump_version.ps1` — missing `BumpType` now exits with code 1 (usage error) instead of 0.
- Added: `ps/lib/packaging.ps1` — `pkg_*` functions mirroring the Bash `packaging.sh` public API: `pkg_load_metadata`, `pkg_require_vars`, `pkg_trim`, `pkg_join_list`, `pkg_quote_list`, `pkg_render_lines`, `pkg_classify_name`, `pkg_guess_version`.

## 2026-05-21 — v0.13.0
- Changed: `scripts/git-hooks/pre-commit` — hardened for universal use across all repos:
  - Blocks accidental `.env` / `.env.*` file commits.
  - Docs lint (`lint_docs.sh`) skipped gracefully when the script is absent.
  - Release version check runs only on `release/*` branches (not on every commit).
- Added: `scripts/git-hooks/pre-push` — language-aware test runner (Node/Python/Go/Rust/Flutter) with auto-detection. Runs before every push; skip with `--no-verify` only when justified.
- Added: `scripts/setup-hooks.sh` — one-liner hook installer. Uses `.githooks/` when both shared hook entry points are overridden, otherwise falls back to `scripts/script-helpers/scripts/git-hooks/`, then `scripts/git-hooks/`.
- Added: `scripts/local_test_node.sh` — install + test for Node/npm projects (`--quick`, `--workspace`).
- Added: `scripts/local_test_python.sh` — venv-aware pytest runner that installs `requirements.txt` when present (`--quick`, `--dir`).
- Added: `scripts/local_test_go.sh` — `go vet` + `go test` across all modules (`--quick`, `--module`).
- Added: `scripts/local_test_rust.sh` — `cargo check` + `cargo clippy` + `cargo test` (`--quick`, `--manifest`).
- Added: `scripts/local_test_flutter.sh` — `flutter analyze` + `flutter test` (`--quick`, `--dir`).

## 2026-04-11 — v0.12.2
- Added: `scripts/check_release_tag.sh` so reusable workflows can perform release-tag checks via shared shell logic.
- Added: `scripts/ci_pimcore_bundle_check.sh` for reusable Pimcore bundle CI orchestration.
- Added: `scripts/ci_wp_plugin_check.sh` for reusable WordPress plugin-check CI orchestration.
- Added: `scripts/ci_gitleaks_report.sh` to normalize and evaluate Gitleaks SARIF output in reusable workflows.

## 2026-03-20 — v0.12.1
- Changed: Ollama model selection now uses a `dialog --menu` browser instead of the older radiolist/manual-entry flow.
- Changed: Ollama model browsers now default to official un-namespaced library models, sorted alphabetically, with a reusable parsed menu cache valid for 30 minutes.
- Changed: `ollama_dialog_select_size` now returns a distinct cancel status so callers can return to model selection instead of implicitly reusing an old size.
- Fixed: Ollama selector cache generation can be reused safely across repeated opens within the same session and across launches while the cache is still fresh.
- Fixed: Ollama selector cache refreshes now write atomically and ignore empty/stale cache files instead of reusing corrupted menu data.
- Fixed: Ollama size-selection warnings now go to stderr so stdout-only callers do not corrupt captured values.
- Added: dialog-based Ollama pull progress UI for runtime pulls, including model/layer/progress/speed/ETA parsing.
- Fixed: Dialog pull progress now cleans up background pulls on cancel and bounds progress-log parsing to the recent tail of the log file.

## 2026-02-13 — v0.12.0
- Added: Ollama runtime helpers in `lib/ollama.sh` for local/docker execution (`ollama_runtime_*`) and shared model ref builder (`ollama_model_ref`).
- Added: `is_wsl` helper in `lib/os.sh` for reusable WSL/WSL2 detection.
- Added: `DIALOG_DOWNLOAD_SHOW_ERROR_DIALOG` support in `lib/dialog.sh` to optionally suppress popup error dialogs from `dialog_download_file`.
- Docs: Updated README and module docs for Ollama runtime helpers, WSL detection, and dialog error-popup controls.
- Docs: Added missing `ollama_model_ref_safe` API entry in `docs/modules/ollama.md` to match exported helper aliases.

## 2026-02-01 — v0.11.1
- Changed: Ollama model index preparation now reuses an existing JSON when present and resolves Python 3 via `python3` or `python` (3.x). Adds apt-based installs for `python3-bs4`/`python3-requests` with a non-fatal `apt-get update` fallback.
- Docs: Updated Ollama module docs and README to cover Python resolution and dependency handling.
- Fixed: Skip `pip` requirement when `apt-get` can install Python deps.
- Fixed: Fail fast if Python deps fail to install and verify deps after install.
- Added: `python` module for resolving Python 3 and ensuring local virtualenvs.
- Added: `OLLAMA_MODELS_REPO_REF` to pin the models repo before executing its scripts.
- Fixed: pip installs for Ollama deps avoid `--user` when running as root.
- Fixed: Validate Ollama model index JSON before falling back after a failed refresh.
- Fixed: Validate venv Python executables before returning from `python_ensure_venv`.
- Added: `--digest` parameter to `ci_flutter.sh` for supply-chain image pinning.
- Added: `--gitleaks-digest` parameter to `ci_security.sh` for supply-chain image pinning.
- Added: `lib/ci_defaults.sh` module — centralized Docker image version defaults for all CI scripts. No more `:latest` tags; all images use pinned versions. Overridable via CLI flags or environment variables.
- Changed: CI helper scripts default to Docker and refuse to run when `CI=true` (local-only).
- Changed: Docker cache mounts in all `ci_*.sh` scripts now target `/tmp/` paths with corresponding env vars (`NPM_CONFIG_CACHE`, `PIP_CACHE_DIR`, `PUB_CACHE`, `GRADLE_USER_HOME`, `GOMODCACHE`) to avoid permission issues with non-root UIDs.
- Changed: `ci_python.sh` Docker mode now chains install and test commands in a single container so pip-installed packages persist for the test step.
- Changed: `ci_security.sh` uses `--python-version`, `--node-version`, `--gitleaks-version` with defaults; `--*-image` overrides take precedence.
- Changed: `ci_security.sh` computes `ABS_WORKDIR` inside Docker/no-Docker branches for consistency with other CI scripts.
- Fixed: `pin_production.sh` now resets local production branch from remote before merge, with fallback for first-run when remote production does not yet exist.
- Fixed: `check_release_version.sh` RC warning message is now clearer about when a pre-existing base tag is expected.
- Fixed: Consistent Docker-not-found error messages across all `ci_*.sh` scripts.
- Docs: Added CI helper usage notes and production-branch release guidance.
- Docs: Clarified that `check_release_version.sh` works in both local hooks and CI pipelines.
- Docs: Added `--version`, `--image`, and `--digest` examples to usage guide.

## 2026-01-11 — v0.10.0
- Added: Cross-distro packaging scaffolds (Debian, RPM, Arch, Homebrew) with shared metadata templates.
- Added: Packaging helper module and scripts to render templates and build RPM/Arch artifacts.
- Added: Packaging docs covering structure, build commands, signing notes, and install commands.
- Changed: Auto-tag workflow now opens a PR for VERSION bumps instead of pushing directly to protected `main`.
- Changed: Tag existence checks now verify exact refs to avoid false matches (e.g., `0.10.0` vs `0.1.0`).

## 2026-01-08 — v0.9.1
- Added: `lib/package_publish.sh` for shared Debian/PPA publishing helpers.
- Added: package publish example script.
- Changed: packaging scripts now use shared helpers via `shlib_import`.
- Changed: download dialog gauge uses fixed sizing and no-shadow to avoid visual artifacts.
- Added: Debian packaging helpers (`scripts/build_deb_artifacts.sh`, `scripts/ppa_upload.sh`).
- Added: Homebrew packaging helpers (`scripts/build_brew_tarball.sh`, `scripts/gen_brew_formula.sh`, `scripts/publish_homebrew.sh`).

## 2025-12-26 — v0.9.0
- Changed: Unified script help rendering across `display_help`, `print_help`, and `show_help` with a shared renderer.
- Changed: `-h/--help` now prefers script-level header help when the caller script is known.
- Fixed: Header parsing now only reads the top comment block and captures parameter lines reliably without pulling unrelated script comments.

## 2025-12-20 — v0.8.0
- Added: `version` module (`version_bump`, `version_compare`) with support for optional version file paths and preserving prefixes/suffixes.
- Changed: `scripts/bump_version.sh` now delegates to `version_bump` and accepts `-f/--file`.
- Changed: `version_compare` now returns -1/0/1 (surfaced as 255/0/1 in shells) and keeps higher codes for errors (2 missing args, 3 invalid format).
- Docs: Added module docs and usage examples for version helpers.

## 2025-12-16 — v0.7.0
- Changed: Docker checks now distinguish missing CLI, stopped daemon, and permission errors for clearer guidance (2025-12-16).

## 2025-12-16 — v0.6.0
- Changed: `init_include` now finds the caller project root reliably and keeps debug logging safe under `set -e` (2025-12-16).

## 2025-11-27 — v0.5.0
- Added: `docker_status` in `lib/docker.sh` to show running containers and cross-check services from the current directory's `docker-compose.yml`, marking statuses with glyphs (✅ running, 💥 failed, ✖️ not running). Includes example `scripts/example_docker_status.sh` and updates to README/Makefile (2025-11-27).
- Changed: Tweak download notification messages for clarity in the dialog gauge (2025-11-05).

## 2025-11-03 — v0.3.0
- Added: Dialog-based download progress gauge via `dialog_download_file`, showing percent, size, speed, and ETA. Integrated into `file.sh::download_file` with automatic fallback to `curl`/`wget` when needed (2025-11-03).
- Added: Example scripts for downloads, dialog input, logging, env, Docker Compose, and JSON helpers; `make examples` target to run demos (2025-11-03).
- Changed: On download failures, display a `dialog` error with exit code and recent output before falling back to non-interactive download (2025-11-03).
- Docs: Expanded README with usage, compatibility notes, and `DOWNLOAD_USE_DIALOG` behavior (2025-11-03).

## 2025-10-22 — v0.2.0
- Added: Ollama helpers (`lib/ollama.sh`) and model installer script (`scripts/install_ollama_model.sh`) to install and manage models via dialog selection or CLI (2025-10-18).
- Added: `CHANGELOG.md` to document notable changes (2025-10-17).
- Added: `scripts/bump_version.sh` to bump semantic version string in `VERSION` (2025-10-22).
- Changed: README install instructions and guidance for using this repo as a Git submodule (2025-10-18, 2025-10-22).
- Maintenance: Purged `RELEASE_CHECKLIST.md` from history; updated version metadata (2025-10-17, 2025-10-22).
- Docs: Unified script help headers across `scripts/*` for consistent usage output (2025-10-22).

## 2025-10-17 — v0.1.0
- Initial release: Bootstrapped reusable Bash helpers with loader `helpers.sh` and core modules: `logging.sh`, `dialog.sh`, `os.sh`, `deps.sh`, `docker.sh`, `file.sh`, `json.sh`, `env.sh`, `ports.sh`, `browser.sh`, `traps.sh`, `certs.sh`, `hosts.sh`, `clipboard.sh`, and `help.sh` (2025-10-17).
- Added: Tag and release automation (`scripts/tag_release.sh`) (2025-10-17).

---

Historical notes prior to this changelog may be incomplete or summarized retroactively.
