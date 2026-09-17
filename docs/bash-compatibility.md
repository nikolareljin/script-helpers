# Bash compatibility

**Short version: bash 3.2 is the floor, not the target. Everything here runs on
bash 4 and 5, and `./dev` prefers them.**

The library is written so that stock macOS can use it without installing
anything. That is a *minimum*, not a ceiling — nothing is held back to 3.2-era
behaviour on a machine that has something newer.

## Which bash actually runs

| Situation | What runs |
|---|---|
| Linux, most containers | bash 5.x — whatever `/usr/bin/env bash` finds |
| macOS with Homebrew bash | bash 5.x from `/opt/homebrew/bin` or `/usr/local/bin` |
| macOS with nothing installed | bash 3.2, `/bin/bash` |
| Anything older than 3.2 | refused at load, with a message |

`./dev` resolves this deliberately, in this order:

```
$BASH → /opt/homebrew/bin/bash → /usr/local/bin/bash → $(command -v bash) → /bin/bash
```

`/bin/bash` is **last**. That ordering exists so a Mac with a modern bash
installed actually uses it: a bare `exec bash` would resolve from `PATH` and
discard the script's own shebang, which on macOS lands back on 3.2.

`helpers.sh` refuses anything below 3.2 outright, and exports
`SHLIB_BASH_LEGACY=1` on bash 3.x, `0` on 4.0 and newer. On 3.x it prints a
one-time note on **stderr**, and only to a terminal, naming the fix for that
host. Silence it with `SHLIB_NO_BASH_ADVISORY=1`.

## Why 3.2 is the floor

macOS ships bash 3.2 as `/bin/bash` and always will: bash 4 moved to GPLv3,
which Apple does not ship. That is not going to change, so a shell library that
requires bash 4 is a shell library that requires every Mac user to install
something before anything works.

This was not true for the first twenty-three releases, which is why there are
now two gates rather than a convention:

```bash
make test-bash32                 # the whole suite under a real bash 3.2, in Docker
bash tests/portability_test.sh   # static scan for bash-4-only and GNU-only constructs
```

CI runs the suite on macOS under `/bin/bash` for every change touching shell
code. `make test-bash32` needs no Mac — it runs the same suite in the
`bash:3.2` image.

## What that costs, in practice

These are bash 4+ features, and they are **not** used in `lib/`:

| Feature | Use instead |
|---|---|
| `mapfile` / `readarray` | `while IFS= read -r line; do arr+=("$line"); done < <(...)` |
| Associative arrays (`declare -A`) | a newline-delimited string, or parallel arrays |
| Namerefs (`declare -n`) | print a value and capture it, or pass a name and `eval` carefully |
| `${var^^}` / `${var,,}` | `tr '[:lower:]' '[:upper:]'` |
| `shopt -s globstar` (`**`) | `find` |
| `&>>` | `>>file 2>&1` |

The same discipline rules out GNU-only tool flags, because macOS ships BSD
versions: no `sed -i`/`sed -r`, no `readlink -f`, no `realpath`, no `grep -P`,
no `date -d`, no `find -printf`, no `xargs -r`, no `base64 -w`, no
`md5sum`/`sha256sum`, and no `\s` or `\b` in a grep or sed pattern.

`tests/portability_test.sh` enforces every one of those statically, over
tracked **and untracked** files — so a new script is checked before it is
committed.

## When a function genuinely needs bash 4

Some things cannot be done on 3.2 at all. The clearest case is a function that
takes an **associative array from the caller**: there is no way to receive one
on 3.2, so there is nothing to degrade to.

Three functions are in that position — `select_distro`,
`select_multiple_distros` and `download_iso`. They do not silently misbehave;
they call `require_bash4` and fail with a message naming the feature and, on
macOS, the remedy:

```bash
require_bash4 "select_distro (DISTROS associative array)" || return 1
```

For anything conditional rather than absolute, use `bash_at_least`:

```bash
if bash_at_least 4 3; then
  # nameref path
else
  # 3.2 path
fi
```

Both live in [`os`](modules/os.md), along with `bash_major`.

## Adding a new module

Write it 3.2-safe. It then runs everywhere, 4+ included, and both gates pass
without you thinking about them again.

Reach for `require_bash4` **only** when the feature is impossible on 3.2 rather
than merely more convenient with bash 4 — and when you do, add the file to the
allow-list in `tests/portability_test.sh` with a comment saying why, so the
exception is visible rather than assumed.

If you find yourself wanting an associative array, a newline-delimited string
usually does the job — `scripts/lint_docs.sh` uses one exactly where a map would
be the obvious bash 4 answer, and says so in a comment.
