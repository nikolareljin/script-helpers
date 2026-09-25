#!/usr/bin/env bash
# SCRIPT: ci_python_test.sh
# DESCRIPTION: Tests the command scripts/ci_python.sh hands to docker.
# USAGE: bash tests/ci_python_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_python_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[ci_python_test] $*"; }
error() { echo "[ci_python_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# A docker stand-in that records the command string it was asked to run.
mkdir -p "$tmp/bin" "$tmp/home" "$tmp/proj"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
# Appended, not overwritten: one run makes several docker calls -- start the
# database, poll it, run the steps, remove it -- and overwriting leaves only the
# last, which is the removal. The assertions are about the step invocation.
printf -- '---docker-call---\n' >> "$tmp/argv"
printf '%s\n' "\$@" >> "$tmp/argv"
for last in "\$@"; do :; done
printf '%s' "\$last" > "$tmp/cmd"
EOF
chmod +x "$tmp/bin/docker"
printf 'pytest\n' > "$tmp/proj/requirements.txt"

rc=0
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh \
  --workdir "$tmp/proj" --extra-install "pytest-cov" --test-cmd "pytest -q" >/dev/null 2>&1 || rc=$?
got="$(cat "$tmp/cmd" 2>/dev/null)"
# shellcheck disable=SC2016 # $PATH is literal text in the expected command
want='python -m pip install --user --upgrade pip && python -m pip install --user -r "requirements.txt" && python -m pip install --user pytest-cov && export PATH="/tmp/.local/bin:$PATH" && pytest -q'
if [[ $rc -eq 0 && "$got" == "$want" ]]; then
  note "docker mode joins every step with ' && '"
else
  error "docker command: rc=$rc"
  error "  want: $want"
  error "  got:  $got"
fi

rc=0
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh \
  --workdir "$tmp/proj" --no-install --test-cmd "pytest -q" >/dev/null 2>&1 || rc=$?
got="$(cat "$tmp/cmd" 2>/dev/null)"
# shellcheck disable=SC2016 # $PATH is literal text in the expected command
want='export PATH="/tmp/.local/bin:$PATH" && pytest -q'
if [[ $rc -eq 0 && "$got" == "$want" ]]; then
  note "a single step is passed unchanged"
else
  error "single step: rc=$rc got: $got"
fi


# --- an optional database ---------------------------------------------------
#
# No database is started unless --db-image asks for one. Of the six Flask
# applications this was measured against, one used a database and five did not,
# so a runner that started postgres by default would be wrong five times in six.
: > "$tmp/argv"
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh --workdir "$tmp/proj" --no-install --test-cmd 'true' >/dev/null 2>&1
if grep -qE '^(DATABASE_URL|DB_NAME)=' "$tmp/argv" 2>/dev/null; then
  error "a connection was exported when no --db-image was asked for"
else
  note "no database, and no connection exported, unless one is asked for"
fi

: > "$tmp/argv"
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh --workdir "$tmp/proj" --no-install --db-image postgres:16 --db-wait-seconds 2 \
  --db-name probe_db --db-user probe_user --db-password probe_pw \
  --test-cmd 'true' >/dev/null 2>&1
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the database assertions prove nothing"
else
  for want in 'DB_ENGINE=pgsql' 'DB_NAME=probe_db' 'DB_USER=probe_user'; do
    grep -qx -- "$want" "$tmp/argv" || error "argv is missing ${want}"
  done
  note "a postgres image is recognised and its variables are passed"
  if grep -q 'DATABASE_URL=postgresql://probe_user:probe_pw@ci-python-db-' "$tmp/argv"; then
    note "DATABASE_URL names the container, which is how a container reaches it"
  else
    error "DATABASE_URL is wrong: $(grep -m1 DATABASE_URL "$tmp/argv")"
  fi
  # The STEP invocation must carry the network, not merely some invocation:
  # ci_stack_start_database passes --network too when it creates the database,
  # so grepping the whole file finds it even when the steps have none. Dropping
  # the network from DOCKER_CMD passed this assertion until it named the call.
  #
  # Each call is delimited; the step's is the one carrying --pull=always.
  step_call="$(awk -v RS='---docker-call---' '/--pull=always/{print}' "$tmp/argv")"
  if [[ -z "$step_call" ]]; then
    error "no step invocation was recorded, so this assertion proves nothing"
  elif grep -qx -- '--network' <<<"$step_call"; then
    note "the step invocation joins the database network"
  else
    error "the steps do not join the database network"
  fi
  if grep -qx -- '-p' "$tmp/argv"; then
    error "a port is published even though the steps run in a container"
  else
    note "no port is published when the steps run in a container"
  fi
fi

out="$(CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh --workdir "$tmp/proj" --no-install --db-image redis:7 --test-cmd 'true' 2>&1)"
if grep -q "Cannot tell which engine" <<<"$out"; then
  note "an image of unknown engine is refused, not guessed"
else
  error "an unknown image was accepted"
fi

out="$(CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh --workdir "$tmp/proj" --no-install --env NOTAPAIR --test-cmd 'true' 2>&1)"
if grep -q "expects NAME=VALUE" <<<"$out"; then
  note "--env refuses a value that is not a pair"
else
  error "--env accepted a value that is not a pair"
fi

: > "$tmp/argv"
CI="" HOME="$tmp/home" PATH="$tmp/bin:$PATH" bash scripts/ci_python.sh --workdir "$tmp/proj" --no-install --env 'FLASK_APP=web:app' --test-cmd 'true' >/dev/null 2>&1
if grep -qx -- 'FLASK_APP=web:app' "$tmp/argv"; then
  note "--env reaches the steps"
else
  error "--env did not reach the steps"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
