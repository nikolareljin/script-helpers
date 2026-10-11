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

### In one repository

```bash
bash scripts/script-helpers/scripts/setup-hooks.sh     # or vendor/script-helpers/...
```

This sets the repository's `core.hooksPath` to the shared hooks. They run the
checks for every push from that repository, whoever owns it: the repository
opted in.

### On a whole machine

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
  `setup-hooks.sh` in it so its hooks carry the checks.

`bash <script-helpers>/scripts/setup-hooks.sh --global --uninstall` restores
the saved value (or unsets it) and removes the copy.

### Claude Code

`scripts/claude-hooks/pretooluse_private_names.sh` also runs
`check_sensitive.sh` on the text of a `gh pr create`, `gh issue comment`,
`git commit -m` and the like, and refuses the tool call on a hit. With owners
configured it does so for their repositories, judged from `-R`, every
remote of the current directory, and every remote of the directory the command
runs in (`cd <dir> && gh ...`, `git -C <dir> commit`); with nothing to judge
from (no `-R`, not in a repository, a directory it cannot enter) it checks.
It reads `-b`/`--body`, `--body-file`, `-t`, `-m`, `-F`, `gh api -f`/`-F`/
`--raw-field` (and `key=@file`), `--notes`/`--notes-file`, attached short
values (`-b'text'`), and sees the command behind `VAR=value`, `env` and git's
global options. `git tag -m` counts as publishing. `--no-verify` on a commit
or push is refused, and so is its short form `git commit -n` (also in a
cluster such as `-an`). A check that could not run (no private-name list,
gitleaks missing, a checker error) refuses the call; only
`SECURITY_GATE_ALLOW_UNCHECKED=1`, set by the user, lets it through. A body
it cannot read (`--body-file -`, a missing file) and an unreadable payload for
a publishing command count as "could not check". The checkers' exit codes map
one to one: 0 allows, 1 refuses with the reason, 2 refuses as above.
