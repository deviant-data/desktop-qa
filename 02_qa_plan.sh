#!/bin/bash
# 02_qa_plan.sh — Stage 3 QA plan generation
#
# Writes qa_plan.md to $PROJECT_DIR/qa/. Pure bash — no AI, no network.
#
# The primary job of this stage is to SELECT tests, not invent them. The
# scoring logic:
#   1. Scan $PROJECT_DIR/qa/tests/ for files already present, classify each
#      by the project's documented naming convention, and promote them to
#      first-class plan entries with real IDs.
#   2. Inspect ingestion_summary.md to decide which *generic* test templates
#      from the built-in catalog apply to this stack (e.g. HTTP tests only
#      if a web framework was detected; CLI tests only if an entry script
#      is present).
#   3. Merge (1) and (2), deduplicate by description, and emit the tables.
#
# Usage:
#   bash 02_qa_plan.sh /path/to/project
#
# Exit codes:
#   0  plan written
#   1  usage error / bad project path
#   2  ingestion prerequisite missing (run 00_ingestion.sh first)
#   3  cannot write output
#   4  unsupported bash version (requires bash 4+)

# --- Bash version guard --------------------------------------------------
# Matches the guard in 00_ingestion.sh and 01_environment.sh. We use
# associative arrays (`declare -A`) to dedupe test descriptions and to
# group tests by category. Those are bash 4+ features. Failing fast with
# exit code 4 keeps the whole pipeline in lockstep with earlier stages
# (see BUG-001 in the project QA history).
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: bash 4+ required (found: ${BASH_VERSION:-unknown})." >&2
  echo "  On macOS the system bash is 3.2. Install a newer bash with:" >&2
  echo "    brew install bash" >&2
  echo "  Then invoke this script with the newer bash, e.g.:" >&2
  echo "    /opt/homebrew/bin/bash 02_qa_plan.sh /path/to/project" >&2
  exit 4
fi

set -u
# Intentionally not `set -e`: one missing heuristic (e.g. a grep that finds
# nothing) must not abort plan generation. Individual sections degrade to
# empty and the plan still gets written.

# --- Argument parsing ----------------------------------------------------
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash 02_qa_plan.sh /path/to/project" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory." >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QA_DIR="$PROJECT_DIR/qa"
TESTS_DIR="$QA_DIR/tests"
INGESTION_FILE="$QA_DIR/ingestion_summary.md"
OUT_FILE="$QA_DIR/qa_plan.md"

# Stage 1 is a hard prerequisite — the plan is supposed to be informed by
# what ingestion found. Refuse rather than silently guess.
if [ ! -f "$INGESTION_FILE" ]; then
  echo "Error: $INGESTION_FILE not found. Run 00_ingestion.sh first." >&2
  exit 2
fi

mkdir -p "$QA_DIR" || { echo "Error: cannot create $QA_DIR" >&2; exit 3; }
# Tests dir may legitimately not exist yet on a fresh run — that's fine,
# we just skip the existing-tests scan.

# --- Stack & signal extraction from ingestion ---------------------------
# We read ingestion_summary.md ONCE and grep for the handful of facts the
# planner actually needs. External memory, targeted extraction, no
# speculative loading.

INGESTION_BODY="$(cat "$INGESTION_FILE")"

# Derive a coarse stack label. Order of checks matters: the framework line
# in ingestion_summary.md is more specific than the language section.
STACK="unknown"
FRAMEWORK=""
if echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*(express|fastify|koa|nestjs|next|nuxt|remix)'; then
  STACK="node-http"
  FRAMEWORK=$(echo "$INGESTION_BODY" | grep -iE '^- Framework:' | head -n1 | sed 's/^- Framework: *//')
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*(react|vue|svelte|angular)'; then
  STACK="node-frontend"
  FRAMEWORK=$(echo "$INGESTION_BODY" | grep -iE '^- Framework:' | head -n1 | sed 's/^- Framework: *//')
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*Node\.js'; then
  STACK="node-generic"
  FRAMEWORK="Node.js"
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*(django|flask|fastapi|starlette|pyramid|tornado|aiohttp)'; then
  STACK="python-http"
  FRAMEWORK=$(echo "$INGESTION_BODY" | grep -iE '^- Framework:' | head -n1 | sed 's/^- Framework: *//')
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*Python'; then
  STACK="python-generic"
  FRAMEWORK="Python"
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*Spring'; then
  STACK="java-http"
  FRAMEWORK="Spring"
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*(Go|module)'; then
  STACK="go"
  FRAMEWORK="Go"
