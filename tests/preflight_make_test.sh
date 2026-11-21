#!/usr/bin/env bash
# SCRIPT: preflight_make_test.sh
# DESCRIPTION: preflight detects a shell repository (a Makefile with a test target) and runs make test.
# USAGE: bash tests/preflight_make_test.sh
# PARAMETERS: No required parameters.
# EXAMPLE: bash tests/preflight_make_test.sh
# ----------------------------------------------------
# Without the make stack, preflight exited 3 ("no stack detected") in a repo
# like this one, and the pre-push hook ran nothing from it.
# ----------------------------------------------------
set -uo pipefail
# preflight installs a missing gitleaks or foxguard; tests never go to the network.
export PREFLIGHT_NO_INSTALL=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

failures=0
note()  { echo "[preflight_make_test] $*"; }
error() { echo "[preflight_make_test][ERROR] $*" >&2; failures=$((failures+1)); }

command -v make >/dev/null 2>&1 || { note "SKIP: make not available"; exit 0; }

tmp="$(mktemp -d)"
# Guarded: a subshell inherits this trap. See tests/run_bounded_test.sh.
trap 'if [[ ${BASHPID-$$} == "$$" ]]; then rm -rf "$tmp"; fi' EXIT

PF="$ROOT_DIR/scripts/preflight.sh"
# The fixture directory is a global, set before each call.
run_list() { CI="" bash "$PF" --dir "$fx" --list 2>/dev/null; }
run_quick() { CI="" bash "$PF" --dir "$fx" --quick --skip-security >"$tmp/out.log" 2>&1; }

# A Makefile whose test target runs <recipe>.
mkfile() { mkdir -p "$1"; printf '%s\n\t%s\n' "$2" "$3" > "$1/Makefile"; }

# --- detection ----------------------------------------------------------------
mkfile "$tmp/shell" "test:" "@echo ran > ran.txt"
fx="$tmp/shell"; out="$(run_list)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "make	." ]]; then note "Makefile-only repo: make stack"
else error "Makefile-only repo: rc=$rc, got [$out], want [make	.]"; fi

mkfile "$tmp/multi" "lint test test-bash32:" "@true"
fx="$tmp/multi"; out="$(run_list)"
if [[ "$out" == "make	." ]]; then note "test named among several targets: make stack"
else error "test among several targets: got [$out]"; fi

mkdir -p "$tmp/lower"; printf 'test:\n\t@true\n' > "$tmp/lower/makefile"
fx="$tmp/lower"; out="$(run_list)"
if [[ "$out" == "make	." ]]; then note "lower-case makefile: make stack"
else error "lower-case makefile: got [$out]"; fi

mkdir -p "$tmp/posixvar"; printf 'test ::= x\nother :::= y\nbuild:\n\t@true\n' > "$tmp/posixvar/Makefile"
fx="$tmp/posixvar"; out="$(run_list)"; rc=$?
if [[ "$rc" -eq 3 ]]; then note "'test ::=' and ':::=' assignments are not a test target"
else error "'test ::=' read as a test target: rc=$rc, got [$out]"; fi

mkdir -p "$tmp/dcolon"; printf 'test::\n\t@true\n' > "$tmp/dcolon/Makefile"
fx="$tmp/dcolon"; out="$(run_list)"
if [[ "$out" == "make	." ]]; then note "double-colon 'test::' rule: make stack"
else error "double-colon test rule: got [$out]"; fi

mkfile "$tmp/notest" "build:" "@true"
fx="$tmp/notest"; out="$(run_list)"; rc=$?
if [[ "$rc" -eq 3 ]]; then note "Makefile without a test target: no stack (exit 3)"
else error "Makefile without a test target: rc=$rc, got [$out]"; fi

mkdir -p "$tmp/var"; printf 'test := x\ntest-all:\n\t@true\ncheck: test-all\n' > "$tmp/var/Makefile"
fx="$tmp/var"; out="$(run_list)"; rc=$?
if [[ "$rc" -eq 3 ]]; then note "'test :=' variable and 'test-all' target are not a test target"
else error "variable or test-all read as a test target: rc=$rc, got [$out]"; fi

# A project runner at the root wins: a Go repo with a Makefile is still go only.
mkfile "$tmp/gorepo" "test:" "@true"; : > "$tmp/gorepo/go.mod"
fx="$tmp/gorepo"; out="$(run_list)"
if [[ "$out" == "go	." ]]; then note "go.mod plus Makefile: go only, as before"
else error "go.mod plus Makefile: got [$out], want [go	.]"; fi

# Any detected project wins, nested too: the Makefile may already call into
# it, and adding make would run those tests twice.
mkfile "$tmp/mixed" "test:" "@true"; mkdir -p "$tmp/mixed/tool"; : > "$tmp/mixed/tool/go.mod"
fx="$tmp/mixed"; out="$(run_list)"
if [[ "$out" == "go	tool" ]]; then note "nested go module plus root Makefile: go only, as before"
else error "nested go module plus Makefile: got [$out], want [go	tool]"; fi

# --- running ------------------------------------------------------------------
fx="$tmp/shell"; run_quick; rc=$?
if [[ "$rc" -eq 0 && -f "$tmp/shell/ran.txt" ]]; then note "preflight --quick ran make test (exit 0)"
else error "preflight --quick on a passing suite: rc=$rc, ran.txt present: $([[ -f "$tmp/shell/ran.txt" ]] && echo yes || echo no): $(cat "$tmp/out.log")"; fi

mkfile "$tmp/red" "test:" "@exit 1"
fx="$tmp/red"; run_quick; rc=$?
if [[ "$rc" -eq 1 ]]; then note "a failing make test fails preflight (exit 1)"
else error "failing make test: rc=$rc, want 1: $(cat "$tmp/out.log")"; fi

out="$(CI="" bash "$PF" --dir "$tmp/shell" --stack make --list 2>&1)"; rc=$?
if [[ "$rc" -eq 0 ]]; then note "--stack make is accepted"
else error "--stack make: rc=$rc: $out"; fi

printf 'make .\n' > "$tmp/notest/.preflight"
fx="$tmp/notest"; out="$(run_list)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == "make	." ]]; then note ".preflight may name the make stack"
else error ".preflight make: rc=$rc, got [$out]"; fi

# This repository is the case the change is for.
fx="$ROOT_DIR"; out="$(run_list)"
if [[ "$out" == "make	." ]]; then note "script-helpers itself: make stack"
else error "script-helpers itself: got [$out]"; fi

if [[ "$failures" -eq 0 ]]; then
  note "ALL PASSED"; exit 0
fi
note "$failures check(s) failed."; exit 1
