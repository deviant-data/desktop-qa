#!/bin/bash
# 04_report.sh — Stage 5 report generation
#
# Reads the three artifacts produced by Stages 1–4:
#
#   - $PROJECT_DIR/qa/ingestion_summary.md   (from 00_ingestion.sh)
#   - $PROJECT_DIR/qa/qa_plan.md             (from 02_qa_plan.sh)
#   - $PROJECT_DIR/qa/test_log.txt           (from 01_environment.sh + 03_test_execution.sh)
#
# …and emits $PROJECT_DIR/qa/qa_report.md. The earlier stage scripts write
# structured, grep-friendly markers (`=== ENVIRONMENT SUMMARY ===`,
# `=== TEST BATCH N — category ===`, `--- FAILURE DETAIL: ... ---`, etc.);
# this script locks onto those markers rather than trying to fuzzy-match prose.
#
# Read each input file ONCE, extract the facts needed, close the file.
# No speculative re-reads.
#
# Usage:
#   bash 04_report.sh /path/to/project
#
# Exit codes:
#   0  report written
#   1  usage error / bad project path
#   2  prerequisite artifact missing (run earlier stages first)
#   3  cannot write output
#   5  unsupported bash version (requires bash 4+)

# --- Bash version guard --------------------------------------------------
# Matches the pattern in 00/01/02/03. We use associative arrays to bucket
# per-category counts parsed from test_log.txt, and process-substitution
# (`<(...)`) to stream file sections through awk. Both are bash 4+.
#
# Exit 5 is used here (distinct from 3 in 00 and 4 in 01/02/03) so an
# operator running the full pipeline can tell which stage hit the guard.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: bash 4+ required (found: ${BASH_VERSION:-unknown})." >&2
  echo "  On macOS the system bash is 3.2. Install a newer bash with:" >&2
  echo "    brew install bash" >&2
  echo "  Then invoke this script with the newer bash, e.g.:" >&2
  echo "    /opt/homebrew/bin/bash 04_report.sh /path/to/project" >&2
  exit 5
fi

set -u
# Not `set -e`: if one parse heuristic returns empty (e.g. no Failed tests
# section in a clean run), that's a valid state — we still want to emit
# the report, just with an empty section. Failing fast here would hide
# successful runs.

# --- Argument parsing ----------------------------------------------------
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash 04_report.sh /path/to/project" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory." >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QA_DIR="$PROJECT_DIR/qa"
INGESTION_FILE="$QA_DIR/ingestion_summary.md"
PLAN_FILE="$QA_DIR/qa_plan.md"
LOG_FILE="$QA_DIR/test_log.txt"
OUT_FILE="$QA_DIR/qa_report.md"

# Stage 5 needs at minimum the test log — every other artifact is optional
# (we'll degrade the relevant sections if they're missing). The log is
# mandatory because without it there are literally no results to report.
#
# Ingestion and plan files are *strongly* expected but not strictly fatal:
# an operator might want a report from a partial run. We warn on missing
# non-log inputs rather than abort — the pipeline's ground rule is that
# a report must always be produced.
if [ ! -f "$LOG_FILE" ]; then
  echo "Error: $LOG_FILE not found. Run 01_environment.sh and 03_test_execution.sh first." >&2
  exit 2
fi

missing_notes=""
if [ ! -f "$INGESTION_FILE" ]; then
  echo "Warning: $INGESTION_FILE not found; ingestion-derived sections will be blank." >&2
  missing_notes="${missing_notes}ingestion_summary.md missing; "
fi
if [ ! -f "$PLAN_FILE" ]; then
  echo "Warning: $PLAN_FILE not found; planned counts will fall back to executed counts." >&2
  missing_notes="${missing_notes}qa_plan.md missing; "
fi

mkdir -p "$QA_DIR" || { echo "Error: cannot create $QA_DIR" >&2; exit 3; }