elif echo "$INGESTION_BODY" | grep -qiE '^- Framework:.*Rails'; then
  STACK="ruby-http"
  FRAMEWORK="Rails"
fi

# Signals we use to gate generic test templates.
HAS_ENTRY_SHELL=0
HAS_DOTENV=0
HAS_AUTH_HINT=0
HAS_FILE_UPLOAD=0
HAS_DB=0

# CLI/shell entry point — run.sh, setup.sh, or a documented bin script
if echo "$INGESTION_BODY" | grep -qE '^\- (run\.sh|setup\.sh|bin/)' \
   || grep -rqE '^#!/(usr/)?bin/(env )?bash' "$PROJECT_DIR" \
        --include='*.sh' --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null; then
  HAS_ENTRY_SHELL=1
fi

# .env usage — already flagged in ingestion, or direct file presence
if echo "$INGESTION_BODY" | grep -qiE '\.env' \
   || [ -f "$PROJECT_DIR/.env" ] || [ -f "$PROJECT_DIR/.env.example" ]; then
  HAS_DOTENV=1
fi

# Heuristic scans on the actual source tree. Kept bounded: only common
# source extensions, and we short-circuit on first hit via `grep -l -m1`.
if grep -rlE -m1 '(passport|jwt|oauth|bcrypt|argon2|authenticate|authorize)' \
     "$PROJECT_DIR" --include='*.js' --include='*.ts' --include='*.py' \
     --include='*.java' --include='*.go' --include='*.rb' \
     --exclude-dir=node_modules --exclude-dir=.git --exclude-dir=venv \
     --exclude-dir=.venv --exclude-dir=dist --exclude-dir=build 2>/dev/null \
   | head -n1 | grep -q .; then
  HAS_AUTH_HINT=1
fi

if grep -rlE -m1 '(multer|multipart|FileUpload|UploadFile|FormFile)' \
     "$PROJECT_DIR" --include='*.js' --include='*.ts' --include='*.py' \
     --include='*.java' --include='*.go' \
     --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null \
   | head -n1 | grep -q .; then
  HAS_FILE_UPLOAD=1
fi

if grep -rlE -m1 '(mongoose|sequelize|prisma|sqlalchemy|psycopg|pg\.|mysql2|redis|pymongo)' \
     "$PROJECT_DIR" --include='*.js' --include='*.ts' --include='*.py' \
     --exclude-dir=node_modules --exclude-dir=.git 2>/dev/null \
   | head -n1 | grep -q .; then
  HAS_DB=1
fi

