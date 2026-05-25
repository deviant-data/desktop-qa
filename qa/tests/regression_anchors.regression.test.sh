#!/usr/bin/env bash
# Category: regression
# Use case: Protect invariants required by the larger QA pipeline.
# Summary: Rechecks project reachability, qa writability, metadata structure, and recognizes mixed legacy/new test suites.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

PLAN_FILE="${PLAN_FILE:-$QA_DIR/qa_plan.md}"
TESTS_DIR="${TESTS_DIR:-$QA_DIR/tests}"
TARGET_ALLOW_WRITE_CHECKS="${TARGET_ALLOW_WRITE_CHECKS:-1}"
TARGET_REQUIRE_CATEGORY_HEADERS="${TARGET_REQUIRE_CATEGORY_HEADERS:-0}"

if [ -d "$PROJECT_DIR" ]; then
  ok "R01 project directory is reachable"
else
  fail "R01" "project directory is missing: $PROJECT_DIR"
fi

if [ "$TARGET_ALLOW_WRITE_CHECKS" = "1" ]; then
  mkdir -p "$QA_DIR" 2>/dev/null || true
  probe="$QA_DIR/.qa_regression_probe_$$"
  if [ -d "$QA_DIR" ] && (: > "$probe") 2>/dev/null; then
    rm -f "$probe"
    ok "R02 qa directory is writable"
  else
    fail "R02" "qa directory is not writable"
  fi
else
  skip "R02" "write checks disabled"
fi

if [ -s "$INGESTION_FILE" ]; then
  if grep -q '^## Stack' "$INGESTION_FILE"; then
    ok "R03 ingestion summary contains a Stack section"
  else
    fail "R03" "ingestion summary is missing the Stack section"
  fi
else
  skip "R03" "ingestion summary is missing or empty"
fi

if [ -s "$PLAN_FILE" ]; then
  if grep -q '^## Regression Anchors' "$PLAN_FILE"; then
    ok "R04 QA plan includes regression anchors"
  else
    fail "R04" "QA plan is missing regression anchors"
  fi
else
  skip "R04" "QA plan is missing or empty"
fi

if [ -d "$TESTS_DIR" ]; then
  missing=""
  with_header=0
  total=0
  for test_file in "$TESTS_DIR"/*.sh "$TESTS_DIR"/*.bash; do
    [ -f "$test_file" ] || continue
    base="$(basename "$test_file")"
    case "$base" in
      _*) continue ;;
      *.test.sh|*_test.sh|*.test.bash|*_test.bash) ;;
      *) continue ;;
    esac
    total=$((total + 1))
    if grep -q '^# Category:' "$test_file" 2>/dev/null; then
      with_header=$((with_header + 1))
    else
      missing="$missing ${test_file#$PROJECT_DIR/}"
    fi
  done

  if [ "$total" -eq 0 ]; then
    skip "R05" "no shell test files found"
  elif [ -z "$missing" ]; then
    ok "R05 shell tests include category comments"
  elif [ "$TARGET_REQUIRE_CATEGORY_HEADERS" = "1" ]; then
    fail "R05" "shell test file(s) missing category comments:$missing"
  elif [ "$with_header" -gt 0 ]; then
    ok "R05 category comments present on $with_header new-format test file(s); legacy files allowed"
  else
    skip "R05" "no category comments found; legacy suite allowed unless TARGET_REQUIRE_CATEGORY_HEADERS=1"
  fi
else
  skip "R05" "tests directory is not present"
fi
