#!/usr/bin/env bash
# Category: unit
# Language: CSS
# Use case: Validate CSS files with portable static checks.
# Summary: Checks CSS discovery, balanced braces, unresolved placeholders, and suspicious absolute local paths.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t CSS_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/dist' -o -path '*/build' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.css' -o -name '*.scss' -o -name '*.sass' \) -print 2>/dev/null | head -n 40
)

if [ "${#CSS_FILES[@]}" -eq 0 ]; then
  for id in C01 C02 C03 C04; do skip "$id" "no CSS files found"; done
  exit 0
fi
ok "C01 discovered ${#CSS_FILES[@]} CSS-style file(s)"

bad_braces=()
placeholders=()
local_paths=()
for file in "${CSS_FILES[@]}"; do
  opens=$(grep -o '{' "$file" 2>/dev/null | wc -l | tr -d ' ')
  closes=$(grep -o '}' "$file" 2>/dev/null | wc -l | tr -d ' ')
  [ "$opens" = "$closes" ] || bad_braces+=("${file#$PROJECT_DIR/}")
  grep -Eq 'TODO_COLOR|REPLACE_ME|#[xX]{3,6}|undefined' "$file" 2>/dev/null && placeholders+=("${file#$PROJECT_DIR/}")
  grep -Eq 'url\(["'\'']?/Users/|url\(["'\'']?[A-Za-z]:\\' "$file" 2>/dev/null && local_paths+=("${file#$PROJECT_DIR/}")
done

if [ "${#bad_braces[@]}" -eq 0 ]; then
  ok "C02 CSS braces are balanced"
else
  fail "C02" "unbalanced braces: ${bad_braces[*]}"
fi

if [ "${#placeholders[@]}" -eq 0 ]; then
  ok "C03 no obvious unresolved CSS placeholders"
else
  fail "C03" "placeholder-like CSS values found: ${placeholders[*]}"
fi

if [ "${#local_paths[@]}" -eq 0 ]; then
  ok "C04 no machine-local paths in CSS url() values"
else
  fail "C04" "machine-local url() reference(s): ${local_paths[*]}"
fi
