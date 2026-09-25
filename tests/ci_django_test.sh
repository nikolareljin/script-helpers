#!/usr/bin/env bash
# SCRIPT: ci_django_test.sh
# DESCRIPTION: Tests the refusals, the exported environment and the docker argv of scripts/ci_django.sh.
# USAGE: bash tests/ci_django_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_django_test.sh
# ----------------------------------------------------
#
# Starting a real database takes tens of seconds, so what is asserted here is
# what can be wrong without one: the refusals, and the arguments handed to
# docker. The database itself is exercised end to end against postgres in the
# ci-helpers self-test.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_django.sh"
failures=0
note()  { echo "[ci_django_test] $*"; }
error() { echo "[ci_django_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

app="$tmp/app"; mkdir -p "$app"
cat > "$app/manage.py" <<'PY'
#!/usr/bin/env python
import sys
print("fixture manage.py:", sys.argv[1:])
PY
chmod +x "$app/manage.py"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
exit 0
EOF
chmod +x "$tmp/bin/docker"
: > "$tmp/argv"

run()     { PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" >/dev/null 2>&1; }
run_out() { PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

expect_refusal() {   # <label> <needle> <args...>
  local label="$1" needle="$2"; shift 2
  local out rc
  out="$(run_out "$@")"; rc=$?
  if [[ $rc -ne 0 ]] && grep -q -- "$needle" <<<"$out"; then
    note "$label"
  else
    error "$label -- exit ${rc}, output: ${out##*$'\n'}"
  fi
}

# --- refusals --------------------------------------------------------------
expect_refusal "a missing --workdir is refused" "--workdir does not exist" --workdir "$tmp/nope"
mkdir -p "$tmp/notdjango"
expect_refusal "a directory with no manage.py is refused" "No manage.py in" --workdir "$tmp/notdjango"
expect_refusal "an image of unknown engine is refused" "Cannot tell which engine" \
  --workdir "$app" --db-image some/unknown:1
expect_refusal "sqlite with --db-image is refused" "does not use a database image" \
  --workdir "$app" --db-image postgres:16 --db-engine sqlite
expect_refusal "an unknown engine is refused" "must be sqlite, mysql or pgsql" \
  --workdir "$app" --db-engine oracle

# Every option that consumes a value must refuse a missing one with exit 2 and
# a sentence naming itself. The list is built from the parser, and from every
# line that consumes a value rather than from the lines that guard -- keyed on
# the guard, deleting one would drop that option from the list and stay green.
opts=()
while IFS= read -r opt; do opts+=("$opt"); done < <(
  sed -n 's/^    \(--[a-z-]*\)).*"\$2"; shift 2.*/\1/p' "$SCRIPT")
if (( ${#opts[@]} < 10 )); then
  error "only ${#opts[@]} value-taking options found in the parser; the extraction is wrong"
else
  bad=0
  for opt in "${opts[@]}"; do
    out="$(run_out "$opt")"; rc=$?
    if [[ $rc -ne 2 ]] || ! grep -q -- "$opt requires a value" <<<"$out"; then
      error "${opt} with no value: exit ${rc}, said: $(head -1 <<<"$out")"; bad=$((bad+1))
    fi
  done
  (( bad == 0 )) && note "all ${#opts[@]} value-taking options refuse a missing value with exit 2"
fi

# --- the environment the steps get ----------------------------------------
: > "$tmp/argv"
run --workdir "$app" --python-image python:3.12-slim --install-command '' \
    --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the argv assertions prove nothing"
else
  if grep -q -- 'DJANGO_DB_NAME=/app/ci_django_' "$tmp/argv"; then
    note "sqlite is a file the steps share, at the path the container sees"
  else
    error "no usable DJANGO_DB_NAME reached the steps: $(grep -m1 DJANGO_DB_NAME "$tmp/argv")"
  fi
  if grep -q -- 'DJANGO_DB_NAME=:memory:' "$tmp/argv"; then
    error "sqlite is in memory, so the schema cannot outlive the step that creates it"
  fi
  for want in 'DJANGO_DB_ENGINE=sqlite' 'PYTHONUNBUFFERED=1' 'HOME=/tmp' '/app'; do
    grep -q -- "$want" "$tmp/argv" || error "argv is missing ${want}"
  done
  note "argv carries the engine, the python flags, a writable HOME and the mount"
  if grep -qx -- '-lc' "$tmp/argv"; then
    error "steps run through a login shell (-lc), which replaces PATH"
  elif grep -qx -- '-c' "$tmp/argv"; then
    note "steps run with bash -c"
  fi
  if grep -qx -- '-u' "$tmp/argv" && grep -qx -- "$(id -u):$(id -g)" "$tmp/argv"; then
    note "the step container runs as the invoking user"
  else
    error "no -u reached docker; files written into the project would be root-owned"
  fi
fi

# --- a server engine -------------------------------------------------------
: > "$tmp/argv"
run --workdir "$app" --python-image python:3.12-slim --db-image postgres:16 \
    --db-wait-seconds 2 --install-command '' --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called for the postgres run"
else
  for want in 'POSTGRES_DB=django' 'POSTGRES_USER=django' 'DJANGO_DB_ENGINE=pgsql'; do
    grep -qx -- "$want" "$tmp/argv" || error "the postgres run is missing ${want}"
  done
  note "a postgres image is recognised and passes postgres variables"
  if grep -q 'MYSQL_' "$tmp/argv"; then
    error "the postgres run also passed MySQL variables"
  fi
  if grep -q 'DATABASE_URL=postgres://django:django@django-db-' "$tmp/argv"; then
    note "DATABASE_URL names the container, which is how a container reaches it"
  else
    error "DATABASE_URL is wrong for a containerised step: $(grep -m1 DATABASE_URL "$tmp/argv")"
  fi
  # With --python-image the steps reach the database by name; publishing anyway
  # fails the run with "port is already allocated" for a port nothing wanted.
  if grep -qx -- '-p' "$tmp/argv"; then
    error "the port is published even though the steps run in a container"
  else
    note "no port is published when the steps run in a container"
  fi
  grep -qx -- '--network' "$tmp/argv" || error "no shared network was created"
fi

# The database container must be removed with -v: the postgres and mysql images
# declare a VOLUME, so `docker rm -f` alone leaves a data directory behind on
# every run.
if grep -A3 -x -- 'rm' "$tmp/argv" | grep -qx -- '-v'; then
  note "the database container is removed with its anonymous volume"
else
  error "docker rm ran without -v; the container's volume would be orphaned"
fi

# --- a MySQL root password the caller chose -------------------------------
: > "$tmp/argv"
run --workdir "$app" --db-image mysql:8.0 --db-wait-seconds 2 --db-root-password 's3cr3t' \
    --install-command '' --migrate-command '' --test-command 'true'
if grep -qx -- 'MYSQL_ROOT_PASSWORD=s3cr3t' "$tmp/argv"; then
  note "--db-root-password reaches the image"
else
  error "--db-root-password did not reach the image: $(grep -m1 MYSQL_ROOT "$tmp/argv")"
fi
: > "$tmp/argv"
run --workdir "$app" --db-image mysql:8.0 --db-wait-seconds 2 --db-root-password '' \
    --install-command '' --migrate-command '' --test-command 'true'
if grep -qx -- 'MYSQL_ALLOW_EMPTY_PASSWORD=yes' "$tmp/argv"; then
  note "an empty --db-root-password starts the image with an empty root password"
else
  error "an empty --db-root-password sends nothing the image accepts"
fi

# --- the module refuses a wait that would not wait -------------------------
out="$(run_out --workdir "$app" --db-image postgres:16 --db-wait-seconds 0 --test-command 'true')"
if grep -q -- "must be above 0" <<<"$out"; then
  note "--db-wait-seconds 0 is refused, rather than returning success unwaited"
else
  error "--db-wait-seconds 0 was accepted: ${out##*$'\n'}"
fi

# --- packages installed in one step have to exist in the next --------------
#
# Every step is its own `docker run --rm`, so a plain `pip install` puts
# packages in a container that is then discarded and the next step fails with
# ModuleNotFoundError -- after the install step reported success. Composer does
# not have this problem because it writes into the mounted vendor/. PIP_TARGET
# and PYTHONPATH point at a directory inside the mounted workdir instead.
: > "$tmp/argv"
run --workdir "$app" --python-image python:3.12-slim --install-command 'pip install x' \
    --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the pip assertions prove nothing"
else
  for want in 'PIP_TARGET=/app/.ci-python-packages' 'PYTHONPATH=/app/.ci-python-packages'; do
    if grep -qx -- "$want" "$tmp/argv"; then
      note "argv carries ${want%%=*}, so an install survives into the next step"
    else
      error "argv is missing ${want}"
    fi
  done
fi

# --- a step command that lives inside the project --------------------------
#
# The probe used to run `command -v` in the script's own directory, so a command
# naming a path inside the project -- bin/thing, .venv/bin/python,
# vendor/bin/phpunit -- was refused before it ran, while the step itself would
# have cd-ed to the workdir and run it happily. A check that fires on correct
# input is worse than no check, because it gets switched off.
#
# And an environment prefix used to skip the check altogether rather than look
# past it, so `FOO=bar definitely-not-real` was accepted.
mkdir -p "$app/bin"
printf '#!/bin/sh\nexit 0\n' > "$app/bin/thing"
chmod +x "$app/bin/thing"

probe_case() {   # <label> <expect-ok|expect-refused> <command>
  local label="$1" expect="$2" command="$3" out rc
  out="$(run_out --workdir "$app" --install-command "$command" --test-command 'true' \
        --migrate-command '' 2>&1)"; rc=$?
  if [[ "$expect" == "expect-ok" ]]; then
    if grep -q "is not on PATH" <<<"$out"; then
      error "${label}: refused a command that is valid in the project"
    else
      note "$label"
    fi
  else
    if grep -q "is not on PATH" <<<"$out"; then
      note "$label"
    else
      error "${label}: accepted a command that does not exist (exit ${rc})"
    fi
  fi
}

probe_case "a relative command inside the project is accepted"      expect-ok      'bin/thing'
probe_case "an environment prefix is looked past, not skipped"      expect-ok      'FOO=bar bin/thing'
probe_case "env FOO=1 <program> is looked past too"                 expect-ok      'env FOO=1 bin/thing'
probe_case "a command that does not exist is still refused"         expect-refused 'definitely-not-a-program'
probe_case "an environment prefix does not hide a missing program"  expect-refused 'FOO=bar definitely-not-a-program'
# A quoted program path cannot be split on whitespace without a shell. The
# space is what makes it fail: splitting `"/opt/my tools/python" manage.py`
# yields `"/opt/my`, and probing that produces a bash syntax error -- an
# unbalanced quote -- which reads as "not available" and refuses a command that
# works. A quoted path without a space survives either way, so it is not the
# case to test.
mkdir -p "$app/my tools"
printf '#!/bin/sh\nexit 0\n' > "$app/my tools/thing"
chmod +x "$app/my tools/thing"
probe_case "a quoted program path with a space is not mangled"      expect-ok      '"my tools/thing" --flag'
probe_case "a relative ./program is accepted"                       expect-ok      './bin/thing'

if [[ $failures -gt 0 ]]; then
  echo "[ci_django_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_django_test] OK"
