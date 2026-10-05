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

and a start does:

```bash
source scripts/script-helpers/helpers.sh
shlib_import logging ollama_endpoint

models="$(ollama_models_required ai-models.env OLLAMA_MODEL CLASSIFY_MODEL OLLAMA_EMBED_MODEL)"
# shellcheck disable=SC2086  # one model per word
ollama_endpoint_ensure_models "http://127.0.0.1:11434" "$HOME/.ollama/models" $models || exit $?
```

Works against an Ollama on this machine and one in a container alike: every
question is asked over its HTTP API, and the `ollama` CLI is not needed.

Requires `curl`, `awk`, `sed`, `df`. Runs on bash 3.2 and BSD userland.

Environment
-----------

- `OLLAMA_PULL_MISSING` -- `0` never pulls; a missing model is then a refusal. Default `1`.
- `OLLAMA_DISK_RESERVE_GB` -- free space that must remain after the download. Default `10`. A GB is 10^9 bytes throughout, as Ollama shows a model's size.
- `OLLAMA_MEM_HEADROOM_PERCENT` -- added to the largest model's size for the memory check (context, runtime). Default `20`.
- `OLLAMA_IGNORE_BUDGET` -- `1` turns each refusal of the budget into a warning. Default off.
- `OLLAMA_REGISTRY_URL` -- where model sizes are asked. Default `https://registry.ollama.ai`.
- `OLLAMA_REGISTRY_TIMEOUT` -- seconds per size request. Default `15`.
- `OLLAMA_PULL_TIMEOUT` -- seconds to wait for one pull. Default `3600`.
- `OLLAMA_BUDGET_DISK_FREE_BYTES`, `OLLAMA_BUDGET_MEM_TOTAL_BYTES`, `OLLAMA_BUDGET_MEM_AVAILABLE_BYTES`,
  `OLLAMA_BUDGET_GPU_BYTES` -- state a figure instead of having it read: for a machine where it cannot be
  read, for an Ollama on another machine, and for tests.

Functions
---------

- ollama_models_file_get file NAME
  - Purpose: Print the value of `NAME` in a models file.
  - Behavior: Spaces around the name and the value are not part of it, nor is a carriage return; the last line for a name wins; a longer name does not match.
  - Returns: 0, printing nothing when the file or the name is absent.

- ollama_models_file_names file
  - Purpose: Print every name the file sets, one per line, in file order, each once.

- ollama_model_tagged model
  - Purpose: Print the model with a tag; a name without one gets `:latest`, which is how Ollama lists it.
  - Behavior: The tag is looked for in the last path segment only, so `registry.example:5000/team/model` gets `:latest` rather than being read as tagged `5000/team/model`.

- ollama_models_required file [NAME...]
  - Purpose: Print the models a start needs, tagged, one per line, each once.
  - Behavior: With no `NAME`, every name in the file except a large tier's (`NAME_LARGE`, `NAME_LARGE_VRAM_GB`). For each name a non-blank value in the environment wins over the file, trimmed; load the project's `.env` first if it should count.

- ollama_endpoint_models base_url [timeout_seconds=5]
  - Purpose: Print the models the Ollama at `base_url` has, as it names them.
  - Returns: 0; 1 when nothing answers there, or when what answers is not an Ollama (a web server that says 200 to everything).

- ollama_models_missing needed present
  - Purpose: Given two newline-separated lists, print the needed models that are not present.
  - Behavior: Whole names only: `qwen:7b` is not satisfied by `qwen:7b-instruct`.

- ollama_registry_size_bytes model
  - Purpose: Print the size of the model's download in bytes, from the registry manifest.
  - Behavior: Sums every layer and the config. Layers the machine already holds for another model are counted again, so the figure can only overstate.
  - Returns: 0; 1 when the registry does not answer or has no such model; 2 for a model on another registry host (for example `hf.co/...`), which is not asked for.

- ollama_disk_free_bytes path
  - Purpose: Print the bytes free on the filesystem holding `path`, or its nearest existing parent. Prints nothing when it cannot be told.

- ollama_mem_total_bytes / ollama_mem_available_bytes
  - Purpose: Print the machine's memory, and what a new process could have now. Linux reads `/proc/meminfo`; macOS reads `sysctl hw.memsize` and `vm_stat` (free plus inactive pages). Prints nothing when it cannot be told.

- ollama_gpu_mem_bytes
  - Purpose: Print the memory of the largest NVIDIA GPU (`nvidia-smi`), or `0`. Apple silicon shares memory with its GPU and is covered by the total.

- ollama_budget_check pull_bytes largest_model_bytes models_dir
  - Purpose: Say whether the machine can take a download of `pull_bytes` into `models_dir` and then load a model of `largest_model_bytes`.
  - Behavior:
    - Disk: what is free after the download must stay above `OLLAMA_DISK_RESERVE_GB`.
    - Memory: the largest model plus `OLLAMA_MEM_HEADROOM_PERCENT` must fit the machine's memory or its GPU's. Not fitting what is available *right now* is a warning only: that changes by the minute, and a check that refuses a machine that could run the model gets switched off.
    - A figure that cannot be read is said and skipped, not guessed.
    - Each refusal is one line on stderr with the numbers and the setting that governs it.
  - Returns: 0 fits; 1 disk; 2 memory; 3 both. Always 0 with `OLLAMA_IGNORE_BUDGET=1`.
  - Note: the memory figure is an estimate (file size plus headroom). What a model needs to load also depends on the context length it is run with.

- ollama_endpoint_pull base_url model
  - Purpose: Ask that Ollama to pull one model and wait for it.
  - Returns: 0 when it reports success; 1 otherwise.

- ollama_endpoint_ensure_models base_url models_dir model...
  - Purpose: Make sure that Ollama has every model listed, pulling what is missing only when everything fits.
  - Behavior: Lists what the endpoint has; if nothing is missing, returns without asking the registry anything. Otherwise sizes every needed model (the missing ones add up to the download, the largest of all of them is what must fit in memory), checks the budget, and only then pulls, in the order given. Nothing is pulled unless everything fits: a start that ends with half its models is worse than one that says no.
  - `models_dir` is where that Ollama keeps its models, for the disk check: a directory on this machine, or Docker's data root for an Ollama in a container.
  - Returns:
    - 0 every model is there
    - 1, 2, 3 the budget refused (as `ollama_budget_check`); nothing was pulled
    - 4 nothing answers at `base_url` as an Ollama
    - 5 models are missing and `OLLAMA_PULL_MISSING=0`
    - 6 a pull failed
    - 7 a missing model's size could not be learned, so nothing says whether it fits (`OLLAMA_IGNORE_BUDGET=1` pulls anyway)

What this module does not do
----------------------------

It is told the endpoint. Finding one (an Ollama on the host that containers
can reach, or a shared container when there is none) is the next step and
is not in this module yet.
