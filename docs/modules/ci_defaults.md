# Module: ci_defaults

Centralized defaults for Docker images used by `scripts/ci_*.sh` helpers.

## Environment variables

All values can be overridden by setting the variable before invoking a script.

### Node.js
- `CI_DEFAULT_NODE_VERSION` (default: `24-bookworm`)
- `CI_DEFAULT_NODE_IMAGE` (default: `node`)

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

### Gitleaks
- `CI_DEFAULT_GITLEAKS_VERSION` (default: `v8.30.0`)
- `CI_DEFAULT_GITLEAKS_IMAGE` (default: `zricethezav/gitleaks`)

### foxguard
- `CI_DEFAULT_FOXGUARD_VERSION` (default: `0.14.0`)
- `CI_DEFAULT_FOXGUARD_SHA256_LINUX_X86_64`, `..._LINUX_AARCH64`, `..._MACOS_X86_64`, `..._MACOS_AARCH64`

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
