#!/bin/bash
# 03_test_execution.sh — Stage 4 test execution
#
# This stage does NOT write new tests. It discovers the tests already present
# under $PROJECT_DIR/qa/tests/ (written by the operator or by a prior run),
# classifies them by the project's naming convention, executes each category
# in the documented order, and appends actionable results to
# $PROJECT_DIR/qa/test_log.txt. Pure bash — no AI.
#
# "Actionable" means Stage 5 (report) can grep the log for PASS/FAIL counts,
# category headers, and failure reasons without heuristics. The log format
# matches 03_test_execution.md exactly.
#
# Usage:
#   bash 03_test_execution.sh /path/to/project
#
# Exit codes:
#   0  execution complete (may include test failures — those are logged, not
#      fatal; the pipeline continues to Stage 5)
#   1  usage error / bad project path
#   2  prerequisites missing (ingestion, plan, or qa/tests dir)
#   3  cannot write log file
#   4  unsupported bash version (requires bash 4+)

# --- Bash version guard --------------------------------------------------
# Matches 00/01/02. We use associative arrays (`declare -A`) for per-category
# counters and for the flaky-test retry map. macOS /bin/bash is 3.2; running
# earlier stages on bash 4+ and this stage on 3.2 would silently diverge.
# See BUG-001 in the project QA history.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: bash 4+ required (found: ${BASH_VERSION:-unknown})." >&2
  echo "  On macOS the system bash is 3.2. Install a newer bash with:" >&2
  echo "    brew install bash" >&2
  echo "  Then invoke this script with the newer bash, e.g.:" >&2
  echo "    /opt/homebrew/bin/bash 03_test_execution.sh /path/to/project" >&2
  exit 4
fi

set -u
# Intentionally not `set -e`: a failing test is expected output, not a fatal
# script error. Each test's exit code is captured explicitly and classified.

# --- Argument parsing ----------------------------------------------------
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash 03_test_execution.sh /path/to/project" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory." >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QA_DIR="$PROJECT_DIR/qa"
TESTS_DIR="$QA_DIR/tests"
LOG_FILE="$QA_DIR/test_log.txt"
PLAN_FILE="$QA_DIR/qa_plan.md"
INGESTION_FILE="$QA_DIR/ingestion_summary.md"

# Prerequisite: Stages 1 and 3 must have run. Stage 2 produces test_log.txt
# which we append to, but we create it if missing — a user might legitimately
# want to run execution in isolation after manually bootstrapping the env.
if [ ! -f "$INGESTION_FILE" ]; then
  echo "Error: $INGESTION_FILE not found. Run 00_ingestion.sh first." >&2
  exit 2
fi
if [ ! -f "$PLAN_FILE" ]; then
  echo "Error: $PLAN_FILE not found. Run 02_qa_plan.sh first." >&2
  exit 2
fi
if [ ! -d "$TESTS_DIR" ]; then
  echo "Error: $TESTS_DIR does not exist. No tests to execute." >&2
  echo "  (This stage runs existing tests; it does not create new ones.)" >&2
  exit 2
fi

mkdir -p "$QA_DIR" || { echo "Error: cannot create $QA_DIR" >&2; exit 3; }
touch "$LOG_FILE" 2>/dev/null || { echo "Error: cannot write $LOG_FILE" >&2; exit 3; }

# Export PROJECT_DIR so tests that follow the documented portability pattern
# (`if [ -z "$PROJECT_DIR" ]; then ... fi`) can pick it up directly. This is
# the same contract 03_test_execution.md asks test authors to honour.
export PROJECT_DIR

# --- Logging primitives --------------------------------------------------
# Route all logging through log() so stdout and the log file stay in sync.
# Stage 5 greps the log for fixed markers; keep spelling and order stable.

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

# Append-only writer for blocks that should NOT echo to stdout (e.g. full
# captured output from a failing test — it's already summarised live).
log_raw() {
  printf '%s\n' "$@" >> "$LOG_FILE"
}

# --- Header --------------------------------------------------------------
{
  echo ""
  echo "=== TEST EXECUTION ==="
  echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Project: $PROJECT_DIR"
  echo "Tests dir: $TESTS_DIR"
} >> "$LOG_FILE"

log ""
log "Desktop QA — Stage 4: Test Execution"
log "Project: $PROJECT_DIR"
log ""