# Project name — from package.json if present, else directory basename.
PROJECT_NAME=$(basename "$PROJECT_DIR")
if [ -f "$PROJECT_DIR/package.json" ]; then
  pkg_name=$(grep -E '"name"[[:space:]]*:' "$PROJECT_DIR/package.json" 2>/dev/null \
              | head -n1 \
              | sed 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  [ -n "$pkg_name" ] && PROJECT_NAME="$pkg_name"
fi

# --- Existing test classification ---------------------------------------
# Walk $PROJECT_DIR/qa/tests and classify every file by the naming scheme
# documented in 03_test_execution.md:
#   *.test.*                 → unit
#   *.integration.test.*     → integration
#   *.api.test.*             → api
#   edge_cases.test.*        → edge
# Anything else is logged as "uncategorised" and left out of the plan.
#
# Each recognised file contributes one row to the relevant table. The
# description is the basename minus the suffix, lightly humanised.

# Rows: parallel indexed arrays per category. Each row is a tab-separated
# record the formatter will split when writing the markdown table.
declare -a ROWS_UNIT=()
declare -a ROWS_INTEGRATION=()
declare -a ROWS_API=()
declare -a ROWS_EDGE=()
declare -a ROWS_NEGATIVE=()
declare -a ROWS_REGRESSION=()

# Dedupe map: description → 1, shared across categories so a templated test
# never collides with an on-disk test that already covers the same ground.
declare -A SEEN_DESC=()

# Turn "foo_bar_baz" into "Foo bar baz" for human-readable descriptions.
humanise() {
  local s="$1"
  s="${s//_/ }"
  s="${s//-/ }"
  # Upper-case first letter only; rest kept as-is (preserves acronyms).
  printf '%s' "$(echo "${s:0:1}" | tr '[:lower:]' '[:upper:]')${s:1}"
}

# Append a dedup-guarded row to a category array.
#   add_row <category> <desc> <col3> <col4> [<col5> <col6>]
# For API rows, columns are: endpoint, method, input, status, notes.
# For everything else: desc, input, expected.
add_row() {
  local cat="$1" desc="$2"
  # For API rows, the "desc" slot is the endpoint; dedup on
  # endpoint+method+input so two tests hitting the same endpoint with
  # different payloads (e.g. missing token vs malformed token) both survive.
  local key
  if [ "$cat" = "api" ]; then
    key="${cat}::${desc,,}::${3:-}::${4:-}"
  else
    key="${cat}::${desc,,}"
  fi
  if [ -n "${SEEN_DESC[$key]:-}" ]; then
    return
  fi
  SEEN_DESC[$key]=1
  shift 2
  # Join remaining args with tab so the formatter can split them back.
  local row
  row=$(printf '%s\t' "$desc" "$@")
  row="${row%$'\t'}"
  case "$cat" in
    unit)        ROWS_UNIT+=("$row") ;;
    integration) ROWS_INTEGRATION+=("$row") ;;
    api)         ROWS_API+=("$row") ;;
    edge)        ROWS_EDGE+=("$row") ;;
    negative)    ROWS_NEGATIVE+=("$row") ;;
    regression)  ROWS_REGRESSION+=("$row") ;;
  esac
}

EXISTING_COUNT=0
UNCLASSIFIED=()

