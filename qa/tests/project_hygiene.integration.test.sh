#!/usr/bin/env bash
# Category: integration
# Use case: Validate project hygiene with configurable strictness.
# Summary: Keeps documentation and cache checks useful while treating OS metadata as advisory by default.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TARGET_REQUIRED_SECTIONS="${TARGET_REQUIRED_SECTIONS:-}"
TARGET_STRICT_HYGIENE="${TARGET_STRICT_HYGIENE:-0}"

csv_items() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d'
}

safe_find_files() {
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/venv' -o \
       -path '*/.venv' -o -path '*/__pycache__' -o -path '*/dist' -o \
       -path '*/build' -o -path '*/target' -o -path '*/.pytest_cache' \) -prune \
    -o -type f "$@" -print 2>/dev/null
}

text_search() {
  needle="$1"
  while IFS= read -r file; do
    case "$file" in
      *.md|*.txt|*.sh|*.bash|*.py|*.js|*.ts|*.json|*.yml|*.yaml|*.toml|*.ini|*.cfg)
        grep -F -- "$needle" "$file" >/dev/null 2>&1 && return 0
        ;;
    esac
  done < <(safe_find_files)
  return 1
}

README_FILE=""
for candidate in README.md README.rst README.txt README; do
  if [ -f "$PROJECT_DIR/$candidate" ]; then
    README_FILE="$candidate"
    break
  fi
done
if [ -n "$README_FILE" ]; then
  ok "I01 README present"
else
  skip "I01" "no README found at project root"
fi

if [ -n "$README_FILE" ]; then
  bytes="$(wc -c < "$PROJECT_DIR/$README_FILE" | tr -d ' ')"
  if [ "$bytes" -ge 120 ]; then
    ok "I02 README has substantive content"
  else
    skip "I02" "$README_FILE is short ($bytes bytes)"
  fi
else
  skip "I02" "depends on I01"
fi

if [ -f "$PROJECT_DIR/.gitignore" ] || [ -f "$PROJECT_DIR/gitignore" ]; then
  ok "I03 ignore file present"
else
  skip "I03" "no ignore file at project root"
fi

mapfile -t JUNK < <(safe_find_files \( -name '.DS_Store' -o -name 'Thumbs.db' -o -name 'desktop.ini' \))
if [ "${#JUNK[@]}" -eq 0 ]; then
  ok "I04 no common OS metadata files found"
elif [ "$TARGET_STRICT_HYGIENE" = "1" ]; then
  fail "I04" "${#JUNK[@]} OS metadata file(s) found"
else
  skip "I04" "${#JUNK[@]} OS metadata file(s) found; advisory unless TARGET_STRICT_HYGIENE=1"
fi

offenders=""
for path in node_modules venv .venv __pycache__ dist build target .pytest_cache; do
  if [ -e "$PROJECT_DIR/$path" ] && [ ! -L "$PROJECT_DIR/$path" ]; then
    if find "$PROJECT_DIR/$path" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      offenders="$offenders $path"
    fi
  fi
done
if [ -z "$offenders" ]; then
  ok "I05 no common build or cache directories at project root"
else
  fail "I05" "build/cache directories present at project root:$offenders"
fi

if [ -n "$TARGET_REQUIRED_SECTIONS" ]; then
  missing=""
  while IFS= read -r marker; do
    text_search "$marker" >/dev/null 2>&1 || missing="$missing [$marker]"
  done <<EOF
$(csv_items "$TARGET_REQUIRED_SECTIONS")
EOF
  if [ -z "$missing" ]; then
    ok "I06 configured text markers were found"
  else
    fail "I06" "missing configured text marker(s):$missing"
  fi
else
  skip "I06" "TARGET_REQUIRED_SECTIONS is not configured"
fi
