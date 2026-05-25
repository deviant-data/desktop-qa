#!/usr/bin/env bash
# Category: api
# Use case: Probe safe command-line behavior for the project's entry point.
# Summary: Runs only bounded no-arg, help, and invalid-path checks using the discovered runner.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET_EXECUTE_ENTRYPOINT="${TARGET_EXECUTE_ENTRYPOINT:-1}"

run_with_timeout() {
  secs="$1"
  shift
  if has_command timeout; then
    timeout "$secs" "$@"
    return $?
  fi
  "$@" &
  pid=$!
  (
    sleep "$secs"
    kill -TERM "$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid" 2>/dev/null
  rc=$?
  kill -TERM "$watchdog" 2>/dev/null
  return "$rc"
}

runner_for_file() {
  file="$1"
  case "$file" in
    *.sh|*.bash) printf 'bash\n' ;;
    *.py) has_command python3 && printf 'python3\n' ;;
    *.js|*.mjs|*.cjs) has_command node && printf 'node\n' ;;
    *) printf '\n' ;;
  esac
}

if [ "$TARGET_EXECUTE_ENTRYPOINT" != "1" ]; then
  for id in A01 A02 A03 A04; do skip "$id" "entry point execution disabled"; done
  exit 0
fi

ENTRY="${TARGET_ENTRY_POINT:-$(ingestion_entry_point)}"
if [ -z "$ENTRY" ]; then
  for id in A01 A02 A03 A04; do skip "$id" "no entry point declared"; done
  exit 0
fi

ENTRY_PATH="$PROJECT_DIR/$ENTRY"
if [ ! -f "$ENTRY_PATH" ]; then
  for id in A01 A02 A03 A04; do skip "$id" "entry point missing"; done
  exit 0
fi

RUNNER="$(runner_for_file "$ENTRY_PATH")"
if [ -z "$RUNNER" ]; then
  for id in A01 A02 A03 A04; do skip "$id" "no safe runner for entry point extension"; done
  exit 0
fi
ok "A01 entry point has a safe runner"

out="$(run_with_timeout 3 "$RUNNER" "$ENTRY_PATH" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  skip "A02" "no-argument invocation exits 0; this may be valid for this project"
elif [ "$rc" -ge 124 ] && [ "$rc" -le 143 ]; then
  fail "A02" "no-argument invocation timed out"
elif printf '%s' "$out" | grep -qiE 'usage|argument|required|missing|error|invalid'; then
  ok "A02 no-argument invocation fails with diagnostic text"
else
  skip "A02" "no-argument invocation failed without recognizable diagnostic text"
fi

out="$(run_with_timeout 3 "$RUNNER" "$ENTRY_PATH" --help 2>&1)"
rc=$?
if [ "$rc" -ge 124 ] && [ "$rc" -le 143 ]; then
  fail "A03" "help invocation timed out"
elif [ -n "$out" ] && printf '%s' "$out" | grep -qiE 'usage|help|option|argument|command'; then
  ok "A03 help invocation emits recognizable text"
else
  skip "A03" "help flag is not implemented or uses project-specific wording"
fi

case "$ENTRY_PATH" in
  *.sh|*.bash)
    missing="/definitely/not/a/project/path_$$"
    out="$(run_with_timeout 3 bash "$ENTRY_PATH" "$missing" 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      ok "A04 shell entry rejects a nonexistent path argument"
    elif printf '%s' "$out" | grep -qiE 'not found|not a directory|invalid|error'; then
      ok "A04 shell entry reports invalid path input"
    else
      fail "A04" "shell entry silently accepted nonexistent path input"
    fi
    ;;
  *)
    skip "A04" "invalid path contract is only probed for shell entries"
    ;;
esac