if [ -d "$TESTS_DIR" ]; then
  # Use a while-read loop rather than a glob — the glob can expand to the
  # literal pattern if the directory is empty, which would then be treated
  # as a filename by the loop body.
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    local_name=$(basename "$f")
    EXISTING_COUNT=$((EXISTING_COUNT + 1))

    # Strip the extension(s) to get a base for the description.
    # Order of suffix stripping matters: match the most specific first.
    #
    # We accept TWO parallel filename conventions because both are common in
    # the wild and in this project:
    #   a) dotted:      foo.integration.test.sh, edge_cases.test.sh
    #   b) underscored: foo_integration_test.sh, edge_cases_test.sh,
    #                   regression_test.sh, negative_test.sh, cli_api_test.sh
    # BUG-003 in the project's prior QA report was that (b) was rejected as
    # "uncategorised", silently excluding ~70% of the suite from the plan.
    # The underscored forms now map to the same categories as the dotted ones.
    desc_base="$local_name"
    cat=""
    case "$local_name" in
      # --- Dotted convention (most specific first) -----------------------
      *.integration.test.*)
        cat="integration"
        desc_base="${local_name%.integration.test.*}"
        ;;
      *.api.test.*)
        cat="api"
        desc_base="${local_name%.api.test.*}"
        ;;
      edge_cases.test.*|edge.test.*|*.edge.test.*)
        cat="edge"
        desc_base="${local_name%.edge.test.*}"
        desc_base="${desc_base%.test.*}"
        ;;
      *.negative.test.*)
        cat="negative"
        desc_base="${local_name%.negative.test.*}"
        ;;
      *.regression.test.*)
        cat="regression"
        desc_base="${local_name%.regression.test.*}"
        ;;

      # --- Underscored convention (most specific first) ------------------
      # Note: these match BEFORE the generic `*_test.*` catch-all below.
      *_integration_test.sh|*_integration_test.bash|*_integration_test.py|*_integration_test.js|*_integration_test.ts|*_integration_test.go)
        cat="integration"
        desc_base="${local_name%_integration_test.*}"
        ;;
      *_api_test.sh|*_api_test.bash|*_api_test.py|*_api_test.js|*_api_test.ts|*_api_test.go)
        cat="api"
        desc_base="${local_name%_api_test.*}"
        ;;
      edge_cases_test.sh|edge_cases_test.bash|edge_cases_test.py|edge_cases_test.js|edge_cases_test.ts|edge_cases_test.go|*_edge_test.sh|*_edge_test.bash|*_edge_test.py|*_edge_test.js|*_edge_test.ts|*_edge_test.go)
        cat="edge"
        desc_base="${local_name%_test.*}"
        desc_base="${desc_base%_edge}"
        ;;
      negative_test.sh|negative_test.bash|negative_test.py|negative_test.js|negative_test.ts|negative_test.go|*_negative_test.sh|*_negative_test.bash|*_negative_test.py|*_negative_test.js|*_negative_test.ts|*_negative_test.go)
        cat="negative"
        desc_base="${local_name%_test.*}"
        desc_base="${desc_base%_negative}"
        ;;
      regression_test.sh|regression_test.bash|regression_test.py|regression_test.js|regression_test.ts|regression_test.go|*_regression_test.sh|*_regression_test.bash|*_regression_test.py|*_regression_test.js|*_regression_test.ts|*_regression_test.go)
        cat="regression"
        desc_base="${local_name%_test.*}"
        desc_base="${desc_base%_regression}"
        ;;

      # --- Generic unit catch-alls --------------------------------------
      # Dotted generic `.test.*` AND underscored `*_test.*` for all common
      # extensions (.sh, .bash, .py, .js, .ts, .go). `test_*.py` supports
      # the stdlib pytest convention.
      #
      # BEFORE defaulting to unit, we apply a loose keyword check on the
      # filename stem so that files like `edge_cases_extended.test.sh` or
      # `negative_extended.test.sh` — which have a token between the
      # category keyword and the `.test.` marker and therefore fail the
      # strict patterns above — land in the right category. Without this
      # pass they were all being counted under Unit (observed in v3).
      *.test.*|test_*.py|*_test.py|*_test.go|*_test.js|*_test.ts|*_test.sh|*_test.bash)
        # Extract the stem (everything before the test marker).
        if [[ "$local_name" == *.test.* ]]; then
          desc_base="${local_name%%.test.*}"
        elif [[ "$local_name" == *_test.* ]]; then
          desc_base="${local_name%_test.*}"
        elif [[ "$local_name" == test_* ]]; then
          desc_base="${local_name#test_}"
          desc_base="${desc_base%.*}"
        else
          desc_base="${local_name%.*}"
        fi
        stem_lc=$(printf '%s' "$desc_base" | tr '[:upper:]' '[:lower:]')
        if [[ "$stem_lc" == *integration* ]]; then
          cat="integration"
        elif [[ "$stem_lc" == *regression* ]]; then
          cat="regression"
        elif [[ "$stem_lc" == *negative* ]]; then
          cat="negative"
        elif [[ "$stem_lc" == *edge* ]]; then
          cat="edge"
        elif [[ "$stem_lc" == *api* ]] || [[ "$stem_lc" == *cli* ]]; then
          cat="api"
        else
          cat="unit"
        fi
        ;;
      *)
        UNCLASSIFIED+=("$local_name")
        continue
        ;;
    esac

    human=$(humanise "$desc_base")
    # Relative path from project root is stable and greppable in logs.
    rel="${f#$PROJECT_DIR/}"

    case "$cat" in
      unit)
        add_row unit "$human" "existing test file" "as defined in $rel"
        ;;
      integration)
        add_row integration "$human" "components wired per $rel" "as defined in $rel"
        ;;
      api)
        # We don't know the endpoint/method from the filename alone. Leave
        # them generic; Stage 4 will read the actual test file.
        # Columns: endpoint, method, input, status, notes
        add_row api "(from $rel)" "-" "-" "as defined in test" "existing"
        ;;
      edge)
        add_row edge "$human" "see $rel" "as defined in $rel"
        ;;
      negative)
        add_row negative "$human" "see $rel" "as defined in $rel"
        ;;
      regression)
        # Regression rows use columns: description | must-always-pass.
        add_row regression "$human ($rel)" "Yes"
        ;;
    esac
  done < <(find "$TESTS_DIR" -maxdepth 3 -type f -print0 2>/dev/null)
