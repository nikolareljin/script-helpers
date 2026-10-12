# Security gates in the git hooks

The shared hooks refuse three kinds of text before it leaves the machine, and
report a fourth:

| step | hook | on a hit |
|---|---|---|
| private repository names in a public repository (`check_private_names.sh`) | `commit-msg`, `pre-push` | block |
| credentials, through gitleaks (`check_sensitive.sh`) | `pre-commit`, `commit-msg`, `pre-push` | block |
| personal identifiers and PII (`check_sensitive.sh`) | `pre-commit`, `commit-msg`, `pre-push` | block |
| foxguard static analysis of the changed files | `pre-push` | warning only |

Order in `pre-push`: deletions-only shortcut, private names, credentials,
personal identifiers and PII, foxguard, then the repository's own `.githooks/pre-push` (which still gets the
ref lines), then the tests. A repository hook cannot skip the checks: it runs
after them. The steps live in `scripts/security_hooks.sh`.

## check_sensitive.sh

```bash
scripts/check_sensitive.sh --range origin/main..HEAD     # commits: added lines + messages
scripts/check_sensitive.sh --staged                      # the index
scripts/check_sensitive.sh --file pr-body.md             # a PR or issue body
gh pr view 12 --json body -q .body | scripts/check_sensitive.sh --stdin
scripts/check_sensitive.sh --list-identifiers            # what is checked, counts only
```

Only added text is checked. A commit that deletes a value passes; a push that
adds a value in one commit and removes it in the next is still refused, because
the push publishes both commits. Rewrite the commit that added it.

A pure rename adds nothing. A merge commit is read as a combined diff: only
lines it adds against every parent (a conflict resolution) count; the rest
came from a parent, which is checked as its own commit. A pushed annotated tag
adds its message (without the signature). A binary file has no lines to read:
it is named as `binary file not checked`, never skipped silently.

Since this change, a missing private-name list, gitleaks or checker script
refuses a push where it used to print "push allowed". Build the list and
install gitleaks, or let one push through with
`SECURITY_GATE_ALLOW_UNCHECKED=1 git push`.

A push checks what the target remote does not
have: a new branch is compared with that remote's refs only, so a commit
already on another remote (a private one) is still checked; a push to a bare
URL checks the branch's whole history. Private names are judged against the
push target's visibility, not origin's.

| exit | meaning | `pre-push` | `pre-commit`, `commit-msg` |
|---|---|---|---|
| 0 | nothing found | continue | continue |
| 1 | found | refuse | refuse |
| 2 | could not check (gitleaks missing or failed, commits unreadable, terms file or machine identifiers unreadable, `HOME` unset, a scan that crashed) | refuse; `SECURITY_GATE_ALLOW_UNCHECKED=1 git push` lets one push through, with a warning | warn; the push checks again |

A check that did not run is not a clean one. In `pre-push` every "could not
check" refuses: exit 2 from either checker, a checker script missing, commit
messages that could not be read. `SECURITY_GATE_ALLOW_UNCHECKED=1`
(`SENSITIVE_ALLOW_UNCHECKED=1` is the same) is narrower than `--no-verify`:
every check that can run still runs, and the output says what was skipped.

### What it looks for

- **Credentials**: gitleaks on the pushed commits (`gitleaks git --log-opts`,
  or `detect` on gitleaks 8.18 and older), the staged changes, or the file. A
  committed `.gitleaks.toml` is ignored: the default rules always apply. gitleaks is found on `PATH`,
  then in the cache `preflight.sh` installs into
  (`bash scripts/ci_security.sh --install-gitleaks`), or at `GITLEAKS_BIN`.
- **Personal terms**: every line of
  `${XDG_CONFIG_HOME:-~/.config}/script-helpers/sensitive-terms.txt`
  (`SENSITIVE_TERMS_FILE` overrides). One term per line, `#` comments, mode
  `0600`. It is never generated and never committed, so nothing can overwrite
  it. Put there what identifies you and is not a repository name: addresses,
  a VPN provider, a street, a family name.
