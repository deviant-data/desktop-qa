#!/usr/bin/env bash
# environment_sh_test.sh — Unit tests for Stage 2 environment-setup output.
#
# Inspects $PROJECT_DIR/qa/test_log.txt for the `=== ENVIRONMENT SUMMARY ===`
# block produced by Stage 2. Checks are structural: does the log contain
# the block, are the documented fields present, do they have plausible
# values. No claims about specific runtimes — a Python project and a
# Node project both satisfy this test.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

LOG_FILE="$QA_DIR/test_log.txt"

# U01: Log exists. Stage 2 writes to it even on failure, so its absence
# means Stage 2 never ran.
if [ ! -f "$LOG_FILE" ]; then
  fail "U01" "test_log.txt not found at $LOG_FILE"
  for i in U02 U03 U04 U05; do skip "$i" "log file missing"; done
  exit 0
fi
ok "U01 test_log.txt exists"

# U02: Contains the ENVIRONMENT SUMMARY block. We search the whole file,
# not just the tail, because Stage 4 appends its own blocks below.
if grep -q '=== ENVIRONMENT SUMMARY ===' "$LOG_FILE"; then
  ok "U02 environment summary block present"
else
  fail "U02" "no '=== ENVIRONMENT SUMMARY ===' block in test_log.txt"
  for i in U03 U04 U05; do skip "$i" "no environment block to inspect"; done
  exit 0
fi

# Extract the block for field-level checks. We take everything between
# the first `=== ENVIRONMENT SUMMARY ===` and the next `===` line — the
# Stage 2 script emits a trailing `==========================` marker.
BLOCK=$(awk '
  /=== ENVIRONMENT SUMMARY ===/ {capture=1; next}
  capture && /^===/ {exit}
  capture {print}
' "$LOG_FILE")

# U03: Required fields are present. The Stage 2 spec in 01_environment.md
# names these exactly, and Stage 5 greps for them to populate the report.
MISSING=()
for field in "Runtime:" "Install result:" "Build result:" "Startup result:"; do
  echo "$BLOCK" | grep -q "^$field" || MISSING+=("$field")
done
if [ "${#MISSING[@]}" -eq 0 ]; then
  ok "U03 all required environment fields present"
else
  fail "U03" "missing field(s): ${MISSING[*]}"
fi

# U04: Install/Build/Startup values are in the documented enum. The spec
# says these must be one of SUCCESS / PARTIAL / FAILED / SKIPPED.
BAD_VALUE=()
for field in "Install result" "Build result" "Startup result"; do
  val=$(echo "$BLOCK" | grep -E "^$field:" | head -n1 | sed 's/^[^:]*: *//' | awk '{print $1}')
  case "$val" in
    SUCCESS|PARTIAL|FAILED|SKIPPED|'') ;;   # '' covered by U03
    *) BAD_VALUE+=("$field=$val") ;;
  esac
done
if [ "${#BAD_VALUE[@]}" -eq 0 ]; then
  ok "U04 all result fields use documented enum values"
else
  fail "U04" "unrecognised value(s): ${BAD_VALUE[*]}"
fi

# U05: Runtime line is non-empty. "unknown" is an acceptable value for
# projects the stack-detection logic doesn't recognise; we just want the
# field populated.
runtime=$(echo "$BLOCK" | grep -E '^Runtime:' | head -n1 | sed 's/^Runtime: *//')
if [ -n "$runtime" ]; then
  ok "U05 runtime field populated ($runtime)"
else
  fail "U05" "Runtime: field is empty"
fi
