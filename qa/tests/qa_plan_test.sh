#!/usr/bin/env bash
# Category: unit
# Use case: Validate the larger QA application's plan artifact.
# Summary: Checks qa_plan.md for required sections, a declared count, and table headers.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PLAN_FILE="${PLAN_FILE:-$QA_DIR/qa_plan.md}"

if [ ! -f "$PLAN_FILE" ]; then
  fail "U01" "qa_plan.md not found at $PLAN_FILE"
  for id in U02 U03 U04 U05; do skip "$id" "depends on U01"; done
  exit 0
fi
ok "U01 qa_plan.md exists"

if head -n 1 "$PLAN_FILE" | grep -q '^# '; then
  ok "U02 qa_plan.md has a top-level heading"
else
  fail "U02" "qa_plan.md is missing a top-level heading"
fi

missing=""
for section in \
  "## Unit Tests" \
  "## Integration Tests" \
  "## API Tests" \
  "## Edge Cases" \
  "## Negative Tests" \
  "## Regression Anchors"; do
  grep -qF "$section" "$PLAN_FILE" || missing="$missing [$section]"
done
if [ -z "$missing" ]; then
  ok "U03 qa_plan.md includes all standard test categories"
else
  fail "U03" "missing category section(s):$missing"
fi

declared="$(grep -E '^## Total planned tests:' "$PLAN_FILE" | head -n 1 | sed 's/.*: *//')"
if [ -z "$declared" ]; then
  fail "U04" "missing total planned tests line"
elif printf '%s' "$declared" | grep -Eq '^[0-9]+$'; then
  ok "U04 total planned tests is numeric"
else
  fail "U04" "total planned tests is not numeric: $declared"
fi

malformed=""
for section in "Unit Tests" "Integration Tests" "API Tests" "Edge Cases" "Negative Tests" "Regression Anchors"; do
  if ! awk -v heading="## $section" '
      $0 == heading {found=1; count=0; next}
      found && count < 6 {print; count++}
    ' "$PLAN_FILE" | grep -qE '^\|[[:space:]]*ID[[:space:]]*\|'; then
    malformed="$malformed [$section]"
  fi
done
if [ -z "$malformed" ]; then
  ok "U05 category tables include ID headers"
else
  fail "U05" "malformed category table(s):$malformed"
fi
