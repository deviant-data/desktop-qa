#!/usr/bin/env bash
# Category: integration
# Use case: Validate QA output and artifact declarations.
# Summary: Checks output directory writability, configured artifacts, optional manifest consistency, and log format.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

TEST_LOG_FILE="${TEST_LOG_FILE:-$QA_DIR/test_log.txt}"
TARGET_OUTPUT_DIR="${TARGET_OUTPUT_DIR:-$QA_DIR}"
TARGET_REQUIRED_ARTIFACTS="${TARGET_REQUIRED_ARTIFACTS:-}"
TARGET_MANIFEST_FILE="${TARGET_MANIFEST_FILE:-}"
TARGET_ALLOW_WRITE_CHECKS="${TARGET_ALLOW_WRITE_CHECKS:-1}"

csv_items() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d'
}

safe_find_files() {
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/venv' -o \
       -path '*/.venv' -o -path '*/__pycache__' -o -path '*/dist' -o \
       -path '*/build' -o -path '*/target' -o -path '*/.pytest_cache' \) -prune \
    -o -type f -print 2>/dev/null
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

if [ "$TARGET_ALLOW_WRITE_CHECKS" = "1" ]; then
  if mkdir -p "$TARGET_OUTPUT_DIR" 2>/dev/null; then
    ok "I01 target output directory exists or is creatable"
  else
    fail "I01" "cannot create target output directory: $TARGET_OUTPUT_DIR"
  fi
else
  skip "I01" "write checks disabled"
fi

if [ -d "$TARGET_OUTPUT_DIR" ] && [ "$TARGET_ALLOW_WRITE_CHECKS" = "1" ]; then
  probe="$TARGET_OUTPUT_DIR/.qa_write_probe_$$"
  if (: > "$probe") 2>/dev/null; then
    rm -f "$probe"
    ok "I02 target output directory is writable"
  else
    fail "I02" "target output directory is not writable"
  fi
else
  skip "I02" "depends on I01"
fi

if [ -n "$TARGET_REQUIRED_ARTIFACTS" ]; then
  missing=""
  while IFS= read -r artifact; do
    text_search "$artifact" >/dev/null 2>&1 || missing="$missing [$artifact]"
  done <<EOF
$(csv_items "$TARGET_REQUIRED_ARTIFACTS")
EOF
  if [ -z "$missing" ]; then
    ok "I03 configured artifacts are declared in project text"
  else
    fail "I03" "artifact declaration(s) not found:$missing"
  fi
else
  skip "I03" "TARGET_REQUIRED_ARTIFACTS is not configured"
fi

if [ -n "$TARGET_MANIFEST_FILE" ] && [ -n "$TARGET_REQUIRED_ARTIFACTS" ]; then
  if [ ! -f "$TARGET_MANIFEST_FILE" ]; then
    fail "I04" "configured manifest file is missing"
  else
    manifest_missing=""
    while IFS= read -r artifact; do
      grep -F -- "$artifact" "$TARGET_MANIFEST_FILE" >/dev/null 2>&1 || manifest_missing="$manifest_missing [$artifact]"
    done <<EOF
$(csv_items "$TARGET_REQUIRED_ARTIFACTS")
EOF
    if [ -z "$manifest_missing" ]; then
      ok "I04 manifest lists configured artifacts"
    else
      fail "I04" "manifest missing artifact(s):$manifest_missing"
    fi
  fi
else
  skip "I04" "TARGET_MANIFEST_FILE or TARGET_REQUIRED_ARTIFACTS is not configured"
fi

if [ -f "$TEST_LOG_FILE" ]; then
  if grep -Eq '^(=== TEST EXECUTION ===|=== ENVIRONMENT SETUP ===|=== TEST EXECUTION SUMMARY ===)' "$TEST_LOG_FILE"; then
    ok "I05 test_log.txt uses recognizable pipeline section headers"
  else
    skip "I05" "test_log.txt exists but has no recognized section headers"
  fi
else
  skip "I05" "test_log.txt not present yet"
fi
