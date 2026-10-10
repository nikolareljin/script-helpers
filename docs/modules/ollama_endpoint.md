# ollama_endpoint

What a project's start script needs to know before it relies on a local
model: which models the project uses, which of them an Ollama already has,
and whether the machine can take the rest. Nothing is pulled until that last
question has an answer.

A project lists its models by purpose in one env-style file:

```
OLLAMA_MODEL=qwen2.5:7b
CLASSIFY_MODEL=qwen2.5:3b
OLLAMA_EMBED_MODEL=nomic-embed-text
```

and a start does, in one call:

```bash
source scripts/script-helpers/helpers.sh
shlib_import logging ollama_endpoint

# "|| exit": a refusal must stop the start.
ollama_project_ensure_models ai-models.env .env || exit $?
```

That reads the project's `.env` as data (it is never sourced), takes the
address from `OLLAMA_URL`, `OLLAMA_BASE_URL` or `OLLAMA_HOST`, and pulls what is
missing only when it fits. The same in steps, for a start that needs its own
order:

```bash
models="$(ollama_models_required ai-models.env OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL)" || exit $?
# shellcheck disable=SC2086  # one model per word
ollama_endpoint_ensure_models "http://127.0.0.1:11434" "$(ollama_models_dir)" $models || exit $?
```

Works against an Ollama on this machine and one in a container alike: every
question is asked over its HTTP API, and the `ollama` CLI is not needed.

Requires `curl`, `awk`, `sed`, `grep`, `df`, `tail`, `tr`, `cut`, `dirname`.
Runs on bash 3.2 and BSD userland, under `set -euo pipefail` or without it.

Expected imports
----------------

`logging` (`print_info`, `print_warning`, `print_error`). Every message goes
to stderr; stdout carries only what a function is documented to print.

What a message shows of the configuration: an address is named by its scheme,
host and port, never with its credentials, its path or its query (a proxy
path may hold a key), and a value that could not be read as an address is
named by its variable and not shown at all.

The models file
---------------

One assignment per line, read as an env file is read: `export ` before the
name, spaces around `=`, one pair of quotes around the value, a trailing
` # comment` and a carriage return are not part of the value. A byte-order
mark at the start of the file is ignored.

Environment
-----------

