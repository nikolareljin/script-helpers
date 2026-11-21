# deps

Install a set of development/runtime dependencies. These helpers may use network and elevated privileges.

Functions
---------

- install_dependencies [pkg...]
  - Purpose: Install packages using the available package manager.
  - Args: list of packages; if omitted, installs a common set: `dialog curl jq wget util-linux`.
  - Behavior: Detects and uses `apt-get`, `dnf`, `pacman`, or `brew`. Uses `sudo` when available.

- install_dependencies_ai_runner
  - Purpose: Install a profile of tools typically used by the AI tooling consumers (R-643 and its runner).
  - Behavior:
    - Ensures: `dialog`, `curl`, `jq`, `python3`, `pip3`, Node.js (`CI_DEFAULT_NODE_APT_MAJOR`, 24, or newer), `npm`/`npx`, `git`, and `ollama` (through `ollama_install`: the pinned release, checked against its SHA-256).
    - Node.js on Linux (Debian, Ubuntu): nothing is run when `node` is already that major or newer. Else the distribution's `nodejs` when apt offers that major, else NodeSource's apt repository: its key is downloaded to a temp file and used only when it holds exactly one primary key with the fingerprint `CI_DEFAULT_NODESOURCE_APT_FPR`. It then writes `/etc/apt/keyrings/nodesource.gpg` and `/etc/apt/sources.list.d/nodesource.list` (`signed-by=`) and runs `apt-get install -y nodejs`. No remote script is run. A key that does not match writes nothing and prints how to install Node.js by hand; a failed `apt-get update` puts both files back as they were (removed when there were none, restored when an earlier NodeSource setup left them).
    - Node.js on macOS: `brew install node@<major>`, then `brew link --overwrite --force node@<major>` (a versioned formula is not on `PATH` until linked).
    - Installs clipboard utilities (`xclip` on Linux) as needed.
    - Uses platform-specific package managers and installers; may require `sudo`.
  - Returns: 1 when a dependency cannot be installed on Windows, `ollama_install` failed, or Node.js could not be installed (reported after the remaining steps); otherwise 0. Failures of the other install steps are not checked.
  - Env: `CI_DEFAULT_NODE_APT_MAJOR`, `CI_DEFAULT_NODESOURCE_APT_FPR` (see [ci_defaults](./ci_defaults.md)).
  - Notes: Prints messages for unsupported platforms or manual steps when necessary.

Dependencies
------------

- Package managers: `apt-get`, `dnf`, `pacman`, `brew`. Network access is required.
- `gpg` for the NodeSource key check; `curl` or `wget`.
- `logging` and `os` (imported by the caller); `ci_defaults` and `fetch` are sourced by the module.

