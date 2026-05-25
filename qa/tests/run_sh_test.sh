#!/usr/bin/env bash
# run_sh_test.sh — Unit tests for the project's primary entry point.
#
# Filename preserved from the original desktop-qa-specific test, but the
# body is now generic: it uses ingestion_summary.md to discover the
# project's entry point and runs structural checks against whatever it
# finds. For a shell project that's run.sh; for a Node project it'd be
# index.js; for Python it might be app.py or manage.py. If no entry point
# was identified, every assertion skips with a clear reason.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

ENTRY=$(ingestion_entry_point)

# U01: Ingestion identified an entry point at all.
if [ -n "$ENTRY" ]; then
  ok "U01 ingestion_summary.md names an entry point ($ENTRY)"
else
  # Without an entry point we can't run U02..U04. Emit a skip for each
  # so the per-sub-test counts don't silently drop below the plan.
  skip "U01" "no entry point listed in ingestion_summary.md"
  skip "U02" "depends on U01"
  skip "U03" "depends on U01"
  skip "U04" "depends on U01"
  exit 0
fi

ENTRY_PATH="$PROJECT_DIR/$ENTRY"

# U02: The referenced file actually exists on disk. Ingestion can go stale
# if someone renames an entry point without rerunning Stage 1.
if [ -f "$ENTRY_PATH" ]; then
  ok "U02 entry point exists at $ENTRY"
else
  fail "U02" "ingestion named $ENTRY but $ENTRY_PATH is missing"
fi

# U03: The file is non-empty. A zero-byte entry point is a common
# footgun when a build step silently fails.
if [ -f "$ENTRY_PATH" ] && [ -s "$ENTRY_PATH" ]; then
  ok "U03 entry point is non-empty"
elif [ ! -f "$ENTRY_PATH" ]; then
  skip "U03" "depends on U02"
else
  fail "U03" "$ENTRY is zero bytes"
fi

# U04: Structural check tailored to the extension. We avoid executing
# the entry point — executing an unknown project's entry point with no
# arguments can have side effects (binding ports, writing files). We
# limit ourselves to *static* checks that don't run the code.
if [ -f "$ENTRY_PATH" ]; then
  case "$ENTRY" in
    *.sh|*.bash)
      # Shell entry: parse-check only. Catches syntax errors that would
      # surface as runtime "command not found" or "unexpected token".
      if bash -n "$ENTRY_PATH" 2>/dev/null; then
        ok "U04 entry point passes bash -n syntax check"
      else
        fail "U04" "bash -n reported syntax errors in $ENTRY"
      fi
      ;;
    *.py)
      # Python entry: compile-check. `py_compile` is stdlib, no deps.
      if has_command python3; then
        if python3 -m py_compile "$ENTRY_PATH" 2>/dev/null; then
          ok "U04 entry point passes py_compile check"
        else
          fail "U04" "py_compile reported errors in $ENTRY"
        fi
      else
        skip "U04" "python3 not available"
      fi
      ;;
    *.js|*.mjs|*.cjs)
      # Node entry: use `--check` to parse without executing.
      if has_command node; then
        if node --check "$ENTRY_PATH" 2>/dev/null; then
          ok "U04 entry point passes node --check"
        else
          fail "U04" "node --check reported errors in $ENTRY"
        fi
      else
        skip "U04" "node not available"
      fi
      ;;
    *.ts|*.tsx)
      # TypeScript: we don't install tsc just for a parse check. If
      # tsc is already on PATH, use it; otherwise skip cleanly.
      if has_command tsc; then
        if tsc --noEmit "$ENTRY_PATH" 2>/dev/null; then
          ok "U04 entry point passes tsc --noEmit"
        else
          fail "U04" "tsc reported errors in $ENTRY"
        fi
      else
        skip "U04" "tsc not available; skipping static check"
      fi
      ;;
    *)
      # Unknown extension — not all projects have a convention we
      # recognise. A file simply existing is meaningful data, so we
      # don't emit a failure.
      skip "U04" "no static check defined for extension of $ENTRY"
      ;;
  esac
else
  skip "U04" "depends on U02"
fi
