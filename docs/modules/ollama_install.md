# ollama_install

Put Ollama itself on a machine, from a source that can be checked. Ollama's own
one-line installer (`curl -fsSL https://ollama.com/install.sh | sh`) runs whatever
script the server returns at that moment, as root; this module installs the same
program in a way that can be checked instead:

| Platform | Source |
|---|---|
| Linux, x86_64 and arm64 | the official release archive of the pinned version, compared with the pinned SHA-256 before anything is unpacked |
| macOS | Homebrew (`brew install ollama`; Homebrew checks its bottles), else the release archive, checked the same way |
| Windows (PowerShell: `ps/lib/ollama_install.ps1`; or Git Bash, MSYS, Cygwin: this module) | winget (`Ollama.Ollama`; winget checks the installer against its manifest), else the release zip, checked the same way and unpacked under `%LOCALAPPDATA%\Programs\Ollama`. No setup program is run and nothing needs elevation |
| anything else | nothing is downloaded; the message names the official download page |

The version and the SHA-256 of each archive are pinned in `lib/ci_defaults.sh`
(`CI_DEFAULT_OLLAMA_VERSION`, `CI_DEFAULT_OLLAMA_SHA256_LINUX_AMD64`,
`CI_DEFAULT_OLLAMA_SHA256_LINUX_ARM64`, `CI_DEFAULT_OLLAMA_SHA256_DARWIN`,
`CI_DEFAULT_OLLAMA_SHA256_WINDOWS_AMD64`, `CI_DEFAULT_OLLAMA_SHA256_WINDOWS_ARM64`),
copied from the release's `sha256sum.txt`. `ps/lib/ci_defaults.ps1` carries the
Windows ones again for PowerShell; a test fails when the two differ. Bump them
together; an archive that does not match is refused and nothing is unpacked.

Not pinned: what Homebrew and winget install is their current package, checked by
them, not necessarily the pinned version.

It installs the program only. Running Ollama as a service (the systemd unit the
one-line installer writes, or `brew services start ollama`) stays with the owner of
the machine.

Return codes: `0` installed, or already there at the pinned version or newer; `1`
the download failed or does not match the pinned SHA-256; `3` a required tool is
missing (`curl`, `zstd` for the Linux archive, `unzip` for the Windows zip, `shasum` or `openssl`), or the
platform has no checkable source.

Usage
-----

From a checkout, without writing a script:

```bash
scripts/install_ollama.sh --check            # what is installed, what is pinned, what would happen
scripts/install_ollama.sh                    # install or upgrade
scripts/install_ollama.sh --prefix ~/tmp-ollama
```

```powershell
.\ps\scripts\install_ollama.ps1 -Check
.\ps\scripts\install_ollama.ps1 -Prefix $env:TEMP\ollama-test
```