- `OLLAMA_PULL_MISSING` -- off never pulls; a missing model is then a refusal. ask pulls only after a yes on a terminal, once the budget check has passed; no answer, or no terminal (stdin and stderr), is a refusal. Default on.
- `OLLAMA_DISK_RESERVE_GB` -- free space that must remain after the download. Default `10`. A GB is 10^9 bytes throughout, as Ollama shows a model's size.
- `OLLAMA_MEM_HEADROOM_PERCENT` -- added to the largest model's size for the memory check (context, runtime). Default `20`.
- `OLLAMA_IGNORE_BUDGET` -- on turns each refusal of the budget into a warning. Default off.
- `OLLAMA_REGISTRY_URL` -- where model sizes are asked. Default `https://registry.ollama.ai`.
- `OLLAMA_REGISTRY_TIMEOUT` -- seconds per size request. Default `15`.
- `OLLAMA_PULL_STALL_SECONDS` -- a pull is given up when nothing arrives for this long. Default `600`. There is no deadline for the whole download.
- `OLLAMA_BUDGET_DISK_FREE_BYTES`, `OLLAMA_BUDGET_MEM_TOTAL_BYTES`, `OLLAMA_BUDGET_MEM_AVAILABLE_BYTES`,
  `OLLAMA_BUDGET_GPU_BYTES` -- state a figure instead of having it read. The figures read are this machine's:
  for an Ollama on another machine, state all four (`ollama_project_ensure_models` requires the
  first two and never counts this machine's own for the other two).

On is `1`, `true`, `yes` or `on`; off is `0`, `false`, `no`, `off` or `never`; case does not matter.
Any other value is reported and read as off: nothing is pulled, and no check is skipped.

Numbers are decimal: `08` is eight. A value that is not a whole number of at most 15 digits is not used.

Functions
---------

- ollama_models_file_get file NAME
  - Purpose: Print the value of `NAME` in a models file.
  - Behavior: The last line for a name wins; a longer name does not match.
  - Returns: 0, printing an empty line when the file or the name is absent; 2 when `NAME` is not a variable name (it is never put into a pattern unchecked).

- ollama_models_file_names file
  - Purpose: Print every name the file assigns, one per line, in file order, each once.

- ollama_model_tagged model
  - Purpose: Print the model as Ollama lists it: with a tag (`:latest` when none is given), without the default registry's host or its `library/` namespace.
  - Behavior: The tag is looked for in the last path segment only, so `registry.example:5000/team/model` gets `:latest` rather than being read as tagged `5000/team/model`.

- ollama_models_required file [NAME...]
  - Purpose: Print the models a start needs, as Ollama lists them, one per line, each once.
  - Behavior: With no `NAME`, every name in the file except a tier's alternative: a name ending in `_SMALL`, `_LARGE` or `_XLARGE` is the model for another class of machine, and `_VRAM_GB` or `_RAM_GB` after that is a figure for the pick, not a model. Each name gives the model this machine gets (`ollama_model_for_class`): a non-blank value in the environment wins, trimmed; load the project's `.env` first if it should count.
  - Returns: 0; 2, printing nothing, when a `NAME` is not a variable name or `AI_MODEL_TIER` is not a class (checked before any name, so a typo is never an empty list). A list cut short at the bad name would start a project with some of its models. 1, printing nothing, when `file` is named and is not there: a mistyped path would otherwise read as "needs no models". Pass `""` for no file, to take the names from the environment alone.

- ollama_endpoint_models base_url [timeout_seconds=5]
  - Purpose: Print the models the Ollama at `base_url` has, as it names them.
  - Behavior: A `name` nested inside a model's details is not a model. An answer spread over lines is read the same as one on a single line.
  - Returns: 0; 1 when nothing answers there, or when what answers is not an Ollama (a web server that says 200 to everything).

- ollama_models_missing needed present
  - Purpose: Given two newline-separated lists, print the needed models that are not present.
  - Behavior: Whole names only: `qwen:7b` is not satisfied by `qwen:7b-instruct`. Letter case does not count, as it does not to Ollama.

- ollama_registry_size_bytes model
  - Purpose: Print the size of the model's download in bytes, from the registry manifest.
  - Behavior: Sums every layer and the config. Layers the machine already holds for another model are counted again, so the figure can only overstate. An answer without `layers` (a list of manifests, a web page) is not a manifest and is not summed.
  - Returns: 0; 1 when the registry does not answer, answers with something else, or the argument is not a model reference; 2 for a model on another registry host (for example `hf.co/...` or `localhost:5000/...`), which is not asked for; 3 when the registry answers that it has no such model or tag (HTTP 404 with `MANIFEST_UNKNOWN` or `NAME_UNKNOWN`). A 404 from anything else is 1: a mistyped `OLLAMA_REGISTRY_URL` is not a mistyped model.

- ollama_models_dir
  - Purpose: Print where an Ollama on this machine keeps its models, for the disk check.
  - Behavior: `OLLAMA_MODELS` when set (Ollama's own variable); else `/usr/share/ollama/.ollama/models` when it or the service's home `/usr/share/ollama` exists, because the Linux installer sets Ollama up as a service with a user of its own, whose home is often closed to other users; else `~/.ollama/models` (an Ollama started by hand, and macOS). The directory need not exist yet.
  - Note: not for an Ollama in a container; pass Docker's data root there (`docker info -f '{{.DockerRootDir}}'`).

- ollama_disk_free_bytes path
  - Purpose: Print the bytes free on the filesystem holding `path`, or its nearest existing parent. Prints nothing when it cannot be told.

- ollama_mem_total_bytes / ollama_mem_available_bytes
  - Purpose: Print the machine's memory, and what a new process could have now. Linux reads `/proc/meminfo`; macOS reads `sysctl hw.memsize` and `vm_stat` (free plus inactive pages). Prints nothing when it cannot be told.

- ollama_gpu_mem_bytes
  - Purpose: Print the memory of this machine's GPUs together, or `0`: Ollama spreads a model over them. NVIDIA from `nvidia-smi`, AMD from the amdgpu driver's `/sys/class/drm/cardN/device/mem_info_vram_total` (a connector such as `card0-DP-1` is not a GPU). A driver that cannot be reached counts as no GPU. Apple silicon shares memory with its GPU and is covered by the total. `OLLAMA_BUDGET_GPU_BYTES` states it.

- ollama_gpu_mem_largest_bytes
  - Purpose: Print the memory of the largest single GPU, or `0`. A model runs on one GPU, so this, not the sum, says which models the machine can run: two 12 GB cards are not a 24 GB card. `OLLAMA_BUDGET_GPU_LARGEST_BYTES` states it.
  - Per system: Linux, `nvidia-smi` and amdgpu sysfs. Windows (Git Bash), every display adapter's dedicated memory from the registry (`HardwareInformation.qwMemorySize`, through `powershell.exe`). macOS, an Intel Mac's discrete card from `system_profiler`; on Apple silicon (`hw.optional.arm64`, so also under Rosetta) two thirds of the machine's memory, the share macOS lets its GPU use. `ollama_gpu_mem_bytes` stays 0 there, so the budget check does not count that memory twice.

- ollama_machine_figures
  - Purpose: Print `<memory GiB>:<largest GPU GiB>`, whole GiB rounded down, the two figures the class is picked by. Memory is empty (`:0`) when it cannot be read.

- ollama_model_for_class file NAME
  - Purpose: Print the model this machine gets for `NAME`: the highest class column it qualifies for that names a model, else `NAME`.
  - Classes (fleet model registry; figures in whole GiB as the machine reports them, so a 32 GB machine is 31):
    - `xlarge`: its largest GPU has at least `NAME_XLARGE_VRAM_GB`.
    - `large`: its largest GPU has at least `NAME_LARGE_VRAM_GB`, or it has `AI_TIER_LARGE_RAM_GB` of memory.
    - `small`: less than `AI_TIER_SMALL_RAM_GB` of memory *and* of GPU memory (a small machine with a good GPU is not small).
    - otherwise the default, `NAME`.
  - A class with no model for `NAME` falls to the next column below (small to the default). A non-blank `NAME` in the environment wins on any machine. `AI_MODEL_TIER=small|standard|large|xlarge` names the class instead of measuring. Memory that cannot be read picks the default, never a guessed class.
  - Returns: 0, printing nothing when neither `NAME` nor a column has a value; 2 for a `NAME` that is not a variable name or an `AI_MODEL_TIER` that is not a class.

- ollama_budget_check pull_bytes largest_model_bytes models_dir
  - Purpose: Say whether the machine can take a download of `pull_bytes` into `models_dir` and then load a model of `largest_model_bytes`.
  - Behavior:
    - Disk: what is free after the download must be at least `OLLAMA_DISK_RESERVE_GB`.
    - Memory: the largest model plus `OLLAMA_MEM_HEADROOM_PERCENT` must fit the machine's memory and its GPUs' together, since Ollama splits a model between them. More than that is a refusal. Not fitting what is available *right now* is a warning only: that changes by the minute, and a check that refuses a machine that could run the model gets switched off.
    - A figure that cannot be read is said and skipped, not guessed.
    - Each refusal is a message on stderr with the numbers and the setting that governs it.
  - Returns: 0 fits; 1 disk; 2 memory; 3 both; 4 a size given is not a whole number of at most 15 digits (nothing was checked). With `OLLAMA_IGNORE_BUDGET=1`: 0 in place of 1, 2 and 3; still 4.
  - Note: the memory figure is an estimate (file size plus headroom). What a model needs to load also depends on the context length it is run with.

- ollama_endpoint_pull base_url model
  - Purpose: Ask that Ollama to pull one model and wait for it, however long the download takes.
  - Behavior: Asked for as a stream, so progress keeps the connection alive; given up when nothing arrives for `OLLAMA_PULL_STALL_SECONDS`. Each tenth of a layer of 100 MB or more is said on stderr as it arrives (`  qwen2.5:7b: 40% of 4.7 GB`); a layer that Ollama already holds says nothing. An error anywhere in the stream is a failure whatever the HTTP status. What is not a model reference (letters, digits and `. _ - / :`; no `@`, so neither credentials nor a digest; no empty part, as in `qwen3:` or `qwen3/`) is not sent.
  - Returns: 0 when the stream ends in success; 1 otherwise, with what Ollama said last on stderr.

- ollama_endpoint_ensure_models base_url models_dir model...
  - Purpose: Make sure that Ollama has every model listed, pulling what is missing only when everything fits.
  - Behavior: Lists what the endpoint has; if nothing is missing, returns without asking the registry anything. Otherwise sizes every needed model (the missing ones add up to the download, the largest of all of them is what must fit in memory), checks the budget, and only then pulls, in the order given. Nothing is pulled unless everything fits: a start that ends with half its models is worse than one that says no. A credential in `base_url` is used and never printed.
  - `models_dir` is where that Ollama keeps its models, for the disk check: `ollama_models_dir` for one on this machine, or Docker's data root for an Ollama in a container.
  - Returns:
    - 0 every model is there, or none was asked for
    - 1, 2, 3 the budget refused (as `ollama_budget_check`); nothing was pulled
    - 4 nothing answers at `base_url` as an Ollama
    - 5 models are missing and `OLLAMA_PULL_MISSING=0`, or `ask` was not answered yes, or there was no terminal to ask on
    - 6 a pull failed
    - 7 the budget could not be checked: a missing model's size, or the free disk space, could not be learned (`OLLAMA_IGNORE_BUDGET=1` pulls anyway). A missing model the registry says it does not have is 7 too, with a message of its own: the name is wrong (or the model is private and the registry does not show it), and waiting does not help.
    - 8 an argument is not a model reference
  - A model that is already there and whose size cannot be learned does not stop the rest; it is said that memory was not checked for it.

A project's own configuration
-----------------------------

Projects name their Ollama's address in different ways, some store the API
path with it, and many keep it in a `.env` their start script never sources.

### Where the Ollama runs: `OLLAMA_MODE`

A project says in its `.env` where its models are served. It is not guessed
when it is set.

| `OLLAMA_MODE` | Meaning | What the start check does |
|---|---|---|
| `local` (or `host`) | an Ollama on this machine | lists, sizes, checks this machine's disk (`ollama_models_dir`) and memory, pulls what is missing |
| `docker` | an Ollama in a container on this machine | the same, at the published port and against Docker's disk |
| `remote` | an API on another machine: an Ollama, or a hosted API | measures nothing and pulls nothing unless asked; names what a remote Ollama lacks; passes over what is not an Ollama |
| not set, or `auto` | decided by the address | `local` when the address is this machine, otherwise as `remote`, except that nothing answering stays a refusal (4) |

A typical split: `local` on a developer's machine, `docker` where the stack
brings its own Ollama, `remote` in production against a hosted endpoint, and
either for an integration or QA environment.

```
# .env
OLLAMA_MODE=docker
OLLAMA_URL=http://ollama:11434     # what the backend container uses
OLLAMA_PORT=11435                  # the port published on this machine
```

- ollama_project_ensure_models models_file [env_file] [NAME...]
  - Approved set: the models file is the project's approved models, one per role and class of machine. A `NAME` in the environment or `.env` set to any other model is a manual override: on a terminal it is named as not approved, with the approved ones, and used only after a yes; with no terminal and in CI (`CI=true`, `GITHUB_ACTIONS`) it is refused (9), never asked. A `NAME` the file does not name is not judged.
  - Class: the models are this machine's picks (`ollama_model_for_class`). One above the default that the disk or memory check refuses (1-3) falls back one column (xlarge, large, default) and is checked again, with a warning naming the new picks; when the default does not fit either, the refusal stands. `AI_MODEL_TIER` and `OLLAMA_BUDGET_GPU_LARGEST_BYTES` may be in `.env`. For an Ollama on another machine this machine's memory and GPU are not its own: its class is `AI_MODEL_TIER`, or comes from its stated `OLLAMA_BUDGET_MEM_TOTAL_BYTES` (and `OLLAMA_BUDGET_GPU_LARGEST_BYTES`, else no GPU); with neither, the default column.
  - Purpose: The whole start check from a project's own configuration: `.env`, models file, address, mode, then `ollama_endpoint_ensure_models`.
  - Configuration: `env_file` (`""` for none; a file that is not there yet is no `.env`) is read as data for the model names, the address, `OLLAMA_MODE`, `OLLAMA_PORT`, `OLLAMA_HOST_PORT`, `OLLAMA_MODELS` and every setting under Environment above. A value in the environment that is not blank wins. Nothing read from it is left in the caller's environment, and the caller's `IFS` does not change what is read.
  - Models: as `ollama_models_required models_file [NAME...]`. Pass `""` for the file when the project names its models in `.env` alone. One value is one model: `"small:3b embed"` is refused (8), not read as two.
  - Address: the first variable of `OLLAMA_URL_VARS` that has a value (default `OLLAMA_URL OLLAMA_BASE_URL OLLAMA_HOST`; set it to the project's own name, for example `OLLAMA_URL_VARS=MYAPP_OLLAMA_URL`, in the environment or in `.env`), made a base URL by `ollama_endpoint_base_url`; `http://127.0.0.1:11434` when none has. On the host, `host.docker.internal` is read as this machine.
  - `local`: an address that is not this machine is a contradiction (9), with the mode that would fit named.
  - `docker`: the address a container uses for it (`http://ollama:11434`, a compose service: one label, no dots) does not resolve from a start script on the host, so there it is read as `127.0.0.1`, at `OLLAMA_PORT` or `OLLAMA_HOST_PORT` when one is set and at the address's own port otherwise. A published port that is not a number from 1 to 65535 is a mistake (9), not "use the address's port": that port is often the native Ollama's. Inside a container the name is used as written. A name with a dot, an IP address or an IPv6 literal that is not this machine is another machine, and `docker` is the wrong word for it (9, with `remote` named). An address that is this machine already is used as it is. The disk measured is `OLLAMA_MODELS` when stated, else Docker's data root (`docker info`), else `/var/lib/docker`.
  - `remote`: asked what it has. A model it lacks is a refusal (5) that says so, and nothing is pulled there unless `OLLAMA_PULL_MISSING` is set on. What does not answer as an Ollama (a hosted API of another kind, or one that is not up) is said and passed over (0): a start script on this machine can neither check nor mend it.
  - A pull into another machine, asked for with `OLLAMA_PULL_MISSING`, needs `OLLAMA_BUDGET_DISK_FREE_BYTES` and `OLLAMA_BUDGET_MEM_TOTAL_BYTES` stated for that machine, or `OLLAMA_IGNORE_BUDGET=1`; without them it is a refusal (7), not a check against this machine. This machine's GPU and free memory are never counted for it: `OLLAMA_BUDGET_GPU_BYTES` is 0 and `OLLAMA_BUDGET_MEM_AVAILABLE_BYTES` the stated total unless they are stated too.
  - Returns: as `ollama_endpoint_ensure_models`, and 9 for the project's configuration: no models file and no `NAME` (nothing would be checked), a models file that is not there, a `NAME` or an entry of `OLLAMA_URL_VARS` that is not a variable name, an address that is not one, an `OLLAMA_MODE` that is none of the three (trimmed at the ends only, in any case; the value is not repeated in the message), one the address contradicts, a published port that is not one, or a setting in `.env` that the caller holds read-only. So 1, 2 and 3 are always the disk and the memory.
  - Note: 4 (nothing answers) is returned as it is for `local`, `docker` and an unset mode. For an address on another machine in an unset mode, one listing that fails is already 4: it is not asked again, so nothing is pulled into it after a second answer. A project whose backend waits for Ollama by itself may go on from it: `ollama_project_ensure_models ... || { rc=$?; [[ $rc -eq 4 ]] || exit $rc; }`. With no mode set and a one-word host that does not answer, a second message says what a compose service name is and to set `OLLAMA_MODE=docker`.

- ollama_endpoint_base_url address
  - Purpose: Print the base URL of the Ollama at an address as a project configures it.
  - Behavior: `host`, `host:port` or `:port` gets `http://`, and port 11434 when none is given, as Ollama reads `OLLAMA_HOST`; no host is `127.0.0.1`, and an IPv6 address without brackets gets them. A URL keeps its scheme, its port (none given stays none, for an Ollama behind a proxy), its credentials and a path a proxy serves it under. The API path some projects store with it is removed when it ends the URL, however deep it was written (`/api/v1/chat/completions` too) (`/api`, `/v1`, `/api/generate`, `/api/chat`, `/v1/chat/completions` and the other endpoints of the two APIs), with a query, a fragment and a trailing slash; `/api/ollama` is a proxy's path and stays.
  - Returns: 0; 1, printing nothing, for what is not an address: empty, another scheme, `http:` without its slashes, a space or a control character, a port that is not a number from 1 to 65535, a host with a character no host has (an IPv6 literal holds hex digits, colons and dots, and a `%zone`), or an `@` after the first `/`, `?` or `#` (a password with such a character in it, which must be percent-encoded).

- ollama_endpoint_is_local url
  - Purpose: Say whether a URL points at this machine, so that this machine's disk and memory are the ones a pull would use.
  - Behavior: 0 for a loopback name or address (also IPv4 written inside IPv6), `0.0.0.0`, `::`, this host's name and its own addresses (from `ip` and from `ifconfig`, whichever are there), and for `host.docker.internal` and `gateway.docker.internal` when this is not a container itself. Inside a container (`/.dockerenv` or `/run/.containerenv` present, or `KUBERNETES_SERVICE_HOST` set) those two are the host: another machine. 1 for anything else, including a name that only resolves to this machine: read as another machine, nothing is pulled into it unasked.

- ollama_endpoint_container_reach url
  - Purpose: For a project whose containers call this machine's Ollama at `url` (as the container writes it, for example `http://host.docker.internal:11434`): say whether a container can reach it. An Ollama that answers on `127.0.0.1` but listens on loopback only is not on the Docker bridge unless a forwarder puts it there.
  - Behavior: Sends `GET <url>/api/tags` connected to the default bridge's IPv4 gateway (what `host-gateway` resolves to, unless the daemon sets `host-gateway-ip`) with curl's `--connect-to`: the URL's scheme, credentials, proxy path, port and TLS name stay as the container sends them. Only an answer with `"models"` in it counts. The request goes out from `127.0.0.1`: from the host's own bridge address it is dropped on some hosts while containers are answered. Checks nothing and returns 0 when `url` is another machine (`ollama_endpoint_is_local`), when there is no Docker or it does not answer, when the bridge has no IPv4 gateway, and when the bridge's gateway is not one of this machine's addresses: Docker Desktop, a VM (Colima, OrbStack), rootless Docker or a remote `DOCKER_HOST` (said: not checked).
  - Returns: 0; 4 when the bridge does not answer as an Ollama (the forwarder is named); 9 when `url` is not an address.

- ollama_env_file_export file NAME...
  - Purpose: Export each `NAME` from an env-style file, unless the environment already has a value for it that is not blank (a blank one is no choice: the file's is used).
  - Behavior: The file is read as the models file is, as data: it is never sourced, so `$`, a backquote or a space in a value is only a value. A file that is not there exports nothing. A `NAME` may be any variable name, also one this module uses itself (`name`, `value`, `file`).
  - Returns: 0; 2, exporting nothing, when a `NAME` is not a variable name; 9 when the file sets a `NAME` the caller holds read-only (its blank would otherwise stand for the file's value, silently).

What this module does not do
----------------------------

It reads where a project says its Ollama is (`OLLAMA_MODE` and the address);
it does not find, start or stop one. Starting a container, and sharing one
Ollama between projects, is the next step and is not in this module yet.