- **This machine**, read at each run: non-loopback IPv4 and IPv6 addresses,
  default gateways, MAC addresses, the hostname and FQDN, the home directory.
  Loopback and Docker, bridge, veth and virbr interfaces are skipped. The
  public IP is checked only when cached:
  `scripts/check_sensitive.sh --refresh-public-ip` fetches it once. A push makes
  no network call.
- **PII**: email addresses, phone numbers, US social security numbers, payment
  card numbers (Luhn-checked, known test numbers pass).

A MAC address is matched written with `:` or `-`. Terms match whole tokens,
case-insensitive: a term `192.0.2.10` matches
`192.0.2.10:8080` but not `192.0.2.100` or `1.192.0.2.10`. These pass:
RFC 5737 addresses (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`),
`2001:db8::/32`, addresses at `example.com`/`.org`/`.net`, `.test`, `.invalid`,
`noreply` addresses including `users.noreply.github.com`, and the git
identity's own email.

Values are never printed. A term is cited by its line in the terms file, a
machine identifier by its kind, a PII hit masked (`jan***om`).

### Allowing a false positive

Each allow is printed, so it shows in the output:

| how | scope |
|---|---|
| `sensitive:allow` on the line | that line (PII and terms) |
| `.git/sensitive-allow`, one value or `@domain` per line | that clone (PII only; local, never committed, so cloned content cannot allow itself) |
| `SENSITIVE_ALLOW="a@example.org,@example.net"` | one run |
| `gitleaks:allow` on the line | credentials, that line |
| `.git/gitleaksignore`, gitleaks fingerprints | credentials, that clone (a committed `.gitleaksignore` is ignored here, so a commit cannot list its own key; `preflight.sh`'s secret scan still reads it) |

`--no-inline-allow` ignores `sensitive:allow`. The Claude Code hook uses it:
the agent writes the text it is checked on, so a marker in it is not an
allowance from the user.

## foxguard

foxguard is a static-analysis scanner,
[0sec-labs/foxguard](https://github.com/0sec-labs/foxguard). The hook runs it on
the files a push adds or changes and prints each line of output as
`[pre-push] WARNING (foxguard): ...`. It never blocks: its shell taint rules
flag correct code. Not installed: one notice line, and the push goes on.

It is looked up as `FOXGUARD_CMD`, then the pinned binary in
`~/.cache/script-helpers/foxguard/<version>/`, then `foxguard` on `PATH`.
Install the pinned release, checked against the SHA-256 in `lib/ci_defaults.sh`
(`CI_DEFAULT_FOXGUARD_VERSION`, `CI_DEFAULT_FOXGUARD_SHA256_*`):

```bash
bash scripts/ci_security.sh --install-foxguard
```

## Turning it on

### In one repository (the default)

```bash
bash <script-helpers>/scripts/setup-hooks.sh                 # git hooks
bash <script-helpers>/scripts/setup-hooks.sh --claude-repo   # Claude Code hook, this repository only
bash <script-helpers>/scripts/setup-hooks.sh --uninstall     # undo the git hooks (add --claude-repo for the Claude hook)
```

Only untracked files change: keys in `.git/config`, `.claude/settings.local.json`
(listed in `.git/info/exclude`), and the hook copies outside the repository.
`git status` is the same before and after, and `--uninstall` restores the old
values. A tool that sets up many repositories (git-lantern) runs these per
repository.

Hooks that already run here keep running:

| Before setup | After setup |
|---|---|
| no hooks, committed `.githooks/` or vendored script-helpers hooks | `core.hooksPath` points straight at them, as before |
| executable hooks in `.git/hooks` | chained |
| a local `core.hooksPath` from another tool (husky, an employer's tooling) | saved as `script-helpers.previous-hooksPath`, chained |
| a global `core.hooksPath` (an employer's, or `--global`) | chained; the global value is not touched |

Chained means `core.hooksPath` points at a per-repository copy of the wrappers
in `<data>/script-helpers/repo-hooks`, one for every git hook name, and each
runs, in order, stopping at the first failure:

1. the security checks, in the configured owners' repositories only;
2. this repository's committed hooks (`script-helpers.hooks-target`);
3. what git ran before: the saved local `core.hooksPath`, else the global one,
   else `.git/hooks`, with git's arguments and stdin.

So a hook name only the other tool has (`commit-msg`, `post-checkout`) still
runs. If another tool later rewrites `core.hooksPath` (`husky install`,
`pre-commit install`), its hooks keep working and ours stop; `--status` shows
it, and running setup again chains them again.

Not reachable from git: hooks an IDE runs itself (a JetBrains or VS Code
pre-commit check) and server-side hooks. They are never touched, so they keep
working, but nothing here runs alongside them.

### On a whole machine (optional, off by default)

None of this changes code in any repository: it writes `~/.gitconfig`,
`~/.claude/settings.json` and copies outside every repository. It does change
what runs in every repository on the machine, so it is opt-in.

```bash
git config --global script-helpers.owners <your-github-user-or-org>[,<another>]
bash <script-helpers>/scripts/setup-hooks.sh --global
bash <script-helpers>/scripts/setup-hooks.sh --status
```

`--global` copies the hooks and their own copy of the check scripts to
`${XDG_DATA_HOME:-~/.local/share}/script-helpers/git-hooks`, prints the current
global `core.hooksPath`, saves it, and points the global value at the copy. The
copy does not depend on any checkout; run `--global` again to update it.

- Checked: a repository where the URL being pushed to (`pre-push`) or any
  fetch or push URL of any remote is on github.com under one of the owners:
  `https://github.com/<owner>/<repo>` (with or without `.git` or user info),
  `git@github.com:<owner>/<repo>`, `ssh://git@github.com/<owner>/<repo>`.
  Host and owner must match exactly, case-insensitive: `<owner>-fork` is
  another owner.
- Fails closed (`scripts/owner_scope.sh`): a URL that does not parse but has an
  owner as a whole path segment (`https://github.com.evil/<owner>/x`, a mirror
  on another host) is checked; remotes that cannot be listed mean checked.
  `SCRIPT_HELPERS_OWNERS` overrides the git config.
- Every other repository (another org, a fork of someone else's, no remote
  and a push elsewhere) gets a pure pass-through: the hook git would have run
  without the install runs (see Chaining) and nothing is added.
- No owners configured: `--global` refuses (exit 2), and an installed hook
  passes everything through with one notice per push.
- Chaining: after the checks, the hook git would have run without the install
  runs, with git's arguments and stdin, and its exit status is the hook's: the
  previous global hooks directory's `<hook>` if one was set, else an executable
  `.git/hooks/<hook>`. Committed hooks (`.githooks/<hook>`,
  `scripts/git-hooks/<hook>`, or a relative earlier `core.hooksPath`) run only
  in an owner's repository whose clone opted in locally with
  `git config --local script-helpers.trust-repo-hooks true` (the per-repository
  `setup-hooks.sh` sets it). Anywhere else they never run: that would execute
  code from whatever was cloned, which git does not do by itself. The checks
  and the scope logic always come from the installed copy, never from the
  repository.
- A repository with its own `core.hooksPath` ignores the global value. Run
  `setup-hooks.sh` in it: its own hooks are kept and chained (see above).

`bash <script-helpers>/scripts/setup-hooks.sh --global --uninstall` restores
the saved value (or unsets it) and removes the copy.

### Claude Code

Scope: the hook checks a command only when the session's repository (the
payload `cwd`) has its origin on github.com under a configured owner. The
origin is read as git uses it (`git remote get-url origin`, so
`url.<base>.insteadOf` aliases apply) and judged as the git hooks judge a URL:
one that does not parse but names an owner as a path segment
(`ssh://github.com/<owner>/x`, port 443) is in scope. Anywhere else (another owner, no repository, no usable `cwd`, no owners) it
exits 0 and does nothing. The command is not read to widen or narrow that, so
a command run from elsewhere that acts on an owner's repository (`cd`, `-C`,
`-R`, `gh api`, `curl`, a path) is out of scope by the owner's decision; that
repository's `pre-push` hook still covers its pushes.

