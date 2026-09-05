#!/usr/bin/env bash
# Static portability gate.
#
# Every finding here is something that does not fail on Linux and does not fail
# loudly on macOS -- it silently does the wrong thing. A BSD grep given \s does
# not complain, it just never matches; an associative array on bash 3.2 becomes
# an indexed one and returns plausible nonsense. That is why this is a blocking
# test rather than a lint: shellcheck runs with `|| true` in CI and cannot fail
# a build, and the macOS breakage this guards against stood for 23 releases.
#
# Runs on any platform, needs no Mac, and must itself stay bash 3.2 clean.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

failures=0
note()  { echo "[portability_test] $*"; }
error() { echo "[portability_test][ERROR] $*" >&2; failures=$((failures+1)); }

# This file necessarily contains every pattern it searches for.
SELF="tests/portability_test.sh"

# Files to scan: every tracked shell script, plus the extensionless entry points.
shell_files() {
  # git when it is there, find when it is not: this test also runs inside the
  # bash 3.2 container, which has no git.
  _candidates() {
    if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
      # --others --exclude-standard so a brand-new file is scanned before it is
      # committed. With plain ls-files a new script passed here and failed only
      # once staged, which is the wrong moment to find out.
      git ls-files --cached --others --exclude-standard \
        '*.sh' 'bin/*' 'scripts/git-hooks/*' 'templates/dev-cli/dev' 2>/dev/null | sort -u
    else
      find . -type d -name .git -prune -o -type f \
        \( -name '*.sh' -o -path './bin/*' -o -path './scripts/git-hooks/*' \
           -o -path './templates/dev-cli/dev' \) -print 2>/dev/null \
        | sed 's|^\./||' | sort
    fi
  }
  _candidates \
    | while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        [[ "$f" == "$SELF" ]] && continue
        case "$f" in *.ps1|*.md) continue ;; esac
        head -n1 "$f" | grep -q 'bash' && printf '%s\n' "$f"
      done
}

FILES=""
while IFS= read -r f; do FILES="${FILES}${f}"$'\n'; done < <(shell_files)
[[ -n "$FILES" ]] || { error "found no shell files to scan"; exit 1; }
note "scanning $(printf '%s' "$FILES" | grep -c . ) shell files"

# ban <label> <extended-regex> [allowed-file ...]
#
# An allowed file is a deliberate, named exception. Adding one is a decision to
# be argued for in review, which is the point of listing them here rather than
# tuning the pattern until it stops matching.
ban() {
  local label="$1" pattern="$2"; shift 2
  local allowed=" $* "
  local hit file
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    file="${hit%%:*}"
    case "$allowed" in *" $file "*) continue ;; esac
    error "$label -> $hit"
  done < <(printf '%s' "$FILES" | grep -v '^$' | xargs grep -nE "$pattern" 2>/dev/null \
             | grep -vE ':[[:space:]]*#')
}

# --- bash 4+ syntax; stock macOS /bin/bash is 3.2 ---------------------------
ban "mapfile/readarray is bash 4+"        '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)'
ban "associative array is bash 4+"        '(declare|local|typeset)[[:space:]]+-[A-Za-z]*A'
ban "nameref is bash 4.3+"                '(declare|local|typeset)[[:space:]]+-[A-Za-z]*n[[:space:]]'
ban "case modification is bash 4+"        '\$\{[A-Za-z_][A-Za-z0-9_]*(\^\^|,,)'
ban "globstar is bash 4+"                 'shopt[[:space:]]+-s[[:space:]]+globstar'

# --- GNU-only regex; BSD grep does not error, it silently never matches -----
ban "GNU \\s/\\b in grep or sed"          '(grep|sed)([^|;]*)(\\s|\\b)'

# --- GNU-only coreutils flags ----------------------------------------------
ban "GNU sed -i/-r"                       'sed[[:space:]]+(-[a-zA-Z]*i([[:space:]]|$)|-[a-zA-Z]*r([[:space:]]|$))'
ban "readlink -f / realpath"              '(readlink[[:space:]]+-[a-zA-Z]*f|(^|[^[:alnum:]_])realpath([^[:alnum:]_]|$))'
ban "GNU date -d"                         'date[[:space:]]+(-d|--date)([[:space:]]|=)'
ban "grep -P"                             'grep[[:space:]]+-[a-zA-Z]*P'
ban "find -printf/-regextype"             'find[^|;]*(-printf|-regextype)'
ban "xargs -r/-d"                         'xargs[[:space:]]+-[rd]([[:space:]]|$)'
ban "base64 -w"                           'base64[[:space:]]+-w'
ban "md5sum/sha256sum are GNU" \
    '(^|[^[:alnum:]_])(md5sum|sha256sum)([^[:alnum:]_]|$)' \
    "lib/file.sh"   # verify_checksum's default; guarded by command_exists and
                    # tracked as a follow-up, not reachable from ./dev.

# --- shebangs ---------------------------------------------------------------
#
# Checked directly rather than through ban(), which drops comment lines -- and a
# shebang looks exactly like one. `#!/bin/bash` on macOS is bash 3.2 forever,
# whatever the user has installed.
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  first="$(head -n1 "$f")"
  case "$first" in
    '#!/usr/bin/env bash') ;;
    '#!'*) error "shebang is not '#!/usr/bin/env bash' -> $f: $first" ;;
  esac
done < <(printf '%s' "$FILES" | grep -v '^$')

# The same, for shebangs a script writes into a file it generates.
while IFS= read -r hit; do
  [[ -n "$hit" ]] || continue
  error "generated shebang hardcodes an interpreter -> $hit"
done < <(printf '%s' "$FILES" | grep -v '^$' \
           | xargs grep -nE '^[[:space:]]*#!/bin/(ba)?sh[[:space:]]*$' 2>/dev/null \
           | grep -v ':1:')

# --- stat needs both spellings ----------------------------------------------
#
# GNU `stat -c` and BSD `stat -f` take different format flags, so a file using
# one must carry the other as a fallback. Checked per file rather than per line
# because the working pattern here is a multi-line probe: try -c, fall back to
# -f (lib/dialog.sh:124, lib/ollama.sh:282).
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  grep -q 'stat -c' "$f" 2>/dev/null || continue
  grep -q 'stat -f' "$f" 2>/dev/null && continue
  error "stat -c with no BSD (stat -f) fallback anywhere in $f"
done < <(printf '%s' "$FILES" | grep -v '^$')

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED — no GNU-only or bash-4-only construct found"
  exit 0
fi
note "$failures portability problem(s) found"
exit 1