# --- Test framework resolution ------------------------------------------
# We support BOTH naming conventions documented below:
#
#   Dotted (spec default):
#     *.test.[ext]                  → unit
#     *.integration.test.[ext]      → integration
#     *.api.test.[ext]              → api
#     edge_cases.test.[ext]         → edge
#     *.negative.test.[ext]         → negative
#     *.regression.test.[ext]       → regression
#
#   Underscored (Go-style, widely used for shell tests):
#     *_test.[ext]                  → unit
#     *_integration_test.[ext]      → integration
#     *_api_test.[ext]              → api
#     edge_cases_test.[ext], *_edge_test.[ext]       → edge
#     negative_test.[ext], *_negative_test.[ext]     → negative
#     regression_test.[ext], *_regression_test.[ext] → regression
#
# Supported extensions: .sh .bash .py .js .ts .go
# Python also supports test_*.py (pytest discovery default).
#
# For each file we pick a runner based on extension. Shell tests run under
# the *current* bash (which we've already verified is 4+). Python tests
# prefer pytest if present, falling back to the stdlib unittest runner as
# documented in the project's known-practices (no-network environments).
# JS tests run under `node` directly if they look like plain scripts, or
# through the project's configured test command if we can find one. Go
# tests run via `go test`.
#
# We deliberately do NOT install test frameworks here. If pytest isn't on
# the PATH, we fall back to `python3 -m unittest`; if neither works, the
# test is SKIP with a clear reason.

resolve_runner() {
  # Echoes a runner command template where {FILE} is replaced by the path.
  # Returns 1 with empty output if no runner is available.
  local f="$1"
  case "$f" in
    *.sh|*.bash)
      # Use the same bash that's running this script. Guarantees version
      # parity with the version guard — a test that relies on associative
      # arrays won't suddenly fail under /bin/bash.
      echo "bash {FILE}"
      return 0
      ;;
    *.py)
      if command -v pytest >/dev/null 2>&1; then
        # -x stops at first failure within a file; we want the failure
        # detail, not a cascade. Stage 5 cares about which test failed,
        # not how many downstream cases also failed.
        echo "pytest -x --tb=short {FILE}"
        return 0
      fi
      if command -v python3 >/dev/null 2>&1; then
        # Stdlib fallback: run the file as a unittest module. Works for
        # files that end with `unittest.main()` AND for files discoverable
        # by the loader (the `discover` below catches the latter at a
        # directory level, but per-file we just exec it).
        echo "python3 -m unittest {FILE}"
        return 0
      fi
      if command -v python >/dev/null 2>&1; then
        echo "python -m unittest {FILE}"
        return 0
      fi
      return 1
      ;;
    *.js|*.mjs|*.cjs)
      # Prefer a project-configured test runner if package.json exists AND
      # the file lives under the project's declared test dir. But the common
      # QA case is "standalone runnable script" — try node first.
      if command -v node >/dev/null 2>&1; then
        echo "node {FILE}"
        return 0
      fi
      return 1
      ;;
    *.ts|*.tsx)
      if command -v npx >/dev/null 2>&1; then
        # tsx is the most reliable ad-hoc TS runner; falls back to ts-node
        # if the project already depends on it.
        echo "npx --yes tsx {FILE}"
        return 0
      fi
      return 1
      ;;
    *_test.go)
      if command -v go >/dev/null 2>&1; then
        # `go test` needs a package path, not a single file. We handle this
        # in run_test by calling `go test ./...` from the file's directory.
        echo "go-test-dir {FILE}"
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# --- Classification ------------------------------------------------------
# Walk TESTS_DIR once. For each file, assign a category. The order matches
# the spec: unit → integration → api → edge → negative → regression.
# Negative and regression tests don't have dedicated filename conventions;
# we treat any file under a directory named `negative/` or `regression/`
# as that category, falling back to filename-suffix conventions.

declare -a FILES_UNIT=()
declare -a FILES_INTEGRATION=()
declare -a FILES_API=()
declare -a FILES_EDGE=()
declare -a FILES_NEGATIVE=()
declare -a FILES_REGRESSION=()
declare -a FILES_UNCLASSIFIED=()

