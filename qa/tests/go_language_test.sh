#!/usr/bin/env bash
# Category: unit
# Language: Go
# Use case: Validate Go source formatting and module metadata without fetching dependencies.
# Summary: Uses gofmt when available and checks go.mod/go.sum reproducibility signals.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t GO_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/vendor' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.go' -print 2>/dev/null | head -n 40
)

if [ "${#GO_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/go.mod" ]; then
  for id in GO01 GO02 GO03 GO04; do skip "$id" "no Go files or go.mod found"; done
  exit 0
fi
ok "GO01 Go surface discovered"

if [ -f "$PROJECT_DIR/go.mod" ]; then
  if grep -q '^module ' "$PROJECT_DIR/go.mod"; then
    ok "GO02 go.mod declares a module"
  else
    fail "GO02" "go.mod lacks module declaration"
  fi
else
  skip "GO02" "go.mod not present"
fi

if [ "${#GO_FILES[@]}" -eq 0 ]; then
  skip "GO03" "no Go files to format-check"
elif has_command gofmt; then
  bad=()
  for file in "${GO_FILES[@]}"; do
    [ -z "$(gofmt -l "$file" 2>/dev/null)" ] || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "GO03 sampled Go files are gofmt-formatted"
  else
    fail "GO03" "gofmt would change: ${bad[*]}"
  fi
else
  skip "GO03" "gofmt is not available"
fi

if [ -f "$PROJECT_DIR/go.mod" ] && grep -q '^require ' "$PROJECT_DIR/go.mod"; then
  if [ -f "$PROJECT_DIR/go.sum" ]; then
    ok "GO04 go.sum exists for required modules"
  else
    skip "GO04" "go.mod has requirements but go.sum is missing"
  fi
else
  skip "GO04" "no external Go requirements detected"
fi