fi

# --- Generic template catalog -------------------------------------------
# Everything below is gated on signals from ingestion. The rule: a test
# earns its place if the project plausibly has the surface area for it.
# We avoid padding the plan with tests that can't run on this stack.

# Unit tests — always safe to plan some minimum.
add_row unit "Primary module imports without error" "module load" "no exception raised"
add_row unit "Happy-path input returns expected shape" "representative valid input" "correct type and value"
add_row unit "Null / undefined input handled" "null or None" "defined error or safe default"
add_row unit "Empty string / empty collection handled" "\"\" or []" "no crash, sensible result"
add_row unit "Boundary numeric values" "0, 1, -1, INT_MAX" "no overflow, no off-by-one"

# Integration tests — only meaningful if there's something to integrate.
if [ "$HAS_DB" = 1 ]; then
  add_row integration "Database connection established on startup" "DB config from env" "connection succeeds; no leaked credentials"
  add_row integration "Read-after-write consistency on primary entity" "insert then fetch" "fetched record matches insert"
fi
if [ "$STACK" = "node-http" ] || [ "$STACK" = "python-http" ] || [ "$STACK" = "java-http" ] || [ "$STACK" = "ruby-http" ]; then
  add_row integration "Middleware chain executes in declared order" "request through all middleware" "each middleware observed once, in order"
fi
if [ "$HAS_ENTRY_SHELL" = 1 ]; then
  add_row integration "Shell entry script composes sub-scripts correctly" "run.sh with valid args" "sub-scripts invoked in documented order"
fi

# API tests — only for HTTP stacks.
# Columns per 02_qa_plan.md: Endpoint | Method | Input | Expected Status | Notes
if [ "$STACK" = "node-http" ] || [ "$STACK" = "python-http" ] || [ "$STACK" = "java-http" ] || [ "$STACK" = "ruby-http" ]; then
  add_row api "/" "GET" "none" "200 or documented redirect" "smoke: root endpoint responds"
  add_row api "/health or /healthz" "GET" "none" "200" "if exposed"
  add_row api "/__does_not_exist__" "GET" "none" "404" "unknown route; no stack trace leak"
  if [ "$HAS_AUTH_HINT" = 1 ]; then
    add_row api "protected route" "GET" "no token" "401" "auth: rejects missing credentials"
    add_row api "protected route" "GET" "Authorization: Bearer garbage" "401 or 403" "auth: rejects malformed token"
  fi
  if [ "$HAS_FILE_UPLOAD" = 1 ]; then
    add_row api "upload route" "POST" "small valid file" "2xx" "upload: accepts valid file"
    add_row api "upload route" "POST" "file over documented limit" "413 or documented error" "upload: rejects oversized"
  fi
fi

