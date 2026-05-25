#!/usr/bin/env bash
# Category: unit
# Language: PHP
# Use case: Validate PHP source and Composer metadata without installing packages.
# Summary: Runs php lint when available and checks composer.json/composer.lock reproducibility signals.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t PHP_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/vendor' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.php' -print 2>/dev/null | head -n 40
)

if [ "${#PHP_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/composer.json" ]; then
  for id in PHP01 PHP02 PHP03 PHP04; do skip "$id" "no PHP files or composer.json found"; done
  exit 0
fi
ok "PHP01 PHP surface discovered"

if [ "${#PHP_FILES[@]}" -eq 0 ]; then
  skip "PHP02" "no PHP files to lint"
elif has_command php; then
  bad=()
  for file in "${PHP_FILES[@]}"; do
    php -l "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "PHP02 sampled PHP files pass php -l"
  else
    fail "PHP02" "php -l failed: ${bad[*]}"
  fi
else
  skip "PHP02" "php is not available"
fi

if [ -f "$PROJECT_DIR/composer.json" ]; then
  if has_command python3 && python3 -m json.tool "$PROJECT_DIR/composer.json" >/dev/null 2>&1; then
    ok "PHP03 composer.json parses as JSON"
  elif has_command python3; then
    fail "PHP03" "composer.json is not valid JSON"
  else
    skip "PHP03" "python3 unavailable for JSON parse check"
  fi
else
  skip "PHP03" "composer.json not present"
fi

if [ -f "$PROJECT_DIR/composer.json" ]; then
  if [ -f "$PROJECT_DIR/composer.lock" ]; then
    ok "PHP04 composer.lock exists for reproducible installs"
  else
    skip "PHP04" "composer.lock not present"
  fi
else
  skip "PHP04" "composer.json not present"
fi
