# Local models with Ollama

How a project uses `lib/ollama_endpoint.sh` and the dialog wrappers in
`lib/dialog.sh`: what to put in the repository, what the start script does,
what the person running it sees, how to test it, and how to change it.

The idea in one paragraph: a project names the models it needs in one file,
and says in its `.env` where they are served. Its start script asks that
Ollama which of them it already has, asks the registry how big the rest are,
checks that the download and the largest model fit the machine, and only then
pulls. Nothing is pulled unless everything fits, so a start never ends with
half its models. Every question goes over Ollama's HTTP API, so the same code
works for an Ollama on this machine, one in a container, and one elsewhere.

Contents

- [Which models: the project decides](#which-models-the-project-decides)
- [Installing Ollama](#installing-ollama)
- [What goes into a repository](#what-goes-into-a-repository)
- [The start script](#the-start-script)
- [Where the models are served](#where-the-models-are-served)
- [What the person sees](#what-the-person-sees)
- [Settings](#settings)
- [Exit codes and what to do with them](#exit-codes-and-what-to-do-with-them)
- [Messages and what they mean](#messages-and-what-they-mean)
- [Adopting it in an existing project](#adopting-it-in-an-existing-project)
- [In CI](#in-ci)
- [Dialog boxes from a script that captures output](#dialog-boxes-from-a-script-that-captures-output)
- [Testing a project that uses this](#testing-a-project-that-uses-this)
- [Developing the module](#developing-the-module)
- [Limits, and what comes next](#limits-and-what-comes-next)

Which models: the project decides
---------------------------------

This library names no model and recommends none. It checks and pulls whatever
the project's models file says, so a project can use any model Ollama can
pull, from the Ollama library or another registry (`hf.co/org/model`).

Several projects that should agree on their models keep the list in one
place of their own and generate each project's models file from it, with a
`# purpose` comment per line and a header that says the file is generated.
The project still carries its own file, so it runs without that list. Nothing
here reads such a list; the file is the interface.

To choose a model by hand, the dialog menu in [ollama](modules/ollama.md)
(`ollama_install_model_flow`) browses an index of the Ollama library, asks
for a size, and writes the choice into an env file.

Installing Ollama
-----------------

The start check talks to an Ollama; it does not install one. To install it:

```bash
shlib_import logging ollama_install
ollama_install                          # the pinned release into /usr/local (sudo when needed)
ollama_install --prefix "$HOME/.local"  # without root
```

On Linux this downloads the official release archive of the version pinned in
`lib/ci_defaults.sh` and compares it with the pinned SHA-256 before anything is
unpacked; on macOS it uses Homebrew. On Windows it uses winget, else the
official release zip, checked the same way and unpacked for the user without
running a setup program; from PowerShell the same is
`ps/lib/ollama_install.ps1`. Elsewhere it names the download page and
downloads nothing. An Ollama at the pinned version or newer is left alone; an
older one is upgraded (`brew upgrade`, `winget upgrade`, or the archive). Ollama's
one-line installer (`curl ... install.sh | sh`) is not used: it runs whatever
script the server returns, as root, with nothing to check it against. Full reference: [ollama_install](modules/ollama_install.md).

It installs the program. Starting it (`ollama serve`), or running it as a
service, is up to the machine: the Linux page of the Ollama documentation has
the systemd unit, and on macOS `brew services start ollama`.

In a container, use the official image at a pinned tag (`ollama/ollama:<version>`)
instead; `OLLAMA_MODE=docker` covers that case.

What goes into a repository
---------------------------

1. **`script-helpers` as a submodule**, at a released tag. The functions below
   exist from 0.45.0.

2. **One models file**, by convention `ai-models.env` at the repository root,
   one `NAME=model` per line:

   ```
   # The models this project uses, by purpose. An example: use your own.
   # chat and summaries
   OLLAMA_MODEL=general-model:4b
   # sorting messages into categories
   CLASSIFY_MODEL=small-model:1.7b
   # embeddings for search
   OLLAMA_EMBED_MODEL=embedding-model
   # the same purpose on a machine with a 12 GB GPU or 32 GB of memory
   OLLAMA_MODEL_LARGE=general-model:9b
   OLLAMA_MODEL_LARGE_VRAM_GB=11
   AI_TIER_LARGE_RAM_GB=30
   ```

   The names are placeholders; a real file has real model names, such as
   `qwen3:8b` or `nomic-embed-text`.

   The file is read like an env file: `export ` before a name, spaces around
   `=`, one pair of quotes, a trailing ` # comment`, Windows line ends and a
   byte-order mark are all tolerated. A name ending in `_SMALL`, `_LARGE` or
   `_XLARGE` is the model for another class of machine; a name ending in
   `_RAM_GB` or `_VRAM_GB` after that is a number for the pick. Each name gives
   one model: the column this machine qualifies for (below), else the name
   itself. **Every other name is read as a model**, so the file holds models
   only: `AI_MODEL_TIER=standard` or `OLLAMA_TIMEOUT_MS=180000` written there
   is checked as the model `standard:latest` or `180000:latest`, and the start
   stops with exit 7 ("the registry has no model named ..."). Settings go in
   `.env`.

   The file may be written by hand or generated from a list shared by
   several projects; a generated one says so in its header, and is not edited.

   **Which column a machine gets.** By its memory and its largest GPU, in whole
   GiB as it reports them (`scripts/ollama_models.sh class` prints both):

   | Class | When | Column |
   |---|---|---|
   | xlarge | largest GPU >= `NAME_XLARGE_VRAM_GB` | `NAME_XLARGE` |
   | large | largest GPU >= `NAME_LARGE_VRAM_GB`, or memory >= `AI_TIER_LARGE_RAM_GB` | `NAME_LARGE` |
   | small | memory and largest GPU both < `AI_TIER_SMALL_RAM_GB` | `NAME_SMALL` |
   | default | otherwise | `NAME` |

   A class with no model for a name gets the next column below. A model
   above the default that the disk or memory check refuses falls back one
   column. `AI_MODEL_TIER=small|standard|large|xlarge` in `.env` names the
   class instead; `NAME` in `.env` names the model on any machine. For an
   Ollama on another machine, this machine's figures do not count: its class
   is `AI_MODEL_TIER`, or its stated `OLLAMA_BUDGET_MEM_TOTAL_BYTES`, else the
   default column.

3. **The application reads the same file.** The models the start script
   checks must be the models the code uses, or the check proves nothing. The
   application reads `ai-models.env` (and lets a real environment variable
   win), and no model name is written anywhere else. A test that greps the
   code for model names and fails on a second copy is cheap and worth it.

4. **A `.env` for the machine**, never committed. It says where the models
   are served (`OLLAMA_MODE` and the address, below). A model name set there
   wins over the file (`OLLAMA_MODEL=qwen3.5:4b` for a machine that wants to
   try one), and so do the settings below. The start script does not have to
   source it: it is read as data.

The start script
----------------

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

source scripts/script-helpers/helpers.sh
shlib_import logging ollama_endpoint

# "|| exit": a refusal here must stop the start.
ollama_project_ensure_models ai-models.env .env || exit $?

docker compose up -d
```

What that one call does:

- It reads `.env` as data. The file is never sourced, so a value with a `$`,
  a space or a backquote in it is only a value, and nothing the call reads is
  left in the script's environment. A value already in the environment wins
  over `.env`, and `.env` over `ai-models.env`. A `.env` that is not there
  yet (a fresh clone) is no `.env`.
- The models are every name in `ai-models.env` that is not another class's
  (`_SMALL`, `_LARGE`, `_XLARGE`), as Ollama names them (`nomic-embed-text`
  becomes `nomic-embed-text:latest`). With names after the two files
  (`ollama_project_ensure_models ai-models.env .env OLLAMA_MODEL CLASSIFY_MODEL`)
  only those are checked. With `""` for the models file the names must be
  given (`ollama_project_ensure_models "" .env OLLAMA_MODEL`) and their values
  come from `.env` and the environment alone; `""` with no names is exit 9,
  because it would check nothing.
- The address is `OLLAMA_URL`, `OLLAMA_BASE_URL` or `OLLAMA_HOST`, whichever
  has a value first, and `http://127.0.0.1:11434` when none has. A project
  with its own name for it says so: `OLLAMA_URL_VARS=MYAPP_OLLAMA_URL`, in
  the environment or in `.env`. What projects store there is accepted as it
  is: `host:port`, a URL, a URL with the API path
  (`http://ollama:11434/api/generate`, `/v1/chat/completions`).
- `OLLAMA_MODE` says where that Ollama runs; see the next section.
- It runs under `set -euo pipefail` or without it, under any `IFS`, and
  cannot end a strict caller by itself.

Then, inside (`ollama_endpoint_ensure_models`):

1. List what the endpoint has (`GET /api/tags`). Nothing answering, or a web
   server that is not an Ollama: exit 4.
2. If nothing is missing: exit 0, and the registry is never asked. A machine
   that has its models starts offline.
3. If pulling is off (`OLLAMA_PULL_MISSING=0`): exit 5, naming the missing
   models. With `OLLAMA_PULL_MISSING=ask`, steps 4 and 5 run first, then each
   missing model is listed with its size and the person is asked `Pull now?
   [y/N]`. Anything but yes is exit 5. With no terminal to ask on (a desktop
   launcher, a service, CI) it is exit 5 too, saying so: nothing downloads
   gigabytes without a yes.
4. Ask the registry for the size of every needed model. The missing ones add
   up to the download; the largest of all of them must fit in memory. A size
   that cannot be learned stops here (exit 7), unless the budget is ignored.
5. `ollama_budget_check`: disk after the download at least
   `OLLAMA_DISK_RESERVE_GB`; largest model plus headroom within memory plus
   GPU memory. A refusal names the numbers and the setting; exit 1, 2 or 3.
6. Pull the missing models, in order, through `POST /api/pull`. A failed pull
   is exit 6, with what Ollama said.

A project whose backend runs in a container and calls this machine's Ollama
(`http://host.docker.internal:11434`) checks one thing more, after the models:
that a container can reach it. An Ollama that listens on `127.0.0.1` only
answers the start script and not the container.

```bash
ollama_project_ensure_models ai-models.env .env || exit $?
ollama_endpoint_container_reach "http://host.docker.internal:11434" || exit $?
```

A start script that needs its own order can call the steps itself:

```bash
models="$(ollama_models_required ai-models.env)" || exit $?
# shellcheck disable=SC2086  # one model per word, on purpose
ollama_endpoint_ensure_models "http://127.0.0.1:11434" "$(ollama_models_dir)" $models || exit $?
```

`ollama_models_dir` is where an Ollama on this machine keeps its models, for
the disk check: `OLLAMA_MODELS` when set, `/usr/share/ollama/.ollama/models`
for the service the Linux installer sets up (it has a user of its own, so it
is not under your home), and `~/.ollama/models` for an Ollama started by hand
and on macOS. The wrong directory measures the wrong disk when the two are on
different filesystems.

Where the models are served
---------------------------

A project sets `OLLAMA_MODE` in `.env`. It is not guessed when it is set, and
a value that is none of the three is refused (exit 9).

| `OLLAMA_MODE` | Meaning | What the start check does |
|---|---|---|
| `local` | an Ollama installed on this machine | lists, sizes, checks this machine's disk and memory, pulls what is missing |
| `docker` | an Ollama in a container on this machine | the same, reached at the published port and measured against Docker's disk |
| `remote` | an API on another machine: an Ollama server, or a hosted API | measures nothing here, pulls nothing unless asked, names what a remote Ollama lacks, and passes over what is not an Ollama |
| not set | the address decides | `local` when the address is this machine, otherwise as `remote`, except that an address that does not answer is 4 (`remote` passes it over with 0) |

By environment, typically:

```
# development: an Ollama installed on the machine
OLLAMA_MODE=local
OLLAMA_URL=http://127.0.0.1:11434

# a stack that brings its own Ollama container
OLLAMA_MODE=docker
OLLAMA_URL=http://ollama:11434     # what the backend container uses
OLLAMA_PORT=11435                  # the port published on this machine

# integration, QA or production: an endpoint elsewhere
OLLAMA_MODE=remote
OLLAMA_URL=https://llm.example.com
```

- `local`: an address that is not this machine is a contradiction, refused
  with the mode that would fit (exit 9).
- `docker`: the address in `.env` is the one a container uses, and a compose
  service's name (one label, no dots) does not resolve from a start script on
  the host. There it is read as `127.0.0.1`, at `OLLAMA_PORT` or
  `OLLAMA_HOST_PORT` when one is set and at the address's own port otherwise;
  a published port that is not a number from 1 to 65535 is refused (exit 9),
  because the address's own port is often the native Ollama's. Inside a
  container (Docker, Podman, a Kubernetes pod) the name is used as written.
  A name with a dot, an IP address or an IPv6 literal that is not this
  machine is another machine, and `docker` is the wrong word for it: refused
  (exit 9) with `remote` named. The disk measured is Docker's data root
  (`docker info`), or `OLLAMA_MODELS` when the project states it.
- `remote`: a model a remote Ollama lacks is a refusal (exit 5) that names
  it. Nothing is pulled into another machine unless `OLLAMA_PULL_MISSING=1`
  asks for it, and then that machine's disk and memory have to be stated
  (`OLLAMA_BUDGET_DISK_FREE_BYTES`, `OLLAMA_BUDGET_MEM_TOTAL_BYTES`) or the
  check waived (`OLLAMA_IGNORE_BUDGET=1`): this machine's are never used for
  it, nor its GPU. A hosted API that is not an Ollama, or an endpoint that is
  not up, is said and passed over (exit 0): a start script here can neither
  check nor mend it.
- The module does not start, stop or share an Ollama. `docker` means "it is
  in a container the project starts"; the start script still starts it.

What the person sees
--------------------

Nothing, when every model is there: the start goes on. Otherwise, on stderr:

```
[Info]: Pulling qwen3:8b into the Ollama at http://127.0.0.1:11434
  qwen3:8b: 10% of 5.2 GB
  qwen3:8b: 20% of 5.2 GB
  ...
  qwen3:8b: 100% of 5.2 GB
```

One line per tenth of every layer of 100 MB or more, and 100% when the pull
has succeeded. There is no time limit
for the whole download; a pull is given up only when nothing arrives for
`OLLAMA_PULL_STALL_SECONDS` (default 600).

A refusal says what did not fit and which setting governs it:

```
[Error!]: Not enough disk for the models: the download is 5.2 GB, 8.1 GB is free at /home/me/.ollama/models, and 10 GB must stay free (OLLAMA_DISK_RESERVE_GB).
[Error!]: Nothing was pulled. Missing: qwen3:8b
```

```
[Error!]: Not enough memory for the largest model: it needs about 5.6 GB to load, and this machine has 4.1 GB of memory and 0.0 GB on its GPUs.
```

A model that fits the machine but not the memory free right now is a
warning, not a refusal: free memory changes by the minute, and a check that
refuses a machine that could run the model gets switched off.

A GB is 10^9 bytes throughout, the unit `ollama list` shows, so the numbers
can be compared with it.

An address is named in a message by its scheme, host and port: never with its
credentials, and never with its path or query, where a proxy may carry a key.
A value that cannot be read as an address is named by its variable and not
shown.

Settings
--------

All optional, read from the environment or, through
`ollama_project_ensure_models`, from the project's `.env`.

| Setting | Default | Meaning |
|---|---|---|
| `OLLAMA_MODE` | the address decides | `local`, `docker` or `remote`: where the models are served. |
| `OLLAMA_URL`, `OLLAMA_BASE_URL`, `OLLAMA_HOST` | `http://127.0.0.1:11434` | The address; the first with a value. `OLLAMA_URL_VARS` names other variables to read it from. |
| `OLLAMA_PORT`, `OLLAMA_HOST_PORT` | the address's own port | `docker`: the port the container is published on; 1 to 65535, or exit 9. |
| `OLLAMA_MODELS` | see `ollama_models_dir` | Where that Ollama keeps its models, for the disk check. |
| `OLLAMA_PULL_MISSING` | on (`remote`: off) | off: never pull; a missing model is exit 5. ask: pull after a yes on a terminal; no, or no terminal, is exit 5. |
| `OLLAMA_IGNORE_BUDGET` | off | on: a refusal of the disk or memory check becomes a warning, and an unknown size does not stop the pull. For a machine you know better than the numbers. |
| `OLLAMA_DISK_RESERVE_GB` | 10 | Free space that must remain after the download. Not a number, or above 100000, is read as a typo: 10. |
| `OLLAMA_MEM_HEADROOM_PERCENT` | 20 | Added to the largest model's file size for the memory check (context, runtime). Not a number, or above 1000: 20. |
| `OLLAMA_PULL_STALL_SECONDS` | 600 | A pull is given up when nothing arrives for this long. |
| `OLLAMA_REGISTRY_URL` | `https://registry.ollama.ai` | Where sizes are asked. |
| `OLLAMA_REGISTRY_TIMEOUT` | 15 | Seconds per size request. |
| `OLLAMA_BUDGET_DISK_FREE_BYTES`, `OLLAMA_BUDGET_MEM_TOTAL_BYTES`, `OLLAMA_BUDGET_MEM_AVAILABLE_BYTES`, `OLLAMA_BUDGET_GPU_BYTES` | read from this machine | State a figure instead of reading it. For a pull into another machine the first two must be stated. |

On and off are `1/true/yes/on` and `0/false/no/off/never`, in any case. A
value that is neither is reported and read as off: nothing is pulled, no
check is skipped.

Exit codes and what to do with them
-----------------------------------

`ollama_project_ensure_models` and `ollama_endpoint_ensure_models`:

| Code | Meaning | What usually helps |
|---|---|---|
| 0 | every model is there, none was asked for, or (`remote`) what answers is not an Ollama | |
| 1 | the disk cannot take the download | free space, or lower `OLLAMA_DISK_RESERVE_GB` for this machine |
| 2 | memory cannot take the largest model | a smaller model in `.env` |
| 3 | neither can | |
| 4 | nothing answers at the address as an Ollama | start Ollama, or fix the address; for a compose service's name set `OLLAMA_MODE=docker` |
| 5 | models are missing and pulling is off, or the Ollama is another machine | `ollama pull <model>` there, or turn pulling on |
| 6 | a pull failed | the message has what Ollama said: no network, no space during the pull |
| 7 | the budget could not be checked: a missing model's size or the free disk space could not be learned, the registry has no such model, or a pull into another machine was asked for without its figures | the message says which; a wrong name is said as a wrong name |
| 8 | a model is not a model reference | a space, a quote, `@`, `..`, or an empty part such as `qwen3:` |
| 9 | the project's configuration (`ollama_project_ensure_models` only): no models file at that path, a name that is not a variable name, an address that is not one, an `OLLAMA_MODE` that is none of the three or that the address contradicts, a published port that is not one, or a setting in `.env` the caller holds read-only | the message names the variable |

`ollama_budget_check`, called on its own, also returns 4 when a size it is
given is not a whole number: a size that was never measured is not read as
zero.

1 to 3 are always the disk and the memory. A project whose backend waits for
Ollama by itself may go on from 4:
`ollama_project_ensure_models ai-models.env .env || { rc=$?; [[ $rc -eq 4 ]] || exit $rc; }`.

`ollama_models_required` on its own: 1 for a models file that is named and
absent, 2 for a `NAME` that is not a variable name. Both print nothing on
stdout, so with `|| exit $?` the start stops instead of checking nothing.

Messages and what they mean
---------------------------

What the start prints, and the one thing to do about each. `<...>` is filled
in by the message.

| Message (start) | Exit | What to do |
|---|---|---|
| `No Ollama answers at <address>.` | 4 | start Ollama, or fix the address. A one-word host in an unset mode adds a second line about compose service names: set `OLLAMA_MODE=docker` |
| `<VAR> is not the address of an Ollama.` | 9 | the value is not shown on purpose; it is a host, `host:port` or an http(s) URL, and a password in it is percent-encoded |
| `OLLAMA_MODE is not local ..., docker ... or remote ...` | 9 | fix the spelling; `host`, `container`, `api`, `external` and `auto` are also read |
| `OLLAMA_MODE is local, and <address> is not this machine.` | 9 | `docker` for a container here, `remote` for another machine |
| `OLLAMA_MODE is docker, and <address> is another machine.` | 9 | a container here is named by its compose service name or by `localhost` at its published port; otherwise `remote` |
| `OLLAMA_PORT is not a port number (1 to 65535).` | 9 | the port the container is published on, as a number |
| `<VAR> is set in <file> and cannot be set here: the caller holds it read-only.` | 9 | the start script made the variable `readonly`; remove that, or give it a value |
| `No models file at <path>` | 9 | the path is relative to where the start script runs (the example `cd`s to the repository first) |
| `No models file and no names` | 9 | name the file, or the variables after the two files |
| `Not a model reference: <name>` | 8 | a space, a quote, `@`, `..` or an empty part (`qwen3:`) in a model name |
| `The Ollama at <address> lacks: <models>. Pulling is off (OLLAMA_PULL_MISSING).` | 5 | `ollama pull <model>`, or set `OLLAMA_PULL_MISSING=1` |
| `Nothing was pulled. Missing: <models>` | 1 to 3 | follows a disk or memory refusal, the line above it says which |
| `Nothing was pulled. Missing: <models>. Pull it with: ...` | 5 | `OLLAMA_PULL_MISSING=ask` and the answer was not yes; the line gives the exact `ollama pull` (with `OLLAMA_HOST=` when the Ollama is not at `127.0.0.1:11434`) |
| `... OLLAMA_PULL_MISSING=ask and there is no terminal to ask on ...` | 5 | run the start from a terminal, run the `ollama pull` the line gives, or set `OLLAMA_PULL_MISSING=1` to pull without asking |
| `That Ollama is another machine, so nothing is pulled from here ...` | 5 | pull on that machine, or ask for it (`OLLAMA_PULL_MISSING=1`) with its figures stated |
| `That Ollama is another machine and lacks: <models>. Its free disk and its memory are not known here ...` | 7 | state `OLLAMA_BUDGET_DISK_FREE_BYTES` and `OLLAMA_BUDGET_MEM_TOTAL_BYTES` for that machine, or `OLLAMA_IGNORE_BUDGET=1` |
| `The registry has no model named <model> ...` | 7 | a typo, or a setting written in the models file (see the models file above) |
| `The size of <model> could not be learned ...` | 7 | no network to the registry; pull by hand, or `OLLAMA_IGNORE_BUDGET=1` |
| `Free disk space at <dir> could not be read ...` | 7 | state `OLLAMA_BUDGET_DISK_FREE_BYTES`, or `OLLAMA_MODELS` when the directory is elsewhere |
| `Not enough disk for the models: ...` | 1 | free space, or a smaller `OLLAMA_DISK_RESERVE_GB` for this machine |
| `Not enough memory for the largest model: ...` | 2 | a smaller model in `.env` |
| `The largest model needs about ... It fits this machine, but not beside what is running.` | (warning) | nothing; close something if the model is slow to load |
| `The Ollama at <address> did not pull <model>: <what it said>` | 6 | what Ollama said: disk full, no network, an unknown model |
| `<SETTING> is neither on (1, true, yes) nor off (0, false, no): ... Read as off.` | (warning) | fix the spelling; until then nothing is pulled and no check is skipped |

Adopting it in an existing project
----------------------------------

Most projects already have an Ollama address and a model name somewhere.
In order:

1. Find every model name in the code and move it to `ai-models.env`; make the
   code read the file (step 3 of "What goes into a repository").
2. Keep the project's own name for the address: set
   `OLLAMA_URL_VARS=MYAPP_OLLAMA_URL` in `.env` rather than renaming it.
3. If the compose file starts its own Ollama, set `OLLAMA_MODE=docker` and
   `OLLAMA_PORT` to the port it publishes. A service that publishes no port
   cannot be reached from the start script; publish it on `127.0.0.1` or give
   the call an address that can be reached.
4. Add the one call to the start script before anything that uses a model,
   and decide what 4 means for this project (stop, or go on because the
   backend waits).
5. Add `ai-models.env` to the image if a container reads it: an ignore rule
   such as `*.env` in `.dockerignore` keeps it out unless it has its own `!`
   line.
6. Add the test of layer 1 below, so a model name cannot come back into the
   code.

Bash only: there is no PowerShell version of `lib/ollama_endpoint.sh`. A
Windows project runs the start check under WSL or Git Bash, which have `curl`
and `awk`.

In CI
-----

A CI runner has no Ollama, or one that must not download gigabytes per run.
Two ways:

- Do not call the start check in CI; test the start script against a fake
  Ollama instead (layer 2 below).
- Call it with `OLLAMA_PULL_MISSING=0`: with the models already on the
  runner it is 0, otherwise 5 with the missing ones named, and nothing is
  downloaded.

The registry is asked only when a model is missing, so a runner with its
models cached needs no network for the check.

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
default "just for now". When the application reads the file with a parser of
its own (it is not a shell script), a second test feeds one awkward file
(quotes, comments, a byte-order mark, a name twice) to that parser and to
`ollama_models_file_get`, and compares: two readers of one file agree only
while something checks that they do.

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

**3. Once, for real.** Run a second Ollama for the test, with a models
directory of its own, so nothing the machine's own Ollama has is touched:

```bash
scratch="$(mktemp -d)"
OLLAMA_MODELS="$scratch" OLLAMA_HOST=127.0.0.1:11500 ollama serve &
```

Point the start at it (`OLLAMA_URL=http://127.0.0.1:11500 OLLAMA_MODELS="$scratch"`)
and name a small model for one run (`OLLAMA_EMBED_MODEL=smollm2:135m`,
271 MB): first with `OLLAMA_BUDGET_DISK_FREE_BYTES=1`, where the refusal must
name the numbers and the scratch Ollama must list nothing, then without,
watching the progress lines until it lists the model. Stop that Ollama and
delete the scratch directory. Fakes encode what their author believes; this is
the step that checks the belief. The first real pull showed that Ollama never
reports a layer as complete, which no stand-in had said.

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
  helpers print with `echo -e`). An address is named through
  `_ollama_ep_shown_url`: scheme, host and port, never its credentials, path
  or query. A value that could not be read is named by its variable only.
- **A rule is one function, in the C locale.** What counts as a name or a
  model is decided in one place each (`_ollama_ep_is_name`,
  `_ollama_ep_is_model`), with the pattern written in the function and
  `local LC_ALL=C` before it: kept in a variable, the pattern is empty in a
  shell that lost the variable and then matches everything, and in other
  locales `[A-Za-z]` takes accented letters.
- **A function does not borrow the caller's names or word splitting.** A
  `NAME` is read through `${!NAME}`, so a function that takes names keeps its
  own variables under a prefix (`_oep_`): a local called `url` or `name` was
  read in place of the caller's variable. A function that splits a list sets
  `IFS` itself: a caller in "strict mode" has it set to newline and tab.
- **No early exit in a pipeline whose status counts.** `... | grep -q` ends
  the pipeline at the first match, and under `pipefail` the tools it cut off
  turn a found answer into a failure. Collect first, search after.
- **Fail closed.** A size that is not a number is exit 4, not zero. An
  unknown size is exit 7, not "fits". A setting that is neither on nor off is
  off. A models file that is absent is an error, not "no models".
- **A test cannot reach a real service.** Where the code has a default
  address, the default has a seam (`_OLLAMA_EP_DEFAULT_URL`) and the test file
  moves it to a closed port: a regression in what is under test must not send
  a pull to the developer's own Ollama.
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

- **The module is told where the Ollama is** (`OLLAMA_MODE` and the
  address). It does not start, stop or share one: bringing up a container,
  and one Ollama shared by several projects, is the next step and is not in
  this release.
- **`docker` assumes the published port.** On the host, the compose
  service's name is read as `127.0.0.1` at `OLLAMA_PORT`, `OLLAMA_HOST_PORT`
  or the address's own port. A container published on another address, or
  not published at all, needs the address given for the call.
- **An Ollama on another machine** is listed and, when asked for, pulled
  into; its disk and memory cannot be read from here, so a pull needs them
  stated or the check waived. Whether a name is this machine is decided
  without resolving it: a name that only resolves to this machine is read as
  another machine, the safe way to be wrong. Set `OLLAMA_MODE` when that is
  not what is meant.
- **Models on other hosts** (`hf.co/org/model`, a private registry) are
  listed, matched and pulled, but their size is not asked for: the registry
  manifest is `registry.ollama.ai`'s. A missing one is exit 7 unless the
  budget is ignored. A private model on the default registry is answered as
  unknown there, and is said as a name to check.
- **GPU memory** is read from `nvidia-smi` only. Apple silicon shares memory
  and is covered by the total; AMD is not read (state
  `OLLAMA_BUDGET_GPU_BYTES`).
- **The memory figure is an estimate**: file size plus headroom. What a model
  needs also depends on the context length it is run with.
