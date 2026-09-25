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
  # sqlite as a file under the application, not :memory:. Each step is its own
  # process, so an in-memory database dies with the step that made it: migrate
  # reported every migration DONE and the next step answered "Migration table
  # not found".
  for want in 'DB_CONNECTION=sqlite' 'APP_ENV=testing'; do
    if grep -qx -- "$want" "$tmp/argv"; then
      note "the default run passes ${want}"
    else
      error "argv is missing ${want}"
    fi
  done
  if grep -qx -- 'DB_DATABASE=:memory:' "$tmp/argv"; then
    error "sqlite is in memory, so the schema cannot outlive the step that creates it"
  elif grep -q -- 'DB_DATABASE=/app/database/ci_laravel_' "$tmp/argv"; then
    note "sqlite is a file the steps share, at the path the container sees"
  else
    error "no usable DB_DATABASE reached the steps: $(grep -m1 DB_DATABASE "$tmp/argv")"
  fi

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
  for want in 'MYSQL_DATABASE=laravel' 'MYSQL_USER=laravel' 'MYSQL_ROOT_PASSWORD=root' 'DB_CONNECTION=mysql'; do
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
    --db-root-password 'forwarded-anyway' \
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

# --- an option written last, with no value ---------------------------------
#
# Every option read "$2" with no check that it was there. Under `set -u` that
# is a bash internal error -- "line 82: $2: unbound variable", exit 1 -- where
# this script's own EXIT_CODES promise 2 for a bad argument.
#
# The list comes from every parser line that consumes a value, NOT from the
# lines that call need_value. Keying it on the guard would have made the test
# blind to exactly the change it exists to catch: delete a guard and that
# option simply drops out of the list, and the run stays green.
# read, not mapfile: mapfile is bash 4+ and macOS ships 3.2. portability_test
# catches this, which is how this line was caught.
opts=()
while IFS= read -r opt; do opts+=("$opt"); done < <(
  sed -n 's/^    \(--[a-z-]*\)).*"\$2"; shift 2.*/\1/p' "$SCRIPT")
if (( ${#opts[@]} < 10 )); then
  error "only ${#opts[@]} value-taking options were found in the parser; the extraction is wrong"
else
  unguarded=0
  for opt in "${opts[@]}"; do
    out="$(run_out "$opt")"; rc=$?
    if [[ $rc -ne 2 ]] || ! grep -q -- "$opt requires a value" <<<"$out"; then
      error "${opt} with no value: exit ${rc}, said: $(head -1 <<<"$out")"
      unguarded=$((unguarded+1))
    fi
  done
  (( unguarded == 0 )) && note "all ${#opts[@]} value-taking options refuse a missing value with exit 2"
fi

# And the other direction: an empty value is legitimate for several of these,
# so the guard must check that the argument exists, not that it is non-empty.
# --php-image so the steps go through the stubbed docker: this machine has no
# php, and without it the run stops at the "install PHP" refusal before any
# step is reached, which would make this assertion pass or fail for an
# unrelated reason.
out="$(run_out --workdir "$app" --php-image php:8.4-cli --install-command '' --migrate-command '' --test-command 'true')"
if grep -q "skipped (no command)" <<<"$out"; then
  note "an empty --install-command still skips the step rather than being refused"
else
  error "an empty value was refused, or the step ran anyway: ${out##*$'\n'}"
fi

# --- the MySQL root password -----------------------------------------------
#
# ci-helpers' laravel.yml declares db_root_password and forwards it here. It
# was hard-coded to "root" in this script, so the input was accepted and
# discarded -- a caller setting it got a database with a different root
# password than the one it asked for, and nothing said so.
#
# The failure it causes is remote from its cause: the image will not initialise
# without a root password (or MYSQL_ALLOW_EMPTY_PASSWORD), and it exits during
# its entrypoint, so what the caller sees is the readiness poll timing out.

: > "$tmp/argv"
run --workdir "$app" --db-image mysql:8.0 --db-wait-seconds 2 --db-root-password 's3cr3t' \
    --install-command '' --migrate-command '' --test-command 'true'
if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called for the root-password run"
else
  if grep -qx -- 'MYSQL_ROOT_PASSWORD=s3cr3t' "$tmp/argv"; then
    note "--db-root-password reaches the image"
  else
    error "--db-root-password did not reach the image: $(grep -m1 MYSQL_ROOT "$tmp/argv")"
  fi
  # The assertion above would also pass if the hard-coded value were still
  # being sent alongside, and MySQL takes the last -e it is given.
  if grep -qx -- 'MYSQL_ROOT_PASSWORD=root' "$tmp/argv"; then
    error "the hard-coded root password is still passed as well"
  fi
fi

# Empty is not "no password" to the MySQL image -- it is a refusal to start.
# MYSQL_ALLOW_EMPTY_PASSWORD is how it is spelled.
: > "$tmp/argv"
run --workdir "$app" --db-image mysql:8.0 --db-wait-seconds 2 --db-root-password '' \
    --install-command '' --migrate-command '' --test-command 'true'
if grep -qx -- 'MYSQL_ALLOW_EMPTY_PASSWORD=yes' "$tmp/argv" 2>/dev/null; then
  note "an empty --db-root-password starts the image with an empty root password"
else
  error "an empty --db-root-password sends nothing the image accepts, so it would never initialise"
fi
if grep -q -- 'MYSQL_ROOT_PASSWORD=' "$tmp/argv" 2>/dev/null; then
  error "an empty --db-root-password still passed MYSQL_ROOT_PASSWORD, which the image rejects"
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

# --- a step whose command the image does not have --------------------------
#
# The official php images ship neither composer nor any database driver, so the
# defaults die at the first step with "command not found" and exit 127 -- a
# message that names the step rather than the cause. Both are checked up front
# now, and the message has to say which.

# The stub answers `command -v` with exit 0, so a run that gets past the probes
# proves nothing about them. A stub that refuses is what exercises the check.
# Selective: php is present, composer is not. A stub that refuses every probe
# would fail at the PHP check first and never reach the composer message.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
for a in "\$@"; do
  case "\$a" in *"command -v composer"*) exit 1 ;; esac
done
exit 0
EOF
chmod +x "$tmp/bin/docker"

out="$(run_out --workdir "$app" --php-image php:8.4-cli)"
if grep -q "'composer' is not on PATH" <<<"$out" && grep -q "no composer" <<<"$out"; then
  note "a missing composer is named, with the image and the fix"
else
  error "a missing composer was not reported: ${out##*$'\n'}"
fi

# php missing is the more fundamental case, and the one whose absence used to
# surface as "Application key failed (exit 127)" -- true, and no help at all.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
for a in "\$@"; do
  case "\$a" in *"command -v php"*) exit 1 ;; esac
done
exit 0
EOF
chmod +x "$tmp/bin/docker"

out="$(run_out --workdir "$app" --php-image php:8.4-cli)"
if grep -q "'php' is not on PATH" <<<"$out" && grep -q -- "--php-image" <<<"$out"; then
  note "a missing php is named before anything tries to use it"
else
  error "a missing php was not reported: ${out##*$'\n'}"
fi

# Now php is present and composer irrelevant; only the driver probe refuses.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
for a in "\$@"; do
  case "\$a" in *getAvailableDrivers*) exit 1 ;; esac
