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
# 1. Static: no `bash -lc` or `sh -lc` anywhere a docker command is being
#    assembled. `sh -lc` sources /etc/profile the same way.
#
# The three shapes that occur, all of which were real:
#   DOCKER_CMD+=("$IMAGE" bash -lc)
#   docker run ... "$IMAGE" bash -lc "cmd"
#   docker run ... "$IMAGE" \
#     bash -lc "cmd"
#   docker_compose ... run|exec ... "$service" sh -lc "cmd"
# A `bash -lc` outside them is the host path, where a login shell is correct:
# it is what picks up a user's nvm or asdf setup.
# ---------------------------------------------------------------------------
# Prints `lineno|text` for each login shell handed to docker in file $1.
#
# A login shell is any flag form that sets login mode: -lc, -cl, -lic, -l -c,
# --login -c, -o pipefail -lc. Options are read up to the first word that is not
# an option, so `sh -c 'ls -l'` is not a hit: `'ls` ends the options.
scan_login_shells() {
  awk '
    # 1 if a bash or sh on this line is started with a login flag.
    function login_hit(s,    rest, n, i, t, toks, skip) {
      # bash or sh as a whole word, bare or quoted: /bin/sh and "sh" count,
      # zsh and fish-sh do not. \047 is a single quote.
      while (match(s, /(^|[^[:alnum:]_.-])(bash|sh)["\047]?([[:space:]]|$)/)) {
        rest = substr(s, RSTART + RLENGTH)
        s = rest
        n = split(rest, toks, /[[:space:]]+/)
        skip = 0
        for (i = 1; i <= n; i++) {
          t = toks[i]
          gsub(/["\047]/, "", t)
          sub(/[);]+$/, "", t)
          if (t == "") continue
          if (skip) { skip = 0; continue }
          if (t == "--login") return 1
          if (t == "--") break
          if (t ~ /^--[[:alnum:]-]+$/) continue
          if (t ~ /^[-+][[:alpha:]]+$/) {
            if (t ~ /^-.*l/) return 1
            # -o and -O take an argument, also at the end of a cluster: -eo pipefail.
            if (t ~ /[oO]$/) skip = 1
            continue
          }
          break
        }
      }
      return 0
    }
    # $0 without quoted strings, backslash escapes and a trailing comment, so
    # parens in `sh -c "echo ("` or `# (note` do not move the array depth.
    # q is the open quote: \047 single, " double, $ for $'...', where a
    # backslash escapes the next character. # starts a comment only at the
    # start of a word: `(# x`, not `${#a[@]}` or `foo#bar`.
    function code_only(s,    out, i, c, q, n) {
      out = ""; q = ""; n = length(s)
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (q == "\047") { if (c == "\047") q = ""; continue }
        if (c == "\\") { i++; continue }
        if (q == "$") { if (c == "\047") q = ""; continue }
        if (q == "\"") { if (c == "\"") q = ""; continue }
        if (c == "$" && substr(s, i + 1, 1) == "\047") { q = "$"; i++; continue }
        if (c == "\047" || c == "\"") { q = c; continue }
        if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:]();|&<>]/)) break
        out = out c
      }
      return out
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      # A comment is prose, not a call site. ci_go.sh documents the bug by
      # quoting the broken command, and that must not fail this test.
      if (line ~ /^#/) { cont = 0; next }

      # Any DOCKER-ish token, not just DOCKER_CMD. A helper assembling its
      # argv under another array name (DOCKER_RUN, DOCKER_ARGS) evaded this
      # check entirely and the test still reported OK.
      # docker_compose and `docker compose` too: ci_wp_plugin_check.sh and
      # ci_pimcore_bundle_check.sh hand their shells to `docker_compose run|exec`.
      docker_ctx = ($0 ~ /docker run/ || $0 ~ /DOCKER/ || $0 ~ /docker(_compose|[[:space:]]+compose|[[:space:]]+exec|[[:space:]]+container[[:space:]]+(run|exec))/)
      if ((docker_ctx || cont || depth > 0) && login_hit($0)) print NR "|" line
      # A trailing backslash carries docker context onto the next line, and
      # so does an array literal opened on a docker line, until the `)` that
      # balances it. Counting parens closes `a=(\n x)` and keeps `$(pwd)`
      # inside the array from closing it early.
      cont = (docker_ctx || cont || depth > 0) && ($0 ~ /\\[[:space:]]*$/)
      if (docker_ctx || depth > 0) {
        p = code_only($0)
        depth += gsub(/\(/, "", p) - gsub(/\)/, "", p)
        if (depth < 0) depth = 0
      }
    }
  ' "$1"
}

