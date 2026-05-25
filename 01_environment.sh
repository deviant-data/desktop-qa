#!/bin/bash
# 01_environment.sh — Stage 2 environment setup
#
# Verifies the runtime, installs dependencies, attempts a build, starts the
# application in the background, and probes for health. All actions and output
# are appended to $PROJECT_DIR/qa/test_log.txt. Pure bash — no AI, no network
# beyond the project's own package installer.
#
# Usage:
#   bash 01_environment.sh /path/to/project
#
# Exit codes:
#   0  environment ready (best-effort complete)
#   1  usage error / bad project path
#   2  ingestion prerequisite missing (run 00_ingestion.sh first)
#   3  cannot write log file
#   4  unsupported bash version (requires bash 4+)

# --- Bash version guard --------------------------------------------------
# This script uses features (process-substitution with `comm <(...) <(...)`,
# readarray-style loops, arithmetic comparisons on `${BASH_VERSINFO[0]}`)
# that are cleanest on bash 4+. More importantly, Stage 1 requires bash 4+,
# and running Stage 2 on a different bash than Stage 1 is a recipe for the
# kind of pipeline-wide silent-failure described in the project's QA report.
# Fail fast with a clear message rather than silently diverging from Stage 1.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: bash 4+ required (found: ${BASH_VERSION:-unknown})." >&2
  echo "  On macOS the system bash is 3.2. Install a newer bash with:" >&2
  echo "    brew install bash" >&2
  echo "  Then invoke this script with the newer bash, e.g.:" >&2
  echo "    /opt/homebrew/bin/bash 01_environment.sh /path/to/project" >&2
  exit 4
fi

set -u
# Intentionally not `set -e`: individual phases (install, build, startup) must
# be allowed to fail and be recorded as PARTIAL/FAILED without aborting the
# remaining phases. Per-command exit codes are captured explicitly.

# --- Argument parsing ----------------------------------------------------
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash 01_environment.sh /path/to/project" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory." >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QA_DIR="$PROJECT_DIR/qa"
LOG_FILE="$QA_DIR/test_log.txt"
INGESTION_FILE="$QA_DIR/ingestion_summary.md"

# Stage 1 is a hard prerequisite. The spec says "Read ingestion_summary.md to
# confirm the stack." If it's missing, we refuse rather than silently guess.
if [ ! -f "$INGESTION_FILE" ]; then
  echo "Error: $INGESTION_FILE not found. Run 00_ingestion.sh first." >&2
  exit 2
fi

mkdir -p "$QA_DIR" || { echo "Error: cannot create $QA_DIR" >&2; exit 3; }
touch "$LOG_FILE" 2>/dev/null || { echo "Error: cannot write $LOG_FILE" >&2; exit 3; }

# --- Logging -------------------------------------------------------------
# All logging routes through log(): tee to stdout so the operator can watch
# progress, and append to the log file so Stage 5 can reconstruct the run.

log() {
  echo "$@" | tee -a "$LOG_FILE"
}

# Run a command, capture its stdout+stderr into the log, and return its exit
# code. Using a here-doc boundary in the log makes it easy to grep out one
# command's output later.
run_logged() {
  local label="$1"; shift
  log "--- $label ---"
  log "\$ $*"
  # Capture to a temp file so we can both tee live output AND return the real
  # exit code (piping to tee would return tee's 0 even if the command failed).
  local tmp
  tmp=$(mktemp)
  ( "$@" ) >"$tmp" 2>&1
  local rc=$?
  cat "$tmp" >> "$LOG_FILE"
  # Echo a short head to stdout too, so the operator isn't staring at silence.
  head -n 20 "$tmp"
  [ "$(wc -l < "$tmp")" -gt 20 ] && echo "  ... (truncated; full output in $LOG_FILE)"
  rm -f "$tmp"
  log "--- exit: $rc ---"
  return $rc
}

# --- Cleanup trap --------------------------------------------------------
# We may start a long-running app process. On script exit (normal or
# interrupted), kill it. Addresses DESIGN-001 in the project's known issues.

