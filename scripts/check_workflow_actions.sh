#!/usr/bin/env bash
# SCRIPT: check_workflow_actions.sh
# DESCRIPTION: Fail when a GitHub Actions workflow uses an action outside the allowed list,
#              checks out with a persisted token, or passes `secrets: inherit`.
# USAGE: scripts/check_workflow_actions.sh [-h] [path ...]
# PARAMETERS:
#   path         Workflow files or directories of them (*.yml, *.yaml).
#                Default: .github/workflows under the repository root.
#   -h, --help   Show this help message.
# EXIT_CODES:
#   0  Every `uses:` is allowed, every checkout sets persist-credentials: false,
#      and no job passes `secrets: inherit` (also -h/--help).
#   1  At least one violation; each is printed as file:line: reason.
#   2  Could not check: unknown option, no such path, or no workflow file found.
# EXAMPLE:
#   scripts/check_workflow_actions.sh .github/workflows
# ----------------------------------------------------
#
# Allowed, and nothing else:
#   actions/<name>[/<path>]@<40-hex sha>
#   github/<name>[/<path>]@<40-hex sha>
#   nikolareljin/ci-helpers/<path>@production
# Owner and name must be lowercase, as GitHub prints them.
#
# actions/checkout must set `persist-credentials: false` in its step. A step
# that really needs the stored token carries, on its `uses:` line, the comment
# `# persist-credentials-exception: <reason>`; an empty reason does not count.
set -euo pipefail

usage() { sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; }

paths=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do paths+=("$1"); shift; done ;;
    -*) echo "check_workflow_actions: unknown option: $1" >&2; exit 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done

if [[ ${#paths[@]} -eq 0 ]]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  paths=("$root/.github/workflows")
fi

files=()
for p in "${paths[@]}"; do
  if [[ -d "$p" ]]; then
    for f in "$p"/*.yml "$p"/*.yaml; do
      if [[ -f "$f" ]]; then files+=("$f"); fi
    done
  elif [[ -f "$p" ]]; then
    files+=("$p")
  else
    echo "check_workflow_actions: no such file or directory: $p" >&2
    exit 2
  fi
done

if [[ ${#files[@]} -eq 0 ]]; then
  echo "check_workflow_actions: no workflow file found in: ${paths[*]}" >&2
  exit 2
fi

rc=0
for f in "${files[@]}"; do
  # Plain POSIX awk: no interval expressions or \x escapes, so mawk and the
  # macOS awk read it the same way as gawk.
  awk -v file="$f" -v q="'" '
    function indent(s) { match(s, /^[ ]*/); return RLENGTH }
    function unquote(s) { gsub(/"/, "", s); gsub(q, "", s); return s }
    function report(n, msg) { printf "%s:%d: %s\n", file, n, msg; bad = 1 }
    { line[NR] = $0 }
    END {
      bad = 0
      for (i = 1; i <= NR; i++) {
        s = line[i]
        if (s ~ /^[ ]*#/) continue
        if (unquote(s) ~ /^[ ]*(-[ ]+)?secrets:[ ]*inherit[ ]*(#.*)?$/)
          report(i, "secrets: inherit passes every secret; name the ones the called workflow needs")
        # A flow mapping ({uses: x}) would slip past the line checks below.
        if (s ~ /^[ ]*(-[ ]+)?\{.*uses[ ]*:/) {
          report(i, "flow-style uses: is not checked; write the step in block style")
          continue
        }
        if (s !~ /^[ ]*(-[ ]+)?uses:/) continue

        v = s
        sub(/^[ ]*(-[ ]+)?uses:[ ]*/, "", v)
        comment = ""
        if (match(v, /[ ]+#.*$/)) { comment = substr(v, RSTART); v = substr(v, 1, RSTART - 1) }
        sub(/[ ]+$/, "", v)
        v = unquote(v)
        ref = v; sub(/^[^@]*@/, "", ref)

        if (v ~ /^(actions|github)\/[a-z0-9._-]+(\/[a-z0-9._\/-]+)?@[0-9a-f]+$/ && length(ref) == 40) {
          # allowed
        } else if (v ~ /^nikolareljin\/ci-helpers\/[a-z0-9._\/-]+@production$/) {
          # allowed
        } else {
          report(i, "uses: " v " is not allowed (actions/* or github/* at a 40-hex SHA, or nikolareljin/ci-helpers/...@production)")
          continue
        }

        if (v !~ /^actions\/checkout@/) continue
        if (comment ~ /#[ ]*persist-credentials-exception:[ ]*[^ ]/) continue

        # The step runs from its "- " line to the next line indented at or left of the dash.
        k = indent(s)
        if (s ~ /^[ ]*-[ ]/) { d = k; start = i }
        else {
          d = -1; start = i
          for (j = i - 1; j >= 1; j--) {
            t = line[j]
            if (t ~ /^[ ]*$/ || t ~ /^[ ]*#/) continue
            if (indent(t) < k) {
              if (t ~ /^[ ]*-[ ]/) { d = indent(t); start = j }
              break
            }
          }
          if (d < 0) d = k - 2
        }
        found = 0
        for (j = start; j <= NR; j++) {
          t = line[j]
          if (j > start && t !~ /^[ ]*$/ && t !~ /^[ ]*#/ && indent(t) <= d) break
          if (unquote(t) ~ /^[ ]*persist-credentials:[ ]*false[ ]*(#.*)?$/) { found = 1; break }
        }
        if (!found)
          report(i, "actions/checkout without persist-credentials: false (or a # persist-credentials-exception: <reason> comment on this line)")
      }
      exit bad
    }
  ' "$f" || rc=1
done

exit "$rc"