# --- Project identity ---------------------------------------------------
# The project "name" for the report. Prefer package.json's "name" field,
# then fall back to directory basename. Kept cheap — one grep, no jq.
PROJECT_NAME=$(basename "$PROJECT_DIR")
if [ -f "$PROJECT_DIR/package.json" ]; then
  pkg_name=$(grep -E '"name"[[:space:]]*:' "$PROJECT_DIR/package.json" 2>/dev/null \
              | head -n1 \
              | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  [ -n "$pkg_name" ] && PROJECT_NAME="$pkg_name"
fi

RUN_DATE=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

# --- Environment section extraction -------------------------------------
# The `=== ENVIRONMENT SUMMARY ===` block in test_log.txt is emitted by
# 01_environment.sh in a fixed order. We pull the canonical values with
# anchored greps so noise elsewhere in the log can't contaminate them.
#
# If the pipeline has been re-run in the same project, the log may contain
# multiple ENVIRONMENT SUMMARY blocks. The LAST one is the most recent run
# — that's what we want, so each extraction uses `tail -n1`.

extract_env_field() {
  local field="$1"
  # Anchor on field name at line start to avoid matching e.g. "Install
  # result" inside a free-form note. Read-once: the whole LOG_FILE is
  # streamed through one awk; individual grep calls below stay bounded
  # because the file is small relative to the context.
  awk -v f="$field" '
    /^=== ENVIRONMENT SUMMARY ===$/ { in_block = 1; next }
    /^==========================$/  { in_block = 0; next }
    in_block && $0 ~ "^"f":" {
      sub("^"f":[[:space:]]*", "")
      value = $0
    }
    END { if (value != "") print value }
  ' "$LOG_FILE" 2>/dev/null | tail -n1
}

# Walk the log once and collect the fields. If there are multiple blocks,
# the awk's END only prints the final value it saw, which is exactly the
# most-recent-run behaviour we want.
ENV_RUNTIME=$(extract_env_field "Runtime")
ENV_INSTALL=$(extract_env_field "Install result")
ENV_BUILD=$(extract_env_field "Build result")
ENV_STARTUP=$(extract_env_field "Startup result")
ENV_APP_URL=$(extract_env_field "App available at")
ENV_NOTES=$(extract_env_field "Notes")

# Default empties to "(not recorded)" so the markdown table doesn't have
# blank cells that could be mistaken for a template placeholder.
: "${ENV_RUNTIME:=(not recorded)}"
: "${ENV_INSTALL:=(not recorded)}"
: "${ENV_BUILD:=(not recorded)}"
: "${ENV_STARTUP:=(not recorded)}"
: "${ENV_APP_URL:=n/a}"
: "${ENV_NOTES:=none}"

# --- Test results extraction --------------------------------------------
# 03_test_execution.sh writes one "=== TEST BATCH N — category ===" block
# per category, followed by a final "=== TEST EXECUTION SUMMARY ===" block.
# We parse per-category results from the batch blocks because the final
# summary doesn't carry per-category sub-test numbers in a grep-friendly
# format — the batch blocks do.
#
# Counter tables: one entry per canonical category. "Planned" comes from
# qa_plan.md (separately); "passed/failed/skipped/flaky" come from the log.

declare -A CAT_PLANNED=()
declare -A CAT_PASSED=()
declare -A CAT_FAILED=()
declare -A CAT_SKIPPED=()
declare -A CAT_FLAKY=()

# Sub-test counts — the "real" assertion numbers parsed out of each test's
# own `PASS:`/`FAIL:` output. The pipeline v3 report collapsed ~118 real
# assertions into 16 file-verdicts; tracking both here restores the full
# picture. We report sub-test numbers as the primary column in the summary
# table (they're what developers actually want to see) and include the
# file counts as a secondary annotation.
declare -A CAT_SUB_PASSED=()
declare -A CAT_SUB_FAILED=()
declare -A CAT_SUB_SKIPPED=()

for cat in unit integration api edge negative regression; do
  CAT_PLANNED[$cat]=0
  CAT_PASSED[$cat]=0
  CAT_FAILED[$cat]=0
  CAT_SKIPPED[$cat]=0
  CAT_FLAKY[$cat]=0
  CAT_SUB_PASSED[$cat]=0
  CAT_SUB_FAILED[$cat]=0
  CAT_SUB_SKIPPED[$cat]=0
done

# Parse each TEST BATCH block. If the pipeline ran more than once in the
# same project, multiple blocks per category will exist; we take the LAST
# value we see (most-recent run), which is what the stage 4 summary does.
#
# Block shape (from 03_test_execution.sh):
#   === TEST BATCH N — <category> ===
#   Files run: X
#   PASS (files): X
#   FAIL (files): X
#   SKIP (files): X
#   FLAKY (files): X
#   Sub-tests: X
#   PASS (sub-tests): X
#   FAIL (sub-tests): X
#   SKIP (sub-tests): X
#
# The em-dash (—) is U+2014, not a regular hyphen — we match it literally.
parse_batches() {
  awk '
    /^=== TEST BATCH [0-9]+ — .+ ===$/ {
      # Extract category: everything after the em-dash, before " ==="
      line = $0
      sub(/^=== TEST BATCH [0-9]+ — /, "", line)
      sub(/ ===$/, "", line)
      current = tolower(line)
      next
    }
    current == "" { next }
    /^PASS \(files\):/        { sub(/^PASS \(files\):[[:space:]]*/, "");        print current"\tpass\t"$0 }
    /^FAIL \(files\):/        { sub(/^FAIL \(files\):[[:space:]]*/, "");        print current"\tfail\t"$0 }
    /^SKIP \(files\):/        { sub(/^SKIP \(files\):[[:space:]]*/, "");        print current"\tskip\t"$0 }
    /^FLAKY \(files\):/       { sub(/^FLAKY \(files\):[[:space:]]*/, "");       print current"\tflaky\t"$0 }
    /^PASS \(sub-tests\):/    { sub(/^PASS \(sub-tests\):[[:space:]]*/, "");    print current"\tsub_pass\t"$0 }
    /^FAIL \(sub-tests\):/    { sub(/^FAIL \(sub-tests\):[[:space:]]*/, "");    print current"\tsub_fail\t"$0 }
    /^SKIP \(sub-tests\):/    { sub(/^SKIP \(sub-tests\):[[:space:]]*/, "");    print current"\tsub_skip\t"$0 }
    # Blank line ends a block for our purposes — resets current so values
    # from a following narrative section cannot leak in.
    /^$/                      { current = "" }
  ' "$LOG_FILE"
}

while IFS=$'\t' read -r cat field value; do
  [ -z "$cat" ] && continue
  # Guard against unexpected categories in the log (defensive — our own
  # writer only emits the six canonical ones).
  case "$cat" in
    unit|integration|api|edge|negative|regression) ;;
    *) continue ;;
  esac
  # Normalise: values should be pure integers; strip anything weird.
  value="${value//[^0-9]/}"
  [ -z "$value" ] && value=0
  case "$field" in
    pass)     CAT_PASSED[$cat]=$value ;;
    fail)     CAT_FAILED[$cat]=$value ;;
    skip)     CAT_SKIPPED[$cat]=$value ;;
    flaky)    CAT_FLAKY[$cat]=$value ;;
    sub_pass) CAT_SUB_PASSED[$cat]=$value ;;
    sub_fail) CAT_SUB_FAILED[$cat]=$value ;;
    sub_skip) CAT_SUB_SKIPPED[$cat]=$value ;;
  esac
