# Real-machine checks

`make test` is offline and stubbed: it proves what the code does against fakes. These
checks run the real thing on a real machine, downloads and binaries included, so a
person can confirm a change on Linux, macOS and Windows with the same commands every
time. They are regression tests that need a machine, and they are not run by `make test`
or by the bash 3.2 runner (those read `tests/*_test.sh` only).

Rules for a check here:

- One per feature that installs, downloads, or depends on the real machine, written in
  the same pull request as the feature. Bash in `tests/machine/`, PowerShell in
  `ps/tests/machine/`.
- It works only in a directory it makes, and removes it (`--keep` / `-Keep` leaves it). It
  never changes what is installed on the machine, and says what it does not cover.
- It prints one `PASS`/`FAIL` line per case and a `summary:` line, and exits 0 when all
  pass, 1 when one fails, 2 when the machine cannot run it (no network, no tool).
- The feature also has an entry script a person runs (`scripts/<verb>.sh`,
  `ps/scripts/<verb>.ps1`).

## Checks

| Check | Linux / macOS | Windows | What it runs | Last run by a person |
|---|---|---|---|---|
| Ollama install | `bash tests/machine/ollama_install_check.sh` | `pwsh -NoProfile -File ps/tests/machine/ollama_install_check.ps1` | the pinned release, downloaded and checked; install, nothing-to-do, mismatch, damaged archive, upgrade of a running older install, launcher prefix | Linux x86_64, 2026-10-07 |

Entry scripts for the same feature: `scripts/install_ollama.sh --check`,
`ps/scripts/install_ollama.ps1 -Check`.

When you run a check on a machine, add the OS and date to the last column in the pull
request that next touches the feature.
