#!/usr/bin/env bash
# SCRIPT: lint_docs_test.sh
# DESCRIPTION: Tests scripts/lint_docs.sh — that it accepts both docs/api.md index forms and still catches a genuinely undocumented module.
# USAGE: bash tests/lint_docs_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/lint_docs_test.sh
# ----------------------------------------------------
#
# The index in docs/api.md used to be plain text — `- name — ./modules/name.md`
# — which renders as dead text on a documentation site. Making it a markdown
# link broke the linter, because the original pattern required whitespace
# between the name and the path and every link form puts `](` there instead.
# There was no link syntax that satisfied it.
#
# So the pattern was widened to accept both. Both must keep working: the linter
# runs in the pre-commit hook and in CI, and a linter that silently stops
# recognising entries would report every module as undocumented — or, far
# worse, quietly match nothing and pass.
#
# The last case here is the one that matters most. A linter that accepts
# everything is indistinguishable from a linter that works, right up until
# something ships undocumented.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[lint_docs_test] $*"; }
error() { echo "[lint_docs_test][ERROR] $*" >&2; failures=$((failures+1)); }
ok()    { echo "[lint_docs_test]   ok  $*"; }

# The pattern under test, copied from scripts/lint_docs.sh. Copied rather than
# sourced because the linter runs top-to-bottom over the real repository; this
# tests the matching rule in isolation.
matches() {
  local line="$1"
  [[ "$line" =~ \-\ \[?([a-zA-Z0-9_-]+)\]?[[:space:]]*(\—[[:space:]]*)?\(?\./modules/([a-zA-Z0-9_-]+)\.md ]]
}
name_of() {
  local line="$1"
  if [[ "$line" =~ \-\ \[?([a-zA-Z0-9_-]+)\]?[[:space:]]*(\—[[:space:]]*)?\(?\./modules/([a-zA-Z0-9_-]+)\.md ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

note "both index forms are recognised"

for line in \
  "- helpers — ./modules/helpers.md" \
  "- docker_install — ./modules/docker_install.md" \
  "- git_branches — ./modules/git_branches.md"
do
  if matches "$line" && [[ -n "$(name_of "$line")" ]]; then
    ok "plain text: $(name_of "$line")"
  else
    error "the original plain-text form stopped matching: $line"
  fi
done

for line in \
  "- [helpers](./modules/helpers.md)" \
  "- [docker_install](./modules/docker_install.md)" \
  "- [git_branches](./modules/git_branches.md)"
do
  if matches "$line" && [[ -n "$(name_of "$line")" ]]; then
    ok "markdown link: $(name_of "$line")"
  else
    error "the markdown-link form does not match: $line"
  fi
done

note "the captured name is the module name, not the path"

got="$(name_of "- [ci_defaults](./modules/ci_defaults.md)")"
if [[ "$got" = "ci_defaults" ]]; then
  ok "capture group 1 is still the module name after the pattern was widened"
else
  error "expected 'ci_defaults', got '$got' — the capture groups shifted"
fi

note "lines that are not index entries are still rejected"

# A linter that matches everything passes everything. These prove it does not.
for line in \
  "This index lists all modules and their functions." \
  "- see the modules directory" \
  "- [helpers](https://example.com/helpers.md)" \
  "- [helpers](./guides/helpers.md)" \
  ""
do
  if matches "$line"; then
    error "should not have matched: '$line'"
  else
    ok "rejected: '${line:-(empty line)}'"
  fi
done

note "the real docs/api.md is fully recognised"

# Guards the specific bug that a trailing-newline loss caused: `while read`
# drops a final line with no newline, so the last module silently vanished
# from the index while the file looked correct.
if [[ "$(tail -c 1 docs/api.md | od -An -c | tr -d ' ')" != '\n' ]]; then
  error "docs/api.md does not end with a newline — its last entry will be dropped by the linter's read loop"
else
  ok "docs/api.md ends with a newline, so its last entry is read"
fi

indexed=0
while IFS= read -r line; do
  matches "$line" && indexed=$((indexed+1))
done < docs/api.md

libs=0
for f in lib/*.sh; do
  [[ -e "$f" ]] || continue
  libs=$((libs+1))
done
# helpers.sh is documented as a module too, so the index carries one more
# entry than there are files under lib/.
expected=$((libs+1))
if (( indexed == expected )); then
  ok "docs/api.md indexes all ${expected} modules"
else
  error "docs/api.md indexes ${indexed} modules but ${expected} are expected (lib/*.sh plus helpers)"
fi

if (( failures > 0 )); then
  echo "[lint_docs_test] FAILED: $failures" >&2
  exit 1
fi
echo "[lint_docs_test] all passed"
