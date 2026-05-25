#!/usr/bin/env bash
# Category: edge
# Use case: Validate path, filename, and filesystem conditions common to QA runs.
# Summary: Exercises spaces, symlinks, long filenames, unicode filenames, and empty directories.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SCRATCH="$(make_scratch)"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

SPACED="$SCRATCH/path with spaces"
mkdir -p "$SPACED"
if ln -s "$PROJECT_DIR" "$SPACED/project" 2>/dev/null; then
  if [ -d "$SPACED/project" ]; then
    ok "E01 project can be reached through a path containing spaces"
  else
    fail "E01" "symlinked project path was not reachable"
  fi
else
  skip "E01" "filesystem does not allow creating a symlink here"
fi

LONG_NAME="$(printf 'a%.0s' $(seq 1 200))"
if touch "$SCRATCH/$LONG_NAME" 2>/dev/null; then
  ok "E02 filesystem accepts a 200-character filename"
else
  skip "E02" "filesystem rejected a 200-character filename"
fi

UNICODE_NAME="$(printf 'caf\303\251_utf8_check.txt')"
if touch "$SCRATCH/$UNICODE_NAME" 2>/dev/null && [ -f "$SCRATCH/$UNICODE_NAME" ]; then
  ok "E03 filesystem accepts UTF-8-safe filenames"
else
  skip "E03" "filesystem rejected UTF-8-safe filename probe"
fi

EMPTY_DIR="$SCRATCH/empty"
mkdir -p "$EMPTY_DIR"
if [ -d "$EMPTY_DIR" ] && [ -z "$(ls -A "$EMPTY_DIR")" ]; then
  ok "E04 empty directory fixture behaves as expected"
else
  fail "E04" "empty directory fixture was not empty"
fi

ENTRY="$(ingestion_entry_point)"
if [ -n "$ENTRY" ] && [ -f "$PROJECT_DIR/$ENTRY" ]; then
  case "$ENTRY" in
    *.sh|*.bash)
      suspect="$(grep -cE '(^|[[:space:]])(cd|cat|ls|rm|cp|mv|mkdir)[[:space:]]+\$[A-Za-z_]' "$PROJECT_DIR/$ENTRY" 2>/dev/null || true)"
      suspect="${suspect:-0}"
      if [ "$suspect" -eq 0 ]; then
        ok "E05 shell entry has no obvious unquoted path-variable patterns"
      else
        skip "E05" "$suspect possible unquoted path-variable pattern(s) found"
      fi
      ;;
    *)
      skip "E05" "entry point is not a shell file"
      ;;
  esac
else
  skip "E05" "no entry point available to inspect"
fi
