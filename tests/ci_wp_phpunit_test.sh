#!/usr/bin/env bash
# SCRIPT: ci_wp_phpunit_test.sh
# DESCRIPTION: Tests the guards and the docker argv of scripts/ci_wp_phpunit.sh.
# USAGE: bash tests/ci_wp_phpunit_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_wp_phpunit_test.sh
# ----------------------------------------------------
#
# The provisioning clones wordpress-develop, so what is asserted here is the
# part that can be wrong without the network: the refusals, the arguments
# handed to docker, and the pin check, driven through a stubbed git.
# `--wp-tests-dir` reaches `rm -rf`, so a caller passing "." would delete the
# plugin under test.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_wp_phpunit.sh"
failures=0
note()  { echo "[ci_wp_phpunit_test] $*"; }
error() { echo "[ci_wp_phpunit_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

# 1. Anything that is not an absolute path is refused, before any removal.
for bad in "." "/" "relative/path" ""; do
  out="$(bash "$SCRIPT" --skip-provision true --wp-tests-dir "$bad" --workdir "$tmp" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]] && grep -q "must be absolute paths" <<<"$out"; then
    note "refused --wp-tests-dir '${bad}'"
  else
    error "--wp-tests-dir '${bad}' was not refused (exit ${rc})"
  fi
done

# Every case below passes --skip-provision true, so a guard that regressed
# reports "absent" instead of removing a directory. $HOME is a directory under
# $tmp for the same reason.
mkdir -p "$tmp/proj/plugin" "$tmp/home/user" "$tmp/elsewhere"
ln -s "$tmp/proj/plugin" "$tmp/lnk"
fake_home="$tmp/home/user"

# 1b. A path that only reaches "/" or a parent through ".", ".." or repeated
#     slashes is refused too, and so is $HOME however it is spelled.
for bad in "//" "/." "/./" "/tmp/.." "/tmp/../" "/a/../../" "$fake_home" "$fake_home/" "$fake_home//" "$fake_home/." "$tmp/home//user" "$tmp/home"; do
  out="$(HOME="$fake_home" bash "$SCRIPT" --skip-provision true --wp-tests-dir "$bad" --workdir "$tmp/proj/plugin" 2>&1)"
  rc=$?
  if [[ $rc -eq 2 ]]; then
    note "refused --wp-tests-dir '${bad}'"
  else
    error "--wp-tests-dir '${bad}' was not refused (exit ${rc}): ${out}"
  fi
done

# 1c. The working directory and the plugin, under other spellings: trailing or
#     repeated slashes, a parent, a symlink, and the plugin when the working
#     directory is somewhere else.
scratch_rc() {   # <cwd> <workdir> <scratch>: exit code of the script
  (cd "$1" && HOME="$fake_home" bash "$ROOT_DIR/$SCRIPT" --skip-provision true \
    --wp-tests-dir "$3" --workdir "$2" >/dev/null 2>&1)
}
while IFS='|' read -r cwd wd scratch label; do
  scratch_rc "$cwd" "$wd" "$scratch"; rc=$?
  if [[ $rc -eq 2 ]]; then
    note "refused ${label}"
  else
    error "${label} was not refused (exit ${rc})"
  fi
done <<CASES
$tmp/proj/plugin|.|$tmp/proj/plugin//|the working directory with trailing slashes
$tmp/proj/plugin|.|$tmp/proj//plugin|the working directory with a repeated slash
$tmp/proj/plugin|.|$tmp/proj|the parent of the working directory
$tmp/proj/plugin|.|$tmp/lnk|a symlink to the working directory
$tmp/proj/plugin|.|$tmp/lnk/|a symlink to the working directory with a trailing slash
$tmp/elsewhere|$tmp/proj/plugin|$tmp/proj/plugin|the plugin from another working directory
$tmp/elsewhere|$tmp/proj/plugin|$tmp/proj|the parent of the plugin
$tmp/elsewhere|$tmp/proj/plugin|$tmp/lnk|a symlink to the plugin
CASES

# 1d. A directory next to all of those is accepted (exit 1: the library is
#     absent), with and without HOME.
scratch_rc "$tmp/elsewhere" "$tmp/proj/plugin" "$tmp/scratch/wp-tests"; rc=$?
if [[ $rc -eq 1 ]]; then note "accepted a separate scratch directory"; else error "a separate scratch directory was refused (exit ${rc})"; fi
out="$(cd "$tmp/elsewhere" && env -u HOME bash "$ROOT_DIR/$SCRIPT" --skip-provision true \
  --wp-tests-dir "$tmp/scratch/wp-tests" --workdir "$tmp/proj/plugin" 2>&1)"; rc=$?
if [[ $rc -eq 1 ]] && grep -q "is absent" <<<"$out"; then
  note "runs with HOME unset"
else
  error "with HOME unset: exit ${rc}: ${out}"
fi

# 2. The working directory itself is refused even when absolute. "." is caught
#    above; this is the same mistake spelled out in full.
out="$(bash "$SCRIPT" --skip-provision true --wp-tests-dir "$ROOT_DIR" --workdir "$tmp" 2>&1)"
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

# --db-wait-seconds is 2, not 0, in every case below. At 0 the readiness loop
# runs no polls at all: the old inline start_database fell straight through to
# "did not become ready" and exit 1, and these assertions passed anyway because
# they read the argv `docker run` had already recorded on the way to a
# guaranteed failure. lib/ci_stack.sh refuses 0 outright, which is what exposed
# it. The stubbed docker answers the probe immediately, so 2 succeeds on the
# first poll. ci_laravel_test.sh records the same lesson.
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
  --skip-provision true --db-image mysql:8.0 --db-wait-seconds 2 \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --test-command 'true' 2>&1)"
