#!/usr/bin/env bash
# cli_api_test.sh — API tests for the project's CLI surface.
#
# Runs only if ingestion identified an entry-point script that looks like
# a CLI (shell script, Python script with argparse-ish hints, etc.). We
# deliberately avoid executing the CLI with random arguments against an
# unknown project — too much risk of side effects. Instead we probe the
# "no args" and "invalid args" paths, which are always safe and usually
# return quickly with a usage string.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

ENTRY=$(ingestion_entry_point)

# A01: There's a plausible CLI to probe.
if [ -z "$ENTRY" ]; then
  skip "A01" "no entry point listed in ingestion"
  for i in A02 A03; do skip "$i" "no CLI to probe"; done
  exit 0
fi

ENTRY_PATH="$PROJECT_DIR/$ENTRY"
if [ ! -f "$ENTRY_PATH" ]; then
  skip "A01" "entry point $ENTRY missing from disk"
  for i in A02 A03; do skip "$i" "no CLI to probe"; done
  exit 0
fi

# Choose a safe invocation. If the entry is a shell script, we run it
# under `bash`. For Python, `python3`. For Node, `node`. For anything
# else we skip rather than guess.
case "$ENTRY" in
  *.sh|*.bash)   RUNNER=(bash) ;;
  *.py)          has_command python3 && RUNNER=(python3) || { skip "A01" "python3 unavailable"; exit 0; } ;;
  *.js|*.cjs)    has_command node    && RUNNER=(node)    || { skip "A01" "node unavailable"; exit 0; } ;;
  *)
    skip "A01" "no safe runner for extension of $ENTRY"
    for i in A02 A03; do skip "$i" "no runner"; done
    exit 0
    ;;
esac
ok "A01 entry point $ENTRY is runnable via ${RUNNER[0]}"

# A02: No-argument invocation exits non-zero and emits something usage-ish.
# We cap the run at 3 seconds — a CLI that hangs with no args is a bug,
# but we don't want the test to hang with it. `timeout` is coreutils; if
# it's absent (minimal containers, BSD), fall back to backgrounding.
run_with_timeout() {
  local secs="$1"; shift
  if has_command timeout; then
    timeout "$secs" "$@"
  else
    # Portable fallback: background, sleep, kill if still alive.
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local watchdog=$!
    wait "$pid" 2>/dev/null
    local rc=$?
    kill -TERM "$watchdog" 2>/dev/null
    return $rc
  fi
}

out=$(run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" 2>&1); rc=$?
if [ $rc -eq 0 ]; then
  # Some CLIs legitimately run without args (e.g. REPL entry points).
  # We don't fail here — just note it as a skip with a clear reason.
  skip "A02" "no-args invocation exited 0 (possibly a REPL or always-on script)"
elif [ $rc -ge 124 ] && [ $rc -le 143 ]; then
  # Exit codes 124 (GNU timeout) and 143 (SIGTERM) mean it hung.
  fail "A02" "no-args invocation hung (exit $rc); CLI should fail fast with usage"
elif echo "$out" | grep -qiE 'usage|argument|missing|required'; then
  ok "A02 no-args invocation exits non-zero with usage/hint text"
else
  # Exited non-zero but without any usage hint. Not a clear bug; could
  # just be a terse CLI. Report as skip so we don't flap.
  skip "A02" "no-args exited $rc but without usage text — style choice"
fi

# A03: Invalid-path / garbage argument is rejected. We pass a clearly
# non-existent filesystem path; any sane CLI either ignores it (if the
# argument is ignored), errors with a clear message, or errors silently
# with a non-zero code. We accept any of these; we fail only on hang.
out=$(run_with_timeout 3 "${RUNNER[@]}" "$ENTRY_PATH" "/no/such/path/__qa_test__" 2>&1); rc=$?
if [ $rc -ge 124 ] && [ $rc -le 143 ]; then
  fail "A03" "invalid-arg invocation hung (exit $rc)"
elif [ $rc -ne 0 ]; then
  ok "A03 invalid-path argument produces non-zero exit ($rc)"
else
  # Exit 0 on a bogus path argument is a code smell but not always a bug.
  skip "A03" "invalid-path invocation exited 0 — CLI may ignore positional args"
fi