done < <(parse_batches)

# --- Planned counts from qa_plan.md -------------------------------------
# 02_qa_plan.sh emits one markdown section per category:
#   ## Unit Tests
#   ## Integration Tests
#   ## API Tests
#   ## Edge Cases
#   ## Negative Tests
#   ## Regression Anchors
# Each is followed by a table whose data rows start with `| U01 |`, `| I01 |`,
# etc. Counting ID prefixes is the most robust way to get the planned count
# — it ignores the header row, the separator row, and the occasional
# "(none planned)" placeholder (which uses e.g. `U00` and so still increments
# the count by 1, accurately reflecting "the plan listed one row, even if
# it was an empty placeholder"). We don't try to special-case "(none
# planned)" because the human reader will see it in the plan anyway and
# because miscounting by 1 is strictly less bad than misclassifying.
#
# Also read: the `## Total planned tests: N` line if present, as a fallback
# when individual prefixes can't be counted.
if [ -f "$PLAN_FILE" ]; then
  # Fallback total — may be used only if we fail to extract any per-category
  # numbers (very defensive; our own plan writer always emits both).
  PLAN_TOTAL_FALLBACK=$(grep -E '^## Total planned tests:' "$PLAN_FILE" 2>/dev/null \
                        | head -n1 | sed -E 's/^## Total planned tests:[[:space:]]*//')
  PLAN_TOTAL_FALLBACK="${PLAN_TOTAL_FALLBACK//[^0-9]/}"

  count_prefix() {
    local prefix="$1"
    # Anchor on a pipe, optional space, prefix, two digits, space, pipe —
    # this matches table rows only (`| U01 | ... |`) and excludes the
    # header row (`| ID | Description | ... |`) which has no digit suffix.
    grep -cE "^\|[[:space:]]*${prefix}[0-9]{2}[[:space:]]*\|" "$PLAN_FILE" 2>/dev/null || echo 0
  }

  CAT_PLANNED[unit]=$(count_prefix U)
  CAT_PLANNED[integration]=$(count_prefix I)
  CAT_PLANNED[api]=$(count_prefix A)
  CAT_PLANNED[edge]=$(count_prefix E)
  CAT_PLANNED[negative]=$(count_prefix N)
  CAT_PLANNED[regression]=$(count_prefix R)