if grep -qi "unbound variable" <<<"$out"; then
  error "start_database expands an empty array unsafely: $(grep -i 'unbound' <<<"$out" | sed -n 1p)"
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

# 8. The database port is published only when the tests run on the host. With
#    --php-image they reach it by container name, and publishing anyway fails
#    the whole run with "port is already allocated" for a port nothing needed.
: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --db-image mysql:8.0 --db-wait-seconds 2 --db-port 3999 \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --php-image php:8.3-cli --test-command 'true' >/dev/null 2>&1
if grep -q -- '3999:3306' "$tmp/argv" 2>/dev/null; then
  error "the port is published even though the tests run in a container"
else
  note "no port is published when the tests run in a container"
fi

: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --db-image mysql:8.0 --db-wait-seconds 2 --db-port 3999 \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --test-command 'true' >/dev/null 2>&1
if grep -q -- '3999:3306' "$tmp/argv" 2>/dev/null; then
  note "the port is published when the tests run on the host"
else
  error "the port was not published for a host run, so the tests cannot reach the database"
fi

# 9. The test container runs as the invoking user by default. PHPUnit writes
#    .phpunit.cache into the working directory; owned by root it cannot be
#    deleted afterwards without Docker, which leaves undeletable files in the
#    caller's repository.
: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --php-image php:8.3-cli --db-host db.example \
  --test-command 'true' >/dev/null 2>&1
if grep -qx -- '-u' "$tmp/argv" && grep -qx -- "$(id -u):$(id -g)" "$tmp/argv"; then
  note "the test container runs as the invoking user"
else
  error "no -u reached docker; files written into the workdir would be root-owned"
fi

# And the escape hatch, for an image that needs root to install extensions.
: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --php-image php:8.3-cli --db-host db.example \
  --docker-user "" --test-command 'true' >/dev/null 2>&1
if grep -qx -- '-u' "$tmp/argv"; then
  error "--docker-user '' still passed -u"
else
  note "--docker-user '' runs as the image default"
fi

# 10. The database container is removed with its anonymous volume. The mysql
#     image declares VOLUME /var/lib/mysql, so `docker rm -f` alone leaves a
#     ~200 MB data directory behind on every run, referenced by nothing.
: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" \
  --skip-provision true --db-image mysql:8.0 --db-wait-seconds 2 \
  --wp-tests-dir "$tmp/lib" --wp-core-dir "$tmp/core" \
  --workdir "$tmp/proj" --test-command 'true' >/dev/null 2>&1
if ! grep -qx -- 'rm' "$tmp/argv"; then
  error "docker rm was never called, so the cleanup assertion proves nothing"
elif grep -qx -- '-v' <<< "$(grep -A2 -x -- 'rm' "$tmp/argv")"; then
  note "the database container is removed with its anonymous volume"
else
  error "docker rm ran without -v; the container's volume would be orphaned"
fi

