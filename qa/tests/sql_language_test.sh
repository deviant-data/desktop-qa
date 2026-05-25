#!/usr/bin/env bash
# Category: unit
# Language: SQL
# Use case: Validate SQL migration and seed files with portable text checks.
# Summary: Checks SQL discovery, transaction hints, destructive statement guards, and unresolved placeholders.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t SQL_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.sql' -print 2>/dev/null | head -n 40
)

if [ "${#SQL_FILES[@]}" -eq 0 ]; then
  for id in SQL01 SQL02 SQL03 SQL04; do skip "$id" "no SQL files found"; done
  exit 0
fi
ok "SQL01 discovered ${#SQL_FILES[@]} SQL file(s)"

placeholders=()
unguarded_drop=()
no_tx=()
for file in "${SQL_FILES[@]}"; do
  grep -Eiq 'TODO|REPLACE_ME|CHANGE_ME|\{\{[^}]+\}\}' "$file" 2>/dev/null && placeholders+=("${file#$PROJECT_DIR/}")
  if grep -Eiq 'drop[[:space:]]+(table|database|schema)' "$file" 2>/dev/null \
     && ! grep -Eiq 'drop[[:space:]]+(table|database|schema)[[:space:]]+if[[:space:]]+exists' "$file" 2>/dev/null; then
    unguarded_drop+=("${file#$PROJECT_DIR/}")
  fi
  if grep -Eiq '(create|alter|drop)[[:space:]]+(table|index|database|schema)' "$file" 2>/dev/null \
     && ! grep -Eiq 'begin[;[:space:]]|commit[;[:space:]]' "$file" 2>/dev/null; then
    no_tx+=("${file#$PROJECT_DIR/}")
  fi
done

if [ "${#placeholders[@]}" -eq 0 ]; then
  ok "SQL02 no obvious unresolved SQL placeholders"
else
  fail "SQL02" "placeholder-like SQL content found: ${placeholders[*]}"
fi

if [ "${#unguarded_drop[@]}" -eq 0 ]; then
  ok "SQL03 destructive DROP statements are guarded"
else
  fail "SQL03" "unguarded DROP statement(s): ${unguarded_drop[*]}"
fi

if [ "${#no_tx[@]}" -eq 0 ]; then
  ok "SQL04 schema-changing SQL includes transaction markers"
else
  skip "SQL04" "transaction markers not obvious in: ${no_tx[*]}"
fi