APP_PID=""
APP_PGID=""
cleanup() {
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    log "Stopping app process (PID $APP_PID, PGID ${APP_PGID:-$APP_PID})..."
    # Kill the whole process group. `npm start` spawns `node` as a child; if we
    # only signal the npm PID, the node child survives and keeps the port.
    # Using -PGID with kill signals every member of the group.
    if [ -n "$APP_PGID" ]; then
      kill -TERM -"$APP_PGID" 2>/dev/null || true
    else
      kill -TERM "$APP_PID" 2>/dev/null || true
    fi
    sleep 1
    if kill -0 "$APP_PID" 2>/dev/null; then
      if [ -n "$APP_PGID" ]; then
        kill -KILL -"$APP_PGID" 2>/dev/null || true
      else
        kill -KILL "$APP_PID" 2>/dev/null || true
      fi
    fi
  fi
}
trap cleanup EXIT INT TERM

# --- Header --------------------------------------------------------------
{
  echo ""
  echo "=== ENVIRONMENT SETUP ==="
  echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Project: $PROJECT_DIR"
} >> "$LOG_FILE"

log ""
log "Desktop QA — Stage 2: Environment Setup"
log "Project: $PROJECT_DIR"
log ""

# --- Stack detection -----------------------------------------------------
# Re-probe the filesystem directly. The ingestion summary is markdown — easy
# for humans, brittle for regex. The manifests haven't moved since Stage 1, so
# this is faster and more reliable than parsing ingestion_summary.md.
#
# The shell-stack fallback (BUG-004 in the project's prior QA report) fires
# only when no recognised manifest is present AND the project contains shell
# scripts. This ensures a pure-bash project gets runtime verification
# (bash >= 4, as required by the stage scripts themselves) rather than
# being labelled "unknown" and silently skipping the runtime phase.

STACK=""
if [ -f "$PROJECT_DIR/package.json" ]; then
  STACK="node"
elif [ -f "$PROJECT_DIR/requirements.txt" ] || [ -f "$PROJECT_DIR/pyproject.toml" ] || [ -f "$PROJECT_DIR/Pipfile" ]; then
  STACK="python"
elif [ -f "$PROJECT_DIR/pom.xml" ]; then
  STACK="maven"
elif [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ]; then
  STACK="gradle"
elif [ -f "$PROJECT_DIR/go.mod" ]; then
  STACK="go"
elif [ -f "$PROJECT_DIR/Cargo.toml" ]; then
  STACK="rust"
elif [ -f "$PROJECT_DIR/Gemfile" ]; then
  STACK="ruby"
else
  # Fallback: look for shell scripts. `find -quit` short-circuits on first
  # hit and skips the usual noise dirs. If we find any .sh or .bash file
  # outside ignored paths, treat this as a shell project.
  if find "$PROJECT_DIR" \
        \( -path '*/node_modules' -o -path '*/.git' -o \
           -path '*/venv' -o -path '*/.venv' -o \
           -path '*/__pycache__' -o -path '*/dist' -o \
           -path '*/build' -o -path '*/target' \) -prune \
        -o -type f \( -name '*.sh' -o -name '*.bash' \) -print 2>/dev/null \
      | head -n1 | grep -q .; then
    STACK="shell"
  fi
fi

log "Detected stack: ${STACK:-unknown}"

# --- Phase 1: runtime verification --------------------------------------
# Verify the runtime is present. Do NOT attempt to auto-install system
# packages — the spec allows it, but a script that calls `apt-get install`
# unprompted is a privilege-escalation footgun. We log the absence and let
# the downstream phases degrade gracefully.

RUNTIME="unknown"
RUNTIME_OK=0

