#!/usr/bin/env bash
# Tests for scripts/check_workflow_actions.sh: each refusal fails on a fixture,
# the allowed forms pass, and this repository's own workflows pass.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT_DIR/scripts/check_workflow_actions.sh"
failures=0
note()  { echo "[workflow_actions_test] $*"; }
error() { echo "[workflow_actions_test][ERROR] $*" >&2; failures=$((failures+1)); }

tmp="$(mktemp -d)"
# Invoked only by the EXIT trap, so shellcheck reads it as unreachable.
# shellcheck disable=SC2317
cleanup() {
  # Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
  [[ ${BASHPID-$$} == "$$" ]] || return 0
  rm -rf -- "$tmp"
}
trap cleanup EXIT
SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

# expect <exit code> <name> <text the output must contain, or empty>; workflow on stdin.
expect() {
  local want="$1" name="$2" text="$3" out rc
  cat > "$tmp/case.yml"
  out="$(bash "$GATE" "$tmp/case.yml" 2>&1)"; rc=$?
  if [[ "$rc" != "$want" ]]; then
    error "$name: exit $rc, want $want: $out"
  elif [[ -n "$text" && "$out" != *"$text"* ]]; then
    error "$name: output lacks '$text': $out"
  else
    note "PASS: $name (exit $rc)"
  fi
}

expect 0 ok_all "" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA # v7
        with:
          persist-credentials: false
      - name: named first
        uses: "actions/checkout@$SHA"
        with:
          fetch-depth: 0
          persist-credentials: 'false'
      - name: with before uses
        with:
          persist-credentials: false
        uses: actions/checkout@$SHA
      - uses: github/codeql-action/init@$SHA
  b:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@production
    secrets:
      TOKEN: \${{ secrets.TOKEN }}
YML

expect 1 checkout_no_persist "persist-credentials: false" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA
        with:
          fetch-depth: 0
      - run: echo persist-credentials: false
YML

expect 1 checkout_persist_true "persist-credentials: false" <<YML
jobs:
  a:
    steps:
      - name: c
        uses: actions/checkout@$SHA
        with:
          persist-credentials: true
YML

# The next step's setting does not count for this one.
expect 1 checkout_next_step "persist-credentials: false" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA
      - uses: actions/checkout@$SHA
        with:
          persist-credentials: false
YML

expect 0 checkout_exception "" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA # persist-credentials-exception: pushes a tag with the job token
YML

expect 1 checkout_exception_empty "persist-credentials" <<YML
jobs:
  a:
    steps:
      - uses: actions/checkout@$SHA # persist-credentials-exception:
YML

expect 1 third_party "not allowed" <<YML
jobs:
  a:
    steps:
      - uses: someone/action@$SHA
YML

expect 1 actions_by_tag "not allowed" <<YML
jobs:
  a:
    steps:
      - uses: actions/setup-node@v4
YML

expect 1 short_sha "not allowed" <<YML
jobs:
  a:
    steps:
      - uses: actions/setup-node@3d3c42e5
YML

expect 1 uppercase_owner "not allowed" <<YML
jobs:
  a:
    steps:
      - uses: Actions/setup-node@$SHA
YML

expect 1 ci_helpers_by_sha "not allowed" <<YML
jobs:
  a:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@$SHA
YML

expect 1 ci_helpers_by_main "not allowed" <<YML
jobs:
  a:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@main
YML

expect 1 local_and_docker "not allowed" <<YML
jobs:
  a:
    steps:
      - uses: ./.github/actions/x
      - uses: docker://alpine:3
YML

expect 1 secrets_inherit "secrets: inherit" <<YML
jobs:
  a:
    uses: nikolareljin/ci-helpers/.github/workflows/pages.yml@production
    secrets: inherit
YML

expect 0 commented_out "" <<YML
jobs:
  a:
    steps:
      # - uses: someone/action@v1
      # secrets: inherit
      - run: true
YML

# A missing path, an empty directory and an unknown option exit 2.
mkdir -p "$tmp/empty"
for args in "$tmp/nope" "$tmp/empty" "--bogus"; do
  bash "$GATE" "$args" >/dev/null 2>&1; rc=$?
  if [[ "$rc" == 2 ]]; then note "PASS: $(basename -- "$args") exits 2"; else error "$args: exit $rc, want 2"; fi
done

# This repository's own workflows.
if out="$(bash "$GATE" "$ROOT_DIR/.github/workflows" 2>&1)"; then
  note "PASS: .github/workflows passes"
else
  error ".github/workflows: $out"
fi

if [[ "$failures" -gt 0 ]]; then
  echo "[workflow_actions_test] $failures failure(s)" >&2
  exit 1
fi
note "all passed"