In scope, `scripts/claude-hooks/pretooluse_private_names.sh` also runs
`check_sensitive.sh` on the text of a `gh pr create`, `gh issue comment`,
`git commit -m` and the like, and refuses the tool call on a hit.
It reads `-b`/`--body`, `--body-file`, `-t`, `-m`, `-F`, `gh api -f`/`-F`/
`--raw-field` (and `key=@file`), `--notes`/`--notes-file`, attached short
values (`-b'text'`), and sees the command behind `VAR=value`, `env` and git's
global options. `git tag -m` counts as publishing. `--no-verify` on a commit
or push is refused, and so is its short form `git commit -n` (also in a
cluster such as `-an`).

Every Bash call is also checked as a whole, whatever it looks like, because a
parser of shell commands always misses some shape bash runs (`bash -c`,
`$(...)`, backticks, quoting such as `g''it`, aliases):

- the whole command text, also with quotes and backslashes removed, plus every
  file it names that can be read (`--body-file X`, `-F X`, `@X`, `< X`), goes
  through the private-name check and `check_sensitive.sh --no-machine
  --no-inline-allow`. Paths after `cd` and `-C` are left out of the text.
  In scope, private names are checked in every command, including one run
  inside a private repository and a pull request into one: agents cite a
  private repository by its code in command text, never by name.