fi

# --- Failures & bugs ----------------------------------------------------
# Extract failure records for the "Bugs Found" section. Two sources:
#
#   1. Per-batch "Failed tests:" lines: `- [VERDICT] path: reason`
#   2. "--- FAILURE DETAIL: path (VERDICT) ---" blocks with last 40 lines
#      of captured test output.
#
# (1) gives us a clean one-liner per failure with a reason. (2) gives
# reproduction context. We use (1) as the primary record and attach the
# tail of (2) as a short excerpt for each bug.
#
# If the pipeline was re-run, duplicate records exist. We keep the LAST
# occurrence of each unique (category,path) pair — same policy as the
# per-category counts.

# Temp file for parsed failures: one tab-separated record per line.
#   category \t relpath \t verdict \t reason
FAIL_RECORDS=$(mktemp)
trap 'rm -f "$FAIL_RECORDS"' EXIT

awk '
  /^=== TEST BATCH [0-9]+ — .+ ===$/ {
    line = $0
    sub(/^=== TEST BATCH [0-9]+ — /, "", line)
    sub(/ ===$/, "", line)
    current = tolower(line)
    in_failed = 0
    next
  }
  /^Failed tests:$/      { in_failed = 1; next }
  /^Bugs found:$/        { in_failed = 0; next }
  /^$/                   { in_failed = 0; current_ok = 0 }
  in_failed && current != "" && /^- / {
    # Record shape: "- [VERDICT] path: reason"
    # Skip the "(none)" placeholder.
    if ($0 ~ /^- \(none\)$/) next
    line = $0
    sub(/^- /, "", line)
    # Parse "[VERDICT] rest"
    verdict = ""
    if (match(line, /^\[[A-Z]+\] /)) {
      verdict = substr(line, 2, RLENGTH - 3)
      line = substr(line, RLENGTH + 1)
    }
    # Split into path and reason at the FIRST ": " — reasons can contain
    # colons (error strings often do), so anchoring on the first match
    # preserves the full reason text.
    idx = index(line, ": ")
    if (idx > 0) {
      path = substr(line, 1, idx - 1)
      reason = substr(line, idx + 2)
    } else {
      path = line
      reason = ""
    }
    # Tab-separate for the shell side. Strip any tabs from the fields
    # themselves so the join round-trips cleanly.
    gsub(/\t/, " ", path)
    gsub(/\t/, " ", reason)
    gsub(/\t/, " ", verdict)
    printf "%s\t%s\t%s\t%s\n", current, path, verdict, reason
  }
' "$LOG_FILE" > "$FAIL_RECORDS"

# Dedupe: keep the LAST record per (category,path) pair. Also keep a
# stable ordering — insertion order by first appearance — so the report
# lists bugs in the order they were encountered during the run.
#
# Implementation: two-pass. Pass 1 discovers the last-value for each key.
# Pass 2 walks the file again and emits each key on its first sighting,
# using the stored last-value.

declare -A LAST_VERDICT=()
declare -A LAST_REASON=()
declare -a BUG_KEYS=()
declare -A SEEN_KEY=()

while IFS=$'\t' read -r cat path verdict reason; do
  [ -z "$cat" ] && continue
  key="${cat}::${path}"
  LAST_VERDICT[$key]="$verdict"
  LAST_REASON[$key]="$reason"
done < "$FAIL_RECORDS"

while IFS=$'\t' read -r cat path verdict reason; do
  [ -z "$cat" ] && continue
  key="${cat}::${path}"
  if [ -z "${SEEN_KEY[$key]:-}" ]; then
    SEEN_KEY[$key]=1
    BUG_KEYS+=("$key")
  fi
done < "$FAIL_RECORDS"

# --- Flaky test list ----------------------------------------------------
# The FLAKY verdict shows up in the same "Failed tests:" section in
# 03_test_execution.sh (flakiness counts as a failure for exit-pressure
# purposes). Surface those as a separate list so the report can
# call them out explicitly.
declare -a FLAKY_KEYS=()
for key in "${BUG_KEYS[@]}"; do
  if [ "${LAST_VERDICT[$key]:-}" = "FLAKY" ]; then
    FLAKY_KEYS+=("$key")
  fi
