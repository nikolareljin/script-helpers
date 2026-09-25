#!/usr/bin/env bash
# SCRIPT: ci_laravel_test.sh
# DESCRIPTION: Tests the refusals, the environment and the docker argv of scripts/ci_laravel.sh.
# USAGE: bash tests/ci_laravel_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_laravel_test.sh
# ----------------------------------------------------
#
# Starting a real database takes ten seconds and pulling PHP images takes
# longer, so what is asserted here is what can be wrong without either: the
# refusals, the environment Laravel's config will read, and the arguments handed
# to docker. Every argv assertion checks first that docker was called at all --
# an empty log makes every later grep pass for the wrong reason.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_laravel.sh"
failures=0
note()  { echo "[ci_laravel_test] $*"; }
error() { echo "[ci_laravel_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

app="$tmp/app"
mkdir -p "$app"
: > "$app/artisan"

# A docker that records its argv instead of running anything. The PDO driver
# probe runs through it too, so it must exit 0 or every run stops there.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
exit 0
EOF
chmod +x "$tmp/bin/docker"
: > "$tmp/argv"

run() { PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" >/dev/null 2>&1; }
run_out() { PATH="$tmp/bin:$PATH" bash "$SCRIPT" "$@" 2>&1; }

# --- refusals --------------------------------------------------------------

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

expect_refusal "a missing --workdir is refused" "--workdir does not exist" --workdir "$tmp/nope"
mkdir -p "$tmp/notlaravel"
expect_refusal "a directory with no artisan is refused" "No artisan in" --workdir "$tmp/notlaravel"
expect_refusal "sqlite with --db-image is refused" "does not use one" \
  --workdir "$app" --db-image mysql:8.0 --db-connection sqlite
expect_refusal "an image of unguessable engine is refused" "Cannot tell which engine" \
  --workdir "$app" --db-image some/unknown:1
expect_refusal "an unknown --db-connection is refused" "must be sqlite, mysql or pgsql" \
  --workdir "$app" --db-connection oracle
expect_refusal "an unknown option is refused" "Unknown argument" --workdir "$app" --nope

# Inside a container, 127.0.0.1 is that container. Writing it into the config
# and then running the tests in an image points them at themselves, and fails
# later as "connection refused" with nothing to say why.
for host in 127.0.0.1 localhost ::1; do
  expect_refusal "--php-image against ${host} is refused" "is that container" \
    --workdir "$app" --php-image php:8.4-cli --db-connection mysql --db-host "$host"
done

# --- the environment Laravel will read -------------------------------------

: > "$tmp/argv"
run --workdir "$app" --php-image php:8.4-cli --install-command '' --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the argv assertions prove nothing"
else
  # sqlite in memory: nothing to create, nothing to clean up, no state carried
  # between runs.
  for want in 'DB_CONNECTION=sqlite' 'DB_DATABASE=:memory:' 'APP_ENV=testing'; do
    if grep -qx -- "$want" "$tmp/argv"; then
      note "the default run passes ${want}"
    else
      error "argv is missing ${want}"
    fi
  done
  # A login shell sources /etc/profile and replaces PATH, losing the PHP the
  # image put there. Same lesson as ci_go.sh.
  if grep -qx -- '-lc' "$tmp/argv"; then
    error "steps run through a login shell (-lc)"
  elif grep -qx -- '-c' "$tmp/argv"; then
    note "steps run with bash -c"
  else
    error "no bash shell flag reached docker"
  fi
  # composer and artisan write into the working directory. Root-owned, those
  # files cannot be removed afterwards without Docker, in the caller's own
  # repository.
  if grep -qx -- '-u' "$tmp/argv" && grep -qx -- "$(id -u):$(id -g)" "$tmp/argv"; then
    note "steps run as the invoking user"
  else
    error "no -u reached docker; files written into the app would be root-owned"
  fi
  if grep -qx -- 'HOME=/tmp' "$tmp/argv"; then
    note "HOME is set, so composer has somewhere to cache"
  else
    error "no HOME reached docker"
  fi
  grep -q -- '/app' "$tmp/argv" || error "argv is missing the /app mount"
fi

# --- a started database ----------------------------------------------------
#
# --db-wait-seconds must be positive: at 0 the readiness loop never runs a
# single poll and the script exits before any step, which would make every
# assertion below about the steps pass for the wrong reason. The stubbed docker
# answers the probe immediately, so 2 succeeds on the first poll.

: > "$tmp/argv"
run --workdir "$app" --php-image php:8.4-cli --db-image mysql:8.0 --db-wait-seconds 2 \
    --install-command '' --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called for the mysql run"
else
  for want in 'MYSQL_DATABASE=laravel' 'MYSQL_USER=laravel' 'DB_CONNECTION=mysql'; do
    grep -qx -- "$want" "$tmp/argv" || error "the mysql run is missing ${want}"
  done
  note "a mysql run passes the server's own variables and DB_CONNECTION=mysql"
  # With --php-image the tests reach the database by container name on a shared
  # network. Publishing anyway fails the run with "port is already allocated"
  # for a port nothing was going to use.
  if grep -q -- ':3306' "$tmp/argv" && grep -q -- '-p' "$tmp/argv"; then
    error "the port is published even though the steps run in a container"
  else
    note "no port is published when the steps run in a container"
  fi
  grep -qx -- '--network' "$tmp/argv" || error "no shared network was created for the container to reach the database"
fi

: > "$tmp/argv"
run --workdir "$app" --db-image mysql:8.0 --db-wait-seconds 2 --db-port 33061 \
    --install-command '' --migrate-command '' --test-command 'true'
if grep -q -- '33061:3306' "$tmp/argv" 2>/dev/null; then
  note "the port is published when the steps run on the host"
else
  error "the port was not published for a host run, so nothing could reach the database"
fi

# postgres is a different image, different variables and a different readiness
# probe. Guessed from the image name, so a caller does not have to say twice.
: > "$tmp/argv"
run --workdir "$app" --php-image php:8.4-cli --db-image postgres:16 --db-wait-seconds 2 \
    --install-command '' --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called for the postgres run"
else
  for want in 'POSTGRES_DB=laravel' 'POSTGRES_USER=laravel' 'DB_CONNECTION=pgsql' 'DB_PORT=5432'; do
    grep -qx -- "$want" "$tmp/argv" || error "the postgres run is missing ${want}"
  done
  note "a postgres image is recognised and passes postgres variables"
  if grep -q 'MYSQL_' "$tmp/argv"; then
    error "the postgres run also passed MySQL variables"
  fi
fi

# --- .env, and the key Laravel refuses to boot without ---------------------

envapp="$tmp/envapp"
mkdir -p "$envapp"; : > "$envapp/artisan"
printf 'FROM_TESTING=1\n' > "$envapp/.env.testing"
printf 'FROM_EXAMPLE=1\n' > "$envapp/.env.example"
run --workdir "$envapp" --php-image php:8.4-cli --install-command '' --migrate-command '' --test-command 'true'
if [[ -f "$envapp/.env" ]] && grep -q 'FROM_TESTING' "$envapp/.env"; then
  note ".env is created from .env.testing in preference to .env.example"
else
  error ".env was not created from .env.testing: $(cat "$envapp/.env" 2>/dev/null)"
fi

# An existing .env is left alone -- a caller's own configuration is not
# something to overwrite because a test run happened.
keyapp="$tmp/keyapp"
mkdir -p "$keyapp"; : > "$keyapp/artisan"
printf 'APP_KEY=base64:alreadyset\nMINE=yes\n' > "$keyapp/.env"
: > "$tmp/argv"
run --workdir "$keyapp" --php-image php:8.4-cli --install-command '' --migrate-command '' --test-command 'true'
if grep -q 'MINE=yes' "$keyapp/.env"; then
  note "an existing .env is left as it is"
else
  error "an existing .env was overwritten"
fi
if grep -q 'key:generate' "$tmp/argv"; then
  error "key:generate ran even though .env already has an APP_KEY"
else
  note "key:generate is skipped when APP_KEY is already set"
fi

nokeyapp="$tmp/nokeyapp"
mkdir -p "$nokeyapp"; : > "$nokeyapp/artisan"
printf 'APP_KEY=\n' > "$nokeyapp/.env"
: > "$tmp/argv"
run --workdir "$nokeyapp" --php-image php:8.4-cli --install-command '' --migrate-command '' --test-command 'true'
if grep -q 'key:generate' "$tmp/argv"; then
  note "key:generate runs when APP_KEY is empty"
else
  error "APP_KEY was empty and key:generate did not run; Laravel would refuse to boot"
fi

# --- a failing step says so ------------------------------------------------

out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" --workdir "$app" --install-command 'exit 3' \
       --migrate-command '' --test-command 'true' 2>&1)"
rc=$?
if [[ $rc -eq 3 ]] && grep -q "Dependencies failed (exit 3)" <<<"$out"; then
  note "a failing step is named, and its exit code is kept"
else
  error "a failing step gave exit ${rc} and: ${out##*$'\n'}"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_laravel_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_laravel_test] OK"
