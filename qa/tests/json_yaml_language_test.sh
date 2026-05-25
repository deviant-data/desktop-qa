#!/usr/bin/env bash
# Category: unit
# Language: JSON/YAML
# Use case: Validate common configuration file formats without adding parsers.
# Summary: Parses JSON with python3 when available and checks YAML files for tab indentation.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t JSON_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.json' -print 2>/dev/null | head -n 40
)
mapfile -t YAML_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null | head -n 40
)

if [ "${#JSON_FILES[@]}" -eq 0 ] && [ "${#YAML_FILES[@]}" -eq 0 ]; then
  for id in CFG01 CFG02 CFG03 CFG04; do skip "$id" "no JSON or YAML files found"; done
  exit 0
fi
ok "CFG01 JSON/YAML configuration files discovered"

if [ "${#JSON_FILES[@]}" -eq 0 ]; then
  skip "CFG02" "no JSON files to parse"
elif has_command python3; then
  bad=()
  for file in "${JSON_FILES[@]}"; do
    python3 -m json.tool "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "CFG02 sampled JSON files parse successfully"
  else
    fail "CFG02" "invalid JSON file(s): ${bad[*]}"
  fi
else
  skip "CFG02" "python3 unavailable for JSON parse check"
fi

if [ "${#YAML_FILES[@]}" -eq 0 ]; then
  skip "CFG03" "no YAML files to inspect"
else
  tabbed=()
  for file in "${YAML_FILES[@]}"; do
    grep -q "$(printf '\t')" "$file" 2>/dev/null && tabbed+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#tabbed[@]}" -eq 0 ]; then
    ok "CFG03 YAML files do not use tab indentation"
  else
    fail "CFG03" "YAML file(s) contain tab characters: ${tabbed[*]}"
  fi
fi

secrets=()
for file in "${JSON_FILES[@]}" "${YAML_FILES[@]}"; do
  [ -f "$file" ] || continue
  grep -Eiq '(api[_-]?key|secret|token|password)[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9_./+=-]{16,}' "$file" 2>/dev/null && secrets+=("${file#$PROJECT_DIR/}")
done
if [ "${#secrets[@]}" -eq 0 ]; then
  ok "CFG04 no obvious hardcoded secrets in sampled config files"
else
  fail "CFG04" "possible hardcoded secret(s): ${secrets[*]}"
fi
