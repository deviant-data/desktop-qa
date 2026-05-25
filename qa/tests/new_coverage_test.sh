#!/usr/bin/env bash
# new_coverage_test.sh — Unit tests for the qa_plan.md output.
#
# Original was a kitchen-sink regression file heavily tied to desktop-qa
# internals. The new version is a project-agnostic sanity check on the
# Stage 3 plan: does it exist, does it have the six required category
# tables, does the total count reconcile with the table rows.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PLAN_FILE="$QA_DIR/qa_plan.md"

# U01: Plan exists.
if [ ! -f "$PLAN_FILE" ]; then
  fail "U01" "qa_plan.md not found at $PLAN_FILE"
  for i in U02 U03 U04 U05; do skip "$i" "plan missing"; done
  exit 0
fi
ok "U01 qa_plan.md exists"

# U02: Plan has a title line.
if head -n 1 "$PLAN_FILE" | grep -q '^# '; then
  ok "U02 qa_plan.md has a top-level heading"
else
  fail "U02" "qa_plan.md missing top-level heading"
fi

# U03: All six documented category sections are present. The spec in
# 02_qa_plan.md names them exactly.
MISSING=()
for sec in \
  "## Unit Tests" \
  "## Integration Tests" \
  "## API Tests" \
  "## Edge Cases" \
  "## Negative Tests" \
  "## Regression Anchors"; do
  grep -qF "$sec" "$PLAN_FILE" || MISSING+=("$sec")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "U03 all six category sections present"
else
  fail "U03" "missing section(s): ${MISSING[*]}"
fi

# U04: Plan declares a "Total planned tests" count and the count is a
# non-negative integer. Zero is valid (a trivial project might plan none).
total=$(grep -E '^## Total planned tests:' "$PLAN_FILE" | head -n1 | sed 's/.*: *//')
if [ -z "$total" ]; then
  fail "U04" "no '## Total planned tests:' line"
elif [[ "$total" =~ ^[0-9]+$ ]]; then
  ok "U04 total planned tests declared: $total"
else
  fail "U04" "'Total planned tests' is not an integer: $total"
fi

# U05: Every category table has a header row. A table missing its header
# renders as garbage in the report. We look for the minimal `| ID | `
# prefix after each section heading.
MALFORMED=()
for sec in "Unit Tests" "Integration Tests" "API Tests" "Edge Cases" "Negative Tests" "Regression Anchors"; do
  # Grab the five lines after the section heading — the header and the
  # separator should be in there.
  if ! awk -v s="## $sec" '
        $0 == s {found=1; c=0; next}
        found && c<5 {print; c++}
      ' "$PLAN_FILE" | grep -qE '^\|[[:space:]]*ID[[:space:]]*\|'; then
    MALFORMED+=("$sec")
  fi
done
if [ "${#MALFORMED[@]}" -eq 0 ]; then
  ok "U05 all category tables have an ID header row"
else
  fail "U05" "category table(s) missing header: ${MALFORMED[*]}"
fi
