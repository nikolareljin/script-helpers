#!/usr/bin/env bash
# SCRIPT: lint_docs_test.sh
# DESCRIPTION: End-to-end tests for scripts/lint_docs.sh against fixture trees.
# USAGE: bash tests/lint_docs_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/lint_docs_test.sh
# ----------------------------------------------------
#
# This runs THE REAL scripts/lint_docs.sh. That is the whole design.
#
# An earlier version copied the linter's regex into this file and tested the
# copy. It was worthless and provably so: with `scripts/lint_docs.sh` deleted
# outright it still reported "all passed", and with the linter's condition
# replaced by one that matches every line -- the exact catastrophe its header
# warns about -- it still reported "all passed". It tested that one string
# literal equalled another string literal.
#
# lint_docs.sh resolves its root from BASH_SOURCE and cd's there, so copying it
# into a fixture tree points it at that tree. Every case below builds a small
# repository, runs the real script, and asserts the exit status. If the linter
# stops working, these fail.
#
# The negative cases matter more than the positive ones. A linter that accepts
# everything is indistinguishable from one that works, right up until something
# ships undocumented.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[lint_docs_test] $*"; }
error() { echo "[lint_docs_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[lint_docs_test]   ok  $*"; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

[[ -f scripts/lint_docs.sh ]] || { error "scripts/lint_docs.sh is missing — there is nothing to test"; exit 1; }

# Builds a minimal repository the linter will accept, and prints its path.
# $1 is a label so each case gets its own tree.
make_fixture() {
  local name="$1" root="$tmp/$1"
  mkdir -p "$root/scripts" "$root/lib" "$root/docs/modules"
  cp "$ROOT_DIR/scripts/lint_docs.sh" "$root/scripts/lint_docs.sh"

  # One module with one documented function, plus helpers.
  cat > "$root/helpers.sh" <<'SH'
#!/usr/bin/env bash
shlib_import() { :; }
SH
  cat > "$root/lib/widget.sh" <<'SH'
#!/usr/bin/env bash
widget_make() { :; }
SH
  cat > "$root/docs/modules/helpers.md" <<'MD'
# helpers
The loader.

- shlib_import
MD
  cat > "$root/docs/modules/widget.md" <<'MD'
# widget
Makes widgets.

- widget_make
MD
  cat > "$root/docs/api.md" <<'MD'
# API Index

- [helpers](./modules/helpers.md)
- [widget](./modules/widget.md)
MD
  # The two module lists a reader meets first, and a guide naming the linter.
  cat > "$root/README.md" <<'MD'
# fixture
- `helpers.sh`: the loader.
- `widget.sh`: widgets. 1 Bash modules, 0 PowerShell mirrors.
- `scripts/lint_docs.sh` checks the docs.
MD
  cat > "$root/docs/README.md" <<'MD'
# fixture
- helpers - the loader.
- widget: widgets.
MD
  printf '%s' "$root"
}

run_lint() { ( cd "$1" && bash scripts/lint_docs.sh >/dev/null 2>&1 ); }

# --- the linter accepts a correct tree ------------------------------------------
note "a correct tree passes"
f="$(make_fixture clean)"
if run_lint "$f"; then
  ok "a well-formed index and matching docs pass"
else
  error "a correct fixture failed — the linter rejects valid input"
fi

# --- and the plain-text form still passes ---------------------------------------
note "both index forms are accepted"
f="$(make_fixture plaintext)"
cat > "$f/docs/api.md" <<'MD'
# API Index

- helpers — ./modules/helpers.md
- widget — ./modules/widget.md
MD
if run_lint "$f"; then
  ok "the original plain-text index form still passes"
else
  error "the plain-text form stopped being accepted"
fi

# --- THE NEGATIVE CASES: the linter must actually fail --------------------------
note "the linter fails on real problems"

f="$(make_fixture nodoc)"
rm "$f/docs/modules/widget.md"
if run_lint "$f"; then
  error "a module with no docs page PASSED — the gate is not gating"
else
  ok "a module with no docs page fails"
fi

f="$(make_fixture noentry)"
cat > "$f/docs/api.md" <<'MD'
# API Index

- [helpers](./modules/helpers.md)
MD
if run_lint "$f"; then
  error "a module missing from the index PASSED"
else
  ok "a module missing from the index fails"
fi

f="$(make_fixture nofunc)"
cat > "$f/docs/modules/widget.md" <<'MD'
# widget
Makes widgets, but names none of them.
MD
if run_lint "$f"; then
  error "an undocumented public function PASSED"
else
  ok "an undocumented public function fails"
fi

# The bug this pairing exists for: thirty-six near-identical bracketed lines are
# exactly the shape that gets copy-pasted wrong, and a wrong target used to
# satisfy the index while sending the reader to another page.
f="$(make_fixture mismatch)"
cat > "$f/docs/api.md" <<'MD'
# API Index

- [helpers](./modules/helpers.md)
- [widget](./modules/helpers.md)
MD
if run_lint "$f"; then
  error "an entry whose name and target DISAGREE passed — the index can point at the wrong page"
else
  ok "an entry whose name and target disagree fails"
fi

# --- junk must not count as an entry --------------------------------------------
note "text that merely mentions a module path is not an entry"

f="$(make_fixture junk)"
cat > "$f/docs/api.md" <<'MD'
# API Index

- [helpers](./modules/helpers.md)

Examples of what an entry looks like, which must NOT satisfy the index:

<!-- - [widget](./modules/widget.md) -->
Do not write - widget ./modules/widget.md in prose.
| cell | - widget ./modules/widget.md |
MD
if run_lint "$f"; then
  error "a commented-out or prose mention satisfied the index for 'widget'"
else
  ok "commented-out, prose and table mentions do not satisfy the index"
fi

# --- coverage beyond the module pages -----------------------------------------
note "functions, lists, scripts, config and counts are all checked"

# The linter read only the first 500 lines of a module, so a function defined
# further down was never checked. lib/ollama_endpoint.sh is 2795 lines.
f="$(make_fixture late)"
{ echo '#!/usr/bin/env bash'; echo 'widget_make() { :; }'
  for i in $(seq 1 600); do echo "# filler $i"; done
  echo 'widget_late() { :; }'; } > "$f/lib/widget.sh"
if run_lint "$f"; then
  error "an undocumented function past line 500 PASSED"
else
  ok "an undocumented function past line 500 fails"
fi

f="$(make_fixture nohome)"
printf '# fixture\n- helpers - the loader.\n' > "$f/docs/README.md"
if run_lint "$f"; then
  error "a module missing from the docs/README.md overview PASSED"
else
  ok "a module missing from the docs/README.md overview fails"
fi

f="$(make_fixture noreadme)"
printf '# fixture\n- `helpers.sh`\n- `scripts/lint_docs.sh`\n' > "$f/README.md"
if run_lint "$f"; then
  error "a module missing from README.md PASSED"
else
  ok "a module missing from README.md fails"
fi

f="$(make_fixture noscript)"
printf '#!/usr/bin/env bash\n' > "$f/scripts/tool.sh"
printf '# Commands\n`scripts/tool.sh`\n' > "$f/docs/commands.md"
if run_lint "$f"; then
  error "a script named only in the generated docs/commands.md PASSED"
else
  ok "a script no guide names fails (docs/commands.md does not count)"
fi
printf '# Usage\nRun `scripts/mytool.sh`.\n' > "$f/docs/usage.md"
if run_lint "$f"; then
  error "a script named only inside a longer name (mytool.sh) PASSED"
else
  ok "a longer name containing the script's does not count"
fi
printf '# Usage\nRun `scripts/tool.sh`.\n' > "$f/docs/usage.md"
if run_lint "$f"; then
  ok "a script a guide names passes"
else
  error "a script named in docs/usage.md still failed"
fi

f="$(make_fixture nops)"
mkdir -p "$f/ps/scripts" "$f/bin" "$f/config"
printf '# x\n' > "$f/ps/scripts/tool.ps1"
if run_lint "$f"; then
  error "an undocumented ps/scripts/*.ps1 PASSED"
else
  ok "an undocumented ps/scripts/*.ps1 fails"
fi

f="$(make_fixture nobin)"
mkdir -p "$f/bin"; printf '#!/bin/sh\n' > "$f/bin/tool"
if run_lint "$f"; then
  error "an undocumented bin/ command PASSED"
else
  ok "an undocumented bin/ command fails"
fi

f="$(make_fixture noconfig)"
mkdir -p "$f/config"; printf 'x\n' > "$f/config/tool.txt"
if run_lint "$f"; then
  error "an undocumented config/ file PASSED"
else
  ok "an undocumented config/ file fails"
fi

f="$(make_fixture pstable)"
mkdir -p "$f/ps/lib"; printf '# x\n' > "$f/ps/lib/widget.ps1"
sed -i.bak 's/0 PowerShell mirrors/1 PowerShell mirrors/' "$f/README.md"
if run_lint "$f"; then
  error "a ps/lib module missing from the README.md PowerShell table PASSED"
else
  ok "a ps/lib module missing from the README.md PowerShell table fails"
fi
printf '| `widget.ps1` | widget_make |\n' >> "$f/README.md"
if run_lint "$f"; then
  ok "a ps/lib module with a README.md table row passes"
else
  error "a ps/lib module with a README.md table row still failed"
fi

# Published pages describe the product as it is. History goes in CHANGELOG.md.
for phrase in "it used to print a warning" "This no longer happens" \
              "An earlier version did this" "Previously it failed" \
              "Since this change, it refuses" "There was none here before"; do
  f="$(make_fixture history)"
  printf '# Usage\n%s.\n' "$phrase" > "$f/docs/usage.md"
  if run_lint "$f"; then
    error "history phrase in a docs page PASSED: $phrase"
  else
    ok "history phrase in a docs page fails: $phrase"
  fi
  rm -rf "$f"
done
f="$(make_fixture present)"
printf '# Usage\nRun it before the push. The tool used to sign is gpg.\n' > "$f/docs/usage.md"
if run_lint "$f"; then
  ok "present-tense 'before' and 'used to sign' pass"
else
  error "present-tense text was flagged as history"
fi

f="$(make_fixture count)"
sed -i.bak 's/1 Bash modules/37 Bash modules/' "$f/README.md"
if run_lint "$f"; then
  error "a stale 'N Bash modules' count PASSED"
else
  ok "a stale 'N Bash modules' count fails"
fi

f="$(make_fixture pscount)"
mkdir -p "$f/docs/assets"
printf '<svg><text>29</text>\n<text>PowerShell mirrors</text></svg>\n' > "$f/docs/assets/hero.svg"
if run_lint "$f"; then
  error "a stale 'N PowerShell mirrors' count in hero.svg PASSED"
else
  ok "a stale 'N PowerShell mirrors' count in hero.svg fails"
fi

# --- result ---------------------------------------------------------------------
if (( failures > 0 )); then
  echo "[lint_docs_test] FAILED: $failures" >&2
  exit 1
fi
echo "[lint_docs_test] all passed"
