#!/usr/bin/env bash
# _lib.sh — Shared helpers for the Desktop QA plug-and-play test suite.
#
# Every test file in this directory sources this file. Its job:
#
#   1. Resolve $PROJECT_DIR portably.
#   2. Provide ok / fail / skip emitters that match the batch-summary
#      convention parsed by 03_test_execution.sh (`PASS:` / `FAIL:` /
#      `SKIP:` at column 0, final `PASS: N | FAIL: N | SKIP: N`).
#   3. Provide helpers that inspect ingestion_summary.md so individual
#      tests can discover facts about the project under test (stack,
#      entry points, HTTP framework, env usage) rather than hardcoding
#      desktop-qa-specific paths.
#   4. Provide small utilities (find_first_match, has_command) that
#      keep individual tests short and readable.
#
# Everything here is project-agnostic. The only contract a caller must
# honour is exporting $PROJECT_DIR (or running this file from inside
# qa/tests/ so the derivation below works).

# --- Project root resolution --------------------------------------------
# Honour $PROJECT_DIR if the runner already exported it. Otherwise derive
# it from the test file's location: tests live at $PROJECT_DIR/qa/tests/,
# so two `..` hops from the test file's directory give us the root.
# Callers source us via `source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"`,
# which makes ${BASH_SOURCE[1]} point to the test file itself.
if [ -z "${PROJECT_DIR:-}" ]; then
  _CALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
  PROJECT_DIR="$(cd "$_CALLER_DIR/../.." && pwd)"
  export PROJECT_DIR
fi

# Canonical paths downstream tests rely on.
QA_DIR="$PROJECT_DIR/qa"
INGESTION_FILE="$QA_DIR/ingestion_summary.md"

# --- Counters & emitters -------------------------------------------------
# The runner in 03_test_execution.sh parses three things from a test file's
# output:
#   a) individual lines starting with PASS:, FAIL:, SKIP: (authoritative
#      when no summary block is present)
#   b) a final `PASS: N | FAIL: N | SKIP: N` line (preferred — it includes
#      skips that might not have printed their own line)
#
# We emit both, so the runner has either signal available.
PASS=0; FAIL=0; SKIP=0

ok()   { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — ${2:-}"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1 — ${2:-}"; SKIP=$((SKIP + 1)); }

# Print the summary block. Every test file calls this at the very end.
# Register it as an EXIT trap so a test that aborts mid-run still gets a
# summary — otherwise the parser falls through to its exit-code fallback
# and credits the file with a single PASS/FAIL instead of the partial
# results actually collected.
_print_summary() {
  echo ""
  echo "=== BATCH SUMMARY ==="
  echo "PASS: $PASS | FAIL: $FAIL | SKIP: $SKIP"
}
trap _print_summary EXIT

# --- Ingestion helpers --------------------------------------------------
# These functions read ingestion_summary.md (the Stage 1 output) to answer
# questions about the project under test. Tests call them instead of
# hardcoding script names, so the same test file produces meaningful
# results against a Node, Python, Go, or shell project.
#
# If ingestion_summary.md is absent we return empty/false — individual
# tests will then skip with a clear reason, which is the correct
# behaviour for a pipeline whose Stage 1 hasn't run yet.

# True if ingestion_summary.md exists.
has_ingestion() {
  [ -f "$INGESTION_FILE" ]
}

# Echo the project's primary language as a lowercase token (e.g. "shell",
# "javascript", "python"). Empty if ingestion is missing or empty.
ingestion_language() {
  has_ingestion || { echo ""; return; }
  # The Languages section emits lines like `- Shell (12 files)`. Take the
  # first entry — that's the highest-count language.
  awk '/^### Languages/{flag=1; next} flag && /^- /{print tolower($2); exit}' \
      "$INGESTION_FILE" 2>/dev/null
}

# Echo the framework line, lowercased, or empty. Example output:
# "framework: shell project (no well-known framework detected)".
ingestion_framework() {
  has_ingestion || { echo ""; return; }
  grep -iE '^- Framework:' "$INGESTION_FILE" 2>/dev/null \
    | head -n1 \
    | tr '[:upper:]' '[:lower:]'
}

# True if the project looks like an HTTP service based on the framework
# name. Covers the common Node, Python, Java, and Ruby web stacks.
ingestion_is_http() {
  local fw
  fw=$(ingestion_framework)
  case "$fw" in
    *express*|*fastify*|*koa*|*nestjs*|*next*|*nuxt*|*remix*) return 0 ;;
    *django*|*flask*|*fastapi*|*starlette*|*pyramid*|*tornado*|*aiohttp*) return 0 ;;
    *spring*) return 0 ;;
    *rails*) return 0 ;;
  esac
  return 1
}

# Echo the first entry-point path (relative to $PROJECT_DIR) from the
# ingestion summary's Entry Points section. Empty if none.
ingestion_entry_point() {
  has_ingestion || { echo ""; return; }
  awk '/^## Entry Points/{flag=1; next}
       /^## /{flag=0}
       flag && /^- [^(]/ {
         # Strip the leading "- " and any trailing annotation in parens.
         sub(/^- */, "");
         sub(/ *\(.*$/, "");
         print; exit
       }' "$INGESTION_FILE" 2>/dev/null
}

# True if the ingestion summary flagged env-var usage (.env file or
# process.env/os.environ references).
ingestion_uses_env() {
  has_ingestion || return 1
  grep -qiE '\.env|env-var usage detected' "$INGESTION_FILE" 2>/dev/null
}

# True if the ingestion summary listed a lockfile (npm/yarn/pnpm/pip etc).
# Used by integration tests that need reproducible installs.
ingestion_has_lockfile() {
  has_ingestion || return 1
  grep -qiE 'package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Pipfile\.lock|poetry\.lock|Cargo\.lock|go\.sum' \
       "$INGESTION_FILE" 2>/dev/null
}

# --- Generic utilities --------------------------------------------------

# True if a command is available on PATH.
has_command() { command -v "$1" >/dev/null 2>&1; }

# Echo the first file under $PROJECT_DIR matching any of the given globs
# (relative paths). Skips node_modules / .git / venv noise. Empty if none.
# Usage: find_first_match '*.py' 'src/*.py'
find_first_match() {
  local pat
  for pat in "$@"; do
    local hit
    hit=$(find "$PROJECT_DIR" \
            \( -path '*/node_modules' -o -path '*/.git' -o \
               -path '*/venv' -o -path '*/.venv' -o \
               -path '*/__pycache__' -o -path '*/dist' -o \
               -path '*/build' -o -path '*/target' \) -prune \
            -o -type f -name "$pat" -print 2>/dev/null \
          | head -n1)
    if [ -n "$hit" ]; then
      echo "${hit#$PROJECT_DIR/}"
      return
    fi
  done
}

# Echo a short, safe scratch directory. Caller is responsible for rm -rf.
make_scratch() { mktemp -d 2>/dev/null || mktemp -d -t qa-scratch; }

# True if running under a TTY — used by tests that would otherwise hang on
# stdin reads (e.g. verifying an interactive script's non-interactive
# fallback path).
is_tty() { [ -t 0 ]; }