classify_file() {
  local f="$1"
  local base
  base=$(basename "$f")

  # Directory-based override wins — operators use this to force a category
  # when the filename convention doesn't fit (e.g. a reused fixture).
  case "$f" in
    */regression/*) FILES_REGRESSION+=("$f"); return ;;
    */negative/*)   FILES_NEGATIVE+=("$f"); return ;;
    */integration/*) FILES_INTEGRATION+=("$f"); return ;;
    */api/*)        FILES_API+=("$f"); return ;;
    */edge/*)       FILES_EDGE+=("$f"); return ;;
    */unit/*)       FILES_UNIT+=("$f"); return ;;
  esac

  # --- Phase 1: strict convention matches --------------------------------
  # Dotted (foo.integration.test.sh) and underscored (foo_integration_test.sh)
  # where the category keyword sits directly adjacent to the test marker.
  # Most-specific first — `.integration.test.` must beat the generic `.test.`.
  case "$base" in
    *.integration.test.*)           FILES_INTEGRATION+=("$f"); return ;;
    *.api.test.*)                   FILES_API+=("$f"); return ;;
    edge_cases.test.*|*.edge.test.*) FILES_EDGE+=("$f"); return ;;
    *.negative.test.*)              FILES_NEGATIVE+=("$f"); return ;;
    *.regression.test.*)            FILES_REGRESSION+=("$f"); return ;;
    *_integration_test.sh|*_integration_test.bash|*_integration_test.py|*_integration_test.js|*_integration_test.ts|*_integration_test.go)
                                    FILES_INTEGRATION+=("$f"); return ;;
    *_api_test.sh|*_api_test.bash|*_api_test.py|*_api_test.js|*_api_test.ts|*_api_test.go)
                                    FILES_API+=("$f"); return ;;
    edge_cases_test.sh|edge_cases_test.bash|edge_cases_test.py|edge_cases_test.js|edge_cases_test.ts|edge_cases_test.go|*_edge_test.sh|*_edge_test.bash|*_edge_test.py|*_edge_test.js|*_edge_test.ts|*_edge_test.go)
                                    FILES_EDGE+=("$f"); return ;;
    negative_test.sh|negative_test.bash|negative_test.py|negative_test.js|negative_test.ts|negative_test.go|*_negative_test.sh|*_negative_test.bash|*_negative_test.py|*_negative_test.js|*_negative_test.ts|*_negative_test.go)
                                    FILES_NEGATIVE+=("$f"); return ;;
    regression_test.sh|regression_test.bash|regression_test.py|regression_test.js|regression_test.ts|regression_test.go|*_regression_test.sh|*_regression_test.bash|*_regression_test.py|*_regression_test.js|*_regression_test.ts|*_regression_test.go)
                                    FILES_REGRESSION+=("$f"); return ;;
  esac

  # --- Phase 2: loose keyword match --------------------------------------
  # For filenames that match the generic `*.test.*` or `*_test.*` shape but
  # carry the category keyword somewhere in the filename stem — e.g.
  # `edge_cases_extended.test.sh` or `negative_extended.test.sh`. Without
  # this pass they fall through to the unit catch-all (observed in the
  # v3 run: both files were counted under Unit instead of their intended
  # categories).
  #
  # Strategy: isolate the filename stem (everything before `.test.` or
  # `_test.`) and check whether it contains a category keyword. Order
  # matters here too — we check "integration" before "api" because a file
  # named e.g. `integration_api_test.sh` is more naturally an integration
  # test than an api test.
  local stem="$base"
  if [[ "$base" == *.test.* ]]; then
    stem="${base%%.test.*}"
  elif [[ "$base" == *_test.* ]]; then
    stem="${base%_test.*}"
  elif [[ "$base" == test_* ]]; then
    stem="${base#test_}"
    stem="${stem%.*}"
  fi
  stem_lc=$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')

  case "$base" in
    *.test.*|test_*.py|*_test.py|*_test.go|*_test.js|*_test.ts|*_test.sh|*_test.bash)
      if [[ "$stem_lc" == *integration* ]]; then
        FILES_INTEGRATION+=("$f"); return
      elif [[ "$stem_lc" == *regression* ]]; then
        FILES_REGRESSION+=("$f"); return
      elif [[ "$stem_lc" == *negative* ]]; then
        FILES_NEGATIVE+=("$f"); return
      elif [[ "$stem_lc" == *edge* ]]; then
        FILES_EDGE+=("$f"); return
      elif [[ "$stem_lc" == *api* ]] || [[ "$stem_lc" == *cli* ]]; then
        # "cli" folds into api per the QA plan spec (API table covers CLI).
        FILES_API+=("$f"); return
      fi
      # No keyword match — genuine unit test.
      FILES_UNIT+=("$f"); return
      ;;
  esac

  FILES_UNCLASSIFIED+=("$f")
}

# Find all plausible test files. Keep the traversal bounded — a rogue
# node_modules symlink inside qa/tests/ would otherwise drag in thousands
# of third-party tests. We stay within qa/tests/ and prune nested heavy dirs.
while IFS= read -r -d '' f; do
  [ -f "$f" ] || continue
  classify_file "$f"
done < <(find "$TESTS_DIR" \
            \( -path '*/node_modules' -o -path '*/.git' -o \
               -path '*/__pycache__' -o -path '*/.pytest_cache' -o \
               -path '*/venv' -o -path '*/.venv' \) -prune \
            -o -type f -print0 2>/dev/null)

TOTAL_DISCOVERED=$(( ${#FILES_UNIT[@]} + ${#FILES_INTEGRATION[@]} \
                   + ${#FILES_API[@]}  + ${#FILES_EDGE[@]} \
                   + ${#FILES_NEGATIVE[@]} + ${#FILES_REGRESSION[@]} ))

log "Discovered test files: $TOTAL_DISCOVERED"
log "  unit:        ${#FILES_UNIT[@]}"
log "  integration: ${#FILES_INTEGRATION[@]}"
log "  api:         ${#FILES_API[@]}"
log "  edge:        ${#FILES_EDGE[@]}"
log "  negative:    ${#FILES_NEGATIVE[@]}"
log "  regression:  ${#FILES_REGRESSION[@]}"
if [ "${#FILES_UNCLASSIFIED[@]}" -gt 0 ]; then
  log "  uncategorised (skipped): ${#FILES_UNCLASSIFIED[@]}"
  for u in "${FILES_UNCLASSIFIED[@]}"; do
    log "    - ${u#$PROJECT_DIR/}"
  done
fi
log ""

if [ "$TOTAL_DISCOVERED" = 0 ]; then
  log "No classified test files under $TESTS_DIR. Nothing to execute."
  {
    echo ""
    echo "=== TEST EXECUTION SUMMARY ==="
    echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Files discovered: 0"
    echo "Per-file:      PASS 0 | FAIL 0 | SKIP 0 | FLAKY 0"
    echo "Per-sub-test:  PASS 0 | FAIL 0 | SKIP 0"
    echo "=============================="
  } >> "$LOG_FILE"
  log ""
  log "TEST EXECUTION COMPLETE — files: PASS 0 | FAIL 0 | SKIP 0 | FLAKY 0"
  exit 0
fi

# --- Global counters -----------------------------------------------------
# Per-category counters are kept in an associative array so the summary
# table at the end is a single loop, not six parallel blocks.
#
# We track TWO layers of counts:
#   CAT_*     — per-file verdicts (one file = one PASS/FAIL/SKIP/FLAKY).
#               This is the layer the pipeline has always tracked.
#   SUB_*     — per-sub-test counts parsed from each file's own output.
#               Test files follow the project's convention of emitting
#               `PASS: <id> …` / `FAIL: <id> …` lines per assertion and a
#               `=== BATCH SUMMARY ===` block ending with
#               `PASS: N | FAIL: N | SKIP: N`. Each file is effectively a
#               batch containing many sub-tests (e.g. regression_test.sh
#               runs R01–R05). Counting only files collapses ~118 real
#               assertions into 16 results, which is what went wrong in
#               the v3 report. SUB_* restores the true count.
declare -A CAT_TOTAL=()
declare -A CAT_PASS=()
declare -A CAT_FAIL=()
declare -A CAT_SKIP=()
declare -A CAT_FLAKY=()
declare -A SUB_TOTAL=()
declare -A SUB_PASS=()
declare -A SUB_FAIL=()
declare -A SUB_SKIP=()
for cat in unit integration api edge negative regression; do
  CAT_TOTAL[$cat]=0
  CAT_PASS[$cat]=0
  CAT_FAIL[$cat]=0
  CAT_SKIP[$cat]=0
  CAT_FLAKY[$cat]=0
  SUB_TOTAL[$cat]=0
  SUB_PASS[$cat]=0
  SUB_FAIL[$cat]=0
  SUB_SKIP[$cat]=0
done

# Failure records: one entry per failed test, formatted for the spec's
# "Failed tests:" section in each batch summary.
declare -a FAILURES=()
# Bug records: per-category free-form list. The spec differentiates
# "test failure" from "project bug", but at this layer we can't reliably
# tell them apart without re-reading the test. We surface the raw failure
# and let Stage 5 (report) classify with full context.

# --- Sub-test count parser ----------------------------------------------
# Extract sub-test counts from a file's captured output. Tests in this
# project follow a shared convention (see regression_test.sh, run_sh_test.sh,
# etc.):
#   1. Each assertion emits a line starting with `PASS:` or `FAIL:`.
#   2. The file ends with a `=== BATCH SUMMARY ===` block whose last line is
#      `PASS: N | FAIL: N | SKIP: N`.
#
# We prefer (2) when present because the file-authored summary is the
# authoritative count (it may include SKIPs that never print a line). Fall
# back to (1) otherwise. If neither is present — i.e. a foreign test file
# that doesn't follow the convention — we treat the file as a single
# sub-test and defer to the process exit code (0 → 1 pass, nonzero → 1 fail).
#
# Stdout: three integers "<pass> <fail> <skip>" on one line.
parse_batch_summary() {
  local output_file="$1"
  local file_rc="$2"

  # 1. Prefer the structured summary line. `tail -n 5` is enough — the
  #    summary block is always near the end.
  local summary
  summary=$(tail -n 10 "$output_file" 2>/dev/null \
            | grep -E '^PASS: [0-9]+ \| FAIL: [0-9]+ \| SKIP: [0-9]+' \
            | tail -n 1)
  if [ -n "$summary" ]; then
    local p f s
    p=$(printf '%s' "$summary" | sed -E 's/.*PASS: ([0-9]+).*/\1/')
    f=$(printf '%s' "$summary" | sed -E 's/.*FAIL: ([0-9]+).*/\1/')
    s=$(printf '%s' "$summary" | sed -E 's/.*SKIP: ([0-9]+).*/\1/')
    echo "$p $f $s"
    return
  fi

  # 2. No summary line — count PASS:/FAIL:/SKIP: individually. We anchor
  #    at line-start to avoid counting `PASS:` inside quoted error strings.
  #    `grep -c` already returns "0" on no match; the `|| echo 0` idiom is
  #    redundant AND harmful here — if grep exits non-zero for any other
  #    reason the `|| echo 0` emits a second "0", producing a two-line
  #    value that breaks the arithmetic below. Capture directly and
  #    default to 0 only if the variable is somehow empty.
  local p f s
  p=$(grep -cE '^PASS:' "$output_file" 2>/dev/null); p=${p:-0}
  f=$(grep -cE '^FAIL:' "$output_file" 2>/dev/null); f=${f:-0}
  s=$(grep -cE '^SKIP:' "$output_file" 2>/dev/null); s=${s:-0}
  if [ "$((p + f + s))" -gt 0 ]; then
    echo "$p $f $s"
    return
  fi

  # 3. Foreign file with no convention at all. Fall back to treating the
  #    file as one sub-test: pass if exit 0, fail otherwise.
  if [ "$file_rc" = 0 ]; then
    echo "1 0 0"
  else
    echo "0 1 0"
  fi
}

# --- Single-test runner --------------------------------------------------
# Responsibilities:
#   - Resolve a runner command for the file.
#   - Capture combined stdout/stderr into a tempfile.
#   - On first failure, retry up to 2 more times to detect flakiness.
#   - Update counters and emit a one-line PASS/FAIL/SKIP/FLAKY record.
#   - Append failure detail (last 40 lines) to the log if the test failed.

run_test() {
  local file="$1"
  local category="$2"
  local rel="${file#$PROJECT_DIR/}"

  CAT_TOTAL[$category]=$(( ${CAT_TOTAL[$category]} + 1 ))

  local runner
  runner=$(resolve_runner "$file" || true)
  if [ -z "$runner" ]; then
    CAT_SKIP[$category]=$(( ${CAT_SKIP[$category]} + 1 ))
    log "  [SKIP] $rel — no runner available for this extension"
    return
  fi

  # Special-case: `go test` needs a package dir, not a file.
  local cmd
  if [ "$runner" = "go-test-dir {FILE}" ]; then
    cmd=(go test -count=1 "./$(dirname "$rel")")
  else
    # Shell-split the runner template and substitute {FILE}.
    # We use an array to avoid re-quoting nightmares.
    cmd=()
    # shellcheck disable=SC2206  # intentional word-split on known-safe runner
    local parts=($runner)
    for p in "${parts[@]}"; do
      if [ "$p" = "{FILE}" ]; then
        cmd+=("$file")
      else
        cmd+=("$p")
      fi
    done
  fi

  # Run up to 3 times if the first attempt fails. Per the spec:
  #   "run any inconsistent test 3 times. If it fails at least once, mark
  #    it as [FLAKY] in the log."
  # We interpret this as: if ANY of the 3 attempts disagrees with the
  # others, it's flaky. If all 3 agree on pass → PASS. All 3 agree on
  # fail → FAIL. Mixed → FLAKY (and we classify by majority for counts).
  local attempts=()
  local max_attempts=1
  local tmp
  tmp=$(mktemp)

  # First attempt
  ( cd "$(dirname "$file")" && "${cmd[@]}" ) >"$tmp" 2>&1
  local rc1=$?
  attempts+=("$rc1")

  if [ "$rc1" -ne 0 ]; then
    # Retry twice more to check for flakiness.
    max_attempts=3
    local tmp2 tmp3
    tmp2=$(mktemp); tmp3=$(mktemp)
    ( cd "$(dirname "$file")" && "${cmd[@]}" ) >"$tmp2" 2>&1
    attempts+=($?)
    ( cd "$(dirname "$file")" && "${cmd[@]}" ) >"$tmp3" 2>&1
    attempts+=($?)

    # Keep the tempfile that captured the representative failure for the
    # failure-detail block. The first failure is the one most likely to
    # match what a developer would reproduce, so we keep tmp.
    rm -f "$tmp2" "$tmp3"
  fi

  # Classify
  local passes=0 fails=0
  for rc in "${attempts[@]}"; do
    if [ "$rc" = 0 ]; then
      passes=$((passes + 1))
    else
      fails=$((fails + 1))
    fi
  done

  local verdict
  if [ "$passes" -gt 0 ] && [ "$fails" -gt 0 ]; then
    verdict="FLAKY"
    CAT_FLAKY[$category]=$(( ${CAT_FLAKY[$category]} + 1 ))
    # Spec says flaky tests get flagged; they don't double-count as
    # pass or fail. Majority vote just determines exit pressure for
    # Stage 5's "did the suite pass" summary — we pick FAIL side so a
    # flaky test doesn't make a broken suite look green.
    CAT_FAIL[$category]=$(( ${CAT_FAIL[$category]} + 1 ))
  elif [ "$fails" = 0 ]; then
    verdict="PASS"
    CAT_PASS[$category]=$(( ${CAT_PASS[$category]} + 1 ))
  else
    verdict="FAIL"
    CAT_FAIL[$category]=$(( ${CAT_FAIL[$category]} + 1 ))
  fi

  log "  [$verdict] $rel"

  # Parse sub-test counts from the file's own output and roll them into
  # the SUB_* counters. We use the first attempt's output ($tmp) regardless
  # of whether retries happened — it's the representative result and matches
  # the convention of our failure-detail blocks.
  #
  # A file that crashed before printing anything (rc=127 "command not
  # found", for example) will have no convention markers; the fallback
  # path in parse_batch_summary handles that by counting the file as one
  # failing sub-test, keeping SUB_* from under-counting when tests can't
  # even start.
  read -r sub_pass sub_fail sub_skip <<< "$(parse_batch_summary "$tmp" "${attempts[0]}")"
  SUB_PASS[$category]=$((  ${SUB_PASS[$category]}  + sub_pass ))
  SUB_FAIL[$category]=$((  ${SUB_FAIL[$category]}  + sub_fail ))
  SUB_SKIP[$category]=$((  ${SUB_SKIP[$category]}  + sub_skip ))
  SUB_TOTAL[$category]=$(( ${SUB_TOTAL[$category]} + sub_pass + sub_fail + sub_skip ))

  # Emit failure detail whenever the file has diagnostic material to offer:
  # either the process-level verdict is non-PASS, OR the file exited 0 but
  # its own PASS:/FAIL: output reports sub-test failures. The second case
  # is what bit v3 — a test harness that exits 0 after printing `FAIL: ...`
  # lines would previously leave Stage 5 to aggregate counts with no bug
  # records attached, producing "2 failed / 0 bugs" reports.
  if [ "$verdict" != "PASS" ] || [ "$sub_fail" -gt 0 ]; then
    # Distilled one-liner failure reason: last non-empty line of output.
    local reason
    reason=$(grep -v '^[[:space:]]*$' "$tmp" | tail -n1 | cut -c1-200)
    [ -z "$reason" ] && reason="(no output)"

    if [ "$verdict" != "PASS" ]; then
      # File-level failure (or flaky): one record for the file itself.
      FAILURES+=("$category|$rel|$verdict|$reason")
    fi

    # If the file emitted individual `FAIL:` sub-test lines, surface each
    # one so Stage 5's bug extractor has per-sub-test records instead of
    # just a file-level rollup. We do this even when the file passed
    # overall — that's the whole point of the fix. Matching the convention
    # documented in parse_batch_summary: line-anchored `FAIL:` with the
    # assertion description as the remainder.
    #
    # Each sub-test gets a synthetic path of the form `<rel>::<subtest>`
    # so Stage 5's `(category, path)` dedupe in 04_report.sh treats each
    # failing assertion as a distinct bug instead of collapsing all
    # assertions in one file down to a single record.
    if [ "$sub_fail" -gt 0 ]; then
      local fail_line sub_reason sub_name sub_verdict
      if [ "$verdict" = "PASS" ]; then
        sub_verdict="SUBFAIL"
      else
        sub_verdict="$verdict"
      fi
      while IFS= read -r fail_line; do
        # Strip leading `FAIL:` and surrounding whitespace. The remaining
        # text is the assertion description; use it as both the sub-test
        # name (for the synthetic path) and the reason.
        sub_name=$(printf '%s' "$fail_line" \
                   | sed -E 's/^FAIL:[[:space:]]*//' \
                   | cut -c1-120)
        [ -z "$sub_name" ] && sub_name="(no description)"
        # Sanitise for the synthetic path: collapse whitespace, drop pipes
        # (our FAILURES record separator) and colons (Stage 5 splits on
        # the first ": " to separate path from reason).
        sub_name_path=$(printf '%s' "$sub_name" \
                        | tr '|:\t' '   ' \
                        | tr -s ' ')
        sub_reason=$(printf '%s' "$sub_name" | cut -c1-200)
        FAILURES+=("$category|$rel::$sub_name_path|$sub_verdict|$sub_reason")
      done < <(grep -E '^FAIL:' "$tmp" 2>/dev/null || true)
    fi

    {
      echo ""
      echo "--- FAILURE DETAIL: $rel ($verdict; sub-test fails: $sub_fail) ---"
      echo "command: ${cmd[*]}"
      echo "attempts: ${attempts[*]}  (0 = pass, non-zero = fail)"
      if [ "$sub_fail" -gt 0 ]; then
        echo "failing sub-tests (from file's own FAIL: lines):"
        grep -E '^FAIL:' "$tmp" 2>/dev/null | sed 's/^/  /' || echo "  (none parseable)"
      fi
      echo "last 40 lines of output:"
      tail -n 40 "$tmp"
      echo "--- end failure detail ---"
    } >> "$LOG_FILE"
  fi

  rm -f "$tmp"
}

# --- Category runner -----------------------------------------------------
# Runs all files in a category as a single batch and emits the
# "=== TEST BATCH [n] — [category] ===" block the spec asks for. We treat
# each category as one batch for logging purposes — we don't need
# sub-batching here because there's no test authoring to evict.

BATCH_NUM=0

run_category() {
  local category="$1"
  shift
  local files=("$@")

  if [ "${#files[@]}" -eq 0 ]; then
    return
  fi

  BATCH_NUM=$((BATCH_NUM + 1))
  local batch_start_total=${CAT_TOTAL[$category]}
  local batch_start_pass=${CAT_PASS[$category]}
  local batch_start_fail=${CAT_FAIL[$category]}
  local batch_start_skip=${CAT_SKIP[$category]}
  local batch_start_flaky=${CAT_FLAKY[$category]}
  local batch_start_sub_total=${SUB_TOTAL[$category]}
  local batch_start_sub_pass=${SUB_PASS[$category]}
  local batch_start_sub_fail=${SUB_FAIL[$category]}
  local batch_start_sub_skip=${SUB_SKIP[$category]}

  log ""
  log "=== TEST BATCH $BATCH_NUM — $category ==="

  for f in "${files[@]}"; do
    run_test "$f" "$category"
  done

  local ran=$(( ${CAT_TOTAL[$category]} - batch_start_total ))
  local p=$(( ${CAT_PASS[$category]}  - batch_start_pass ))
  local fl=$(( ${CAT_FAIL[$category]}  - batch_start_fail ))
  local sk=$(( ${CAT_SKIP[$category]}  - batch_start_skip ))
  local fk=$(( ${CAT_FLAKY[$category]} - batch_start_flaky ))
  local sub_ran=$(( ${SUB_TOTAL[$category]} - batch_start_sub_total ))
  local sub_p=$((  ${SUB_PASS[$category]}  - batch_start_sub_pass ))
  local sub_f=$((  ${SUB_FAIL[$category]}  - batch_start_sub_fail ))
  local sub_s=$((  ${SUB_SKIP[$category]}  - batch_start_sub_skip ))

  # Emit the spec-mandated batch block. Stage 5 greps for these lines.
  # We include BOTH the per-file counts (what the pipeline has always
  # reported) and the per-sub-test counts parsed from the test files'
  # own output. "Files run" and "Sub-tests" are deliberately distinct
  # labels so Stage 5 can pick the right number for the right column
  # without guessing.
  {
    echo ""
    echo "=== TEST BATCH $BATCH_NUM — $category ==="
    echo "Files run: $ran"
    echo "PASS (files): $p"
    echo "FAIL (files): $fl"
    echo "SKIP (files): $sk"
    echo "FLAKY (files): $fk"
    echo "Sub-tests: $sub_ran"
    echo "PASS (sub-tests): $sub_p"
    echo "FAIL (sub-tests): $sub_f"
    echo "SKIP (sub-tests): $sub_s"
    echo ""
    echo "Failed tests:"
    local any=0
    for rec in "${FAILURES[@]}"; do
      IFS='|' read -r rcat rfile rverdict rreason <<< "$rec"
      if [ "$rcat" = "$category" ]; then
        echo "- [$rverdict] $rfile: $rreason"
        any=1
      fi
    done
    [ "$any" = 0 ] && echo "- (none)"
    echo ""
    # Bugs-found is intentionally left as a placeholder pointer to the
    # failure-detail blocks above. Determining whether a failure is a
    # "project bug" vs a "bad test" needs source-level context that Stage 5
    # has (it reads ingestion + plan + log together) and we don't.
    echo "Bugs found:"
    echo "- See FAILURE DETAIL blocks above for diagnosis material."
  } >> "$LOG_FILE"

  log "  batch $BATCH_NUM summary — files: $ran ($p pass / $fl fail / $sk skip / $fk flaky) | sub-tests: $sub_ran ($sub_p / $sub_f / $sub_s)"
}

# --- Execute in spec order ----------------------------------------------
# Unit → Integration → API → Edge → Negative → Regression.

run_category unit        "${FILES_UNIT[@]}"
run_category integration "${FILES_INTEGRATION[@]}"
run_category api         "${FILES_API[@]}"
run_category edge        "${FILES_EDGE[@]}"
run_category negative    "${FILES_NEGATIVE[@]}"
run_category regression  "${FILES_REGRESSION[@]}"

# --- Final summary -------------------------------------------------------
# The pipeline's convention: one canonical summary block at the end of each
# stage. Stage 5 reads this block to populate qa_report.md's "Test Results
# Summary" table.

T_TOTAL=0; T_PASS=0; T_FAIL=0; T_SKIP=0; T_FLAKY=0
T_SUB_TOTAL=0; T_SUB_PASS=0; T_SUB_FAIL=0; T_SUB_SKIP=0
for cat in unit integration api edge negative regression; do
  T_TOTAL=$(( T_TOTAL + ${CAT_TOTAL[$cat]} ))
  T_PASS=$((  T_PASS  + ${CAT_PASS[$cat]}  ))
  T_FAIL=$((  T_FAIL  + ${CAT_FAIL[$cat]}  ))
  T_SKIP=$((  T_SKIP  + ${CAT_SKIP[$cat]}  ))
  T_FLAKY=$(( T_FLAKY + ${CAT_FLAKY[$cat]} ))
  T_SUB_TOTAL=$(( T_SUB_TOTAL + ${SUB_TOTAL[$cat]} ))
  T_SUB_PASS=$((  T_SUB_PASS  + ${SUB_PASS[$cat]}  ))
  T_SUB_FAIL=$((  T_SUB_FAIL  + ${SUB_FAIL[$cat]}  ))
  T_SUB_SKIP=$((  T_SUB_SKIP  + ${SUB_SKIP[$cat]}  ))
done

{
  echo ""
  echo "=== TEST EXECUTION SUMMARY ==="
  echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo ""
  echo "Per-file results (each file = one batch):"
  printf '%-13s  %-6s %-6s %-6s %-6s %-6s\n' \
    "Category" "Total" "Pass" "Fail" "Skip" "Flaky"
  for cat in unit integration api edge negative regression; do
    printf '%-13s  %-6s %-6s %-6s %-6s %-6s\n' \
      "$cat" "${CAT_TOTAL[$cat]}" "${CAT_PASS[$cat]}" \
      "${CAT_FAIL[$cat]}" "${CAT_SKIP[$cat]}" "${CAT_FLAKY[$cat]}"
  done
  printf '%-13s  %-6s %-6s %-6s %-6s %-6s\n' \
    "TOTAL" "$T_TOTAL" "$T_PASS" "$T_FAIL" "$T_SKIP" "$T_FLAKY"
  echo ""
  echo "Per-sub-test results (parsed from each file's own PASS:/FAIL: output):"
  printf '%-13s  %-6s %-6s %-6s %-6s\n' \
    "Category" "Total" "Pass" "Fail" "Skip"
  for cat in unit integration api edge negative regression; do
    printf '%-13s  %-6s %-6s %-6s %-6s\n' \
      "$cat" "${SUB_TOTAL[$cat]}" "${SUB_PASS[$cat]}" \
      "${SUB_FAIL[$cat]}" "${SUB_SKIP[$cat]}"
  done
  printf '%-13s  %-6s %-6s %-6s %-6s\n' \
    "TOTAL" "$T_SUB_TOTAL" "$T_SUB_PASS" "$T_SUB_FAIL" "$T_SUB_SKIP"
  echo "=============================="
} >> "$LOG_FILE"

log ""
log "TEST EXECUTION COMPLETE — files: PASS $T_PASS | FAIL $T_FAIL | SKIP $T_SKIP | FLAKY $T_FLAKY"
log "                            sub-tests: PASS $T_SUB_PASS | FAIL $T_SUB_FAIL | SKIP $T_SUB_SKIP (total $T_SUB_TOTAL)"

# Stage 5 is next. We exit 0 even when tests failed — a failing test is
# expected output of this stage, and aborting would prevent the report
# (which is the whole point of the pipeline) from ever being written.
exit 0