# The scanner itself, on samples: each must be caught or passed as labelled.
# Without this a scanner that matches nothing reports OK on every helper.
sample_dir="$(mktemp -d)"
check_sample() {
  local want="$1" text="$2" got
  printf '%b\n' "$text" > "$sample_dir/sample.sh"
  if [[ -n "$(scan_login_shells "$sample_dir/sample.sh")" ]]; then got=hit; else got=pass; fi
  if [[ "$got" != "$want" ]]; then
    error "scanner: expected $want, got $got for: $text"
  fi
}
check_sample hit  'docker run --rm img bash -lc "go version"'
check_sample hit  'docker run --rm img sh -l -c "go version"'
check_sample hit  'docker run --rm img bash -l -c "go version"'
check_sample hit  'docker run --rm img bash --login -c "go version"'
check_sample hit  'docker run --rm img bash -cl "go version"'
check_sample hit  'docker run --rm img bash -lic "go version"'
check_sample hit  'docker run --rm img bash -c -l "go version"'
check_sample hit  'docker run --rm img bash -o pipefail -lc "go version"'
check_sample hit  'docker run --rm img bash -eo pipefail -lc "go version"'
check_sample hit  'docker run --rm img "bash" "-l" "-c" "go version"'
check_sample hit  'docker run --rm img /bin/sh -lc "go version"'
check_sample hit  'DOCKER_CMD+=("$IMAGE" bash -l)'
check_sample hit  'docker_compose exec -T php sh --login -c "$cmd"'
check_sample hit  'docker run --rm \\\\\n  -v x:y \\\\\n  img \\\\\n  sh -l -c "cmd"'
check_sample hit  'DOCKER_ARGS=(\n  docker run --rm img\n  bash -lc\n)'
check_sample hit  'DOCKER_ARGS=(docker run --rm\n  img bash -lc\n)'
check_sample hit  'DOCKER_ARGS=(\n  docker run -v "$(pwd):/w"\n  img bash -lc\n)'
check_sample hit  'docker container run --rm img bash -lc "x"'
check_sample pass 'DOCKER_ARGS=(\n  docker run --rm img)\nbash -lc "$HOST_CMD"'
check_sample pass 'out=$(docker run --rm img bash -c "x")\nbash -lc "$HOST_CMD"'
check_sample pass 'docker run --rm img bash -c "go version"'
check_sample pass 'docker run --rm img sh -c "ls -l"'
check_sample pass "docker run --rm img sh -c 'ls -l /tmp'"
check_sample pass 'docker run --rm img bash -c -- -l'
check_sample pass 'docker run --rm img bash -o pipefail -c "ls -la"'
check_sample pass 'docker run --rm img zsh -lc "x"'
check_sample pass 'bash -lc "$HOST_CMD"'
check_sample pass 'DOCKER_ARGS=(\n  docker run --rm img\n)\nbash -lc "$HOST_CMD"'
check_sample pass '# docker run --rm img bash -lc "x"'
check_sample pass 'docker run --rm img sh -c "echo ("\nbash -lc "$HOST_CMD"'
check_sample pass "docker run --rm img sh -c 'echo ('\nbash -lc \"\$HOST_CMD\""
check_sample pass 'docker run --rm img  # see (notes\nbash -lc "$HOST_CMD"'
check_sample hit  'DOCKER_ARGS=(\n  docker run img sh -c "echo )"\n  bash -lc\n)'
check_sample hit  'DOCKER_ARGS=( # )\n  img bash -lc\n)'
check_sample hit  'DOCKER_ARGS=(\n  img "\\")"\n  bash -lc\n)'
check_sample pass 'DOCKER_ARGS=(#(note\n  img)\nbash -lc "$HOST_CMD"'
check_sample pass "DOCKER_ARGS=(img \$'a\\\\'(')\nbash -lc \"\$HOST_CMD\""
check_sample hit  'DOCKER_ARGS=(img "${#a[@]}" foo#bar\n  bash -lc\n)'
rm -rf "$sample_dir"

static_hits=0
for script in scripts/ci_*.sh; do
  while IFS='|' read -r lineno text; do
    [[ -z "$lineno" ]] && continue
    error "$script:$lineno hands a login shell to docker: $text"
    static_hits=$((static_hits+1))
  done < <(scan_login_shells "$script")
done
if [[ $static_hits -eq 0 ]]; then
  note "no helper hands a login shell to docker ($(ls scripts/ci_*.sh | wc -l) scripts read)"
fi

# ---------------------------------------------------------------------------
# 2. Dynamic: run each helper in Docker mode against a stand-in that records
#    argv, and read the flag that actually reached docker.
# ---------------------------------------------------------------------------
tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT
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
  if ! grep -qx -- '-c' <<< "$(grep -A1 -x -- 'bash' "$tmp/argv")"; then
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