done

# --- Failure detail excerpts --------------------------------------------
# For each bug, extract a short excerpt from the most recent FAILURE
# DETAIL block. We use awk to slice out the block bounded by
#   --- FAILURE DETAIL: <path> (<verdict>) ---
# and
#   --- end failure detail ---
# keeping at most the last 12 lines of captured output. 12 lines is
# enough for a stack trace or assertion failure to be readable, short
# enough not to drown the report.

get_failure_excerpt() {
  local target_path="$1"
  # awk is safer than sed here because the path may contain regex
  # metacharacters (parentheses, dots, plus signs). We pass the path as
  # a literal variable and use `index()` for matching.
  awk -v want="$target_path" '
    /^--- FAILURE DETAIL: / {
      # Extract path from between "FAILURE DETAIL: " and " (VERDICT) ---"
      line = $0
      sub(/^--- FAILURE DETAIL: /, "", line)
      sub(/ \([A-Z]+\) ---$/, "", line)
      if (line == want) {
        in_block = 1
        buf = ""
        next
      }
    }
    /^--- end failure detail ---$/ {
      if (in_block) {
        # Keep only the captured output section — skip the "command:",
        # "attempts:", "last 40 lines of output:" headers the writer adds.
        # Simplest reliable approach: emit the whole buf; the caller
        # trims to a line budget.
        final = buf
        in_block = 0
      }
      next
    }
    in_block {
      # Skip the FAILURE DETAIL header lines; we only want the captured
      # stdout/stderr from the test.
      if ($0 ~ /^command:/) next
      if ($0 ~ /^attempts:/) next
      if ($0 ~ /^last 40 lines of output:$/) next
      buf = buf $0 "\n"
    }
    END {
      if (final != "") printf "%s", final
    }
  ' "$LOG_FILE" | tail -n 12
}

# --- Recommendation heuristics ------------------------------------------
# The report asks for a prioritised list of actions. We derive it from the
# concrete signals we have — failures, flakiness, skipped categories, env
# issues — rather than generating prose that might not match the data.

build_recommendations() {
  local -a recs=()
  local total_failed=0 total_flaky=0 total_skipped=0 total_passed=0
  for cat in unit integration api edge negative regression; do
    total_failed=$((  total_failed  + ${CAT_SUB_FAILED[$cat]:-0}  ))
    total_flaky=$((   total_flaky   + ${CAT_FLAKY[$cat]:-0}       ))
    total_skipped=$(( total_skipped + ${CAT_SUB_SKIPPED[$cat]:-0} ))
    total_passed=$((  total_passed  + ${CAT_SUB_PASSED[$cat]:-0}  ))
  done

  # Environment signals first — if install/build/startup failed, testing
  # was necessarily partial and fixing that unblocks everything else.
  case "${ENV_INSTALL,,}" in
    failed|partial)
      recs+=("Resolve dependency installation issues (status: ${ENV_INSTALL}). Test coverage is likely incomplete until the environment installs cleanly.")
      ;;
  esac
  case "${ENV_BUILD,,}" in
    failed)
      recs+=("Fix the build failure reported in Stage 2. Integration and API tests cannot be trusted against an unbuilt project.")
      ;;
  esac
  case "${ENV_STARTUP,,}" in
    failed)
      recs+=("Diagnose the startup failure. Any API/integration test verdicts against a non-running app are misleading.")
      ;;
  esac

  # Failures are the next priority.
  if [ "$total_failed" -gt 0 ]; then
    recs+=("Address the ${total_failed} failing sub-test$([ "$total_failed" = 1 ] || echo s) listed under Bugs Found. Start with Critical/High severity before Medium/Low.")
  fi

  # Flakiness is a medium-priority signal: unreliable tests erode trust
  # in the suite faster than outright failures do.
  if [ "$total_flaky" -gt 0 ]; then
    recs+=("Investigate ${total_flaky} flaky test$([ "$total_flaky" = 1 ] || echo s). Flakiness usually indicates timing assumptions, shared-state leakage, or unseeded randomness.")
  fi

  # Skipped categories: worth flagging but rarely top priority.
  if [ "$total_skipped" -gt 0 ]; then
    recs+=("Review ${total_skipped} skipped sub-test$([ "$total_skipped" = 1 ] || echo s) — either enable them or document why skipping is correct for this project.")
  fi

  # Green-run advice.
  if [ "$total_failed" = 0 ] && [ "$total_flaky" = 0 ] && [ "$total_passed" -gt 0 ]; then
    recs+=("All executed tests passed. Consider promoting the regression anchors into a CI workflow so future changes are gated by this suite.")
  fi

  # If we have nothing at all, say so rather than emit an empty list.
  if [ "${#recs[@]}" -eq 0 ]; then
    recs+=("No test results were recorded. Re-run the pipeline with 03_test_execution.sh before drawing conclusions from this report.")
  fi

  local i=1
  for r in "${recs[@]}"; do
    printf '%s. %s\n' "$i" "$r"
    i=$((i + 1))
  done
}

