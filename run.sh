#!/bin/bash
# run.sh — Run the deterministic QA pipeline against a project directory
#
# Usage:
#   bash run.sh /path/to/project              # run on host
#   bash run.sh --docker /path/to/project     # run inside a sandboxed container
#
# Environment variables:
#   USE_DOCKER=1        Equivalent to passing --docker.
#   DOCKER_IMAGE=...    Image to run the pipeline in. Default: qa-runner-image.
#                       Build it with `bash setup.sh` before the first --docker run.
#
# The pipeline is five bash scripts executed in order against $PROJECT_DIR:
#   00_ingestion.sh → 01_environment.sh → 02_qa_plan.sh
#                   → 03_test_execution.sh → 04_report.sh
# No network calls beyond whatever package installers each stage needs.

set -e

# --- Argument parsing ----------------------------------------------------
USE_DOCKER="${USE_DOCKER:-0}"

if [ "$1" = "--docker" ]; then
  USE_DOCKER=1
  shift
fi

PROJECT_DIR="$1"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash run.sh [--docker] /path/to/project"
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory."
  exit 1
fi

# Resolve to absolute path to avoid any relative-path ambiguity.
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Location of this script (the pipeline root) before changing directory.
AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "========================================"
echo " Desktop QA Suite (v4)"
echo " Project: $PROJECT_DIR"
echo " Mode:    $([ "$USE_DOCKER" = "1" ] && echo 'sandboxed (Docker)' || echo 'host')"
echo "========================================"
echo ""

# Create the output directory on the host so artifacts are visible regardless
# of whether we sandbox.
mkdir -p "$PROJECT_DIR/qa/tests"

STAGES=(00_ingestion 01_environment 02_qa_plan 03_test_execution 04_report)

# --- Teardown trap -------------------------------------------------------
# In --docker mode, write the container ID to a file and tear it down on
# exit. `docker run --rm` already cleans up on normal exit; the trap handles
# the mid-pipeline SIGINT/SIGTERM case where --rm hasn't fired yet.
CID_FILE=""
cleanup() {
  if [ -n "$CID_FILE" ] && [ -f "$CID_FILE" ]; then
    local cid
    cid="$(cat "$CID_FILE" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      docker rm -f "$cid" >/dev/null 2>&1 || true
    fi
    rm -f "$CID_FILE"
  fi
}
trap cleanup EXIT INT TERM

# --- Container mode ------------------------------------------------------
if [ "$USE_DOCKER" = "1" ]; then
  if ! command -v docker &> /dev/null; then
    echo "Error: --docker requested but docker CLI is not installed."
    exit 1
  fi
  if ! docker info &> /dev/null; then
    echo "Error: Docker daemon is not reachable. Is Docker Desktop running?"
    exit 1
  fi

  DOCKER_IMAGE="${DOCKER_IMAGE:-qa-runner-image}"

  # Confirm the image exists locally. Unlike the prior iteration we do NOT
  # pull from a registry — qa-runner-image is built locally by setup.sh and
  # has no upstream. If it's missing, point the user at the fix.
  if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    echo "Error: Docker image '$DOCKER_IMAGE' not found locally."
    echo "  Build it first with: bash setup.sh"
    echo "  (Or override with DOCKER_IMAGE=<name> if you maintain your own.)"
    exit 1
  fi

  # -t only when we have a TTY; -i always so stdio works under CI too.
  TTY_FLAG=""
  if [ -t 0 ] && [ -t 1 ]; then
    TTY_FLAG="-t"
  fi

  CID_FILE="$(mktemp)"
  # --cidfile needs a path that does NOT exist yet; mktemp created it.
  rm -f "$CID_FILE"

  # Build the in-container command: loop stages, fail fast on the first
  # non-zero exit. The pipeline scripts live at /agent (read-only mount);
  # the project under test lives at /app.
  IN_CONTAINER_CMD='set -e
for s in 00_ingestion 01_environment 02_qa_plan 03_test_execution 04_report; do
  echo "[stage] $s"
  bash "/agent/${s}.sh" /app
done'

  docker run --rm -i $TTY_FLAG \
    --cidfile "$CID_FILE" \
    --label qa-runner \
    -v "$PROJECT_DIR":/app \
    -v "$AGENT_DIR":/agent:ro \
    -w /app \
    "$DOCKER_IMAGE" \
    bash -lc "$IN_CONTAINER_CMD"

  exit $?
fi

# --- Host mode -----------------------------------------------------------
cd "$PROJECT_DIR"

for s in "${STAGES[@]}"; do
  echo "[stage] $s"
  bash "$AGENT_DIR/${s}.sh" "$PROJECT_DIR"
done

echo ""
echo "Pipeline complete. Artifacts in: $PROJECT_DIR/qa/"
