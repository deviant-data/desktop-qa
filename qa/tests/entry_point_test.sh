#!/usr/bin/env bash
# Category: unit
# Use case: Validate the project's declared entry point without unsafe execution.
# Summary: Reads ingestion metadata or TARGET_ENTRY_POINT, then checks existence, size, and syntax.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

static_check() {
  file="$1"
  case "$file" in
    *.sh|*.bash)
      bash -n "$file" >/dev/null 2>&1
      ;;
    *.py)
      has_command python3 && python3 -m py_compile "$file" >/dev/null 2>&1
      ;;
    *.js|*.mjs|*.cjs)
      has_command node && node --check "$file" >/dev/null 2>&1
      ;;
    *)
      return 2
      ;;
  esac
}

ENTRY="${TARGET_ENTRY_POINT:-$(ingestion_entry_point)}"
if [ -z "$ENTRY" ]; then
  skip "U01" "no entry point declared in ingestion metadata or TARGET_ENTRY_POINT"
  skip "U02" "depends on U01"
  skip "U03" "depends on U01"
  skip "U04" "depends on U01"
  exit 0
fi
ok "U01 entry point declared: $ENTRY"

ENTRY_PATH="$PROJECT_DIR/$ENTRY"
if [ -f "$ENTRY_PATH" ]; then
  ok "U02 entry point exists"
else
  fail "U02" "entry point missing: $ENTRY"
fi

if [ -s "$ENTRY_PATH" ]; then
  ok "U03 entry point is non-empty"
elif [ -f "$ENTRY_PATH" ]; then
  fail "U03" "entry point is empty: $ENTRY"
else
  skip "U03" "depends on U02"
fi

if [ -f "$ENTRY_PATH" ]; then
  if static_check "$ENTRY_PATH"; then
    ok "U04 entry point passes static syntax check"
  else
    rc=$?
    if [ "$rc" -eq 2 ]; then
      skip "U04" "no static checker for this file type"
    else
      fail "U04" "static syntax check failed for $ENTRY"
    fi
  fi
else
  skip "U04" "depends on U02"
fi
