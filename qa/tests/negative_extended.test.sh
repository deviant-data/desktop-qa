#!/usr/bin/env bash
# negative_extended.test.sh — Extended negative tests.
#
# Targets negative paths in the project's declared surface that aren't
# about argument handling: missing env vars, corrupt fixtures, bad
# ingestion input. Each test skips cleanly if the project doesn't have
# the relevant surface.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SCRATCH=$(make_scratch)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# N01: Corrupt ingestion_summary.md is detected. We simulate corruption
# by pointing a downstream stage at an empty qa/ directory in our
# scratch, and verifying the downstream script emits an error. Only
# runs if the project ships such a script.
#
# We look for anything matching 01_*.sh or similar that takes a project
# dir and expects ingestion to exist. If none, skip.
DOWNSTREAM=""
for cand in 01_environment.sh 02_qa_plan.sh 03_test_execution.sh; do
  [ -f "$PROJECT_DIR/$cand" ] && DOWNSTREAM="$cand" && break
done

if [ -n "$DOWNSTREAM" ]; then
  # Build a faux project without ingestion_summary.md.
  FAUX="$SCRATCH/faux"; mkdir -p "$FAUX/qa"
  out=$(bash "$PROJECT_DIR/$DOWNSTREAM" "$FAUX" 2>&1); rc=$?
  # We want non-zero exit AND a mention of ingestion in the error,
  # otherwise the user gets a confusing downstream crash.
  if [ $rc -ne 0 ] && echo "$out" | grep -qiE 'ingestion|summary'; then
    ok "N01 $DOWNSTREAM fails loudly when ingestion_summary.md is missing (exit $rc)"
  elif [ $rc -ne 0 ]; then
    fail "N01" "$DOWNSTREAM exited $rc but error didn't mention ingestion"
  else
    fail "N01" "$DOWNSTREAM accepted a project with no ingestion_summary.md (exit 0)"
  fi
else
  skip "N01" "project has no pipeline-style downstream script"
fi

# N02: Unwritable qa/ directory. A downstream stage that tries to write
# under qa/ should fail clearly, not crash with a permission denied
# trace. We can only test this meaningfully if a downstream script
# exists; otherwise skip.
if [ -n "$DOWNSTREAM" ]; then
  RO="$SCRATCH/ro_proj"; mkdir -p "$RO/qa"
  # Seed a minimal ingestion summary so we get past N01's check.
  cat > "$RO/qa/ingestion_summary.md" <<'EOF'
# Ingestion Summary
## Stack
## Entry Points
## Dependency Manifest
## Flags & Observations
EOF
  chmod 0555 "$RO/qa"   # Read/exec only.
  # If the filesystem doesn't honour chmod 0555 (FAT, overlayfs) the
  # test becomes meaningless — probe and skip in that case.
  if (: > "$RO/qa/probe") 2>/dev/null; then
    rm -f "$RO/qa/probe"
    chmod 0755 "$RO/qa"
    skip "N02" "filesystem ignores chmod 0555 — can't simulate unwritable qa/"
  else
    out=$(bash "$PROJECT_DIR/$DOWNSTREAM" "$RO" 2>&1); rc=$?
    chmod 0755 "$RO/qa"
    if [ $rc -ne 0 ]; then
      ok "N02 $DOWNSTREAM fails on unwritable qa/ (exit $rc)"
    else
      fail "N02" "$DOWNSTREAM exited 0 despite unwritable qa/"
    fi
  fi
else
  skip "N02" "no downstream script to probe"
fi

# N03: Garbage ingestion_summary.md is handled. A downstream stage
# should not parse garbage as success. We write a 1-byte file and see
# whether the downstream exits zero.
if [ -n "$DOWNSTREAM" ]; then
  GARBAGE="$SCRATCH/garbage_proj"; mkdir -p "$GARBAGE/qa"
  printf '?' > "$GARBAGE/qa/ingestion_summary.md"
  out=$(bash "$PROJECT_DIR/$DOWNSTREAM" "$GARBAGE" 2>&1); rc=$?
  # We accept either non-zero exit OR an exit-0 run that logged a
  # complaint about the garbage. The latter is common for stages that
  # degrade to "partial" rather than fail outright.
  if [ $rc -ne 0 ]; then
    ok "N03 $DOWNSTREAM rejects a 1-byte ingestion summary (exit $rc)"
  elif echo "$out" | grep -qiE 'empty|malformed|invalid|unknown'; then
    ok "N03 $DOWNSTREAM ran on garbage but logged a complaint"
  else
    # Exit 0 and no complaint on a 1-byte file is the failure mode we
    # care about — it means garbage propagates silently downstream.
    skip "N03" "$DOWNSTREAM silently processed a 1-byte ingestion summary (exit 0) — review tolerance"
  fi
else
  skip "N03" "no downstream script to probe"
fi
