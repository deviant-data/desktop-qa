#!/bin/bash
# setup.sh — One-time setup for the Desktop QA Suite
#
# Responsibilities:
#   1. Verify required host tools (bash 4+, Docker optional).
#   2. Report which language runtimes are present on the host (informational).
#   3. If Docker is available, build the sandboxed runner image from the
#      Dockerfile that ships alongside this script.
#
# This script does NOT run the pipeline. Pipeline invocation lives in run.sh.

set -e

AGENT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_NAME="${IMAGE_NAME:-qa-runner-image}"

echo "Setting up Desktop QA Suite (v4)..."
echo ""

# --- Host bash version ---------------------------------------------------
# The stage scripts require bash 4+ (they use `declare -A` and friends).
# run.sh itself runs fine on 3.2 but the downstream stages do not; flag
# early so the operator is not surprised mid-pipeline.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "⚠ Host bash is ${BASH_VERSION:-unknown}. The pipeline stages require bash 4+."
  echo "  On macOS: brew install bash, then invoke stages with the Homebrew bash."
  echo "  Host-mode runs will fail at the first stage until this is resolved."
  echo "  (Docker mode is unaffected — the container ships its own bash.)"
else
  echo "✓ bash $BASH_VERSION"
fi

# --- Docker (optional but recommended) -----------------------------------
DOCKER_OK=0
if command -v docker &> /dev/null; then
  if docker info &> /dev/null; then
    DOCKER_OK=1
    echo "✓ Docker CLI and daemon available"
  else
    echo "⚠ Docker CLI found but daemon is not reachable."
    echo "  Start Docker Desktop (or the docker service) and re-run setup.sh"
    echo "  if you plan to use --docker mode."
  fi
else
  echo "⚠ Docker not found. The pipeline will only run in host mode."
fi

# --- Common language runtimes (informational) ----------------------------
# These are checked for host mode only. The sandbox image bakes in its own.
echo ""
echo "Host language runtimes (used in host mode):"
for cmd in node python3 java go rustc ruby; do
  if command -v "$cmd" &> /dev/null; then
    echo "  ✓ $cmd"
  else
    echo "    $cmd not found (install if testing $cmd projects in host mode)"
  fi
done

# --- Build the sandbox image --------------------------------------------
# This is the only bit of setup that does real work. We build the
# qa-runner-image from the Dockerfile in this directory so the first
# `bash run.sh --docker ...` doesn't pay the build cost mid-pipeline.
if [ "$DOCKER_OK" = "1" ]; then
  echo ""
  if [ ! -f "$AGENT_DIR/Dockerfile" ]; then
    echo "⚠ Dockerfile not found at $AGENT_DIR/Dockerfile — skipping image build."
  else
    echo "Building sandbox image: $IMAGE_NAME"
    echo "  (this takes a few minutes on first run; subsequent runs use the cache)"
    if docker build -t "$IMAGE_NAME" "$AGENT_DIR"; then
      echo "✓ $IMAGE_NAME built"
    else
      echo "✗ Image build failed. Fix the error above and re-run setup.sh."
      exit 1
    fi
  fi
fi

echo ""
echo "Setup complete."
echo "  Host mode:      bash run.sh /path/to/project"
echo "  Sandbox mode:   bash run.sh --docker /path/to/project"
