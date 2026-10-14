# Git hooks

script-helpers ships git hooks that stop secrets, private repository names and
broken files before they leave your machine. A push runs fast checks of what
it sends; tests run when you ask for them.

## What runs when

| Hook | When | Blocks on |
|---|---|---|
| `pre-commit` | `git commit` | credentials (gitleaks), personal identifiers and PII in the staged lines; a staged `.env` file |
| `commit-msg` | `git commit` | a private repository name, credentials or PII in the message |
| `pre-push` | `git push` | security, hygiene and lint of the commits and files the push sends (below) |

Tests do not run on commit or push. Run them with `make test` or `./dev test`
(or `scripts/run_repo_tests.sh` in a repository with neither).

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

- Any value other than `quick` or `off` refuses the push, so a typo does not
  turn the tests off.
- A repository where no tests are found refuses the push too: opting in with
  nothing to run is not a pass.
- With the global hooks, the setting works only in the repositories of
  `script-helpers.owners`; anywhere else the push says the tests were not run.

## Set up

Configure whose repositories are checked, once per machine. Installing refuses
until this is set:

```bash
git config --global script-helpers.owners <user-or-org>[,<another>]
```

Then, from a repository's root:

```bash
# Inside the script-helpers repo
bash scripts/setup-hooks.sh

# In a repository that vendors script-helpers
bash scripts/script-helpers/scripts/setup-hooks.sh
```

| Command | What it does |
|---|---|
| `setup-hooks.sh` | this repository: point `core.hooksPath` at the hooks; hooks that already ran here (another tool's, an employer's, `.git/hooks`) are kept and chained after ours |
| `setup-hooks.sh --global` | every repository on the machine (opt-in); a repository with its own `core.hooksPath` keeps it |
| `setup-hooks.sh --status` | what is installed here, and the prerequisites (gitleaks, the name list, SSH keepalive, lint tools) |
| `setup-hooks.sh --status --porcelain` | the same as one machine-readable line |
| `setup-hooks.sh --repair` | chain again after another tool replaced `core.hooksPath` (husky does on `npm install`) |
| `setup-hooks.sh --uninstall` | undo; the previous `core.hooksPath` comes back |
| `setup-hooks.sh --claude`, `--agent <list>` | the same checks for AI agents' shell commands (Claude Code, Codex, Gemini, Copilot CLI, Cursor) |
| `setup-hooks.sh --doctor` | the prerequisites, then probes through the installed agent hook |

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
- A lint tool that is not installed is named and skipped; `--status` lists them.
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
the push exits 141 with `Connection to github.com closed by remote host`. The
hook prints a note before the checks when no keepalive is set. Set one:

| Scope | Set it with |
|---|---|
| every repository | `~/.ssh/config`: `Host github.com` then `  ServerAliveInterval 20` |
| one repository | `git config core.sshCommand "ssh -o ServerAliveInterval=20"` |
| one push | `GIT_SSH_COMMAND="ssh -o ServerAliveInterval=20" git push` |

An HTTPS remote is not affected.
