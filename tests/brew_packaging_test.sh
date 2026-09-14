#!/usr/bin/env bash
# SCRIPT: brew_packaging_test.sh
# DESCRIPTION: Tests packaging_init.sh, render_brew_formula.sh, gen_brew_formula.sh and build_brew_tarball.sh.
# USAGE: bash tests/brew_packaging_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/brew_packaging_test.sh
# ----------------------------------------------------
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[brew_packaging_test] $*"; }
error() { echo "[brew_packaging_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# --- values with awk replacement metacharacters survive rendering ----------
# gsub() reads & in a replacement as "the matched text", so every awk the
# scripts may run under is exercised: mawk (Debian/Ubuntu), gawk, busybox
# (Alpine), and whatever `awk` is on this host (BSD awk on macOS).
awks=("awk")
for candidate in mawk gawk; do
  command -v "$candidate" >/dev/null 2>&1 && awks+=("$candidate")
done
command -v busybox >/dev/null 2>&1 && busybox awk 'BEGIN{}' 2>/dev/null && awks+=("busybox")

for impl in "${awks[@]}"; do
  bin="$tmp/awk-$impl"; mkdir -p "$bin"
  if [[ "$impl" == "busybox" ]]; then
    printf '#!/usr/bin/env sh\nexec busybox awk "$@"\n' > "$bin/awk"
  else
    printf '#!/usr/bin/env sh\nexec %s "$@"\n' "$(command -v "$impl")" > "$bin/awk"
  fi
  chmod +x "$bin/awk"

  repo="$tmp/init-$impl"
  mkdir -p "$repo/packaging"
  cat > "$repo/packaging/packaging.env" <<'EOF'
APP_NAME="myapp"
APP_VERSION="1.2.3"
APP_DESCRIPTION="Search & replace tool"
APP_HOMEPAGE="https://example.com/?a=1&b=2"
APP_LICENSE="MIT"
APP_BUILD_CMD="make && make docs"
APP_INSTALL_CMD="make install"
MAINTAINER_NAME="A & B"
MAINTAINER_EMAIL="ab@example.com"
BREW_URL="https://example.com/myapp-1.2.3.tar.gz"
BREW_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
BREW_INSTALL_CMD='system "make", "install", "PREFIX=#{prefix}" if true && true'
EOF
  if PATH="$bin:$PATH" bash scripts/packaging_init.sh --repo "$repo" >/dev/null 2>&1; then
    if grep -qF 'make && make docs' "$repo/debian/rules" &&
       grep -qF 'make && make docs' "$repo/packaging/rpm/myapp.spec" &&
       grep -qF 'desc "Search & replace tool"' "$repo/packaging/brew/myapp.rb" &&
       ! grep -rqF '@APP_BUILD_CMD@' "$repo/debian" "$repo/packaging"; then
      note "packaging_init ($impl): & in values rendered literally"
    else
      error "packaging_init ($impl): values mangled: $(grep -h 'make' "$repo/debian/rules" "$repo/packaging/rpm/myapp.spec" | tr '\n' ' ')"
    fi
  else
    error "packaging_init ($impl) failed"
  fi

  out="$tmp/render-$impl.rb"
  if PATH="$bin:$PATH" bash scripts/render_brew_formula.sh --repo "$repo" --output "$out" >/dev/null 2>&1; then
    if grep -qF 'homepage "https://example.com/?a=1&b=2"' "$out" &&
       grep -qF '"PREFIX=#{prefix}" if true && true' "$out" &&
       grep -qF "sha256 \"$SHA\"" "$out"; then
      note "render_brew_formula ($impl): & in values rendered literally"
    else
      error "render_brew_formula ($impl): values mangled: $(cat "$out")"
    fi
  else
    error "render_brew_formula ($impl) failed"
  fi
done

# --- render_brew_formula refuses a missing or placeholder checksum ----------
repo="$tmp/init-awk"
for sha in "" "REPLACE_WITH_SHA256"; do
  sed -i.bak '/^BREW_SHA256=/d' "$repo/packaging/packaging.env"
  printf 'BREW_SHA256="%s"\n' "$sha" >> "$repo/packaging/packaging.env"
  rc=0
  bash scripts/render_brew_formula.sh --repo "$repo" --output "$tmp/nosha.rb" >/dev/null 2>&1 || rc=$?
  if [[ $rc -ne 0 ]]; then note "render_brew_formula refuses sha256 '${sha:-<empty>}' (exit $rc)"; else error "render_brew_formula accepted sha256 '${sha:-<empty>}'"; fi
done
rc=0
bash scripts/render_brew_formula.sh --repo "$repo" --output "$tmp/withsha.rb" --sha256 "$SHA" >/dev/null 2>&1 || rc=$?
if [[ $rc -eq 0 ]] && grep -qF "sha256 \"$SHA\"" "$tmp/withsha.rb"; then
  note "--sha256 overrides the placeholder"
else
  error "--sha256 override failed (exit $rc)"
fi

# --- gen_brew_formula: one depends_on per line, valid Ruby -----------------
if command -v shasum >/dev/null 2>&1; then
  mkdir -p "$tmp/gen/dist"
  printf 'x\n' > "$tmp/gen/dist/myapp-1.0.0.tar.gz"
  formula="$tmp/gen/myapp.rb"
  if bash scripts/gen_brew_formula.sh --name myapp --desc "d" --homepage https://example.com \
       --tarball "$tmp/gen/dist/myapp-1.0.0.tar.gz" --url https://example.com/myapp-1.0.0.tar.gz \
       --dep git --dep "python@3.12" --formula-path "$formula" >/dev/null 2>&1; then
    if grep -qx '  depends_on "git"' "$formula" && grep -qx '  depends_on "python@3.12"' "$formula" &&
       ! grep -qF '\n' "$formula"; then
      note "gen_brew_formula: each dependency on its own line"
    else
      error "gen_brew_formula: dependency lines wrong: $(cat "$formula")"
    fi
    if command -v ruby >/dev/null 2>&1; then
      if ruby -c "$formula" >/dev/null 2>&1; then note "gen_brew_formula: ruby -c accepts the formula"; else error "gen_brew_formula: ruby -c rejects the formula: $(ruby -c "$formula" 2>&1)"; fi
    else
      note "SKIP: ruby not available for the syntax check"
    fi
  else
    error "gen_brew_formula failed"
  fi
else
  note "SKIP: shasum not available for gen_brew_formula"
fi

# --- build_brew_tarball: no secrets, no git metadata, no earlier tarballs --
if command -v rsync >/dev/null 2>&1; then
  src="$tmp/tarball"
  mkdir -p "$src/.git" "$src/app" "$src/dist"
  printf '1.0.0' > "$src/VERSION"
  printf 'code\n' > "$src/app/main.sh"
  printf 'ref\n' > "$src/.git/HEAD"
  printf 'SECRET=1\n' > "$src/.env"
  printf 'SECRET=1\n' > "$src/.env.local"
  printf 'SECRET=1\n' > "$src/app/.env.production"
  printf 'SECRET=\n' > "$src/.env.example"
  printf 'SECRET=\n' > "$src/.env.local.sample"
  printf 'built\n' > "$src/dist/bundle.js"
  printf 'old\n' > "$src/dist/myapp-0.9.0.tar.gz"
  if bash scripts/build_brew_tarball.sh --name myapp --repo "$src" >/dev/null 2>&1; then
    listing="$(tar -tzf "$src/dist/myapp-1.0.0.tar.gz" | sed 's|^myapp-1.0.0/||')"
    for bad in .git/HEAD .env .env.local app/.env.production dist/myapp-0.9.0.tar.gz; do
      if printf '%s\n' "$listing" | grep -qxF "$bad"; then error "tarball contains $bad"; fi
    done
    for good in app/main.sh VERSION .env.example .env.local.sample dist/bundle.js; do
      if printf '%s\n' "$listing" | grep -qxF "$good"; then :; else error "tarball is missing $good"; fi
    done
    note "build_brew_tarball: contents checked"
  else
    error "build_brew_tarball failed"
  fi
  # A caller's --exclude still applies, including to a template it wants out.
  rm -f "$src/dist/myapp-1.0.0.tar.gz"
  if bash scripts/build_brew_tarball.sh --name myapp --repo "$src" --exclude .env.example --exclude dist >/dev/null 2>&1; then
    listing="$(tar -tzf "$src/dist/myapp-1.0.0.tar.gz" | sed 's|^myapp-1.0.0/||')"
    if printf '%s\n' "$listing" | grep -qE '^(\.env\.example|dist/.*)$'; then
      error "caller --exclude was overridden: $listing"
    else
      note "build_brew_tarball: caller excludes still win"
    fi
  else
    error "build_brew_tarball with --exclude failed"
  fi
else
  note "SKIP: rsync not available for build_brew_tarball"
fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
