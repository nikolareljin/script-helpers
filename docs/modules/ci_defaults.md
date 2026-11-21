# Module: ci_defaults

Centralized defaults for Docker images used by `scripts/ci_*.sh` helpers.

## Environment variables

All values can be overridden by setting the variable before invoking a script. Overrides are per variable: `lib/foxguard.sh`, `lib/gitleaks.sh` and `lib/ollama_install.sh` always load these defaults, so a variable you set is kept and every other one stays pinned. A different release version with the pinned checksums is refused as a checksum mismatch, so set the version and the checksum of each platform you install on.

### Node.js
- `CI_DEFAULT_NODE_VERSION` (default: `24-bookworm`)
- `CI_DEFAULT_NODE_IMAGE` (default: `node`)
- `CI_DEFAULT_NODE_APT_MAJOR` (default: `24`)
- `CI_DEFAULT_NODESOURCE_APT_FPR` (default: `6F71F525282841EEDAF851B42F59B5F99B1BE0B4`)

The last two are not a Docker image: they are the Node.js major the [deps module](./deps.md) installs on a host, and the fingerprint NodeSource's apt repository key must have before it is used. Bump the major only after checking that `node_<major>.x` is signed by that key.

### Python
- `CI_DEFAULT_PYTHON_VERSION` (default: `3.12-slim`)
- `CI_DEFAULT_PYTHON_IMAGE` (default: `python`)

### Flutter
- `CI_DEFAULT_FLUTTER_VERSION` (default: `3.38.8`)
- `CI_DEFAULT_FLUTTER_IMAGE` (default: `ghcr.io/cirruslabs/flutter`)

### Gradle (Kotlin / Android)
- `CI_DEFAULT_GRADLE_VERSION` (default: `8.7-jdk17`)
- `CI_DEFAULT_GRADLE_IMAGE` (default: `gradle`)

### Go
- `CI_DEFAULT_GO_VERSION` (default: `1.22`)
- `CI_DEFAULT_GO_IMAGE` (default: `golang`)

### Legacy bash (macOS compatibility gate)
- `CI_DEFAULT_BASH32_VERSION` (default: `3.2`)
- `CI_DEFAULT_BASH32_IMAGE` (default: `bash`)

The image `make test-bash32` and `scripts/local_test_bash32.sh` run the suite in; see [bash compatibility](../bash-compatibility.md).

### Gitleaks
- `CI_DEFAULT_GITLEAKS_VERSION` (default: `v8.30.1`)
- `CI_DEFAULT_GITLEAKS_IMAGE` (default: `zricethezav/gitleaks`)
- `CI_DEFAULT_GITLEAKS_SHA256_LINUX_X64`, `..._LINUX_ARM64`, `..._DARWIN_X64`, `..._DARWIN_ARM64`, `..._WINDOWS_X64`

The SHA-256 of each release archive `lib/gitleaks.sh` installs on a host without gitleaks; an archive that does not match is refused. Bump the version and every checksum together, from the release's `gitleaks_<version>_checksums.txt`.

### foxguard
- `CI_DEFAULT_FOXGUARD_VERSION` (default: `0.14.1`)
- `CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64`, `..._LINUX_AARCH64`, `..._MACOS_X86_64`, `..._MACOS_AARCH64`, `..._WINDOWS_X86_64`

Not a Docker image. `ci_security.sh --install-foxguard` downloads that release binary and refuses it unless its SHA-256 matches; see the [foxguard module](./foxguard.md). Bump the version and every checksum together, from the release's `checksums.txt`.

### Wrangler (Cloudflare)
- `CI_DEFAULT_WRANGLER_VERSION` (default: `4.42.0`)

Not a Docker image. This is the version `lib/cloudflare.sh` hands to `npx` when a project has no wrangler of its own; a project with a lockfile gets the version it was tested against instead.

## Usage

```bash
# Override the default Python image tag for this shell
export CI_DEFAULT_PYTHON_VERSION="3.12-slim"
./scripts/ci_python.sh --workdir backend
```

## See also

- `docs/ci_defaults.md` for update guidance and supply-chain pinning tips.
