#!/usr/bin/env bash
# regression_test.sh — Regression anchors that must always pass.
#
# Regression anchors capture the small set of invariants the project
# cannot regress without breaking downstream consumers. For any project
# the pipeline touches, three invariants hold:
#
#   1. The project is reachable via $PROJECT_DIR.
#   2. qa/ exists (or can be created) and is writable.
#   3. If ingestion has run, its output is structurally valid.
#
# Everything else the pipeline cares about is category-specific and
# lives in the other test files. This file deliberately stays minimal.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# R01: $PROJECT_DIR resolves to a real directory. The library's header
# already derives this, so this test is really a sanity check on the
# library itself — if it fails, every other test is running blind.
if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
  ok "R01 \$PROJECT_DIR resolves to a directory ($PROJECT_DIR)"
else
  fail "R01" "\$PROJECT_DIR is unset or not a directory: '${PROJECT_DIR:-}'"
fi

# R02: qa/ directory exists or can be created. Pipeline stages write
# under qa/ — if we can't write there, nothing else runs.
if [ -d "$QA_DIR" ]; then
  ok "R02 qa/ directory exists"
elif mkdir -p "$QA_DIR" 2>/dev/null; then
  ok "R02 qa/ directory was absent but is creatable"
else
  fail "R02" "qa/ doesn't exist and can't be created at $QA_DIR"
fi

# R03: qa/ is writable. A read-only qa/ is a common symptom of a
# root-owned directory inherited from a prior Docker-based run.
if [ -d "$QA_DIR" ]; then
  if (: > "$QA_DIR/.qa_write_probe_$$") 2>/dev/null; then
    rm -f "$QA_DIR/.qa_write_probe_$$"
    ok "R03 qa/ is writable"
  else
    fail "R03" "qa/ exists but is not writable (permission issue?)"
  fi
else
  skip "R03" "qa/ missing — covered by R02"
fi

# R04: If ingestion_summary.md exists, it has content. Zero-byte output
# is a silent Stage 1 failure — one of the specific symptoms the project
# QA history flags as BUG-001 (bash 3.2 fall-through). Catching a
# zero-byte file here keeps future regressions loud.
if has_ingestion; then
  if [ -s "$INGESTION_FILE" ]; then
    ok "R04 ingestion_summary.md is non-empty"
  else
    fail "R04" "ingestion_summary.md exists but is zero bytes (Stage 1 silent failure)"
  fi
else
  # Not an error — regression anchors must work even when only some
  # stages have run. Skip with a clear reason.
  skip "R04" "ingestion hasn't run yet"
fi

# R05: If ingestion_summary.md exists, it declares a Stack section.
# Downstream stages branch on stack; a missing Stack section breaks
# every subsequent decision.
if has_ingestion && [ -s "$INGESTION_FILE" ]; then
  if grep -q '^## Stack' "$INGESTION_FILE"; then
    ok "R05 ingestion_summary.md contains a Stack section"
  else
    fail "R05" "ingestion_summary.md is missing the ## Stack section"
  fi
else
  skip "R05" "ingestion missing or empty — covered by R04"
fi
