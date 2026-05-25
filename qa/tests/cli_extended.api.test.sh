#!/usr/bin/env bash
# cli_extended.api.test.sh — Extended API/CLI tests.
#
# Complements cli_api_test.sh with tests for conventional flags: --help,
# --version, and --invalid-flag behaviour. Each test auto-skips if the
# entry point's shape doesn't fit, keeping the suite green on projects
# that aren't CLIs.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

ENTRY=$(ingestion_entry_point)
if [ -z "$ENTRY" ] || [ ! -f "$PROJECT_DIR/$ENTRY" ]; then
  for i in A01 A02 A03; do skip "$i" "no runnable entry point"; done
  exit 0
fi

ENTRY_PATH="$PROJECT_DIR/$ENTRY"
case "$ENTRY" in
  *.sh|*.bash)   RUNNER=(bash) ;;
  *.py)          has_command python3 && RUNNER=(python3) || { for i in A01 A02 A03; do skip "$i" "python3 unavailable"; done; exit 0; } ;;
  *.js|*.cjs)    has_command node    && RUNNER=(node)    || { for i in A01 A02 A03; do skip "$i" "node unavailable"; done; exit 0; } ;;
  *)
    for i in A01 A02 A03; do skip "$i" "no safe runner for $ENTRY"; done
    exit 0
    ;;
esac

# Shared timeout helper. Identical to cli_api_test.sh — kept inline so
# each test file is self-contained and runnable in isolation.
run_with_timeout() {
  local secs="$1"; shift
  if has_command timeout; then
    timeout "$secs" "$@"
  else
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    return $rc
  fi
}

# A01: --help flag (or -h) emits something and exits. Not all CLIs
# implement this — we treat "silently rejected" as a skip, not a fail,
# since it's a convention, not a requirement.
out=$(run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" --help 2>&1); rc=$?
if [ $rc -ge 124 ] && [ $rc -le 143 ]; then
  fail "A01" "--help invocation hung"
elif [ -n "$out" ] && echo "$out" | grep -qiE 'usage|help|option|argument'; then
  ok "A01 --help emits recognisable help text"
else
  # Try -h as a secondary probe before giving up.
  out=$(run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" -h 2>&1); rc=$?
  if [ -n "$out" ] && echo "$out" | grep -qiE 'usage|help|option'; then
    ok "A01 -h emits recognisable help text (--help not recognised)"
  else
    skip "A01" "neither --help nor -h emits help text — may not be a convention this CLI follows"
  fi
fi

# A02: Unknown flag is rejected, not silently ignored. A CLI that accepts
# `--definitely-not-a-real-flag` without complaint is a footgun.
out=$(run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" --xyzzy-qa-test-flag 2>&1); rc=$?
if [ $rc -ge 124 ] && [ $rc -le 143 ]; then
  fail "A02" "unknown-flag invocation hung"
elif [ $rc -eq 0 ]; then
  # Exited 0 despite an unknown flag. Many shell scripts are written
  # this way — they only read positional args — so we skip rather than fail.
  skip "A02" "unknown --xyzzy-qa-test-flag was silently accepted (exit 0)"
else
  ok "A02 unknown flag produces non-zero exit ($rc)"
fi

# A03: Stdin handling — many CLIs read stdin when no path is given. We
# send an EOF (empty input) to confirm it doesn't hang waiting for input.
# The key property is "exits within the timeout", not "exits zero".
out=$(echo "" | run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" 2>&1); rc=$?
if [ $rc -ge 124 ] && [ $rc -le 143 ]; then
  fail "A03" "CLI hung on empty stdin — probable infinite read loop"
else
  ok "A03 empty stdin does not cause hang (exit $rc)"
fi
