#!/usr/bin/env bash
# environment_stack_test.sh — Unit tests confirming the detected stack
# is consistent between ingestion and environment setup.
#
# This is a cross-stage consistency check: Stage 1 (ingestion) identifies
# a framework, and Stage 2 (environment) acts on it. If the two disagree,
# downstream stages work on false premises. Runs against any project.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

LOG_FILE="$QA_DIR/test_log.txt"

# U01: Both ingestion and environment artefacts exist. This test is
# cross-stage, so both must be present.
if ! has_ingestion; then
  fail "U01" "ingestion_summary.md missing"
  for i in U02 U03; do skip "$i" "prerequisite missing"; done
  exit 0
fi
if [ ! -f "$LOG_FILE" ]; then
  fail "U01" "test_log.txt missing"
  for i in U02 U03; do skip "$i" "prerequisite missing"; done
  exit 0
fi
ok "U01 both ingestion and environment artefacts present"

# U02: Languages section in ingestion is non-empty. A zero-length section
# means language detection failed silently — Stage 2 would then fall
# through to "unknown stack" and skip everything.
lang=$(ingestion_language)
if [ -n "$lang" ] && [ "$lang" != "(none" ]; then
  ok "U02 ingestion detected at least one language ($lang)"
else
  fail "U02" "ingestion Languages section is empty or '(none detected)'"
fi

# U03: Stage 2's "Detected stack" line exists and is not 'unknown' — OR,
# if it IS 'unknown', that's only acceptable when ingestion also couldn't
# identify a framework. This catches the case where ingestion saw (say)
# Python but Stage 2's probe logic missed it.
stack_line=$(grep -E 'Detected stack:' "$LOG_FILE" | tail -n1 | sed 's/.*Detected stack: *//')
fw_line=$(ingestion_framework)

if [ -z "$stack_line" ]; then
  fail "U03" "Stage 2 did not log a 'Detected stack:' line"
elif [ "$stack_line" != "unknown" ]; then
  ok "U03 Stage 2 detected stack: $stack_line"
elif echo "$fw_line" | grep -qE 'not identified|no well-known'; then
  # Both stages agree the stack is unidentifiable — that's consistent.
  ok "U03 stack is 'unknown' but ingestion also found no framework (consistent)"
else
  fail "U03" "Stage 2 says 'unknown' but ingestion reported: $fw_line"
fi