# CLI tests — only when a shell entry point is present. CLI surface area
# lives in the API table too since "API" in 02_qa_plan.md includes CLI.
if [ "$HAS_ENTRY_SHELL" = 1 ]; then
  add_row api "bash run.sh (no args)" "CLI" "no args" "non-zero exit with usage text" "cli: prints usage"
  add_row api "bash run.sh /does/not/exist" "CLI" "invalid path" "non-zero exit with clear error" "cli: rejects bad path"
fi

# Edge cases — portable across stacks; each one is cheap and high-signal.
add_row edge "Unicode input (emoji, RTL, combining marks)" "\"café 🚀 مرحبا\"" "preserved round-trip, no corruption"
add_row edge "Very long string input" "1 MB string" "handled or rejected with clear error"
add_row edge "Whitespace-only input" "\"   \"" "treated as empty or rejected"
add_row edge "Concurrent requests to same resource" "N parallel callers" "no race condition, deterministic outcome"
if [ "$HAS_DOTENV" = 1 ]; then
  add_row edge "Missing required env var at startup" "unset required var" "fails fast with actionable message"
fi
if [ "$HAS_ENTRY_SHELL" = 1 ]; then
  add_row edge "Script run under bash 3.2 (macOS default)" "/bin/bash script.sh" "version guard fires OR script runs"
  add_row edge "Script run with spaces in project path" "/tmp/path with spaces/proj" "no word-splitting errors"
fi

# Negative tests — wrong types and missing fields across stacks.
add_row negative "Wrong type where string expected" "integer 42" "type error surfaced, not swallowed"
add_row negative "Missing required field" "payload with field omitted" "validation error, no partial write"
if [ "$HAS_AUTH_HINT" = 1 ]; then
  add_row negative "Expired auth token" "token past exp" "401, token not accepted"
  add_row negative "Token signed with wrong key" "forged JWT" "401, signature rejected"
fi
if [ "$STACK" = "node-http" ] || [ "$STACK" = "python-http" ] || [ "$STACK" = "java-http" ]; then
  add_row negative "Malformed JSON body" "\"{not: json\"" "400 with parse error, no 500"
  add_row negative "Wrong content-type on POST" "text/plain body to JSON endpoint" "415 or 400"
fi

# Regression anchors — the "must always pass" set. We promote existing
# tests into this list (they were already considered worth keeping), and
# add a few stack-specific invariants.
for row in "${ROWS_UNIT[@]}"; do
  desc=$(printf '%s' "$row" | cut -f1)
  add_row regression "$desc" "Yes"
done
add_row regression "Primary entry point starts without error" "Yes"
if [ "$HAS_ENTRY_SHELL" = 1 ]; then
  add_row regression "Bash version guard fires on bash 3.2" "Yes"
fi
if [ "$STACK" = "node-http" ] || [ "$STACK" = "python-http" ] || [ "$STACK" = "java-http" ] || [ "$STACK" = "ruby-http" ]; then
  add_row regression "Server responds on documented health path" "Yes"
fi