To confirm it on a real machine (downloads the release, works only in a throwaway
directory, prints PASS/FAIL per case): `bash tests/machine/ollama_install_check.sh`,
or on Windows `pwsh -NoProfile -File ps/tests/machine/ollama_install_check.ps1`. See
[tests/machine](https://github.com/nikolareljin/script-helpers/tree/main/tests/machine).

From a script:

```bash
source scripts/script-helpers/helpers.sh
shlib_import logging ollama_install

ollama_install                          # into /usr/local (sudo when not root)
ollama_install --prefix "$HOME/.local"  # no root; $HOME/.local/bin must be on PATH
ollama_install --force                  # reinstall the pinned version
```

PowerShell (Windows):

```powershell
. scripts/script-helpers/ps/helpers.ps1
Import-ScriptHelpers ci_defaults ollama_install
ollama_install                          # winget, else the zip into $env:LOCALAPPDATA\Programs\Ollama
ollama_install -Prefix C:\Tools\Ollama  # the zip into that directory; winget is not used
```

The zip install does not change `PATH`: add the directory, or start
`ollama.exe` from it. The PowerShell module is tested on Linux PowerShell with
the download stubbed; it has not run on a Windows machine yet.

Functions
---------

- ollama_install [--prefix DIR] [--force]
  - Purpose: Install the pinned Ollama unless one at that version or newer is on `PATH` already. An older one is upgraded: Homebrew's own with `brew upgrade` (one from elsewhere gets the formula installed beside it), winget's with `winget upgrade` (when winget has nothing newer, the pinned zip goes where Ollama's installer puts it), and an archive install is replaced. After Homebrew or winget the version on `PATH` is reported, with a warning when their catalog is still behind the pin.
  - Args: `--prefix DIR`: where `bin/ollama` (and on Linux `lib/ollama/`) goes, or on Windows `ollama.exe` (default `%LOCALAPPDATA%\Programs\Ollama`; a prefix skips winget); default `/usr/local`, unpacked through `sudo` when the shell is not root and the directory is not writable. `--force`: install even when the pinned version or a newer one is there.
  - Env: `OLLAMA_RELEASE_BASE_URL` (default `https://github.com/ollama/ollama/releases/download`), for a mirror; the archive is still checked against the pinned SHA-256. `CI_DEFAULT_OLLAMA_*` override the pins.
  - Behavior: On macOS with Homebrew, `brew install ollama`. Otherwise downloads `v<version>/<asset>`, checks its SHA-256, and unpacks it. A mismatch deletes the download and unpacks nothing. The Linux archive is `bin/ollama` and `lib/ollama/`. The macOS archive is flat (the binary, `llama-server` and the libraries it loads from beside itself): all of it goes to `lib/ollama/`, and `bin/ollama` is a two-line launcher that runs it from there. The archive is unpacked into a staging directory first, so a damaged one fails before anything installed is touched. An upgrade then removes the old `lib/ollama/`, so no library of the previous version is loaded beside the new one, and replaces `bin/ollama` rather than writing over it, which a running Ollama (the Linux service) would refuse; nothing else in the prefix is touched. On macOS a `--prefix` means the archive, not Homebrew. Root is needed when the nearest existing directory of the prefix is not writable. A relative prefix is made absolute (the macOS launcher names it, and must not depend on where it is started), and a prefix with a quote, `$`, a backquote, a backslash or a line break is refused (3).
  - Note: replacing an Ollama that is running does not restart it; the message says so (`sudo systemctl restart ollama` for the Linux service).
  - Returns: 0, 1 or 3 as above.

- ollama_install_asset
  - Purpose: Print the release asset for this machine: `ollama-linux-amd64.tar.zst`, `ollama-linux-arm64.tar.zst`, `ollama-darwin.tgz`, or under Git Bash, MSYS or Cygwin `ollama-windows-amd64.zip` / `ollama-windows-arm64.zip`.
  - Returns: 3 on a platform with no archive this module installs.

- ollama_install_expected_sha256 asset
  - Purpose: Print the pinned SHA-256 of that asset, from `CI_DEFAULT_OLLAMA_SHA256_*`.
  - Returns: 3 for an asset with no pin.

- ollama_install_sha256 file
  - Purpose: Print the file's SHA-256, with `shasum` or `openssl`.
  - Returns: 3 when neither is there.

- ollama_installed_version [binary]
  - Purpose: Print the version of that `ollama` binary, or of the one on `PATH` (`0.40.0`). `ollama --version` reports a running server's version first; the binary's own is read instead (asked with `OLLAMA_HOST` at a port nothing listens on, and its `client version` line wins).
  - Returns: 1 when there is no `ollama`, or its version cannot be read.

Used by
-------

- `install_dependencies_ai_runner` (`lib/deps.sh`) and `ollama_install_cli` (`lib/ollama.sh`), which used to run the one-line installer.
- The start check of a project (`lib/ollama_endpoint.sh`) does not install anything; see [local models](../local-models.md#installing-ollama).
