# Local models with Ollama

How a project uses `lib/ollama_endpoint.sh` and the dialog wrappers in
`lib/dialog.sh`: what to put in the repository, what the start script does,
what the person running it sees, how to test it, and how to change it.

The idea in one paragraph: a project names the models it needs in one file.
Its start script asks an Ollama which of them it already has, asks the
registry how big the rest are, checks that the download and the largest model
fit this machine, and only then pulls. Nothing is pulled unless everything
fits, so a start never ends with half its models. Every question goes over
Ollama's HTTP API, so the same code works for an Ollama on this machine and
for one in a container.

Contents

- [What goes into a repository](#what-goes-into-a-repository)
- [The start script](#the-start-script)
- [What the person sees](#what-the-person-sees)
- [Settings](#settings)
- [Exit codes and what to do with them](#exit-codes-and-what-to-do-with-them)
- [Dialog boxes from a script that captures output](#dialog-boxes-from-a-script-that-captures-output)
- [Testing a project that uses this](#testing-a-project-that-uses-this)
- [Developing the module](#developing-the-module)
- [Limits, and what comes next](#limits-and-what-comes-next)

What goes into a repository
---------------------------

1. **`script-helpers` as a submodule**, at a released tag. The functions below
   exist from the release after 0.44.1.

2. **One models file**, by convention `ai-models.env` at the repository root,
   one `NAME=model` per line:

   ```
   # generated: do not edit by hand (see the fleet model registry)
   OLLAMA_MODEL=qwen2.5:7b
   CLASSIFY_MODEL=qwen2.5:3b
   VLM_MODEL=qwen2.5vl:3b
   OLLAMA_EMBED_MODEL=nomic-embed-text
   OLLAMA_MODEL_LARGE=qwen3.5:9b
   OLLAMA_MODEL_LARGE_VRAM_GB=11
   AI_TIER_LARGE_RAM_GB=30
   ```

   The file is read like an env file: `export ` before a name, spaces around
   `=`, one pair of quotes, a trailing ` # comment`, Windows line ends and a
   byte-order mark are all tolerated. A name ending in `_SMALL`, `_LARGE` or
   `_XLARGE` is the model for another class of machine; a name ending in
   `_RAM_GB` or `_VRAM_GB` after that is a number for the pick. Neither is a
   model this machine needs by default, and `ollama_models_required` skips
   them.

   In this workspace the file is generated from one registry and must not be
   edited by hand; the header says where it comes from. A project outside the
   workspace writes it by hand.

3. **The application reads the same file.** The models the start script
   checks must be the models the code uses, or the check proves nothing. The
   application reads `ai-models.env` (and lets a real environment variable
   win), and no model name is written anywhere else. A test that greps the
   code for model names and fails on a second copy is cheap and worth it.

4. **A `.env` for the machine**, optional and never committed. A model name
   set there wins over the file (`OLLAMA_MODEL=qwen3.5:4b` for a machine that
   wants to try one), and so do the settings below.

The start script
----------------

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

source scripts/script-helpers/helpers.sh
shlib_import logging ollama_endpoint

# .env first: a name set there wins over ai-models.env.
if [[ -f .env ]]; then set -a; source .env; set +a; fi

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_MODELS_DIR="${OLLAMA_MODELS_DIR:-$HOME/.ollama/models}"

# "|| exit": a refusal here must stop the start. Without it the list is empty,
# and an empty list is "nothing to check".
models="$(ollama_models_required ai-models.env)" || exit $?

# shellcheck disable=SC2086  # one model per word, on purpose
ollama_endpoint_ensure_models "$OLLAMA_URL" "$OLLAMA_MODELS_DIR" $models || exit $?

docker compose up -d
```

Line by line:

- `ollama_models_required ai-models.env` prints the models to check, one per
  line, as Ollama names them (`nomic-embed-text` becomes
  `nomic-embed-text:latest`). With names after the file
  (`ollama_models_required ai-models.env OLLAMA_MODEL CLASSIFY_MODEL`) only
  those are checked. A file that is named and does not exist is an error
  (exit 1), so a mistyped path cannot read as "needs no models".
- `ollama_endpoint_ensure_models URL DIR MODEL...` does the rest. `DIR` is
  where that Ollama keeps its models, for the disk check: `~/.ollama/models`
  for an Ollama on this machine, Docker's data root for one in a container
  (`docker info -f '{{.DockerRootDir}}'`).
- Both run under `set -euo pipefail` or without it; neither can end a strict
  caller by itself.

The order inside `ollama_endpoint_ensure_models`:

1. List what the endpoint has (`GET /api/tags`). Nothing answering, or a web
   server that is not an Ollama: exit 4.
2. If nothing is missing: exit 0, and the registry is never asked. A machine
   that has its models starts offline.
3. If pulling is off (`OLLAMA_PULL_MISSING=0`): exit 5, naming the missing
   models.
4. Ask the registry for the size of every needed model. The missing ones add
   up to the download; the largest of all of them must fit in memory. A size
   that cannot be learned stops here (exit 7), unless the budget is ignored.
5. `ollama_budget_check`: disk after the download at least
   `OLLAMA_DISK_RESERVE_GB`; largest model plus headroom within memory plus
   GPU memory. A refusal names the numbers and the setting; exit 1, 2 or 3.
6. Pull the missing models, in order, through `POST /api/pull`. A failed pull
   is exit 6, with what Ollama said.

What the person sees
--------------------

Nothing, when every model is there: the start goes on. Otherwise, on stderr:

```
[INFO] Pulling qwen2.5:7b into the Ollama at http://127.0.0.1:11434
  qwen2.5:7b: 10% of 4.7 GB
  qwen2.5:7b: 20% of 4.7 GB
  ...
  qwen2.5:7b: 100% of 4.7 GB
```

One line per tenth of every layer of 100 MB or more. There is no time limit
for the whole download; a pull is given up only when nothing arrives for
`OLLAMA_PULL_STALL_SECONDS` (default 600).

A refusal says what did not fit and which setting governs it:

```
[Error!]: Not enough disk for the models: the download is 4.7 GB, 8.1 GB is free at /home/me/.ollama/models, and 10 GB must stay free (OLLAMA_DISK_RESERVE_GB).
[Error!]: Nothing was pulled. Missing: qwen2.5:7b
```

```
[Error!]: Not enough memory for the largest model: it needs about 5.6 GB to load, and this machine has 4.1 GB of memory and 0.0 GB on its GPUs.
```

A model that fits the machine but not the memory free right now is a
warning, not a refusal: free memory changes by the minute, and a check that
refuses a machine that could run the model gets switched off.

A GB is 10^9 bytes throughout, the unit `ollama list` shows, so the numbers
can be compared with it.

Settings
--------

All optional, read from the environment (so from `.env` when the start script
sources it).

| Setting | Default | Meaning |
|---|---|---|
| `OLLAMA_PULL_MISSING` | on | off: never pull; a missing model is exit 5. |
| `OLLAMA_IGNORE_BUDGET` | off | on: a refusal of the disk or memory check becomes a warning, and an unknown size does not stop the pull. For a machine you know better than the numbers. |
| `OLLAMA_DISK_RESERVE_GB` | 10 | Free space that must remain after the download. |
| `OLLAMA_MEM_HEADROOM_PERCENT` | 20 | Added to the largest model's file size for the memory check (context, runtime). |
| `OLLAMA_PULL_STALL_SECONDS` | 600 | A pull is given up when nothing arrives for this long. |
| `OLLAMA_REGISTRY_URL` | `https://registry.ollama.ai` | Where sizes are asked. |
| `OLLAMA_REGISTRY_TIMEOUT` | 15 | Seconds per size request. |
| `OLLAMA_BUDGET_DISK_FREE_BYTES`, `OLLAMA_BUDGET_MEM_TOTAL_BYTES`, `OLLAMA_BUDGET_MEM_AVAILABLE_BYTES`, `OLLAMA_BUDGET_GPU_BYTES` | read from this machine | State a figure instead of reading it. For an Ollama on another machine, state all four. |

On and off are `1/true/yes/on` and `0/false/no/off/never`, in any case. A
value that is neither is reported and read as off: nothing is pulled, no
check is skipped.

Exit codes and what to do with them
-----------------------------------

`ollama_endpoint_ensure_models`:

| Code | Meaning | What usually helps |
|---|---|---|
| 0 | every model is there, or none was asked for | |
| 1 | the disk cannot take the download | free space, or lower `OLLAMA_DISK_RESERVE_GB` for this machine |
| 2 | memory cannot take the largest model | a smaller model in `.env`, or the small tier |
| 3 | neither can | |
| 4 | nothing answers at the URL as an Ollama | start Ollama, or fix `OLLAMA_URL` |
| 5 | models are missing and pulling is off | `ollama pull <model>` by hand, or turn pulling on |
| 6 | a pull failed | the message has what Ollama said; a name that does not exist, no network, no space during the pull |
| 7 | a missing model's size, or the free disk space, could not be learned | the registry is unreachable, or the model is on another host (`hf.co/...`); pull by hand, or `OLLAMA_IGNORE_BUDGET=1` |
| 8 | an argument is not a model reference | a space, a quote, `@`, `..`, or an empty part such as `qwen3:` |

`ollama_models_required`: 1 for a models file that is named and absent, 2 for
a `NAME` that is not a variable name. Both print nothing on stdout, so with
`|| exit $?` the start stops instead of checking nothing.

Dialog boxes from a script that captures output
-----------------------------------------------

Unrelated to models, shipped in the same release, and used by the model
selectors: `dialog` draws a box on its standard output unless it is asked for
the answer there. `value=$(dialog --inputbox ...)` puts the whole screen into
the variable and shows nothing. Three wrappers in `lib/dialog.sh` fix that for
any kind of box:

```bash
shlib_import logging dialog

if dialog_run --defaultno --yesno "Remove the old volume?" 8 50; then ...; fi
name="$(dialog_capture --inputbox "Name" 8 40 "default")" || echo "cancelled ($?)"
progress_command | dialog_gauge --gauge "Working" 7 40 0
```

- The screen and the keys use the terminal device (`/dev/tty`); stdout
  carries only the answer. With no terminal (cron, systemd, CI) they are
  plain `dialog`; ask `has_interactive_dialog_session` first and prompt for
  nothing there.
- A call `dialog` does not understand (a typo such as `--yesn`, or a box with
  no arguments) returns 255 before anything is drawn. `dialog` itself prints
  its help and exits 0 for both, which a `--yesno` caller would read as Yes.
- `get_value`, the distro selectors, the Ollama model and size selectors and
  the hub setup prompts go through these, so `x=$(get_value ...)` works.

Full reference: [dialog](modules/dialog.md).

Testing a project that uses this
--------------------------------

Three layers, cheapest first.

**1. The models file is the one source.** A test in the project greps its
code for model names (`grep -rn 'qwen\|llama' src/`) and fails on any hit
outside the file. Cheap, and it is the test that fails when someone adds a
default "just for now".

**2. The start script against a fake Ollama.** `tests/ollama_endpoint_test.sh`
in script-helpers carries a small Python HTTP server that answers
`/api/tags`, `/api/pull` and the registry's `/v2/.../manifests/<tag>` from a
state directory, and sets the machine's figures through the
`OLLAMA_BUDGET_*` variables. Copy that pattern: point `OLLAMA_URL` and
`OLLAMA_REGISTRY_URL` at the fake, state the budget, run the start script,
and assert on three things: the exit code, what was pulled (the fake records
it), and that nothing was pulled when the budget refused. The cases worth
pinning are the ones that look right while being wrong: a pull before the
budget is known, a pull of only some models, a model counted as present
because a longer name contains it, a web server that answers 200 taken for
an Ollama.

**3. Once, for real.** On a machine with Ollama: remove one small model
(`ollama rm nomic-embed-text`), run the start script, watch the progress
lines, check `ollama list` shows it again. Then set
`OLLAMA_BUDGET_DISK_FREE_BYTES=1` and run again: the refusal must name the
numbers and nothing must be pulled. Fakes encode what their author believes;
this is the step that checks the belief.

`tests/dialog_pty_test.sh` shows how to drive the real `dialog` in a
pseudo-terminal from a test (python's `pty.fork`, send a key once the screen
has been drawn, tell apart what reached the terminal from what reached the
caller). Use it when a project adds its own boxes.

Developing the module
---------------------

Rules the module follows; a change keeps them.

- **bash 3.2 and BSD tools.** No associative arrays, no `${var,,}`, no
  `mapfile`, no GNU-only flags. `tests/portability_test.sh` scans for the
  known constructs; `scripts/local_test_bash32.sh --test tests/<file>` runs a
  test under bash 3.2 with busybox tools in a container, which is where
  `tr '[:print:]'` and `sed -i ''` differences show. The macOS leg of CI runs
  the suite on BSD userland.
- **A strict caller must survive.** Every function works under
  `set -euo pipefail` and without it: no pipeline may end the caller (hence
  the `|| true` after pipelines whose status does not matter), and no
  function reads a positional parameter it was not given (`${1:-}`).
- **stdout is the answer, stderr is everything else.** A function that
  prints a value prints only the value. Messages go through `print_info`,
  `print_warning`, `print_error`, always with `>&2`.
- **Nothing from the other side is printed raw.** A model name is checked
  before it reaches a URL, a JSON body or a sed program
  (`_ollama_ep_is_model`, `_ollama_ep_is_name`). Text from Ollama, curl or
  the registry goes through `_ollama_ep_said` (last line, printable
  characters, credentials removed, backslashes doubled because the logging
  helpers print with `echo -e`), URLs through `_ollama_ep_shown`.
- **Fail closed.** A size that is not a number is exit 4, not zero. An
  unknown size is exit 7, not "fits". A setting that is neither on nor off is
  off. A models file that is absent is an error, not "no models".
- **Measure before you fake.** When a behaviour of Ollama, the registry or
  `dialog` is in question, ask the real program first (`curl` against the
  local Ollama, the real registry manifest, `dialog` in a pty), then write the
  fake to match. The fake registry was once stricter than the real one about
  letter case; the first stand-in for `dialog` encoded a wrong belief about
  which stream it draws on. Both were found by running the real thing.
- **Every fix has a test that fails without it.** Make the change, run the
  suite, then revert the one line on a copy and run again: the suite must
  fail. A test that passes either way pins nothing.

Running the suites:

```bash
make test                                              # everything
bash tests/ollama_endpoint_test.sh                     # one file (python3 needed for the fake)
bash tests/dialog_pty_test.sh                          # the real dialog, in a pty
scripts/local_test_bash32.sh --test tests/ollama_endpoint_test.sh
shellcheck -S warning lib/ollama_endpoint.sh tests/ollama_endpoint_test.sh
make lint-docs                                         # every function documented
```

Adding a function: write it in `lib/ollama_endpoint.sh` with a `# Usage:`
comment that states what it prints and returns; add its tests; add it to
`docs/modules/ollama_endpoint.md` (`make lint-docs` fails otherwise) and a
line under `## Unreleased` in `CHANGELOG.md`.

Limits, and what comes next
---------------------------

- **The module is told the endpoint.** Finding one (an Ollama on the host
  that containers can reach, or one shared container when there is none) is
  the next step and is not in this release.
- **An Ollama on another machine** works today for listing, sizing and
  pulling: `OLLAMA_URL=http://other-host:11434`, with credentials in the URL
  if a proxy wants them (they are used and never printed). The disk and
  memory checks read this machine's figures, so for a remote Ollama state all
  four `OLLAMA_BUDGET_*` variables, or set `OLLAMA_IGNORE_BUDGET=1` and let
  the remote machine refuse by itself.
- **Models on other hosts** (`hf.co/org/model`, a private registry) are
  listed, matched and pulled, but their size is not asked for: the registry
  manifest is `registry.ollama.ai`'s. A missing one is exit 7 unless the
  budget is ignored.
- **GPU memory** is read from `nvidia-smi` only. Apple silicon shares memory
  and is covered by the total; AMD is not read (state
  `OLLAMA_BUDGET_GPU_BYTES`).
- **The memory figure is an estimate**: file size plus headroom. What a model
  needs also depends on the context length it is run with.
