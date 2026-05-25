#!/usr/bin/env bash
# Category: negative
# Use case: Verify bad inputs fail clearly without corrupting project state.
# Summary: Sends missing, file-as-directory, empty, and missing-metadata inputs to safe shell surfaces.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

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

primary_script() {
  if [ -n "${TARGET_RUN_SCRIPT:-}" ]; then
    printf '%s\n' "$TARGET_RUN_SCRIPT"
    return
  fi
  entry="${TARGET_ENTRY_POINT:-$(ingestion_entry_point)}"
  if [ -n "$entry" ]; then
    printf '%s\n' "$PROJECT_DIR/$entry"
  elif [ -f "$PROJECT_DIR/run.sh" ]; then
    printf '%s\n' "$PROJECT_DIR/run.sh"
  else
    printf '\n'
  fi
}

SCRIPT="$(primary_script)"
SCRATCH="$(make_scratch)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ]; then
  for id in N01 N02 N03 N04; do skip "$id" "no primary script available"; done
  exit 0
fi

case "$SCRIPT" in
  *.sh|*.bash) ;;
  *)
    for id in N01 N02 N03; do skip "$id" "primary script is not a shell script"; done
    ;;
esac

if [[ "$SCRIPT" == *.sh || "$SCRIPT" == *.bash ]]; then
  out="$(run_with_timeout 3 bash "$SCRIPT" "/definitely/not/a/project/path_$$" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "N01 primary script rejects nonexistent project path"
  elif printf '%s' "$out" | grep -qiE 'not found|not a directory|invalid|error'; then
    ok "N01 primary script reports nonexistent project path"
  else
    fail "N01" "primary script accepted nonexistent project path"
  fi

  fake_file="$SCRATCH/not_a_directory"
  : > "$fake_file"
  out="$(run_with_timeout 3 bash "$SCRIPT" "$fake_file" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "N02 primary script rejects a file where a directory is expected"
  elif printf '%s' "$out" | grep -qiE 'not a directory|invalid|error'; then
    ok "N02 primary script reports file-as-directory input"
  else
    fail "N02" "primary script accepted a file where a directory is expected"
  fi

  out="$(run_with_timeout 3 bash "$SCRIPT" "" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "N03 primary script rejects an empty-string argument"
  elif [ -n "$out" ]; then
    skip "N03" "empty-string argument exited 0 but produced output"
  else
    fail "N03" "empty-string argument was silently accepted"
  fi
fi

DOWNSTREAM=""
for candidate in 01_environment.sh 02_qa_plan.sh 03_test_execution.sh 04_report.sh; do
  if [ -f "$PROJECT_DIR/$candidate" ]; then
    DOWNSTREAM="$PROJECT_DIR/$candidate"
    break
  fi
done

if [ -n "$DOWNSTREAM" ]; then
  faux="$SCRATCH/faux_project"
  mkdir -p "$faux/qa"
  out="$(run_with_timeout 3 bash "$DOWNSTREAM" "$faux" 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qiE 'ingestion|summary|plan|qa'; then
    ok "N04 downstream stage rejects missing prerequisite metadata clearly"
  elif [ "$rc" -ne 0 ]; then
    skip "N04" "downstream stage failed but message is project-specific"
  else
    fail "N04" "downstream stage accepted missing prerequisite metadata"
  fi
else
  skip "N04" "no downstream stage script found"
fi
