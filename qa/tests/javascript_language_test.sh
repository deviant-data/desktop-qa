#!/usr/bin/env bash
# Category: unit
# Language: JavaScript
# Use case: Validate JavaScript syntax and package metadata without installing dependencies.
# Summary: Runs node parse checks when available and inspects package.json for basic script hygiene.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t JS_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/dist' -o -path '*/build' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) -print 2>/dev/null | head -n 40
)

if [ "${#JS_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/package.json" ]; then
  for id in JS01 JS02 JS03 JS04; do skip "$id" "no JavaScript files or package.json found"; done
  exit 0
fi
ok "JS01 JavaScript surface discovered"

if [ "${#JS_FILES[@]}" -eq 0 ]; then
  skip "JS02" "no standalone JavaScript files to parse"
elif has_command node; then
  bad=()
  for file in "${JS_FILES[@]}"; do
    node --check "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "JS02 sampled JavaScript files pass node --check"
  else
    fail "JS02" "node --check failed: ${bad[*]}"
  fi
else
  skip "JS02" "node is not available"
fi

if [ -f "$PROJECT_DIR/package.json" ]; then
  if has_command python3; then
    if python3 -m json.tool "$PROJECT_DIR/package.json" >/dev/null 2>&1; then
      ok "JS03 package.json parses as JSON"
    else
      fail "JS03" "package.json is not valid JSON"
    fi
  else
    skip "JS03" "python3 unavailable for JSON parse check"
  fi
  if grep -Eq '"test"[[:space:]]*:' "$PROJECT_DIR/package.json"; then
    ok "JS04 package.json declares a test script"
  else
    skip "JS04" "package.json has no test script"
  fi
else
  skip "JS03" "package.json not present"
  skip "JS04" "package.json not present"
fi
