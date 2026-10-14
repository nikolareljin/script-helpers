# Adopt script-helpers in a repository

The steps to bring a repository onto script-helpers: the library, the git
hooks, the scanners and the test entry points. Each step stands alone; stop
after any of them.

## 1. Add the library

Vendor it as a git submodule at `scripts/script-helpers`, on the `production`
branch:

```bash
git submodule add -b production https://github.com/nikolareljin/script-helpers.git scripts/script-helpers
git submodule update --init --recursive
git commit -m "chore: vendor script-helpers"
```

Your scripts then load it with:

```bash
source "scripts/script-helpers/helpers.sh"
shlib_import logging env
```

Later updates: `git submodule update --remote scripts/script-helpers`, then
commit the new pointer. See [Installation](installation.md) and
[Usage](usage.md).

## 2. Install the git hooks

From the repository root:

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh
bash scripts/script-helpers/scripts/setup-hooks.sh --status   # what is installed
```

Hooks the repository already had (a team's, another tool's, `.git/hooks`)
keep running, after ours. `--uninstall` puts the previous setup back. To cover
every repository on the machine instead, use `--global`.

Installing here opts this repository in: it is always checked. With
`--global`, the checks apply only to the repositories you own; setup records
your GitHub account through `gh`. To count an organisation as yours too:

```bash
git config --global script-helpers.owners <org>[,<another>]
```

The repository-name check reads a list of your private repositories. Build it
once, with `gh` signed in, before the first push; without it a push is
refused as "could not check":

```bash
bash scripts/script-helpers/scripts/refresh_private_names.sh
```

Details: [Git hooks](git-hooks.md).

## 3. What a push then checks

| Group | Checks | On a finding |
|---|---|---|
| security | private repository names (public repositories), credentials (gitleaks), personal identifiers and PII | refused |
| hygiene | conflict markers, large or secret-looking files, release CHANGELOG and VERSION, AI trailers in commit messages | refused |
| lint | syntax and lint of the changed files, with the tools installed | refused |
| static analysis | foxguard on the changed files | warning only |

The checks read what the push sends; the repository-name check also reads
the tracked files. A normal push takes a few seconds.
Exceptions and limits: [Settings and exceptions](git-hooks.md#settings-and-exceptions).

## 4. The scanners

gitleaks and foxguard are pinned releases, checked against their SHA-256.
Setup offers both; a push installs a missing one, except in CI or with
`SCRIPT_HELPERS_NO_AUTO_INSTALL=1`. To install them now:

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh --install-gitleaks --install-foxguard
```

Without gitleaks a push is refused: the credential scan cannot run. Without
foxguard the push goes on with a warning. foxguard findings can be written to
a JSON report:

```bash
bash scripts/script-helpers/scripts/foxguard_report.sh --base origin/main --output foxguard-report.json
```

## 5. Tests

Tests do not run on push by default. Run them with:

```bash
make test        # when the repository has a test target
./dev test       # with the shared ./dev entry point
bash scripts/script-helpers/scripts/run_repo_tests.sh   # neither: detects the stack
```

`./dev` comes from `scripts/install_dev_cli.sh`:

```bash
bash scripts/script-helpers/scripts/install_dev_cli.sh
```

A repository whose tests run nowhere else (no CI test job) can run its quick
tests on every push:

```bash
git config script-helpers.push-tests quick
```

The push is then refused when a test fails, or when no tests are found.

## 6. Check the result

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh --status
```

Every script and its options: [Command reference](commands.md).