# --- Coverage gaps ------------------------------------------------------
# A category is a "gap" if it has zero executed sub-tests (either because
# the plan had nothing or the executor skipped them all). We emit one
# bullet per gap with the reason we can infer.
build_coverage_gaps() {
  local any=0
  for cat in unit integration api edge negative regression; do
    local planned="${CAT_PLANNED[$cat]:-0}"
    local passed="${CAT_SUB_PASSED[$cat]:-0}"
    local failed="${CAT_SUB_FAILED[$cat]:-0}"
    local skipped="${CAT_SUB_SKIPPED[$cat]:-0}"
    local executed=$(( passed + failed + skipped ))

    if [ "$executed" = 0 ]; then
      if [ "$planned" = 0 ]; then
        printf -- '- **%s**: no tests planned for this category. This may be appropriate for the stack, but is worth confirming.\n' "$cat"
      else
        printf -- '- **%s**: %s test(s) planned but none executed. Likely cause: missing test files under qa/tests/ matching this category'\''s naming convention.\n' "$cat" "$planned"
      fi
      any=1
    fi
  done
  [ "$any" = 0 ] && echo "- None identified: every planned category produced at least one executed sub-test."
}

# --- Executive summary --------------------------------------------------
# Short, factual, lead with the verdict. The report spec says 2–4
# sentences. We build three: overall verdict, most critical finding,
# recommended action.
build_exec_summary() {
  local total_failed=0 total_flaky=0 total_passed=0 total_skipped=0
  for cat in unit integration api edge negative regression; do
    total_failed=$((  total_failed  + ${CAT_SUB_FAILED[$cat]:-0}  ))
    total_flaky=$((   total_flaky   + ${CAT_FLAKY[$cat]:-0}       ))
    total_passed=$((  total_passed  + ${CAT_SUB_PASSED[$cat]:-0}  ))
    total_skipped=$(( total_skipped + ${CAT_SUB_SKIPPED[$cat]:-0} ))
  done
  local total=$((total_passed + total_failed + total_skipped))

  local verdict
  if [ "$total" = 0 ]; then
    verdict="**No results recorded.** The test log contains no per-category batch blocks; either the execution stage did not run or it produced no classifiable output."
  elif [ "$total_failed" = 0 ] && [ "$total_flaky" = 0 ]; then
    verdict="**Healthy.** All ${total_passed} executed sub-tests passed across ${total} total."
  elif [ "$total_failed" = 0 ] && [ "$total_flaky" -gt 0 ]; then
    verdict="**Mostly healthy, with stability concerns.** ${total_passed}/${total} sub-tests passed, but ${total_flaky} test file${total_flaky:+(s)} exhibited flaky behaviour."
  else
    verdict="**Needs attention.** ${total_failed} of ${total} executed sub-tests failed${total_flaky:+, with ${total_flaky} flaky file(s) in addition}."
  fi

  local critical
  if [ "${#BUG_KEYS[@]}" -gt 0 ]; then
    # Use the first bug as the "most critical finding" proxy — it's the
    # first thing a developer will look at, and it's a fact we can cite
    # concretely rather than a prose judgement.
    local first_key="${BUG_KEYS[0]}"
    local first_path="${first_key#*::}"
    local first_reason="${LAST_REASON[$first_key]:-(no reason captured)}"
    critical="The first recorded failure is in \`${first_path}\`: ${first_reason}"
  elif [ "$total_flaky" -gt 0 ]; then
    critical="No hard failures, but flakiness suggests hidden timing or state-leak bugs worth tracking down."
  else
    critical="No blocking findings."
  fi

  local action
  case "${ENV_INSTALL,,}" in
    failed|partial) action="Fix the environment setup issue (install: ${ENV_INSTALL}) first; everything downstream depends on it." ;;
    *)
      if [ "$total_failed" -gt 0 ]; then
        action="Triage the failures listed under Bugs Found and rerun the pipeline."
      elif [ "$total_flaky" -gt 0 ]; then
        action="Reproduce the flaky tests in isolation to identify the root cause."
      elif [ "$total_passed" -gt 0 ]; then
        action="No urgent action required; consider wiring this pipeline into CI."
      else
        action="Re-run the pipeline end-to-end; current results are insufficient to draw a conclusion."
      fi
      ;;
  esac

  echo "$verdict $critical $action"
}

