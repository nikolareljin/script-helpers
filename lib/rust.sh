#!/usr/bin/env bash
# Rust toolchain resolution: run a gate against the toolchain CI uses, not
# whatever PATH happens to offer first.
#
# CI installs Rust with dtolnay/rust-toolchain@stable, which is rustup's
# stable. A workstation frequently also has a distribution cargo, and on many
# distributions it comes first on PATH and is years older. The failure that
# produces does not look like a toolchain problem:
#
#     error: lock file version 4 requires `-Znext-lockfile-bump`
#     error: failed to download `time-core v0.1.9`
#     feature `edition2024` is required
#
# Both read as a broken lockfile. A gate that claims "this is what CI would
# have run" while running a different compiler is worse than no gate, which is
# ADR-0027 rule 5 in the fleet that produced this library.
#
# Written for bash 3.2: no namerefs, no associative arrays, no ${var,,}.

# Usage: rust_toolchain_ci_uses
#
# Puts rustup's cargo first on PATH and exports it. Says so when that differs
# from what PATH offered, because a silent switch is its own surprise. Returns
# non-zero, with an actionable message, when rustup cannot supply one.
rust_toolchain_ci_uses() {
  local rustup_cargo on_path

  if ! command -v rustup >/dev/null 2>&1; then
    echo "[rust] rustup is not installed; CI compiles with rustup's stable." >&2
    echo "[rust] Install it from https://rustup.rs, then: rustup toolchain install stable" >&2
    return 1
  fi

  rustup_cargo="$(rustup which cargo 2>/dev/null || true)"
  if [[ -z "$rustup_cargo" || ! -x "$rustup_cargo" ]]; then
    echo "[rust] rustup has no usable cargo. Run: rustup toolchain install stable" >&2
    return 1
  fi

  on_path="$(command -v cargo 2>/dev/null || true)"
  if [[ "$on_path" != "$rustup_cargo" ]]; then
    echo "[rust] using $("$rustup_cargo" --version 2>/dev/null) from rustup"
    if [[ -n "$on_path" ]]; then
      echo "[rust] (PATH offered $("$on_path" --version 2>/dev/null || echo 'an unusable cargo'), which is not what CI compiles with)"
    fi
  fi

  PATH="$(dirname "$rustup_cargo"):$PATH"
  export PATH
}

# Usage: rust_toolchain_report
#
# Prints which cargo and rustc would be used, without changing PATH. For a
# status verb, or a gate that wants to say what it ran with afterwards.
rust_toolchain_report() {
  local cargo_path
  cargo_path="$(command -v cargo 2>/dev/null || true)"
  if [[ -z "$cargo_path" ]]; then
    echo "[rust] no cargo on PATH"
    return 1
  fi
  echo "[rust] cargo: $cargo_path ($("$cargo_path" --version 2>/dev/null || echo 'version unavailable'))"
  if command -v rustup >/dev/null 2>&1; then
    echo "[rust] rustup stable: $(rustup which cargo 2>/dev/null || echo 'none')"
  else
    echo "[rust] rustup: not installed"
  fi
}