# 11. The pin check. git is stubbed: `clone` lays out the files the script
#     reads, `rev-parse HEAD` answers with the content of $tmp/fake_sha. A full
#     X.Y.Z version resolves without the network.
pins="$ROOT_DIR/config/wordpress_develop_pins.tsv"
bad_pins="$(grep -v '^#' "$pins" | awk -F'\t' 'NF != 2 || $1 !~ /^[0-9]+\.[0-9]+\.[0-9]+$/ || $2 !~ /^[0-9a-f]{40}$/ { print }')"
dup_pins="$(grep -v '^#' "$pins" | cut -f1 | sort | uniq -d)"
if [[ -z "$bad_pins" && -z "$dup_pins" ]]; then
  note "the pins file is tag<TAB>commit per line, each tag once"
else
  error "pins file: bad lines '${bad_pins}' duplicate tags '${dup_pins}'"
fi
pinned_tag="7.1.4"
pinned_sha="$(awk -F'\t' -v t="$pinned_tag" '!/^#/ && $1 == t { print $2 }' "$pins")"
[[ -n "$pinned_sha" ]] || error "the pins file has no ${pinned_tag}, so the pin cases below prove nothing"

cat > "$tmp/bin/git" <<EOF
#!/usr/bin/env bash
printf 'git %s\n' "\$*" >> "$tmp/gitargv"
if [[ "\$1" == "clone" ]]; then
  dest="\${@: -1}"
  mkdir -p "\$dest/tests/phpunit/includes" "\$dest/src"
  : > "\$dest/tests/phpunit/includes/functions.php"
  : > "\$dest/src/index.php"
  printf '%s\n' "dirname( __FILE__ ) . '/src/'" youremptytestdbnamehere yourusernamehere yourpasswordhere localhost \\
    > "\$dest/wp-tests-config-sample.php"
  exit 0
fi
if [[ "\$*" == *"rev-parse HEAD"* ]]; then cat "$tmp/fake_sha"; exit 0; fi
exit 0
EOF
chmod +x "$tmp/bin/git"

# The stub answers rev-parse with this file's content; the script's other
# arguments are the same in every case.
printf '%s\n' "$pinned_sha" > "$tmp/fake_sha"
wp_args=(--wp-tests-dir "$tmp/wplib" --wp-core-dir "$tmp/wpcore" --workdir "$tmp/proj" --test-command 'true')

# A tag the file does not list is refused before anything is removed or cloned.
mkdir -p "$tmp/wplib/includes"; : > "$tmp/wplib/includes/functions.php"
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9.9 >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 2 ]] && grep -q "is not in" "$tmp/out" && [[ ! -s "$tmp/gitargv" ]] && [[ -f "$tmp/wplib/includes/functions.php" ]]; then
  note "an unpinned tag exits 2 with git never called and the old library kept"
else
  error "unpinned tag: rc=$rc git='$(cat "$tmp/gitargv")' lib kept=$([[ -f "$tmp/wplib/includes/functions.php" ]] && echo yes || echo no): $(tail -2 "$tmp/out")"
fi

# ... unless the caller accepts it unchecked.
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9.9 --allow-unpinned-wp true >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -q "unchecked" "$tmp/out" && grep -q -- '--depth 1 --branch 9.9.9' "$tmp/gitargv" && [[ -f "$tmp/wplib/wp-tests-config.php" ]]; then
  note "--allow-unpinned-wp true clones the tag shallowly and provisions"
else
  error "allow-unpinned: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi

# A pinned tag at its commit provisions.
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version "$pinned_tag" >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -q "(pinned)" "$tmp/out" && [[ -f "$tmp/wplib/wp-tests-config.php" ]]; then
  note "a pinned tag at the pinned commit provisions"
else
  error "pinned ok: rc=$rc: $(tail -2 "$tmp/out")"
fi

# A pinned tag at another commit exits 1 with nothing provisioned.
printf 'a%.0s' {1..40} > "$tmp/fake_sha"; echo >> "$tmp/fake_sha"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version "$pinned_tag" >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 1 ]] && grep -q "pinned ${pinned_sha}" "$tmp/out" && [[ ! -f "$tmp/wplib/wp-tests-config.php" ]]; then
  note "a pinned tag at another commit exits 1 with nothing provisioned"
else
  error "pin mismatch: rc=$rc config=$([[ -f "$tmp/wplib/wp-tests-config.php" ]] && echo written || echo absent): $(tail -2 "$tmp/out")"
