#!/usr/bin/env bash
# negative_test.sh — Negative tests — inputs designed to fail.
#
# Each test confirms the project (or its environment) rejects bad input
# the way you'd want it to: non-zero exit, clear message, no silent
# corruption. Project-agnostic: we feed garbage to well-defined surfaces
# and verify they push back.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SCRATCH=$(make_scratch)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

ENTRY=$(ingestion_entry_point)

# N01: Non-existent project directory passed to a pipeline-style script.
# Only meaningful if the entry takes a path argument — we assume it does
# for shell entries, which is the common convention.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  out=$(bash "$PROJECT_DIR/$ENTRY" /definitely/nonexistent/path_$$ 2>&1); rc=$?
  if [ $rc -ne 0 ]; then
    ok "N01 entry script rejects a nonexistent path argument (exit $rc)"
  else
    fail "N01" "entry script accepted a nonexistent path (exit 0)"
  fi
else
  skip "N01" "no shell entry point to probe"
fi

# N02: A file where a directory is expected. Catches scripts that assume
# `-d` without checking. Same entry-point precondition as N01.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  fake="$SCRATCH/not_a_dir"
  : > "$fake"   # Create as regular file.
  out=$(bash "$PROJECT_DIR/$ENTRY" "$fake" 2>&1); rc=$?
  # We allow either non-zero exit OR a clear "not a directory" message
  # with any exit code — some scripts treat this case as a soft warning.
  if [ $rc -ne 0 ] || echo "$out" | grep -qiE 'not a dir|not a directory|invalid'; then
    ok "N02 entry script handles 'file where directory expected' (exit $rc)"
  else
    fail "N02" "entry script silently accepted a regular file as the target (exit 0, no error message)"
  fi
else
  skip "N02" "no shell entry point to probe"
fi

# N03: Empty-string argument. A surprisingly common crash source.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  out=$(bash "$PROJECT_DIR/$ENTRY" "" 2>&1); rc=$?
  # We want either a clean usage message OR a non-zero exit. A 0 exit
  # with no output is the worst case — it suggests the empty arg was
  # silently swallowed.
  if [ $rc -ne 0 ]; then
    ok "N03 empty-string argument produces non-zero exit"
  elif [ -n "$out" ]; then
    skip "N03" "empty-string arg exited 0 but produced output — may be handled upstream"
  else
    fail "N03" "empty-string argument silently accepted (exit 0, no output)"
  fi
else
  skip "N03" "no shell entry point to probe"
fi
