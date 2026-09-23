#!/usr/bin/env bash
# SCRIPT: ci_wp_phpunit_test.sh
# DESCRIPTION: Tests the guards and the docker argv of scripts/ci_wp_phpunit.sh.
# USAGE: bash tests/ci_wp_phpunit_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_wp_phpunit_test.sh
# ----------------------------------------------------
#
# The provisioning downloads a 57 MB tarball, so what is asserted here is the
# part that can be wrong without the network: the refusals, and the arguments
# handed to docker. `--wp-tests-dir` reaches `rm -rf`, so a caller passing "."
# would delete the plugin under test.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_wp_phpunit.sh"
failures=0
note()  { echo "[ci_wp_phpunit_test] $*"; }
error() { echo "[ci_wp_phpunit_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. Anything that is not an absolute path is refused, before any removal.
for bad in "." "/" "relative/path" ""; do
  out="$(bash "$SCRIPT" --wp-tests-dir "$bad" --workdir "$tmp" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && grep -q "must be absolute paths" <<<"$out"; then
    note "refused --wp-tests-dir '${bad}'"
  else
    error "--wp-tests-dir '${bad}' was not refused (exit ${rc})"
  fi
done

# 2. The working directory itself is refused even when absolute. "." is caught
#    above; this is the same mistake spelled out in full.
out="$(bash "$SCRIPT" --wp-tests-dir "$ROOT_DIR" --workdir "$tmp" 2>&1)"
if grep -qi "refusing to use" <<<"$out"; then
  note "refused the working directory as a scratch path"
else
  error "the working directory was accepted as a scratch path"
fi

# 3. A missing --workdir is refused rather than discovered later.
out="$(bash "$SCRIPT" --workdir "$tmp/not-here" --skip-provision true 2>&1)"
if grep -q -- "--workdir does not exist" <<<"$out"; then
  note "a missing --workdir is refused"
else
  error "a missing --workdir was not refused: $out"
fi

# 4. --skip-provision must not pretend a library is there. Reporting success
#    over an absent test library is how a green run means nothing.
out="$(bash "$SCRIPT" --skip-provision true --wp-tests-dir "$tmp/empty" --workdir "$tmp" 2>&1)"
if grep -q "is absent" <<<"$out"; then
  note "--skip-provision refuses an absent test library"
else
  error "--skip-provision accepted an absent test library: $out"
fi

# 5. The docker argv, when the tests run in a container. A login shell there
#    replaces PATH with /etc/profile's default; see ci_go.sh.
mkdir -p "$tmp/bin" "$tmp/lib/includes" "$tmp/proj"
: > "$tmp/lib/includes/functions.php"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
EOF
chmod +x "$tmp/bin/docker"
: > "$tmp/argv"

# --db-host names something other than loopback: with --php-image and no
# database of our own, loopback would be the container itself and is refused.
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --php-image php:8.3-cli --db-host db.example \
  --test-command 'true' >/dev/null 2>&1

if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the argv assertions prove nothing"
else
  if grep -qx -- '-lc' "$tmp/argv"; then
    error "the tests are run through a login shell (-lc)"
  elif grep -qx -- '-c' "$tmp/argv"; then
    note "the tests run with bash -c"
  else
    error "no bash shell flag reached docker"
  fi
  for want in '/work' 'WP_TESTS_DIR=/wp-tests' 'WP_CORE_DIR=/wp-core'; do
    if grep -qx -- "$want" "$tmp/argv" || grep -q -- "$want" "$tmp/argv"; then
      note "argv carries ${want}"
    else
      error "argv is missing ${want}"
    fi
  done
fi

# 6. --db-image without --php-image leaves the network array empty, and bash
#    3.2 (which macOS ships) refuses "${arr[@]}" on an empty array under
#    `set -u`. The earlier cases never reach start_database, so this is the
#    only one that exercises it.
: > "$tmp/argv"
out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --db-image mysql:8.0 --db-wait-seconds 0 \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --test-command 'true' 2>&1)"
if grep -qi "unbound variable" <<<"$out"; then
  error "start_database expands an empty array unsafely: $(grep -i 'unbound' <<<"$out" | head -1)"
elif grep -q -- "-d" "$tmp/argv" 2>/dev/null; then
  note "start_database runs with no network argument"
else
  error "docker run was never reached: $out"
fi

# 7. Tests in a container against a database that is not ours: loopback names
#    the container, so the combination is refused rather than written into a
#    config that fails later as "connection refused".
out="$(bash "$SCRIPT" --php-image php:8.3-cli --db-host 127.0.0.1 \
  --skip-provision true --wp-tests-dir "$tmp/lib" --workdir "$tmp/proj" 2>&1)"
if grep -qi "is that container" <<<"$out"; then
  note "a loopback database with --php-image is refused"
else
  error "a loopback database with --php-image was accepted: $out"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_phpunit_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_phpunit_test] OK"
