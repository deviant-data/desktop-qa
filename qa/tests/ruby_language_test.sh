#!/usr/bin/env bash
# Category: unit
# Language: Ruby
# Use case: Validate Ruby files and Gem metadata without installing gems.
# Summary: Runs ruby syntax checks when available and verifies Gemfile-style dependency files are presentable.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t RUBY_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/vendor/bundle' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.rb' -o -name 'Rakefile' -o -name 'Gemfile' \) -print 2>/dev/null | head -n 40
)

if [ "${#RUBY_FILES[@]}" -eq 0 ]; then
  for id in RB01 RB02 RB03 RB04; do skip "$id" "no Ruby files found"; done
  exit 0
fi
ok "RB01 discovered ${#RUBY_FILES[@]} Ruby-related file(s)"

if has_command ruby; then
  bad=()
  for file in "${RUBY_FILES[@]}"; do
    ruby -c "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "RB02 Ruby files pass ruby -c"
  else
    fail "RB02" "ruby -c failed: ${bad[*]}"
  fi
else
  skip "RB02" "ruby is not available"
fi

if [ -f "$PROJECT_DIR/Gemfile" ]; then
  if grep -Eq "^[[:space:]]*source ['\"]https://rubygems.org['\"]" "$PROJECT_DIR/Gemfile"; then
    ok "RB03 Gemfile declares rubygems source"
  else
    skip "RB03" "Gemfile has no standard rubygems source line"
  fi
else
  skip "RB03" "Gemfile not present"
fi

if [ -f "$PROJECT_DIR/Gemfile" ]; then
  if [ -f "$PROJECT_DIR/Gemfile.lock" ]; then
    ok "RB04 Gemfile.lock is present for reproducible installs"
  else
    skip "RB04" "Gemfile.lock not present"
  fi
else
  skip "RB04" "Gemfile not present"
fi
