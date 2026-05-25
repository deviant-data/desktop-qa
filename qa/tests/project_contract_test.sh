#!/usr/bin/env bash
# Category: unit
# Use case: Validate the basic project and QA directory contract.
# Summary: Confirms PROJECT_DIR, qa metadata, and configured required files are discoverable.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PLAN_FILE="${PLAN_FILE:-$QA_DIR/qa_plan.md}"
TARGET_REQUIRED_FILES="${TARGET_REQUIRED_FILES:-}"
TARGET_ALLOW_WRITE_CHECKS="${TARGET_ALLOW_WRITE_CHECKS:-1}"

csv_items() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d'
}

if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
  ok "U01 PROJECT_DIR resolves to a directory"
else
  fail "U01" "PROJECT_DIR is not a directory: ${PROJECT_DIR:-unset}"
fi

if [ -d "$QA_DIR" ]; then
  ok "U02 qa directory exists"
elif [ "$TARGET_ALLOW_WRITE_CHECKS" = "1" ] && mkdir -p "$QA_DIR" 2>/dev/null; then
  ok "U02 qa directory was absent but is creatable"
else
  fail "U02" "qa directory missing or not creatable: $QA_DIR"
fi

if [ -s "$INGESTION_FILE" ]; then
  ok "U03 ingestion_summary.md exists and is non-empty"
else
  skip "U03" "ingestion summary is missing or empty"
fi

if [ -s "$PLAN_FILE" ]; then
  ok "U04 qa_plan.md exists and is non-empty"
else
  skip "U04" "QA plan is missing or empty"
fi

if [ -n "$TARGET_REQUIRED_FILES" ]; then
  missing=""
  while IFS= read -r required; do
    [ -e "$PROJECT_DIR/$required" ] || missing="$missing $required"
  done <<EOF
$(csv_items "$TARGET_REQUIRED_FILES")
EOF
  if [ -z "$missing" ]; then
    ok "U05 configured required files exist"
  else
    fail "U05" "missing configured file(s):$missing"
  fi
else
  skip "U05" "TARGET_REQUIRED_FILES is not configured"
fi