case "$STACK" in
  node)
    if command -v node >/dev/null 2>&1; then
      RUNTIME="node $(node --version 2>/dev/null)"
      RUNTIME_OK=1
    fi
    ;;
  python)
    if command -v python3 >/dev/null 2>&1; then
      RUNTIME="python $(python3 --version 2>&1 | awk '{print $2}')"
      RUNTIME_OK=1
    elif command -v python >/dev/null 2>&1; then
      RUNTIME="python $(python --version 2>&1 | awk '{print $2}')"
      RUNTIME_OK=1
    fi
    ;;
  maven)
    if command -v mvn >/dev/null 2>&1; then
      RUNTIME="maven $(mvn --version 2>/dev/null | head -n1)"
      RUNTIME_OK=1
    fi
    ;;
  gradle)
    if command -v gradle >/dev/null 2>&1; then
      RUNTIME="gradle $(gradle --version 2>/dev/null | grep -E '^Gradle' | head -n1)"
      RUNTIME_OK=1
    elif [ -x "$PROJECT_DIR/gradlew" ]; then
      RUNTIME="gradlew (wrapper)"
      RUNTIME_OK=1
    fi
    ;;
  go)
    if command -v go >/dev/null 2>&1; then
      RUNTIME="go $(go version 2>/dev/null | awk '{print $3}')"
      RUNTIME_OK=1
    fi
    ;;
  rust)
    if command -v cargo >/dev/null 2>&1; then
      RUNTIME="cargo $(cargo --version 2>/dev/null)"
      RUNTIME_OK=1
    fi
    ;;
  ruby)
    if command -v ruby >/dev/null 2>&1 && command -v bundle >/dev/null 2>&1; then
      RUNTIME="ruby $(ruby --version 2>/dev/null)"
      RUNTIME_OK=1
    fi
    ;;
  shell)
    # The script's own version guard (top of file) has already confirmed
    # bash >= 4. We record the exact version in the runtime line so the
    # report can show it alongside the shell-stack label. There is no
    # separate "install"/"build" step for a pure-shell project — the
    # dependency manifest is the POSIX toolchain, which either works or
    # doesn't, and Stage 4 will surface any missing commands via SKIP.
    RUNTIME="bash ${BASH_VERSION}"
    RUNTIME_OK=1
    ;;
esac

log "Runtime: $RUNTIME (available: $([ "$RUNTIME_OK" = 1 ] && echo yes || echo no))"

# --- Phase 2: .env bootstrap --------------------------------------------
# Do this before install so post-install scripts that read env vars find them.
# Conservative: only copy if .env doesn't already exist (never clobber real
# secrets).

ENV_NOTE=""
if [ ! -f "$PROJECT_DIR/.env" ]; then
  for sample in .env.example .env.sample .env.template; do
    if [ -f "$PROJECT_DIR/$sample" ]; then
      cp "$PROJECT_DIR/$sample" "$PROJECT_DIR/.env"
      log "Bootstrapped .env from $sample"
      ENV_NOTE="bootstrapped .env from $sample"
      break
    fi
  done
fi

# --- Phase 3: dependency install ----------------------------------------

INSTALL_RESULT="SKIPPED"
INSTALL_NOTE=""

