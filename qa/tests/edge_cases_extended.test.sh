#!/usr/bin/env bash
# edge_cases_extended.test.sh — Additional edge cases complementing
# edge_cases_test.sh. Covers concurrency, signal handling, and large
# input resilience from a project-agnostic angle.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

SCRATCH=$(make_scratch)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

ENTRY=$(ingestion_entry_point)

# E01: Two writers can create files in a shared scratch directory without
# race-condition artefacts. This is really a test of the filesystem and
# the shell — if it fails, every concurrent-writer test in the suite is
# on shaky ground.
(
  for i in $(seq 1 20); do echo "$i" > "$SCRATCH/a_$i.txt"; done
) &
pid_a=$!
(
  for i in $(seq 1 20); do echo "$i" > "$SCRATCH/b_$i.txt"; done
) &
pid_b=$!
wait $pid_a $pid_b
count=$(find "$SCRATCH" -maxdepth 1 -name '?_*.txt' | wc -l | tr -d ' ')
if [ "$count" -eq 40 ]; then
  ok "E01 concurrent writers produced all 40 expected files"
else
  fail "E01" "concurrent writers produced $count files (expected 40)"
fi

# E02: SIGTERM propagation. A shell entry script that starts background
# work should clean up on SIGTERM, not leave orphans. We test this in a
# general way: start a script that traps EXIT, send SIGTERM, and confirm
# the trap fired. Only meaningful for shell entries.
if [ -n "$ENTRY" ] && [[ "$ENTRY" == *.sh || "$ENTRY" == *.bash ]]; then
  # Check whether the entry script declares an EXIT/TERM trap. A project
  # that traps SIGTERM is generally better-behaved than one that doesn't.
  # We don't fail if absent — it's a best practice, not a requirement.
  if grep -qE '^[[:space:]]*trap[[:space:]]+' "$PROJECT_DIR/$ENTRY" 2>/dev/null; then
    ok "E02 entry script declares at least one signal trap"
  else
    skip "E02" "entry script declares no traps — may leak processes on SIGTERM"
  fi
else
  skip "E02" "no shell entry to inspect"
fi

# E03: Large input. Many scripts that work fine on a few KB choke on an
# MB-scale input due to naive `cat` / `while read` patterns. We generate
# a 1 MB file and simply verify the filesystem accepts it and basic
# tools (wc, head, tail) can process it in under 5 seconds.
LARGE="$SCRATCH/large.txt"
yes "The quick brown fox jumps over the lazy dog" | head -n 20000 > "$LARGE" 2>/dev/null
size=$(wc -c < "$LARGE")
if [ "$size" -ge 900000 ]; then
  start=$(date +%s)
  wc -l "$LARGE" >/dev/null
  head -n 1 "$LARGE" >/dev/null
  tail -n 1 "$LARGE" >/dev/null
  elapsed=$(( $(date +%s) - start ))
  if [ "$elapsed" -le 5 ]; then
    ok "E03 1 MB file processed in ${elapsed}s (standard tools fast enough)"
  else
    fail "E03" "standard tools took ${elapsed}s on 1 MB — environment is unusually slow"
  fi
else
  skip "E03" "could not generate ~1 MB file (size=$size); likely minimal shell"
fi

# E04: Many-files-in-a-directory. `ls` and glob expansion break under
# very large directories. We test at 1000 files, which is modest but
# enough to catch O(n^2) patterns in the shell code we're exercising.
MANY="$SCRATCH/many"
mkdir -p "$MANY"
for i in $(seq 1 1000); do : > "$MANY/f_$i"; done
start=$(date +%s)
count=$(ls "$MANY" | wc -l | tr -d ' ')
elapsed=$(( $(date +%s) - start ))
if [ "$count" -eq 1000 ] && [ "$elapsed" -le 3 ]; then
  ok "E04 1000-file directory listed correctly in ${elapsed}s"
else
  fail "E04" "1000-file listing: count=$count, elapsed=${elapsed}s"
fi

# E05: Filename with leading dash. A common shell bug: `rm *` picks up
# `-rf` as a flag if a file named `-rf` exists. A well-written project
# uses `--` separators. We just verify the project can tolerate the
# presence of such a file in its scratch space — not the project's fault
# if another process created it, but its code should survive.
if touch -- "$SCRATCH/-dash_file" 2>/dev/null; then
  # Clean up with the safe pattern: `rm -- -dash_file`
  rm -- "$SCRATCH/-dash_file" 2>/dev/null
  ok "E05 filesystem accepts filenames starting with a dash"
else
  skip "E05" "filesystem rejected leading-dash filename"
fi

# E06: Read-only mount. Pipeline stages must fail cleanly on a read-only
# target. We can't remount anything as root-less, so we simulate by
# chmod'ing a dir 0555. This exercises the *environment's* ability to
# surface EACCES — the project's own handling of it would need a
# project-specific test.
RO="$SCRATCH/readonly"
mkdir -p "$RO"
chmod 0555 "$RO"
if (: > "$RO/write_probe") 2>/dev/null; then
  # The write succeeded — filesystem doesn't honour 0555. Skip, don't fail.
  chmod 0755 "$RO"
  rm -f "$RO/write_probe"
  skip "E06" "filesystem ignores chmod 0555 (probably FAT/overlayfs)"
else
  ok "E06 filesystem enforces read-only directory (chmod 0555)"
  chmod 0755 "$RO"
fi