- refused outright: `--no-verify`, `git commit -n`, a `core.hooksPath`
  override (`-c`, `GIT_CONFIG_*`); a command that sets the gate's own
  overrides or configuration (`SECURITY_GATE_ALLOW_UNCHECKED=`,
  `SENSITIVE_ALLOW=`, `PRIVATE_NAMES_ALLOW=`, `HOME=`, `export ...`,
  `script-helpers.owners`, writing the allow, terms or name lists); and
  `eval`, `xargs`, `source` or a variable as the command next to a publishing
  verb. Overrides count only from the hook's own environment, set by the
  user.

The private-name check takes seconds on a large list, so a cheap test runs
first: if no listed name occurs in the text in any case, with `-`, `_`, `.`
and spaces ignored, the full check is not needed. The full check is one awk
pass over the list. Measured on a 4,800-name list: about 180 ms per ordinary
command, about 250 ms for a command that names a listed repository (about 14 s
with the old per-name loop). `tests/claude_hook_destinations_test.sh` holds a hit against
5,000 names under 2 s.
Nothing is allowed without that scan: another tool's payload (Write, Edit, if
the hook is wired to them) is scanned as every string of its input; a payload
that is not valid JSON or not UTF-8, or a machine without python3, has the raw
payload scanned, and a publishing command there is refused as "could not
check". The script's header lists every remaining way it allows a call. A check that could not run (no private-name list,
gitleaks missing, a checker error) refuses the call; only
`SECURITY_GATE_ALLOW_UNCHECKED=1`, set by the user, lets it through. A body
it cannot read (`--body-file -`, a missing file) and an unreadable payload for
a publishing command count as "could not check". The checkers' exit codes map
one to one: 0 allows, 1 refuses with the reason, 2 refuses as above.

## Set it up on a machine

Per repository is the default: see "In one repository" above. The commands
below are the optional machine-wide install, both gates for your user: the git
hooks (`--global`) and the Claude Code hook (`--claude`). Rerun at any time; a
second run changes nothing, and a run from a newer checkout updates the
installed copy.

### Prerequisites

| What | Why | Check |
|---|---|---|
| bash, git | the hooks are bash scripts | `git --version` |
| Python 3 (`python3`, or `python` on Windows) | parses the hook payload and merges `settings.json` | `python3 --version` |
| Git for Windows (Windows only) | Claude Code runs hooks through Git Bash | `git --version` in PowerShell |
| owners | only their github.com repositories are checked | `git config --global script-helpers.owners` |
| gitleaks | secret scan; without it every command in your repositories is refused as "could not check" | `setup-hooks.sh --install-gitleaks` installs the pinned build |
| private-name list | `~/.config/script-helpers/private-names.tsv`; without it every command in your repositories is refused as "could not check" | `refresh_private_names.sh` |

### Linux and macOS

```bash
git config --global script-helpers.owners <your-github-user-or-org>
bash <script-helpers>/scripts/setup-hooks.sh --all
bash <script-helpers>/scripts/setup-hooks.sh --doctor
```

### Windows

PowerShell:

```powershell
git config --global script-helpers.owners <your-github-user-or-org>
powershell -NoProfile -ExecutionPolicy Bypass -File <script-helpers>\scripts\setup-hooks.ps1 --all
powershell -NoProfile -ExecutionPolicy Bypass -File <script-helpers>\scripts\setup-hooks.ps1 --doctor
```

Git Bash: the same commands as on Linux. `setup-hooks.ps1` finds Git Bash
(`CLAUDE_CODE_GIT_BASH_PATH`, next to `git.exe`, or the standard install
folders) and runs `setup-hooks.sh` with the same arguments. Without Git Bash it
stops with exit 2 and names what to install.

### What it writes

| Command | Writes |
|---|---|
| (none) | `core.hooksPath` and `script-helpers.*` keys in this repository's `.git/config`; when chaining, the wrapper copy in `<data>/script-helpers/repo-hooks` |
| `--claude-repo` | one entry in this repository's `.claude/settings.local.json` and a line in `.git/info/exclude`; the hook copy in `<data>/script-helpers/claude-repo-hooks`; backups in `.git/script-helpers/claude-backups` |
| `--global` | the hooks copy in `<data>/script-helpers/git-hooks`; global `core.hooksPath` (old value saved) |
| `--claude` | the hook copy in `<data>/script-helpers/claude-hooks`; one `PreToolUse` entry in `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` (matcher `Bash`, timeout 60, `"shell": "bash"`, and `"onFailure": "block"` when `claude --version` is 2.1.295 or newer), after a `settings.json.bak-<time>` copy |
| `--all` | both |
| `--managed` | the entry in the OS managed settings file, and the hook copy in `script-helpers/` beside it (admin only, see below) |

`<data>` is `%LOCALAPPDATA%` on Windows, else `${XDG_DATA_HOME:-~/.local/share}`.
Every other key and hook in `settings.json` is kept; an older entry for the
same hook (another path) is replaced. A `settings.json` that is not valid JSON
is refused (exit 3) and left as it is. CRLF line endings and a BOM are kept.

`--managed` writes `/etc/claude-code/managed-settings.json` (Linux),
`/Library/Application Support/ClaudeCode/managed-settings.json` (macOS) or
`C:\Program Files\ClaudeCode\managed-settings.json` (Windows). No user or
project setting can turn that off. It needs an admin shell (`sudo bash
setup-hooks.sh --managed`, or an elevated PowerShell); without write access it
refuses with exit 2 and never runs sudo itself.

### Undo

```bash
bash <script-helpers>/scripts/setup-hooks.sh --all --uninstall      # or --global / --claude / --managed
bash <script-helpers>/scripts/setup-hooks.sh --uninstall            # in a repository: its git hooks
bash <script-helpers>/scripts/setup-hooks.sh --claude-repo --uninstall
```

This removes only the script-helpers entry and the installed copies, and
restores the saved global `core.hooksPath`.

### Troubleshooting

- `--status` shows what is installed and the prerequisites; `--doctor` also
  runs four probes through the installed hook, from a throwaway repository
  under the first owner, and prints the time each took: a private name from
  your list, an SSN-shaped number and a push that skips the hooks must each be
  refused for that reason, with the deny decision on stdout; `ls` must pass.
  A refusal for another reason (no name list, no gitleaks, a crash) is a
  failure, and the hook's own first lines are shown. The probed name is never
  printed.
- Without `"onFailure": "block"` (Claude Code older than 2.1.295), a hook
  that times out, or exits with anything but 0 or 2, lets the command run;
  `--status` and `--doctor` warn about it. Update Claude Code and run
  `--claude` again. The timeout is 60 s; the hook normally answers in well
  under 1 s. A `--doctor` probe near the limit means something is wrong.
- A refusal is exit 2 with the reason on stderr, and the same reason as a
  `PreToolUse` deny decision (JSON) on stdout.
- In Claude Code, `/hooks` lists the entry. Settings are read when a session
  starts: open a new session after installing.
- `no owners configured` (exit 2): set the owners first (above).
- A hook copy that was deleted fails open; `--doctor` reports it, and
  `--claude` reinstalls it.