if [ "$RUNTIME_OK" = 1 ]; then
  case "$STACK" in
    node)
      # Prefer the lockfile that's actually present.
      cd "$PROJECT_DIR"
      if [ -f "pnpm-lock.yaml" ] && command -v pnpm >/dev/null 2>&1; then
        if run_logged "npm install (pnpm)" pnpm install --frozen-lockfile; then
          INSTALL_RESULT="SUCCESS"
        else
          INSTALL_RESULT="FAILED"
        fi
      elif [ -f "yarn.lock" ] && command -v yarn >/dev/null 2>&1; then
        if run_logged "yarn install" yarn install --frozen-lockfile; then
          INSTALL_RESULT="SUCCESS"
        else
          INSTALL_RESULT="FAILED"
        fi
      else
        # Default path: npm. Try strict first; on failure retry with
        # --legacy-peer-deps per the spec's failure-handling rule.
        if run_logged "npm install" npm install; then
          INSTALL_RESULT="SUCCESS"
        else
          log "npm install failed; retrying with --legacy-peer-deps"
          if run_logged "npm install --legacy-peer-deps" npm install --legacy-peer-deps; then
            INSTALL_RESULT="PARTIAL"
            INSTALL_NOTE="required --legacy-peer-deps"
          else
            INSTALL_RESULT="FAILED"
          fi
        fi
      fi
      ;;
    python)
      cd "$PROJECT_DIR"
      PY=python3
      command -v python3 >/dev/null 2>&1 || PY=python

      # Helper: pip install with a PEP 668 retry. Modern Debian/Ubuntu block
      # system-site installs by default; the spec's failure-handling rule
      # ("try with --legacy-peer-deps equivalent, continue") applies here too.
      pip_install_with_retry() {
        local label="$1"; shift
        if run_logged "$label" "$PY" -m pip install "$@"; then
          return 0
        fi
        # Check whether the last recorded output mentions the PEP 668 marker.
        if tail -n 60 "$LOG_FILE" | grep -qi 'externally-managed-environment\|PEP 668\|--break-system-packages'; then
          log "pip blocked by PEP 668; retrying with --break-system-packages"
          if run_logged "$label (--break-system-packages)" "$PY" -m pip install --break-system-packages "$@"; then
            INSTALL_NOTE="required --break-system-packages"
            return 2  # signals PARTIAL
          fi
        fi
        return 1
      }

      if [ -f "requirements.txt" ]; then
        pip_install_with_retry "pip install -r requirements.txt" -r requirements.txt
        rc=$?
        case $rc in
          0) INSTALL_RESULT="SUCCESS" ;;
          2) INSTALL_RESULT="PARTIAL" ;;
          *) INSTALL_RESULT="FAILED" ;;
        esac
      elif [ -f "pyproject.toml" ]; then
        pip_install_with_retry "pip install ." .
        rc=$?
        case $rc in
          0) INSTALL_RESULT="SUCCESS" ;;
          2) INSTALL_RESULT="PARTIAL" ;;
          *) INSTALL_RESULT="FAILED" ;;
        esac
      elif [ -f "Pipfile" ] && command -v pipenv >/dev/null 2>&1; then
        if run_logged "pipenv install" pipenv install; then
          INSTALL_RESULT="SUCCESS"
        else
          INSTALL_RESULT="FAILED"
        fi
      else
        INSTALL_NOTE="no recognised Python manifest"
      fi
      ;;
    maven)
      cd "$PROJECT_DIR"
      if run_logged "mvn install (no tests)" mvn install -DskipTests; then
        INSTALL_RESULT="SUCCESS"
      else
        INSTALL_RESULT="FAILED"
      fi
      ;;
    gradle)
      cd "$PROJECT_DIR"
      local_gradle="gradle"
      [ -x "$PROJECT_DIR/gradlew" ] && local_gradle="./gradlew"
      if run_logged "gradle build (no tests)" $local_gradle build -x test; then
        INSTALL_RESULT="SUCCESS"
      else
        INSTALL_RESULT="FAILED"
      fi
      ;;
    go)
      cd "$PROJECT_DIR"
      if run_logged "go mod download" go mod download; then
        INSTALL_RESULT="SUCCESS"
      else
        INSTALL_RESULT="FAILED"
      fi
      ;;
    rust)
      cd "$PROJECT_DIR"
      if run_logged "cargo fetch" cargo fetch; then
        INSTALL_RESULT="SUCCESS"
      else
        INSTALL_RESULT="FAILED"
      fi
      ;;
    ruby)
      cd "$PROJECT_DIR"
      if run_logged "bundle install" bundle install; then
        INSTALL_RESULT="SUCCESS"
      else
        INSTALL_RESULT="FAILED"
      fi
      ;;
    shell)
      # Pure-shell projects have no dependency manifest. The project is
      # self-contained; its "dependencies" are the host POSIX toolchain,
      # which is the operator's responsibility. Mark as skipped with a
      # clear note rather than labelling it "unknown stack".
      INSTALL_NOTE="shell project — no dependency install step"
      ;;
    *)
      INSTALL_NOTE="unknown stack"
      ;;
  esac
else
  INSTALL_NOTE="runtime unavailable"
fi

log "Install result: $INSTALL_RESULT${INSTALL_NOTE:+ ($INSTALL_NOTE)}"

# --- Phase 4: build ------------------------------------------------------
# Most projects don't require a separate build step for testing. We only run
# one if there's an obvious build target; missing it is SKIPPED, not FAILED.

BUILD_RESULT="SKIPPED"
BUILD_NOTE=""

