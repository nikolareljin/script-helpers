#!/usr/bin/env bash
# SCRIPT: ci_docker_shell_test.sh
# DESCRIPTION: Asserts no CI helper hands a login shell to docker.
# USAGE: bash tests/ci_docker_shell_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_docker_shell_test.sh
# ----------------------------------------------------
#
# `bash -lc` inside a container sources /etc/profile, which replaces PATH with a
# default built for a shell session. The golang image keeps its toolchain in
# /usr/local/go/bin, which that default does not carry, so every Docker-mode run
# of ci_go.sh exited 127 with `go: command not found`, in every consumer, until
# 2026-09-22.
#
# Two checks, because either alone has a blind spot. The static one reads every
# helper, including ones added after this was written, and is how the two inline
# `docker run ... bash -lc` calls in ci_security.sh were found -- the original
# audit grepped for the DOCKER_CMD array shape and missed them. The dynamic one
# runs each helper against a docker stand-in and reads the argv, because a
# helper can build its argument list in a way no grep predicts.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[ci_docker_shell_test] $*"; }
error() { echo "[ci_docker_shell_test][ERROR] $*" >&2; failures=$((failures+1)); }

# ---------------------------------------------------------------------------
# 1. Static: no `bash -lc` anywhere a docker command is being assembled.
#
# The three shapes that occur, all of which were real:
#   DOCKER_CMD+=("$IMAGE" bash -lc)
#   docker run ... "$IMAGE" bash -lc "cmd"
#   docker run ... "$IMAGE" \
#     bash -lc "cmd"
# A `bash -lc` outside them is the host path, where a login shell is correct:
# it is what picks up a user's nvm or asdf setup.
# ---------------------------------------------------------------------------
static_hits=0
for script in scripts/ci_*.sh; do
  while IFS='|' read -r lineno text; do
    [[ -z "$lineno" ]] && continue
    error "$script:$lineno hands a login shell to docker: $text"
    static_hits=$((static_hits+1))
  done < <(awk '
    # A comment is prose, not a call site. ci_go.sh documents the bug by
    # quoting the broken command, and that must not fail this test.
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^#/) { cont = 0; next }

      # Any DOCKER-ish token, not just DOCKER_CMD. A helper assembling its
      # argv under another array name (DOCKER_RUN, DOCKER_ARGS) evaded this
      # check entirely and the test still reported OK.
      docker_ctx = ($0 ~ /docker run/ || $0 ~ /DOCKER/)
      if (docker_ctx || cont) {
        if ($0 ~ /bash[[:space:]]+-lc/) print NR "|" line
      }
      # A trailing backslash carries docker context onto the next line.
      cont = (docker_ctx || cont) && ($0 ~ /\\[[:space:]]*$/)
    }
  ' "$script")
done
if [[ $static_hits -eq 0 ]]; then
  note "no helper hands a login shell to docker ($(ls scripts/ci_*.sh | wc -l) scripts read)"
fi

# ---------------------------------------------------------------------------
# 2. Dynamic: run each helper in Docker mode against a stand-in that records
#    argv, and read the flag that actually reached docker.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/home"

cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
EOF
chmod +x "$tmp/bin/docker"

# Each helper, the flags that reach its docker call with the least work, and a
# fixture the call needs. Skipping every step would record no argv at all, and
# an empty recording must not read as a pass.
run_case() {
  local name="$1" script="$2"; shift 2
  local proj="$tmp/proj-$name"
  mkdir -p "$proj"
  case "$name" in
    node)     printf '{"name":"t","version":"1.0.0"}\n' > "$proj/package.json" ;;
    python)   printf 'requests==2.32.3\n' > "$proj/requirements.txt" ;;
    gradle)   printf '' > "$proj/gradlew"; chmod +x "$proj/gradlew" ;;
    flutter)  printf 'name: t\n' > "$proj/pubspec.yaml" ;;
    security) printf 'requests==2.32.3\n' > "$proj/requirements.txt" ;;
  esac

  : > "$tmp/argv"
  CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
    bash "$script" --workdir "$proj" "$@" >/dev/null 2>&1

  if [[ ! -s "$tmp/argv" ]]; then
    error "$name: the helper never called docker, so nothing was checked"
    return
  fi
  if grep -qx -- '-lc' "$tmp/argv"; then
    error "$name: docker was handed a login shell (-lc)"
  elif grep -qx -- '-c' "$tmp/argv"; then
    note "$name: docker runs the command with bash -c"
  else
    error "$name: no bash shell flag reached docker:"
    sed 's/^/    /' "$tmp/argv" >&2
  fi
  # bash must be the argument immediately before the flag. Grepping for each
  # separately passes on an argv where they are unrelated.
  if ! grep -A1 -x -- 'bash' "$tmp/argv" | grep -qx -- '-c'; then
    error "$name: 'bash' is not immediately followed by -c in the docker argv:"
    sed 's/^/    /' "$tmp/argv" >&2
  fi
}

run_case node     scripts/ci_node.sh     --skip-lint --skip-test --skip-build
run_case python   scripts/ci_python.sh
run_case gradle   scripts/ci_gradle.sh   --skip-lint --skip-test --skip-detekt
run_case flutter  scripts/ci_flutter.sh  --skip-test --skip-build
run_case security scripts/ci_security.sh --skip-node --skip-gitleaks

if [[ $failures -gt 0 ]]; then
  echo "[ci_docker_shell_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_docker_shell_test] OK"
