#!/usr/bin/env bash
# Category: unit
# Language: Python
# Use case: Validate Python source and dependency metadata without installing packages.
# Summary: Runs py_compile when available and checks common manifest files for basic reproducibility hints.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t PY_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/venv' -o -path '*/.venv' -o -path '*/__pycache__' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.py' -print 2>/dev/null | head -n 40
)

if [ "${#PY_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/pyproject.toml" ] && [ ! -f "$PROJECT_DIR/requirements.txt" ]; then
  for id in PY01 PY02 PY03 PY04; do skip "$id" "no Python files or manifests found"; done
  exit 0
fi
ok "PY01 Python surface discovered"

if [ "${#PY_FILES[@]}" -eq 0 ]; then
  skip "PY02" "no Python files to compile"
elif has_command python3; then
  bad=()
  for file in "${PY_FILES[@]}"; do
    python3 -m py_compile "$file" >/dev/null 2>&1 || bad+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#bad[@]}" -eq 0 ]; then
    ok "PY02 sampled Python files pass py_compile"
  else
    fail "PY02" "py_compile failed: ${bad[*]}"
  fi
else
  skip "PY02" "python3 is not available"
fi

if [ -f "$PROJECT_DIR/pyproject.toml" ]; then
  if grep -Eq '^\[project\]|^\[tool\.' "$PROJECT_DIR/pyproject.toml"; then
    ok "PY03 pyproject.toml has project or tool metadata"
  else
    fail "PY03" "pyproject.toml lacks [project] or [tool.*] sections"
  fi
elif [ -f "$PROJECT_DIR/requirements.txt" ]; then
  ok "PY03 requirements.txt present"
else
  skip "PY03" "no Python manifest found"
fi

if [ -f "$PROJECT_DIR/requirements.txt" ]; then
  unpinned=$(grep -Ev '^[[:space:]]*(#|$)' "$PROJECT_DIR/requirements.txt" | grep -Evc '==|~=|>=|<=|@' || true)
  if [ "$unpinned" -eq 0 ]; then
    ok "PY04 requirements.txt dependencies include version constraints or direct refs"
  else
    skip "PY04" "$unpinned requirement(s) have no visible version constraint"
  fi
else
  skip "PY04" "requirements.txt not present"
fi
