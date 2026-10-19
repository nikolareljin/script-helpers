#!/usr/bin/env bash
# SCRIPT: pipefail_sigpipe_test.sh
# DESCRIPTION: Checks that no early-exit reader (`grep -q`, `grep -m`, `head`)
#   sits on a pipe where pipefail is set, and that library helpers still find
#   a match in large input under pipefail.
#   `printf "$big" | grep -q x` exits 141 when grep quits before the writer is
#   done, so a present match reads as missing.
# USAGE: bash tests/pipefail_sigpipe_test.sh
# PARAMETERS: none
# EXIT_CODES:
#   0 all checks passed
#   1 a check failed
# EXAMPLE: bash tests/pipefail_sigpipe_test.sh
# ----------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail=0
note() { echo "[pipefail_sigpipe_test] $*"; }
error() { echo "[pipefail_sigpipe_test] FAIL: $*" >&2; fail=1; }

# --- lint: lib/*.sh always (callers may set pipefail); other files when they set it.
hits=""
while IFS= read -r f; do
  case "$f" in lib/*.sh) ;; *) grep -q 'pipefail' "$ROOT/$f" || continue ;; esac
  h="$(grep -nE '(^|[^|])\|[[:space:]]*(grep[[:space:]]+(-[A-Za-z]+[[:space:]]+)*-[A-Za-z]*[qm]|head([[:space:]]|$))' "$ROOT/$f" \
        | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  # This file names the pattern in its own lint regex and comments.
  [[ "$f" == tests/pipefail_sigpipe_test.sh ]] && continue
  [[ -n "$h" ]] && hits+="$(sed "s#^#$f:#" <<< "$h")"$'\n'
done < <(cd "$ROOT" && git ls-files '*.sh')
if [[ -n "$hits" ]]; then
  error "early-exit reader on a pipe under pipefail (use a here-string or sed -n 1p):"; printf '%s' "$hits" >&2
else
  note "ok  no '| grep -q', '| grep -m' or '| head' in lib/ or in files that set pipefail"
fi

# --- behaviour: a match at the top of 200000 lines must still be found.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
big="$tmp/big"; { echo "permission denied"; echo "web  Up 2 minutes"; seq 1 200000; } > "$big"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/docker" <<EOF
#!/usr/bin/env bash
[[ "\$1" == compose && "\${2:-}" == version ]] && exit 0
[[ "\$1" == compose && "\${2:-}" == ps && "\${3:-}" == --status ]] && exit 1
[[ "\$1" == info ]] && { cat "$big"; exit 1; }
# exec: the stub itself must die of SIGPIPE, as a real docker would.
exec cat "$big"
EOF
chmod +x "$tmp/bin/docker"

out="$(PATH="$tmp/bin:$PATH" bash -c 'set -euo pipefail
  source "$1/helpers.sh"; shlib_import logging docker
  check_docker 2>&1 || true' _ "$ROOT")"
if grep -q 'permission denied. Add your user' <<< "$out"; then
  note "ok  check_docker finds 'permission denied' at the top of large output"
else
  error "check_docker missed 'permission denied' under pipefail: $(head -c 300 <<< "$out")"
fi

if PATH="$tmp/bin:$PATH" bash -c 'set -euo pipefail
  source "$1/helpers.sh"; shlib_import logging docker
  _docker_service_running web' _ "$ROOT"; then
  note "ok  _docker_service_running finds 'Up' at the top of large output"
else
  error "_docker_service_running missed 'Up' under pipefail"
fi

exit "$fail"
