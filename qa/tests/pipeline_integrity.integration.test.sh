#!/usr/bin/env bash
# Category: integration
# Use case: Validate broad project directory health without over-penalizing local OS artifacts.
# Summary: Checks README, ignore files, build/cache directories, and reports OS metadata as advisory unless strict mode is enabled.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET_STRICT_HYGIENE="${TARGET_STRICT_HYGIENE:-0}"

README=""
for candidate in README.md README.rst README.txt README; do
  if [ -f "$PROJECT_DIR/$candidate" ]; then
    README="$candidate"
    break
  fi
done

if [ -n "$README" ]; then
  ok "I01 README present ($README)"
else
  fail "I01" "no README file found at project root"
fi

if [ -n "$README" ]; then
  size=$(wc -c < "$PROJECT_DIR/$README" | tr -d ' ')
  if [ "$size" -ge 200 ]; then
    ok "I02 README has substantive content ($size bytes)"
  else
    skip "I02" "$README is short ($size bytes); may be acceptable for small projects"
  fi
else
  skip "I02" "no README to inspect"
fi

if [ -f "$PROJECT_DIR/.gitignore" ] || [ -f "$PROJECT_DIR/gitignore" ]; then
  ok "I03 ignore file present"
else
  skip "I03" "no .gitignore or gitignore at project root"
fi

mapfile -t JUNK < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/venv' -o \
       -path '*/.venv' -o -path '*/__pycache__' -o -path '*/dist' -o \
       -path '*/build' -o -path '*/target' \) -prune \
    -o -type f \( -name '.DS_Store' -o -name 'Thumbs.db' -o -name 'desktop.ini' \) -print 2>/dev/null
)
if [ "${#JUNK[@]}" -eq 0 ]; then
  ok "I04 no common OS metadata files found"
elif [ "$TARGET_STRICT_HYGIENE" = "1" ]; then
  fail "I04" "${#JUNK[@]} OS metadata file(s) found: ${JUNK[*]#$PROJECT_DIR/}"
else
  skip "I04" "${#JUNK[@]} OS metadata file(s) found; advisory unless TARGET_STRICT_HYGIENE=1"
fi

OFFENDERS=()
for path in node_modules venv .venv __pycache__ dist build target .pytest_cache; do
  if [ -e "$PROJECT_DIR/$path" ] && [ ! -L "$PROJECT_DIR/$path" ]; then
    if find "$PROJECT_DIR/$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      OFFENDERS+=("$path")
    fi
  fi
done
if [ "${#OFFENDERS[@]}" -eq 0 ]; then
  ok "I05 no common build/cache directories at project root"
else
  fail "I05" "build/cache directories present at project root: ${OFFENDERS[*]}"
fi
