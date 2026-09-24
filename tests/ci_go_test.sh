#!/usr/bin/env bash
# SCRIPT: ci_go_test.sh
# DESCRIPTION: Tests the shell and command scripts/ci_go.sh hands to docker.
# USAGE: bash tests/ci_go_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_go_test.sh
# ----------------------------------------------------
#
# The shell matters as much as the command. Docker mode ran `bash -lc`, and a
# login shell sources /etc/profile, which replaces PATH with a default that does
# not contain /usr/local/go/bin -- where the golang image keeps the toolchain.
# Every Docker-mode run exited 127 with `go: command not found`, in every
# consumer, and nothing here noticed because no test read the argv.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[ci_go_test] $*"; }
error() { echo "[ci_go_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# A docker stand-in recording every argument, so the shell flags are visible and
# not just the command string.
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/proj"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$tmp/argv"
for last in "\$@"; do :; done
printf '%s' "\$last" > "$tmp/cmd"
EOF
chmod +x "$tmp/bin/docker"
printf 'module example.com/t\n\ngo 1.22\n' > "$tmp/proj/go.mod"

rc=0
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_go.sh \
  --workdir "$tmp/proj" --skip-test --skip-build >/dev/null 2>&1 || rc=$?

if [[ $rc -ne 0 ]]; then
  error "docker mode exited $rc"
fi

# 1. The shell must not be a login shell.
if grep -qx -- '-lc' "$tmp/argv" 2>/dev/null; then
  error "docker is invoked with a login shell (-lc); /etc/profile drops /usr/local/go/bin from PATH"
elif grep -qx -- '-c' "$tmp/argv" 2>/dev/null; then
  note "docker runs the command with bash -c"
else
  error "no bash shell flag found in the docker argv:"
  sed 's/^/    /' "$tmp/argv" >&2
fi

# 2. And bash is what runs it, immediately before the flag.
if ! grep -qx -- 'bash' "$tmp/argv" 2>/dev/null; then
  error "docker argv does not contain 'bash'"
fi

# 3. Both caches must point somewhere the host user can write. The container
#    runs as that user, who has no home in it, so an unredirected GOCACHE lands
#    at /.cache and the run dies with a permission error -- which is what the
#    login-shell fix alone left behind.
for var in GOMODCACHE GOCACHE; do
  if grep -qx -- "${var}=/tmp/[a-z-]*" "$tmp/argv" 2>/dev/null; then
    note "${var} is redirected to a writable path"
  else
    error "${var} is not redirected; the container user cannot write Go's default location"
  fi
done

# 4. And both are mounted from the host, or every run is a cold one: the build
#    cache is where the time goes, 13s against 2s on a real module here.
for mount in /tmp/go-cache /tmp/go-build; do
  if grep -q -- ":${mount}\$" "$tmp/argv" 2>/dev/null; then
    note "${mount} is mounted from the host"
  else
    error "${mount} is not mounted; the cache would be discarded after every run"
  fi
done

# 5. The lint command still reaches the container intact.
got="$(cat "$tmp/cmd" 2>/dev/null)"
want='go mod tidy && test -z "$(gofmt -l .)" && go vet ./...'
if [[ "$got" == "$want" ]]; then
  note "the default lint command is passed unchanged"
else
  error "lint command:"
  error "  want: $want"
  error "  got:  $got"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_go_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_go_test] OK"
