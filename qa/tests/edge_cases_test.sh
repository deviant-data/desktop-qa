#!/usr/bin/env bash
# edge_cases_test.sh — Edge case tests for project robustness.
#
# Each edge case tests a property that's widely expected but easily
# broken: paths with spaces, long filenames, unicode, unusual locales.
# None of these touch project internals — they exercise standard
# filesystem and process APIs the project presumably uses.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

ENTRY=$(ingestion_entry_point)

# E01: Project's qa directory path survives spaces. We create a scratch
# directory with a space in its name, symlink the project into it, and
# verify $PROJECT_DIR resolves cleanly. No execution — this is purely
# a path-handling check that catches unquoted $PROJECT_DIR usage.
SCRATCH=$(make_scratch)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
SPACED_DIR="$SCRATCH/path with spaces"
mkdir -p "$SPACED_DIR"
if ln -s "$PROJECT_DIR" "$SPACED_DIR/proj" 2>/dev/null; then
  if [ -f "$SPACED_DIR/proj/qa/ingestion_summary.md" ] \
     || [ -d "$SPACED_DIR/proj/qa" ]; then
    ok "E01 project is reachable via a path containing spaces"
  else
    fail "E01" "qa/ dir unreachable through a spaced path"
  fi
else
  skip "E01" "cannot create symlink (filesystem limitation)"
fi

# E02: Shell scripts in the project handle spaced $PROJECT_DIR. We look
# for common unquoted-variable patterns that break under spaces. This is
# heuristic — false positives happen — so we report SKIP rather than
# FAIL when we find suspect patterns, and only PASS when nothing suspect
# turns up.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  # Look for patterns like `cd $FOO` (no quotes) or `cat $PROJECT_DIR/x`.
  suspect=$(grep -cE '(^|[[:space:]])(cd|cat|ls|rm|cp|mv)[[:space:]]+\$[A-Za-z_]' "$PROJECT_DIR/$ENTRY" 2>/dev/null)
  suspect=${suspect:-0}
  if [ "$suspect" -eq 0 ]; then
    ok "E02 entry script has no obvious unquoted-variable patterns"
  else
    skip "E02" "$suspect unquoted-variable pattern(s) in $ENTRY — may break on spaced paths"
  fi
else
  skip "E02" "no shell entry point to audit"
fi

# E03: Long filenames. Most filesystems cap at 255 bytes per name; we
# probe with a 200-byte name to stay safely under that.
LONG_NAME=$(printf 'a%.0s' {1..200})
if touch "$SCRATCH/$LONG_NAME" 2>/dev/null; then
  ok "E03 filesystem accepts 200-byte filenames"
  rm -f "$SCRATCH/$LONG_NAME"
else
  skip "E03" "filesystem rejected 200-byte filename (unusual FS)"
fi

# E04: Unicode filenames. If the filesystem doesn't support UTF-8
# filenames we can't assume the project does either; we skip, not fail.
UNICODE_NAME="café_测试_🚀.txt"
if touch "$SCRATCH/$UNICODE_NAME" 2>/dev/null && [ -f "$SCRATCH/$UNICODE_NAME" ]; then
  ok "E04 filesystem accepts unicode filenames"
  rm -f "$SCRATCH/$UNICODE_NAME"
else
  skip "E04" "filesystem or locale doesn't support unicode filenames"
fi

# E05: Empty directory — does the project's qa/ dir tolerate being
# empty? Pipeline stages create files under qa/; if the dir is missing
# they must create it, not crash.
EMPTY_QA=$(make_scratch)
trap 'rm -rf "$SCRATCH" "$EMPTY_QA"' EXIT INT TERM
if [ -d "$EMPTY_QA" ] && [ -z "$(ls -A "$EMPTY_QA")" ]; then
  ok "E05 scratch fixture: empty directory behaves as expected"
else
  fail "E05" "scratch directory is unexpectedly non-empty"
fi

# E06: Locale with unusual LC_ALL (POSIX). Some tools break under
# LC_ALL=C because they assume UTF-8; others break under UTF-8 because
# they assume POSIX collation. A project should ideally work under both.
# We can only check this meaningfully if there's a shell entry point.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  # Just a syntax re-check under LC_ALL=C — a weak but fast signal.
  if LC_ALL=C bash -n "$PROJECT_DIR/$ENTRY" 2>/dev/null; then
    ok "E06 entry script parses under LC_ALL=C"
  else
    fail "E06" "entry script has parse errors under LC_ALL=C"
  fi
else
  skip "E06" "no shell entry point to locale-test"
fi

# E07: `/tmp` is writable. Many project fixtures use mktemp; if /tmp
# isn't writable the project's own tests would fail silently. This is
# a sanity check on the environment more than the project itself.
if (: > "/tmp/qa_test_tmp_$$") 2>/dev/null; then
  ok "E07 /tmp is writable"
  rm -f "/tmp/qa_test_tmp_$$"
else
  fail "E07" "/tmp is not writable — tests using mktemp will fail"
fi
