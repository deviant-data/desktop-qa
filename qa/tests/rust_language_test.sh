#!/usr/bin/env bash
# Category: unit
# Language: Rust
# Use case: Validate Rust project metadata and formatting without downloading crates.
# Summary: Checks Cargo metadata and uses rustfmt when available for sampled source files.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t RUST_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/target' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.rs' -print 2>/dev/null | head -n 40
)

if [ "${#RUST_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/Cargo.toml" ]; then
  for id in RS01 RS02 RS03 RS04; do skip "$id" "no Rust files or Cargo.toml found"; done
  exit 0
fi
ok "RS01 Rust surface discovered"

if [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  if grep -q '^\[package\]' "$PROJECT_DIR/Cargo.toml" || grep -q '^\[workspace\]' "$PROJECT_DIR/Cargo.toml"; then
    ok "RS02 Cargo.toml declares package or workspace metadata"
  else
    fail "RS02" "Cargo.toml lacks [package] or [workspace]"
  fi
else
  skip "RS02" "Cargo.toml not present"
fi

if [ "${#RUST_FILES[@]}" -eq 0 ]; then
  skip "RS03" "no Rust files to format-check"
elif has_command rustfmt; then
  bad=()
  for file in "${RUST_FILES[@]}"; do
    rustfmt --check "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "RS03 sampled Rust files pass rustfmt --check"
  else
    fail "RS03" "rustfmt --check failed: ${bad[*]}"
  fi
else
  skip "RS03" "rustfmt is not available"
fi

if [ -f "$PROJECT_DIR/Cargo.toml" ] && grep -q '^\[dependencies\]' "$PROJECT_DIR/Cargo.toml"; then
  if [ -f "$PROJECT_DIR/Cargo.lock" ]; then
    ok "RS04 Cargo.lock exists for dependency reproducibility"
  else
    skip "RS04" "Cargo.lock missing; acceptable for libraries but risky for apps"
  fi
else
  skip "RS04" "no Rust dependencies detected"
fi
