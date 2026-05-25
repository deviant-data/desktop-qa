#!/usr/bin/env bash
# Category: unit
# Language: HTML
# Use case: Validate static HTML document structure without external tools.
# Summary: Checks discovered HTML files for basic document markers, titles, and broken local asset references.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t HTML_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/dist' -o -path '*/build' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.html' -o -name '*.htm' \) -print 2>/dev/null | head -n 30
)

if [ "${#HTML_FILES[@]}" -eq 0 ]; then
  for id in H01 H02 H03 H04; do skip "$id" "no HTML files found"; done
  exit 0
fi
ok "H01 discovered ${#HTML_FILES[@]} HTML file(s)"

missing_structure=()
missing_title=()
broken_assets=()
for file in "${HTML_FILES[@]}"; do
  if ! grep -Eiq '<!doctype[[:space:]]+html|<html([[:space:]>])' "$file"; then
    missing_structure+=("${file#$PROJECT_DIR/}")
  fi
  if grep -Eiq '<html([[:space:]>])' "$file" && ! grep -Eiq '<title[[:space:]>].*</title>' "$file"; then
    missing_title+=("${file#$PROJECT_DIR/}")
  fi
  while IFS= read -r ref; do
    case "$ref" in
      http:*|https:*|//*|mailto:*|tel:*|\#*|""|data:*|javascript:*) continue ;;
    esac
    ref="${ref%%#*}"
    ref="${ref%%\?*}"
    [ -e "$(dirname "$file")/$ref" ] || broken_assets+=("${file#$PROJECT_DIR/} -> $ref")
  done < <(grep -Eoi '(src|href)=["'\''][^"'\'']+["'\'']' "$file" 2>/dev/null | sed -E 's/^[^=]+=["'\'']([^"'\'']+)["'\'']/\1/')
done

if [ "${#missing_structure[@]}" -eq 0 ]; then
  ok "H02 HTML files include doctype or html root markers"
else
  fail "H02" "missing document marker: ${missing_structure[*]}"
fi

if [ "${#missing_title[@]}" -eq 0 ]; then
  ok "H03 full HTML documents include a title"
else
  fail "H03" "missing title tag: ${missing_title[*]}"
fi

if [ "${#broken_assets[@]}" -eq 0 ]; then
  ok "H04 local src/href asset references resolve"
else
  fail "H04" "broken local asset reference(s): ${broken_assets[*]}"
fi
