#!/usr/bin/env bash
# SCRIPT: dev_e2e_test.sh
# DESCRIPTION: Tests the `e2e` verb in templates/dev-cli/cli.sh (Playwright).
# USAGE: bash tests/dev_e2e_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/dev_e2e_test.sh
# ----------------------------------------------------
#
# A stub npx records what it is asked and where, so these cases need neither
# Playwright nor a browser: detection, the install-then-test order, arguments,
# PLAYWRIGHT_BROWSERS, a missing install, a failing run, and project_e2e.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[dev_e2e_test] $*"; }
error() { echo "[dev_e2e_test][ERROR] $*" >&2; failures=$((failures+1)); }

if ! command -v git >/dev/null 2>&1; then
  note "SKIP: git not available"
  exit 0
fi

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

mkdir -p "$tmp/bin"
cat > "$tmp/bin/npx" <<'EOF'
#!/usr/bin/env bash
echo "$(basename "$PWD"): npx $*" >> "$NPX_LOG"
[[ "$*" == "playwright test"* && -n "${NPX_FAIL_TEST:-}" ]] && exit 1
exit 0
EOF
chmod +x "$tmp/bin/npx"
export NPX_LOG="$tmp/npx.log"

new_repo() {
  local r="$tmp/$1"
  mkdir -p "$r/scripts"
  git init -q "$r"
  cp templates/dev-cli/cli.sh templates/dev-cli/_bootstrap.sh "$r/scripts/"
  ln -s "$ROOT_DIR" "$r/scripts/script-helpers"
  echo "$r"
}
# with_playwright <dir>: a config, a package.json that depends on Playwright,
# and an installed @playwright/test.
with_playwright() {
  mkdir -p "$1/node_modules/@playwright/test"
  : > "$1/playwright.config.ts"
  printf '{"devDependencies":{"@playwright/test":"1.63.0"}}\n' > "$1/package.json"
}
dev() { (cd "$1" && shift && PATH="$tmp/bin:$PATH" bash scripts/cli.sh "$@") 2>&1; }

# 1. No config: not applicable, exit 0, npx never called.
r="$(new_repo none)"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"e2e: not applicable"* && ! -s "$NPX_LOG" ]]; then
  note "no playwright.config: not applicable"
else
  error "none: rc=$rc out='$out'"
fi

# 2. A config in web/: install, then test there, with the arguments passed on.
r="$(new_repo found)"; mkdir -p "$r/web"; with_playwright "$r/web"
# A config inside node_modules is a dependency's, not a project.
mkdir -p "$r/web/node_modules/some-dep"; : > "$r/web/node_modules/some-dep/playwright.config.js"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e tests/login.spec.ts)" || rc=$?
want="$(printf 'web: npx playwright install\nweb: npx playwright test tests/login.spec.ts')"
if [[ $rc -eq 0 && "$(cat "$NPX_LOG")" == "$want" ]]; then
  note "config in web/: install then test there, arguments passed, node_modules ignored"
else
  error "found: rc=$rc log='$(cat "$NPX_LOG")' out='$out'"
fi

# 3. PLAYWRIGHT_BROWSERS limits the install.
: > "$NPX_LOG"; rc=0; out="$(cd "$r" && PLAYWRIGHT_BROWSERS="chromium firefox" PATH="$tmp/bin:$PATH" bash scripts/cli.sh e2e 2>&1)" || rc=$?
if grep -qx "web: npx playwright install chromium firefox" "$NPX_LOG"; then
  note "PLAYWRIGHT_BROWSERS is passed to playwright install"
else
  error "browsers: log='$(cat "$NPX_LOG")'"
fi

# 4. A failing run fails the verb.
: > "$NPX_LOG"; rc=0; out="$(cd "$r" && NPX_FAIL_TEST=1 PATH="$tmp/bin:$PATH" bash scripts/cli.sh e2e 2>&1)" || rc=$?
[[ $rc -eq 1 ]] && note "failing tests: exit 1" || error "failing: rc=$rc out='$out'"

# 5. A Playwright project whose install is missing: a clear error, npx not called.
r="$(new_repo notinstalled)"; : > "$r/playwright.config.ts"
printf '{"devDependencies":{"@playwright/test":"1.63.0"}}\n' > "$r/package.json"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ $rc -eq 1 && "$out" == *"run ./dev install first"* && ! -s "$NPX_LOG" ]]; then
  note "Playwright not installed: exit 1, says to run ./dev install"
else
  error "notinstalled: rc=$rc out='$out'"
fi

# 5b. A config that is not a Playwright project's (a vendored copy): skipped, exit 0.
r="$(new_repo vendored)"; mkdir -p "$r/web" "$r/vendor/lib"; with_playwright "$r/web"
: > "$r/vendor/lib/playwright.config.js"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"skipping vendor/lib"* ]] && ! grep -q "^lib:" "$NPX_LOG" && grep -q "^web: npx playwright test" "$NPX_LOG"; then
  note "a vendored config without a Playwright dependency: skipped; the project still runs"
else
  error "vendored: rc=$rc log='$(cat "$NPX_LOG")' out='$out'"
fi

# 5c. A config in a directory git ignores is not found at all.
r="$(new_repo ignored)"; mkdir -p "$r/dist"; printf 'dist/\n' > "$r/.gitignore"; with_playwright "$r/dist"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"e2e: not applicable"* && ! -s "$NPX_LOG" ]]; then
  note "a config in an ignored directory: not found"
else
  error "ignored: rc=$rc out='$out'"
fi

# 5d. A Playwright project inside a git submodule is the dependency's, not run.
src="$tmp/libsrc"; git init -q "$src"; with_playwright "$src"
git -C "$src" add -A; git -C "$src" -c user.name=t -c user.email=t@example.com commit -q -m lib
r="$(new_repo withsub)"
git -C "$r" -c protocol.file.allow=always submodule --quiet add "$src" libmod >/dev/null 2>&1
mkdir -p "$r/libmod/node_modules/@playwright/test"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ -f "$r/libmod/playwright.config.ts" && $rc -eq 0 && "$out" == *"e2e: not applicable"* && ! -s "$NPX_LOG" ]]; then
  note "a Playwright project in a submodule: not run"
else
  error "submodule: rc=$rc present=$([[ -f "$r/libmod/playwright.config.ts" ]] && echo y || echo n) log='$(cat "$NPX_LOG")' out='$out'"
fi

# 6. project_e2e replaces the default.
r="$(new_repo custom)"; with_playwright "$r"
printf 'project_e2e() { echo "custom e2e ran"; }\n' > "$r/scripts/project.sh"
: > "$NPX_LOG"; rc=0; out="$(dev "$r" e2e)" || rc=$?
if [[ $rc -eq 0 && "$out" == *"custom e2e ran"* && ! -s "$NPX_LOG" ]]; then
  note "project_e2e replaces the default"
else
  error "custom: rc=$rc out='$out'"
fi

# 7. Help lists it.
out="$(dev "$r" help)"
[[ "$out" == *"e2e           Browser tests with Playwright"* ]] && note "help lists e2e" \
  || error "help does not list e2e"

if [[ $failures -gt 0 ]]; then
  note "$failures failure(s)"
  exit 1
fi
note "all passed"