if [ "$INSTALL_RESULT" = "SUCCESS" ] || [ "$INSTALL_RESULT" = "PARTIAL" ]; then
  cd "$PROJECT_DIR"
  case "$STACK" in
    node)
      # Only run `npm run build` if a "build" script is actually defined.
      if grep -qE '"build"[[:space:]]*:' package.json 2>/dev/null; then
        if run_logged "npm run build" npm run build; then
          BUILD_RESULT="SUCCESS"
        else
          BUILD_RESULT="FAILED"
          BUILD_NOTE="build script failed; partial testing only"
        fi
      else
        BUILD_NOTE="no build script in package.json"
      fi
      ;;
    python)
      # Python projects usually don't need a build step. Skip unless there's
      # a setup.py build target.
      BUILD_NOTE="no build step required for Python"
      ;;
    maven)
      # `mvn install` above already compiled.
      BUILD_RESULT="SUCCESS"
      ;;
    gradle)
      BUILD_RESULT="SUCCESS"
      ;;
    go)
      if run_logged "go build ./..." go build ./...; then
        BUILD_RESULT="SUCCESS"
      else
        BUILD_RESULT="FAILED"
      fi
      ;;
    rust)
      if run_logged "cargo build" cargo build; then
        BUILD_RESULT="SUCCESS"
      else
        BUILD_RESULT="FAILED"
      fi
      ;;
  esac
fi

log "Build result: $BUILD_RESULT${BUILD_NOTE:+ ($BUILD_NOTE)}"

# --- Phase 5: startup probe ---------------------------------------------
# This is the riskiest phase. Most apps block forever when started. We:
#   1. Launch in the background with stdout/stderr captured
#   2. Sleep briefly to let it initialise
#   3. Check whether the process is still alive
#   4. If we can guess a port, probe it; otherwise "alive" counts as healthy
# The cleanup trap kills the process no matter how the script exits.

STARTUP_RESULT="SKIPPED"
STARTUP_NOTE=""
APP_URL=""

# Startup heuristic: only attempt if install succeeded AND there's something
# that looks like a runnable server. For a CLI or library, startup is N/A.
startup_command() {
  cd "$PROJECT_DIR"
  case "$STACK" in
    node)
      if grep -qE '"start"[[:space:]]*:' package.json 2>/dev/null; then
        echo "npm start"
      elif grep -qE '"dev"[[:space:]]*:' package.json 2>/dev/null; then
        echo "npm run dev"
      fi
      ;;
    python)
      # Only common web frameworks have an obvious dev server. Anything else
      # is left to the human.
      if [ -f "manage.py" ]; then
        echo "python3 manage.py runserver"
      elif [ -f "app.py" ] && grep -qiE '(flask|from flask)' app.py 2>/dev/null; then
        # Flask default CLI; user is responsible for FLASK_APP if needed.
        echo "python3 app.py"
      fi
      ;;
  esac
}

CMD=$(startup_command)

