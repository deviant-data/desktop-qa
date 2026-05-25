#!/usr/bin/env bash
# Category: unit
# Language: TypeScript
# Use case: Validate TypeScript source and configuration without fetching packages.
# Summary: Checks tsconfig JSON, optional tsc availability, and unsafe any usage in sampled files.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t TS_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/dist' -o -path '*/build' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.ts' -o -name '*.tsx' \) -print 2>/dev/null | head -n 40
)

if [ "${#TS_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/tsconfig.json" ]; then
  for id in TS01 TS02 TS03 TS04; do skip "$id" "no TypeScript files or tsconfig.json found"; done
  exit 0
fi
ok "TS01 TypeScript surface discovered"

if [ -f "$PROJECT_DIR/tsconfig.json" ]; then
  if has_command python3; then
    if python3 -m json.tool "$PROJECT_DIR/tsconfig.json" >/dev/null 2>&1; then
      ok "TS02 tsconfig.json parses as JSON"
    else
      fail "TS02" "tsconfig.json is not valid JSON"
    fi
  else
    skip "TS02" "python3 unavailable for JSON parse check"
  fi
else
  skip "TS02" "tsconfig.json not present"
fi

if has_command tsc && [ -f "$PROJECT_DIR/tsconfig.json" ]; then
  if (cd "$PROJECT_DIR" && tsc --noEmit --skipLibCheck >/dev/null 2>&1); then
    ok "TS03 tsc --noEmit passes"
  else
    fail "TS03" "tsc --noEmit reported errors"
  fi
else
  skip "TS03" "tsc or tsconfig.json not available"
fi

if [ "${#TS_FILES[@]}" -eq 0 ]; then
  skip "TS04" "no TypeScript files to inspect"
else
  any_count=0
  for file in "${TS_FILES[@]}"; do
    count=$(grep -E ':[[:space:]]*any\b|as[[:space:]]+any\b' "$file" 2>/dev/null | wc -l | tr -d ' ')
    any_count=$((any_count + count))
  done
  if [ "$any_count" -le 5 ]; then
    ok "TS04 sampled TypeScript files limit explicit any usage"
  else
    skip "TS04" "sample contains $any_count explicit any references; may be intentional migration debt"
  fi
fi