# --- Total count --------------------------------------------------------
TOTAL=$(( ${#ROWS_UNIT[@]} + ${#ROWS_INTEGRATION[@]} + ${#ROWS_API[@]} \
         + ${#ROWS_EDGE[@]} + ${#ROWS_NEGATIVE[@]} + ${#ROWS_REGRESSION[@]} ))

# --- Table formatters ---------------------------------------------------
# Each formatter takes an ID prefix (e.g. "U") and a list of tab-separated
# rows, and emits a markdown table matching the schema in 02_qa_plan.md.
# If the list is empty, emit a single "(none planned)" row so the table
# is still valid markdown — Stage 4's parser is happier with a present
# table than a missing one.

emit_table_3col() {
  # Columns: ID | Description | Input | Expected Result
  local prefix="$1"; shift
  local header3="$1"; shift
  local header4="$1"; shift
  local -a rows=("$@")
  echo "| ID | Description | $header3 | $header4 |"
  echo "|---|---|---|---|"
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "| ${prefix}00 | (none planned for this stack) | - | - |"
    return
  fi
  local i=1
  for row in "${rows[@]}"; do
    local id
    id=$(printf '%s%02d' "$prefix" "$i")
    # awk splits on tab, prints padded fields.
    IFS=$'\t' read -r c1 c2 c3 <<< "$row"
    printf '| %s | %s | %s | %s |\n' "$id" "${c1:-}" "${c2:--}" "${c3:--}"
    i=$((i + 1))
  done
}

emit_table_api() {
  # Columns: ID | Endpoint | Method | Input | Expected Status | Notes
  # Data columns (c1..c5): endpoint, method, input, status, notes.
  local prefix="A"
  local -a rows=("$@")
  echo "| ID | Endpoint | Method | Input | Expected Status | Notes |"
  echo "|---|---|---|---|---|---|"
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "| A00 | (none planned for this stack) | - | - | - | - |"
    return
  fi
  local i=1
  for row in "${rows[@]}"; do
    local id
    id=$(printf '%s%02d' "$prefix" "$i")
    IFS=$'\t' read -r c1 c2 c3 c4 c5 <<< "$row"
    printf '| %s | %s | %s | %s | %s | %s |\n' \
      "$id" "${c1:-}" "${c2:--}" "${c3:--}" "${c4:--}" "${c5:--}"
    i=$((i + 1))
  done
}

emit_table_regression() {
  # Columns: ID | Description | Must always pass
  local -a rows=("$@")
  echo "| ID | Description | Must always pass |"
  echo "|---|---|---|"
  if [ "${#rows[@]}" -eq 0 ]; then
    echo "| R00 | (none planned) | Yes |"
    return
  fi
  local i=1
  for row in "${rows[@]}"; do
    local id
    id=$(printf 'R%02d' "$i")
    IFS=$'\t' read -r c1 c2 <<< "$row"
    printf '| %s | %s | %s |\n' "$id" "${c1:-}" "${c2:-Yes}"
    i=$((i + 1))
  done
}

# --- Compose the plan ---------------------------------------------------
# Write to a tempfile first, then atomic-move into place. Matches the
# pattern used in 00_ingestion.sh — avoids leaving a half-written
# qa_plan.md on disk if something goes wrong mid-render.

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

{
  echo "# QA Plan"
  echo
  echo "## Project: $PROJECT_NAME"
  echo "## Generated: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "## Total planned tests: $TOTAL"
  echo
  echo "_Stack: ${STACK}${FRAMEWORK:+ ($FRAMEWORK)}_"
  echo "_Existing test files discovered: ${EXISTING_COUNT}_"
  if [ "${#UNCLASSIFIED[@]}" -gt 0 ]; then
    echo "_Uncategorised files (not included in plan):_"
    for u in "${UNCLASSIFIED[@]}"; do
      echo "_- ${u}_"
    done
  fi
  echo
  echo "---"
  echo
  echo "## Unit Tests"
  emit_table_3col "U" "Input" "Expected Result" "${ROWS_UNIT[@]}"
  echo
  echo "## Integration Tests"
  emit_table_3col "I" "Components" "Expected Result" "${ROWS_INTEGRATION[@]}"
  echo
  echo "## API Tests"
  emit_table_api "${ROWS_API[@]}"
  echo
  echo "## Edge Cases"
  emit_table_3col "E" "Input" "Expected Result" "${ROWS_EDGE[@]}"
  echo
  echo "## Negative Tests"
  emit_table_3col "N" "Input" "Expected Result" "${ROWS_NEGATIVE[@]}"
  echo
  echo "## Regression Anchors"
  emit_table_regression "${ROWS_REGRESSION[@]}"
  echo
} > "$TMP_OUT"

mv "$TMP_OUT" "$OUT_FILE" || { echo "Error: cannot write $OUT_FILE" >&2; exit 3; }
trap - EXIT

echo "Wrote $OUT_FILE"
echo "QA PLAN COMPLETE — $TOTAL tests planned"