fi
printf '%s\n' "$pinned_sha" > "$tmp/fake_sha"

# --wp-commit pins a tag the file does not list, and is checked for shape first.
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9.9 --wp-commit "$pinned_sha" >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 0 && -f "$tmp/wplib/wp-tests-config.php" ]] && note "--wp-commit pins an unlisted tag" \
  || error "--wp-commit: rc=$rc: $(tail -2 "$tmp/out")"
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9.9 --wp-commit "$pinned_tag" >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 2 && ! -s "$tmp/gitargv" ]] && note "a --wp-commit that is not a commit id exits 2 before any clone" \
  || error "--wp-commit shape: rc=$rc git='$(cat "$tmp/gitargv")'"

# An unreadable pins file exits 2.
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version "$pinned_tag" --wp-pins "$tmp/no-such-pins.tsv" >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 2 && ! -s "$tmp/gitargv" ]] && note "an unreadable --wp-pins exits 2" \
  || error "--wp-pins missing: rc=$rc git='$(cat "$tmp/gitargv")'"

# Another pins file.
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 7.1.4 --wp-pins <(printf '7.1.4\t%s\n' "$pinned_sha") >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 0 ]] && note "--wp-pins reads another file" || error "--wp-pins other file: rc=$rc: $(tail -2 "$tmp/out")"

# 12. "latest" and a minor come from the pins file, not upstream. curl is
#     stubbed as upstream offering a release the file does not have, so a
#     lookup there would pick 9.9.9 and then be refused as unpinned.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *version-check*) printf '{"offers":[{"current":"9.9.9"}]}\n' ;;
  *tags*)          printf '[{"name":"9.9.9"},{"name":"7.1.9"},{"name":"7.1.4"}]\n' ;;
  *)               exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
newest_pinned="$(grep -v '^#' "$pins" | cut -f1 | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
printf '%s\n' "$(awk -F'\t' -v t="$newest_pinned" '!/^#/ && $1 == t { print $2 }' "$pins")" > "$tmp/fake_sha"
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version latest >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -q "newest tag pinned" "$tmp/out" && grep -q -- "--branch ${newest_pinned} " "$tmp/gitargv"; then
  note "latest is the newest pinned tag (${newest_pinned}), not upstream's"
else
  error "latest: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi
printf '%s\n' "$pinned_sha" > "$tmp/fake_sha"
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 7.1 >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -q -- "--branch ${pinned_tag} " "$tmp/gitargv"; then
  note "a minor is its newest pinned tag (7.1 -> ${pinned_tag}), not upstream's 7.1.9"
else
  error "minor: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9 >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 2 ]] && grep -q "matches no tag in" "$tmp/out" && [[ ! -s "$tmp/gitargv" ]]; then
  note "a minor with no pinned tag exits 2 before any clone"
else
  error "unpinned minor: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 9.9 --allow-unpinned-wp true >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 0 ]] && grep -q "comes from upstream" "$tmp/out" && grep -q -- '--branch 9.9.9 ' "$tmp/gitargv"; then
  note "--allow-unpinned-wp true asks upstream for a minor with no pinned tag"
else
  error "unpinned minor allowed: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version 7.1-beta >"$tmp/out" 2>&1; rc=$?
[[ "$rc" == 2 && ! -s "$tmp/gitargv" ]] && note "a --wp-version that is not X.Y.Z, X.Y or latest exits 2" \
  || error "bad version: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"

# An upstream answer that is not X.Y.Z is not handed to git as a ref: an empty
# pins file sends "latest" upstream, and the stub answers with a pre-release.
cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '{"offers":[{"current":"7.2-RC1"}]}\n'
EOF
printf '# tag\tcommit\n' > "$tmp/empty_pins.tsv"
: > "$tmp/gitargv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" "${wp_args[@]}" --wp-version latest --wp-pins "$tmp/empty_pins.tsv" --allow-unpinned-wp true >"$tmp/out" 2>&1; rc=$?
if [[ "$rc" == 1 ]] && grep -q "is not a release tag" "$tmp/out" && [[ ! -s "$tmp/gitargv" ]]; then
  note "an upstream answer that is not X.Y.Z exits 1 before any clone"
else
  error "non-release tag: rc=$rc git='$(cat "$tmp/gitargv")': $(tail -2 "$tmp/out")"
fi
rm -f -- "$tmp/bin/curl"

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_phpunit_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_phpunit_test] OK"
