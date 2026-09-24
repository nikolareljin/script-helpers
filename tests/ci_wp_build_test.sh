#!/usr/bin/env bash
# SCRIPT: ci_wp_build_test.sh
# DESCRIPTION: Tests the guards, the staging excludes and the docker argv of scripts/ci_wp_build.sh.
# USAGE: bash tests/ci_wp_build_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/ci_wp_build_test.sh
# ----------------------------------------------------
#
# The build removes and rewrites its staging tree, so --out-dir reaches `rm -rf`
# and is asserted first. The rest is what ships being wrong rather than absent:
# a package carrying node_modules, a zip named after a bundled library's version,
# a tree with no plugin file at its root. None of that fails the build, so
# nothing but a test catches it.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

SCRIPT="scripts/ci_wp_build.sh"
failures=0
note()  { echo "[ci_wp_build_test] $*"; }
error() { echo "[ci_wp_build_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A plugin, as the script expects to find one: a header at the root, plus the
# development files a package must not carry.
make_plugin() {   # <dir> [version]
  local dir="$1" version="${2:-1.2.3}"
  mkdir -p "$dir/includes" "$dir/tests" "$dir/node_modules/left-pad" "$dir/.git"
  cat > "$dir/my-plugin.php" <<EOF
<?php
/**
 * Plugin Name: My Plugin
 * Version: ${version}
 */
EOF
  : > "$dir/includes/thing.php"
  : > "$dir/tests/test-thing.php"
  : > "$dir/node_modules/left-pad/index.js"
  : > "$dir/.git/HEAD"
  : > "$dir/composer.lock"
}

# ---------------------------------------------------------------------------
# 1. Refusals, before anything is removed.
# ---------------------------------------------------------------------------
out="$(bash "$SCRIPT" --workdir "$tmp/not-here" 2>&1)"
if grep -q -- "--workdir does not exist" <<<"$out"; then
  note "a missing --workdir is refused"
else
  error "a missing --workdir was not refused: $out"
fi

make_plugin "$tmp/guard"
out="$(bash "$SCRIPT" --workdir "$tmp/guard" --out-dir "$tmp/guard" 2>&1)"
if grep -q -- "--out-dir must not be" <<<"$out"; then
  note "--out-dir equal to the plugin directory is refused"
else
  error "--out-dir equal to the plugin directory was accepted: $out"
fi

# The same mistake one level up: staging into the parent would rm -rf a sibling
# and rsync the plugin into itself.
out="$(bash "$SCRIPT" --workdir "$tmp/guard" --out-dir "$tmp" 2>&1)"
if grep -q -- "--out-dir must not be" <<<"$out"; then
  note "an --out-dir containing the plugin is refused"
else
  error "an --out-dir containing the plugin was accepted: $out"
fi

out="$(bash "$SCRIPT" --workdir "$tmp/guard" --out-dir "$tmp/o" \
        --exclude-from "$tmp/no-such-file" --composer-command '' 2>&1)"
if grep -q -- "--exclude-from not found" <<<"$out"; then
  note "a missing --exclude-from is refused"
else
  error "a missing --exclude-from was accepted: $out"
fi

# ---------------------------------------------------------------------------
# 2. The version. It names the zip, so the wrong one ships under the wrong name.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/nover"
: > "$tmp/nover/plugin.php"
out="$(bash "$SCRIPT" --workdir "$tmp/nover" --out-dir "$tmp/o2" --composer-command '' 2>&1)"
if grep -q "No Version: header found" <<<"$out"; then
  note "a plugin with no Version: header is refused"
else
  error "a plugin with no Version: header was accepted: $out"
fi

# A bundled library ships its own header. Taking the first Version: in glob
# order picks that one -- "autoload.php 0.1.0" sorts before "my-plugin.php
# 3.4.1" -- and names the package after a dependency.
make_plugin "$tmp/two" "3.4.1"
cat > "$tmp/two/autoload.php" <<'EOF'
<?php
/**
 * Bundled library shim.
 * Version: 0.1.0
 */
EOF
out="$(bash "$SCRIPT" --workdir "$tmp/two" --out-dir "$tmp/o3" --composer-command '' --zip false 2>&1)"
if grep -q "Building two 3.4.1" <<<"$out"; then
  note "the version comes from the file carrying Plugin Name:"
else
  error "the version was taken from a bundled header: $(grep -i building <<<"$out")"
fi

# ---------------------------------------------------------------------------
# 3. Staging. What is in the tree is what installs.
# ---------------------------------------------------------------------------
make_plugin "$tmp/pkg"
out="$(bash "$SCRIPT" --workdir "$tmp/pkg" --out-dir "$tmp/out" --composer-command '' 2>&1)"
stage="$tmp/out/pkg"
if [[ ! -d "$stage" ]]; then
  error "nothing was staged, so the exclude assertions prove nothing: $out"
else
  for gone in ".git" "tests" "node_modules" "composer.lock"; do
    if [[ -e "$stage/$gone" ]]; then
      error "${gone} is in the package"
    else
      note "${gone} is excluded"
    fi
  done
  # And the plugin itself survived the excludes.
  for kept in "my-plugin.php" "includes/thing.php"; do
    [[ -e "$stage/$kept" ]] || error "${kept} is missing from the package"
  done
  [[ -e "$stage/my-plugin.php" && -e "$stage/includes/thing.php" ]] \
    && note "the plugin's own files are kept"
fi

# The zip is named from the header version, so the archive and what installs
# agree.
if [[ -f "$tmp/out/pkg-1.2.3.zip" ]]; then
  note "the zip is named from the header version"
else
  error "no pkg-1.2.3.zip: $(find "$tmp/out" -maxdepth 1 -name '*.zip' 2>/dev/null | tr '\n' ' ')"
fi

# An --out-dir inside the plugin is copied into the package by rsync unless it
# is excluded: --out-dir dist produced dist/<slug>/dist. The default list
# carries "build", so the default hides this and every other name shows it.
make_plugin "$tmp/inside"
( cd "$tmp/inside" && bash "$ROOT_DIR/$SCRIPT" --workdir . --slug inside \
    --out-dir dist --composer-command '' --zip false >/dev/null 2>&1 )
if [[ ! -d "$tmp/inside/dist/inside" ]]; then
  error "nothing was staged, so the nesting assertion proves nothing"
elif [[ -e "$tmp/inside/dist/inside/dist" ]]; then
  error "the out-dir was copied into the package (dist/inside/dist)"
else
  note "an out-dir inside the plugin is not copied into the package"
fi

# .distignore replaces the default list rather than adding to it: it is the
# plugin's statement of what ships, and a default that cannot be turned off is
# not a default.
make_plugin "$tmp/di"
printf 'includes\n' > "$tmp/di/.distignore"
bash "$SCRIPT" --workdir "$tmp/di" --out-dir "$tmp/odi" --composer-command '' --zip false >/dev/null 2>&1
if [[ ! -d "$tmp/odi/di" ]]; then
  error "nothing was staged, so the .distignore assertion proves nothing"
elif [[ -e "$tmp/odi/di/includes" ]]; then
  error ".distignore was not applied: includes/ is in the package"
elif [[ ! -d "$tmp/odi/di/tests" ]]; then
  error ".distignore was applied but the default list was applied as well"
else
  note ".distignore replaces the default exclude list"
fi

# A tree with no PHP file at its root does not load as a plugin. WordPress
# reads the header from a file directly inside the plugin directory; without
# one the package installs and does nothing.
mkdir -p "$tmp/nophp/includes"
: > "$tmp/nophp/includes/only.php"
out="$(bash "$SCRIPT" --workdir "$tmp/nophp" --version 1.0.0 --out-dir "$tmp/onophp" \
        --composer-command '' 2>&1)"
rc=$?
if [[ $rc -ne 0 ]] && grep -q "would not load as a plugin" <<<"$out"; then
  note "a staged tree with no root PHP file fails the build"
else
  error "a tree with no root PHP file was packaged (exit ${rc})"
fi

# ---------------------------------------------------------------------------
# 4. The docker argv, when the toolchains run in containers.
# ---------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$tmp/argv"
EOF
chmod +x "$tmp/bin/docker"

make_plugin "$tmp/dk"
: > "$tmp/argv"
PATH="$tmp/bin:$PATH" bash "$SCRIPT" --workdir "$tmp/dk" --out-dir "$tmp/odk" \
  --php-image php:8.3-cli --zip false >/dev/null 2>&1

if [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called, so the argv assertions prove nothing"
else
  # A login shell sources /etc/profile and replaces PATH, which loses the
  # composer a php image puts on it. Same lesson as ci_go.sh.
  if grep -qx -- '-lc' "$tmp/argv"; then
    error "the build runs through a login shell (-lc)"
  elif grep -qx -- '-c' "$tmp/argv"; then
    note "the build runs with bash -c"
  else
    error "no bash shell flag reached docker"
  fi

  # composer and npm both write into the working directory. Root-owned, those
  # files cannot be deleted afterwards without Docker, in the caller's own
  # repository.
  if grep -qx -- '-u' "$tmp/argv" && grep -qx -- "$(id -u):$(id -g)" "$tmp/argv"; then
    note "the build container runs as the invoking user"
  else
    error "no -u reached docker; vendor/ would be root-owned"
  fi

  # A uid the image does not know has no home directory, and composer fails
  # with "cannot create cache directory" before it installs anything.
  if grep -qx -- 'HOME=/tmp' "$tmp/argv"; then
    note "HOME is set for that uid"
  else
    error "no HOME reached docker; composer has nowhere to cache"
  fi

  grep -q -- '/work' "$tmp/argv" || error "argv is missing the /work mount"
fi

# --docker-user '' leaves the array empty, and bash 3.2 (which macOS ships)
# refuses "${arr[@]}" on an empty array under set -u.
: > "$tmp/argv"
out="$(PATH="$tmp/bin:$PATH" bash "$SCRIPT" --workdir "$tmp/dk" --out-dir "$tmp/odk2" \
        --php-image php:8.3-cli --docker-user "" --zip false 2>&1)"
if grep -qi "unbound variable" <<<"$out"; then
  error "an empty --docker-user expands an empty array unsafely: $(grep -i unbound <<<"$out" | head -1)"
elif [[ ! -s "$tmp/argv" ]]; then
  error "docker was never called with --docker-user ''"
elif grep -qx -- '-u' "$tmp/argv"; then
  error "--docker-user '' still passed -u"
else
  note "--docker-user '' runs as the image default"
fi

# ---------------------------------------------------------------------------
# 5. The asset step runs on the evidence that there is one to run.
# ---------------------------------------------------------------------------
make_plugin "$tmp/noassets"
out="$(bash "$SCRIPT" --workdir "$tmp/noassets" --out-dir "$tmp/ona" \
        --composer-command '' --zip false 2>&1)"
if grep -q "Front-end assets: skipped (no package.json)" <<<"$out"; then
  note "the asset build is skipped without a package.json"
else
  error "the asset build was not skipped for a plugin with no package.json"
fi

make_plugin "$tmp/assets"
printf '{"name":"x"}\n' > "$tmp/assets/package.json"
out="$(bash "$SCRIPT" --workdir "$tmp/assets" --out-dir "$tmp/oa" --composer-command '' \
        --asset-command 'echo BUILT_ASSETS' --zip false 2>&1)"
if grep -q "BUILT_ASSETS" <<<"$out"; then
  note "the asset build runs when package.json is present"
else
  error "the asset build did not run for a plugin with a package.json: $out"
fi

if [[ $failures -gt 0 ]]; then
  echo "[ci_wp_build_test] FAILED ($failures)" >&2
  exit 1
fi
echo "[ci_wp_build_test] OK"
