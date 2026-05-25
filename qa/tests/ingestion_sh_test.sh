#!/usr/bin/env bash
# ingestion_sh_test.sh — Unit tests for the Stage 1 ingestion output.
#
# These verify that ingestion_summary.md (written by Stage 1 of whatever
# pipeline produced it) is structurally valid and contains the sections
# downstream tools rely on. Project-agnostic: we don't care what's IN
# the sections, only that they exist and are populated.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# U01: ingestion_summary.md exists at all. If not, Stage 1 hasn't run,
# and the rest of the suite will be running blind. Every subsequent test
# skips so the missing file is flagged once, loudly.
if ! has_ingestion; then
  fail "U01" "ingestion_summary.md not found at $INGESTION_FILE"
  for i in U02 U03 U04 U05 U06; do skip "$i" "ingestion missing"; done
  exit 0
fi
ok "U01 ingestion_summary.md exists"

# U02: The file has a top-level heading. A zero-byte file is the common
# failure mode when an earlier bash-version guard bails out.
if head -n 1 "$INGESTION_FILE" | grep -q '^# '; then
  ok "U02 ingestion_summary.md has a top-level heading"
else
  fail "U02" "ingestion_summary.md missing top-level heading"
fi

# U03..U06: Each documented section is present. The spec in 00_ingestion.md
# names these exactly, so we match them literally. If a section is missing,
# report which one — actionable message beats a generic "validation failed".
for section_test in \
  "U03:## Stack" \
  "U04:## Entry Points" \
  "U05:## Dependency Manifest" \
  "U06:## Flags & Observations"; do
  id="${section_test%%:*}"
  heading="${section_test#*:}"
  if grep -qF "$heading" "$INGESTION_FILE"; then
    ok "$id section present: $heading"
  else
    fail "$id" "section missing: $heading"
  fi
done
