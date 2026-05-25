#!/usr/bin/env bash
# Category: unit
# Language: Shell
# Use case: Validate shell scripts used by portable QA and project automation.
# Summary: Runs bash syntax checks and flags common portability hazards in sampled shell files.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t SHELL_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.sh' -o -name '*.bash' \) -print 2>/dev/null | head -n 40
)

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  for id in SH01 SH02 SH03 SH04; do skip "$id" "no shell files found"; done
  exit 0
fi
ok "SH01 discovered ${#SHELL_FILES[@]} shell file(s)"

bad=()
for file in "${SHELL_FILES[@]}"; do
  bash -n "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
done
if [ "${#bad[@]}" -eq 0 ]; then
  ok "SH02 sampled shell files pass bash -n"
else
  fail "SH02" "bash -n failed: ${bad[*]}"
fi

missing_shebang=()
for file in "${SHELL_FILES[@]}"; do
  head -n 1 "$file" | grep -Eq '^#!' || missing_shebang+=("${file#$PROJECT_DIR/}")
done
if [ "${#missing_shebang[@]}" -eq 0 ]; then
  ok "SH03 shell files include shebangs"
else
  skip "SH03" "shell file(s) without shebang: ${missing_shebang[*]}"
fi

dangerous=()
for file in "${SHELL_FILES[@]}"; do
  grep -Eq 'rm[[:space:]]+-rf[[:space:]]+/( |$)|chmod[[:space:]]+777' "$file" 2>/dev/null && dangerous+=("${file#$PROJECT_DIR/}")
done
if [ "${#dangerous[@]}" -eq 0 ]; then
  ok "SH04 no obvious dangerous shell operations"
else
  fail "SH04" "dangerous shell pattern(s): ${dangerous[*]}"
fi