done
exit 0
EOF
chmod +x "$tmp/bin/docker"

out="$(run_out --workdir "$app" --php-image php:8.4-cli --install-command '' --db-connection mysql --db-host db.example)"
if grep -q "no pdo_mysql driver" <<<"$out"; then
  note "a missing pdo driver is named, with the image and the fix"
else
  error "a missing pdo driver was not reported: ${out##*$'\n'}"
fi

# Restore the permissive stub for anything after this.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
exit 0
EOF
chmod +x "$tmp/bin/docker"

# --- --env-file, as given rather than only under the app -------------------
#
# The path was resolved against the application directory unconditionally, so
# an absolute one was refused with "not found" naming a path nobody passed.
extapp="$tmp/extapp"
mkdir -p "$extapp"; : > "$extapp/artisan"
printf 'FROM_ELSEWHERE=1\n' > "$tmp/shared.env"
run --workdir "$extapp" --env-file "$tmp/shared.env" --php-image php:8.4-cli \
    --install-command '' --migrate-command '' --test-command 'true'
if [[ -f "$extapp/.env" ]] && grep -q 'FROM_ELSEWHERE' "$extapp/.env"; then
  note "--env-file is accepted as an absolute path"
else
  error "--env-file with an absolute path did not produce .env"
fi

relapp="$tmp/relapp"
mkdir -p "$relapp"; : > "$relapp/artisan"
printf 'FROM_INSIDE=1\n' > "$relapp/.env.ci"
run --workdir "$relapp" --env-file ".env.ci" --php-image php:8.4-cli \
    --install-command '' --migrate-command '' --test-command 'true'
if [[ -f "$relapp/.env" ]] && grep -q 'FROM_INSIDE' "$relapp/.env"; then
  note "--env-file is still accepted relative to the application"
else
  error "--env-file relative to the application stopped working"
fi

missapp="$tmp/missapp"
mkdir -p "$missapp"; : > "$missapp/artisan"
out="$(run_out --workdir "$missapp" --env-file "does-not-exist.env" --php-image php:8.4-cli)"
if grep -q -- "--env-file not found" <<<"$out"; then
  note "an --env-file that is nowhere is refused"
else
  error "a missing --env-file was accepted"
fi

# --- a failing step says so ------------------------------------------------

# The stub has to fail for this one, or the step it is meant to fail at
# succeeds and the assertion passes for the wrong reason.
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
for a in "\$@"; do
  case "\$a" in *"exit 3"*) exit 3 ;; esac
done
exit 0
EOF
chmod +x "$tmp/bin/docker"

out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" --workdir "$app" --php-image php:8.4-cli \
       --install-command 'exit 3' --migrate-command '' --test-command 'true' 2>&1)"
rc=$?
if [[ $rc -eq 3 ]] && grep -q "Dependencies failed (exit 3)" <<<"$out"; then
  note "a failing step is named, and its exit code is kept"
else
  error "a failing step gave exit ${rc} and: ${out##*$'\n'}"
fi

# The sqlite file is created inside the application; a run that leaves it there
# puts a stray database in someone's repository.
sqliteapp="$tmp/sqliteapp"
mkdir -p "$sqliteapp"; : > "$sqliteapp/artisan"
run --workdir "$sqliteapp" --php-image php:8.4-cli --install-command '' \
    --migrate-command '' --test-command 'true'
left="$(find "$sqliteapp" -name 'ci_laravel_*.sqlite' 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$left" -eq 0 ]]; then
  note "the sqlite file is removed on the way out"
else
  error "${left} sqlite file(s) left in the application"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_laravel_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_laravel_test] OK"