# --- Compose the report -------------------------------------------------
# Atomic write pattern, matching 00/02. Build in a tempfile, then mv into
# place so a crash mid-render never leaves a half-written qa_report.md.

TMP_OUT="$(mktemp)"
# Extend the EXIT trap to clean up both temp files.
trap 'rm -f "$FAIL_RECORDS" "$TMP_OUT"' EXIT

{
  echo "# QA Report"
  echo
  echo "## Project: $PROJECT_NAME"
  echo "## QA Run Date: $RUN_DATE"
  echo "## Tested By: Desktop QA Suite v4 (deterministic bash pipeline)"
  echo
  if [ -n "$missing_notes" ]; then
    echo "_Note: ${missing_notes%; } — the affected sections below are best-effort._"
    echo
  fi
  echo "---"
  echo
  echo "## Executive Summary"
  echo
  build_exec_summary
  echo
  echo "---"
  echo
  echo "## Test Results Summary"
  echo
  echo "Counts below are **sub-tests** — individual assertions parsed from each test file's own \`PASS:\`/\`FAIL:\` output."
  echo "The \"Files\" column shows how many test *files* were executed in each category (each file bundles one or more sub-tests)."
  echo
  echo "| Category       | Planned | Passed | Failed | Skipped | Flaky (files) | Files run |"
  echo "|----------------|---------|--------|--------|---------|---------------|-----------|"

  # Totals row accumulators.
  t_planned=0; t_passed=0; t_failed=0; t_skipped=0; t_flaky=0; t_files=0

  # Display category names with the capitalisation the spec uses.
  # Associative array pairing would be cleaner, but a simple case preserves
  # deterministic ordering without relying on iteration-order guarantees.
  for cat in unit integration api edge negative regression; do
    case "$cat" in
      unit)        label="Unit" ;;
      integration) label="Integration" ;;
      api)         label="API" ;;
      edge)        label="Edge Cases" ;;
      negative)    label="Negative" ;;
      regression)  label="Regression" ;;
    esac
    planned="${CAT_PLANNED[$cat]:-0}"
    passed="${CAT_SUB_PASSED[$cat]:-0}"
    failed="${CAT_SUB_FAILED[$cat]:-0}"
    skipped="${CAT_SUB_SKIPPED[$cat]:-0}"
    flaky="${CAT_FLAKY[$cat]:-0}"
    files_run=$((  ${CAT_PASSED[$cat]:-0} + ${CAT_FAILED[$cat]:-0} + ${CAT_SKIPPED[$cat]:-0} ))

    t_planned=$(( t_planned + planned ))
    t_passed=$((  t_passed  + passed  ))
    t_failed=$((  t_failed  + failed  ))
    t_skipped=$(( t_skipped + skipped ))
    t_flaky=$((   t_flaky   + flaky   ))
    t_files=$((   t_files   + files_run ))

    printf '| %-14s | %7s | %6s | %6s | %7s | %13s | %9s |\n' \
      "$label" "$planned" "$passed" "$failed" "$skipped" "$flaky" "$files_run"
  done
  printf '| **TOTAL**      | %7s | %6s | %6s | %7s | %13s | %9s |\n' \
    "$t_planned" "$t_passed" "$t_failed" "$t_skipped" "$t_flaky" "$t_files"
  echo
  echo "---"
  echo
  echo "## Bugs Found"
  echo
  if [ "${#BUG_KEYS[@]}" -eq 0 ]; then
    echo "_No confirmed bugs in this run._"
    echo
  else
    bug_num=1
    for key in "${BUG_KEYS[@]}"; do
      # Skip pure FLAKY entries here — they get their own section below.
      # A file that both flaked and ultimately failed will still be listed
      # as a bug (verdict is FAIL, not FLAKY) — only report as flaky-only
      # when the verdict is specifically FLAKY.
      verdict="${LAST_VERDICT[$key]:-FAIL}"
      if [ "$verdict" = "FLAKY" ]; then
        continue
      fi

      cat_part="${key%%::*}"
      path_part="${key#*::}"
      reason="${LAST_REASON[$key]:-(no reason captured)}"

      # Severity heuristic — we only have the category and the reason
      # string, so this is coarse-grained. Integration/API failures
      # usually affect real users directly; unit failures are often
      # implementation details. We don't invent severity we can't
      # defend from the data.
      case "$cat_part" in
        integration|api|regression) severity="High" ;;
        edge|negative)              severity="Medium" ;;
        unit)                       severity="Medium" ;;
        *)                          severity="Unknown" ;;
      esac
      # Upgrade to Critical if the reason looks like a crash/panic/trace.
      case "${reason,,}" in
        *"segfault"*|*"segmentation fault"*|*"panic"*|*"traceback"*|*"stack overflow"*|*"out of memory"*)
          severity="Critical"
          ;;
      esac

      # Short title: basename of the path, humanised lightly.
      title=$(basename "$path_part")
      printf '### [BUG-%03d] %s\n' "$bug_num" "$title"
      echo "- **Severity:** $severity"
      echo "- **Category:** $cat_part"
      echo "- **Test file:** \`$path_part\`"
      echo "- **Description:** The test failed with the reason below. Whether this is a project bug or a test bug requires source-level review."
      echo "- **Reason captured:** $reason"
      echo "- **Steps to reproduce:** from \`$PROJECT_DIR\`, run \`bash $path_part\` (or the appropriate runner for the file's extension)."
      echo

      # Attach an excerpt from the captured output if available.
      excerpt=$(get_failure_excerpt "$path_part")
      if [ -n "$excerpt" ]; then
        echo "<details><summary>Captured output (last 12 lines)</summary>"
        echo
        echo '```'
        echo "$excerpt"
        echo '```'
        echo
        echo "</details>"
        echo
      fi

      bug_num=$((bug_num + 1))
    done

    if [ "$bug_num" = 1 ]; then
      echo "_No non-flaky failures in this run (any flaky results are listed below)._"
      echo
    fi
  fi
  echo "---"
  echo
  echo "## Flaky Tests"
  echo
  if [ "${#FLAKY_KEYS[@]}" -eq 0 ]; then
    echo "_No flaky tests detected._"
  else
    for key in "${FLAKY_KEYS[@]}"; do
      path_part="${key#*::}"
      reason="${LAST_REASON[$key]:-(no reason captured)}"
      echo "- \`$path_part\` — probable cause: ${reason}. Flaky tests typically point to timing assumptions, unseeded randomness, or shared-state bleed between tests."
    done
  fi
  echo
  echo "---"
  echo
  echo "## Coverage Gaps"
  echo
  build_coverage_gaps
  echo
  echo "---"
  echo
  echo "## Recommendations"
  echo
  build_recommendations
  echo
  echo "---"
  echo
  echo "## Environment Notes"
  echo
  echo "- **Runtime:** ${ENV_RUNTIME}"
  echo "- **Install result:** ${ENV_INSTALL}"
  echo "- **Build result:** ${ENV_BUILD}"
  echo "- **Startup result:** ${ENV_STARTUP}"
  echo "- **App available at:** ${ENV_APP_URL}"
  echo "- **Notes:** ${ENV_NOTES}"
  echo
  echo "---"
  echo
  echo "## Files Produced"
  echo
  echo "| File | Description |"
  echo "|---|---|"
  echo "| \`qa/ingestion_summary.md\` | Stage 1 project ingestion summary |"
  echo "| \`qa/qa_plan.md\` | Full QA plan (Stage 3) |"
  echo "| \`qa/test_log.txt\` | Raw test output (Stages 2 + 4) |"
  echo "| \`qa/qa_report.md\` | This report |"
  echo
} > "$TMP_OUT"

mv "$TMP_OUT" "$OUT_FILE" || { echo "Error: cannot write $OUT_FILE" >&2; exit 3; }
# Clear the TMP_OUT half of the trap (FAIL_RECORDS still needs cleaning).
trap 'rm -f "$FAIL_RECORDS"' EXIT

echo "Wrote $OUT_FILE"
echo "QA RUN COMPLETE. Report available at $OUT_FILE"