if [ "$INSTALL_RESULT" != "FAILED" ] && [ -n "$CMD" ]; then
  log "Starting app: $CMD"

  # Snapshot listening TCP ports *before* launch, so we can diff after. This
  # is PID-agnostic and works even when the app spawns children (e.g. `npm
  # start` → node), which is the common case.
  # /proc/net/tcp is preferred because it's always present on Linux and needs
  # no external tools. `ss` is the fallback for non-Linux or minimal images.
  # Parse column 2 ("local_address" in IP:PORT hex) where column 4 == 0A
  # (TCP_LISTEN). Done with printf/sed so it works under mawk (no strtonum).
  snapshot_ports() {
    local files=""
    [ -r /proc/net/tcp ]  && files="$files /proc/net/tcp"
    [ -r /proc/net/tcp6 ] && files="$files /proc/net/tcp6"
    if [ -n "$files" ]; then
      # shellcheck disable=SC2086
      awk 'NR>1 && $4=="0A" { n=split($2,a,":"); print a[n] }' $files 2>/dev/null \
        | while read -r hex; do
            # printf handles hex → decimal portably.
            printf '%d\n' "0x$hex" 2>/dev/null
          done | sort -un
    elif command -v ss >/dev/null 2>&1; then
      ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -oE '[0-9]+$' | sort -un
    fi
  }

  PORTS_BEFORE=$(snapshot_ports)

  # `setsid` puts the launched process in its own session and process group,
  # so the cleanup trap can signal the whole tree via `kill -- -PGID`. Fall
  # back to a plain background launch if setsid isn't on the system.
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "cd '$PROJECT_DIR' && exec $CMD" >> "$LOG_FILE" 2>&1 &
    APP_PID=$!
    # In a newly-setsid'd session, the leader's PID equals the PGID.
    APP_PGID="$APP_PID"
  else
    (
      cd "$PROJECT_DIR"
      # shellcheck disable=SC2086
      exec $CMD
    ) >> "$LOG_FILE" 2>&1 &
    APP_PID=$!
    APP_PGID=""
  fi

  # Give the app time to initialise or crash. 5s is a rough middle ground —
  # faster than most frameworks' cold starts, slow enough to catch immediate
  # crashes from missing env vars.
  sleep 5

  if kill -0 "$APP_PID" 2>/dev/null; then
    # Process is alive. Find any new listening port that appeared since
    # launch. This catches child processes that don't share our PID.
    PORT=""
    PORTS_AFTER=$(snapshot_ports)
    if [ -n "$PORTS_AFTER" ]; then
      PORT=$(comm -13 <(echo "$PORTS_BEFORE") <(echo "$PORTS_AFTER") | head -n1)
    fi

    if [ -n "$PORT" ]; then
      APP_URL="http://localhost:$PORT"
      # Best-effort HTTP probe. Short timeout — we just want a TCP accept.
      if command -v curl >/dev/null 2>&1; then
        if curl -sS --max-time 3 -o /dev/null -w '%{http_code}' "$APP_URL" 2>/dev/null | grep -qE '^[2345]'; then
          STARTUP_RESULT="SUCCESS"
          STARTUP_NOTE="listening on port $PORT"
        else
          STARTUP_RESULT="SUCCESS"
          STARTUP_NOTE="process alive on port $PORT but no HTTP response"
        fi
      else
        STARTUP_RESULT="SUCCESS"
        STARTUP_NOTE="listening on port $PORT (curl unavailable)"
      fi
    else
      STARTUP_RESULT="SUCCESS"
      STARTUP_NOTE="process alive; no TCP listener detected (CLI or worker)"
    fi
  else
    STARTUP_RESULT="FAILED"
    STARTUP_NOTE="process exited within 5s — check log for errors"
    APP_PID=""  # don't try to kill a dead process
    APP_PGID=""
  fi
else
  if [ -z "$CMD" ]; then
    STARTUP_NOTE="no recognised start command; library or CLI project"
  else
    STARTUP_NOTE="install failed; startup skipped"
  fi
fi

log "Startup result: $STARTUP_RESULT${STARTUP_NOTE:+ ($STARTUP_NOTE)}"
[ -n "$APP_URL" ] && log "App available at: $APP_URL"

# --- Write the canonical summary block ----------------------------------
# This block is exactly the format specified in 01_environment.md. Stage 5
# parses this by grepping for field names, so order and spelling matter.

{
  echo ""
  echo "=== ENVIRONMENT SUMMARY ==="
  echo "Date: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "Runtime: $RUNTIME"
  echo "Install result: $INSTALL_RESULT"
  echo "Build result: $BUILD_RESULT"
  echo "Startup result: $STARTUP_RESULT"
  echo "App available at: ${APP_URL:-n/a}"
  notes=""
  [ -n "$ENV_NOTE" ]     && notes="$notes; $ENV_NOTE"
  [ -n "$INSTALL_NOTE" ] && notes="$notes; install: $INSTALL_NOTE"
  [ -n "$BUILD_NOTE" ]   && notes="$notes; build: $BUILD_NOTE"
  [ -n "$STARTUP_NOTE" ] && notes="$notes; startup: $STARTUP_NOTE"
  # Strip leading "; "
  notes="${notes#; }"
  echo "Notes: ${notes:-none}"
  echo "=========================="
} >> "$LOG_FILE"

log ""
log "ENVIRONMENT READY"

# The cleanup trap will now kill the app process on exit. Stage 3 (planning)
# doesn't need the app running — it reads the plan and works from static
# analysis. Stage 4 (execution) restarts the app itself if it needs one.
exit 0
