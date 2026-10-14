# Git hooks

script-helpers ships git hooks that stop secrets, private repository names and
broken files before they leave your machine. A push runs fast checks of what
it sends; tests run when you ask for them, or on push in a repository that
opts in.

## What runs when

| Hook | When | Blocks on |
|---|---|---|
| `pre-commit` | `git commit` | credentials (gitleaks), personal identifiers and PII in the staged lines; a staged `.env` file |
| `commit-msg` | `git commit` | a private repository name, credentials or PII in the message |
| `pre-push` | `git push` | security, hygiene and lint of the commits and files the push sends (below) |

By default, tests do not run on commit or push. Run them with `make test` or
`./dev test` (or `scripts/script-helpers/scripts/run_repo_tests.sh` in a
repository with neither).

### Tests on push, for repositories with no CI test gate

A repository whose tests run nowhere else (no pull request workflow, for
example a private one that keeps Actions minutes down) can make the push run
its quick tests and refuse on a failure:

```bash
git config script-helpers.push-tests quick   # in that repository
git config script-helpers.push-tests off     # back to no tests on push
```

`quick` runs `scripts/run_repo_tests.sh` after the other push checks: the
`preflight.sh --quick` from the vendored script-helpers when it has one (the
checks the repository's CI runs), otherwise the stack's quick
test runner (PHP, Node, Python, Go, Gradle, Rust, Flutter), `make test`, bats
or `tests/*_test.sh`. The push then takes as long as those tests.

- Any value other than `quick`, `off` or `false` refuses the push, so a typo
  does not turn the tests off.
- A repository where no tests are found refuses the push too: opting in with
  nothing to run is not a pass.
- `run_repo_tests.sh` exits 0 (passed, or no tests without `--require`), 1
  (tests failed; the runner's own code is in the message), 2 (usage) or 4 (no
  tests, with `--require`).
- With the global hooks, the setting works only in your own repositories
  (`script-helpers.github-user`, `script-helpers.owners`); anywhere else the
  push says the tests were not run.

## Set up

The checks run in the repositories you own: those of your GitHub account,
public or private, and of any organisation you count as your own. Other
repositories run only their own hooks.

- Your account is found for you: when `gh` is signed in, setup records it as
  `script-helpers.github-user`.
- Add organisations, or set the account by hand where `gh` is not available:

```bash
git config --global script-helpers.owners <org>[,<another>]
```

With neither, the global and agent hooks check no repository, and `--global`
and the agent hooks refuse to install. A repository where you run
`setup-hooks.sh` itself is always checked: installing there opts it in.

Then, from a repository's root:

```bash
# Inside the script-helpers repo
bash scripts/setup-hooks.sh

# In a repository that vendors script-helpers
bash scripts/script-helpers/scripts/setup-hooks.sh
```

| Command | What it does |
|---|---|
| `setup-hooks.sh` | this repository: point `core.hooksPath` at the hooks; hooks that already ran here (another tool's, a team's, `.git/hooks`) are kept and chained after ours |
| `setup-hooks.sh --global` | every repository on the machine (opt-in); a repository with its own `core.hooksPath` keeps it |
| `setup-hooks.sh --status` | what is installed here, and the prerequisites (gitleaks, foxguard, owners, the name list, SSH keepalive, lint tools) |
| `setup-hooks.sh --status --porcelain` | the same as one machine-readable line |
| `setup-hooks.sh --repair` | chain again after another tool replaced `core.hooksPath` (husky does on `npm install`) |
| `setup-hooks.sh --uninstall` | undo; the previous `core.hooksPath` comes back |
| `setup-hooks.sh --claude`, `--agent <list>` | the same checks for AI agents' shell commands (Claude Code, Codex, Gemini, Copilot CLI, Cursor) |
| `setup-hooks.sh --doctor` | the prerequisites, then probes through the installed agent hook |

### The scanners: gitleaks and foxguard

Both are pinned releases, downloaded and checked against their SHA-256, for
Linux and macOS (x86_64 and arm64) and Windows (x86_64). Every install above
offers them when they are missing, and `--status` shows both. To install them
yourself:

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh --install-gitleaks --install-foxguard
```

A push with one missing installs it, then runs the scan. When that cannot
happen (no binary for the machine, no network, in CI, or with
`SCRIPT_HELPERS_NO_AUTO_INSTALL=1`):

| Missing | The push |
|---|---|
| gitleaks | `ERROR`: the credential scan cannot run; refused |
| foxguard | a framed `WARNING` that the static-analysis scan did not run; goes on |

Both print the command that installs the tool.

foxguard never blocks a push. Every line it reports is shown, then a framed
summary, the command that writes the same findings as formatted JSON (to keep
as evidence, or to compare later), and a pointer to
[leak-lock](https://github.com/nikolareljin/leak-lock), a VS Code extension for
reviewing findings and secrets across the whole history:

```bash
bash scripts/script-helpers/scripts/foxguard_report.sh --base origin/main --output foxguard-report.json
```

Hooks other tools installed keep working: ours run first, then theirs. Removing
ours restores what was there before. See `setup-hooks.sh --help` for every
option.

## What a push checks

`pre-push` blocks on what must not leave the machine. It reads only the commits
and files the push sends, and every check runs to the end; a first or very large
push takes longer.

| Group | Checks |
|---|---|
| security | private repository names, credentials (gitleaks), personal identifiers and PII; foxguard as warnings ([Security gates](security-gates.md)) |
| hygiene | conflict markers (`<<<<<<<` or `>>>>>>>` at a line start); files over `script-helpers.max-file-mb` (default 5) MB; secret-looking names (`.env`, `*.pem`, `*.key`, `id_rsa`, `*.p12`, `.netrc`, `*.tfstate`, ...); on `release/X.Y.Z`, the CHANGELOG release heading and `VERSION`; in the owners' repositories, commit trailers or `Generated with` lines naming an AI tool; with `script-helpers.ascii-commits`, commit messages in plain ASCII |
| lint | `bash -n` and `shellcheck -S warning`; `ruff` (the repository's config, else only fatal rules) or a Python syntax parse; the repository's `eslint` when installed in `node_modules`; `gofmt -l -e`; `rustfmt --check` when the repository has a rustfmt config; `actionlint` for workflows; JSON and YAML parse; PowerShell parse |

How it reads files:

- The content being pushed, from git, not the work tree: an uncommitted edit
  cannot hide a problem or cause one, and a CRLF checkout is checked as pushed.
- Nothing is written to disk, not even a temporary file: each file goes from git
  to its tool through a pipe.
- A symbolic link is not linted: the push sends the link, not its target.
- A lint tool that is not installed is named and skipped; `--status` lists
  which of shellcheck, ruff, actionlint, gofmt, rustfmt and pwsh are installed.
- In a chained setup the checks run once per push.

## Settings and exceptions

| Setting | Effect |
|---|---|
| `git config script-helpers.max-file-mb <n>` | the file-size limit, in MB (default 5) |
| `.script-helpers-push-allow` | in the repository: one glob per line (`#` comments) exempt from the name and size checks |
| `git config script-helpers.ai-trailers allow` | no AI-trailer check in this repository |
| `git config script-helpers.ascii-commits true` | commit messages must be plain ASCII |
| `git config script-helpers.push-tests quick` | the push runs the quick tests and refuses on a failure ([above](#tests-on-push-for-repositories-with-no-ci-test-gate)) |
| a Makefile target `lint-changed` | replaces the lint group; gets the changed files, one per line, in `CHANGED_FILES` |

`lint-changed` and the repository's `eslint` are the repository's own code, so
they run only when the hook is too (script-helpers vendored and tracked). The
chained and global installs run none of it.

`git push --no-verify` skips every check, the private-name one too.

## Long pushes over SSH

git opens the push's connection before `pre-push` runs and keeps it idle until
the checks pass. Over SSH a long run (a first or very large push) can be cut off:
the push exits 141 with `Connection to github.com closed by remote host`, after
the checks passed. The hook prints a note before the checks when no keepalive is
set, and `setup-hooks.sh --status` reports it. Set one:

| Scope | Set it with |
|---|---|
| every repository | `~/.ssh/config`: `Host github.com` then `  ServerAliveInterval 20` |
| one repository | `git config core.sshCommand "ssh -o ServerAliveInterval=20"` |
| one push | `GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push` |

`ServerAliveInterval 20` sends a keepalive every 20 seconds. With the default
`ServerAliveCountMax 3` the connection still ends after about a minute if the
server stops answering; add `-o ServerAliveCountMax=60` to wait longer.

An HTTPS remote is not affected: git makes a new request after the hook.
