#!/usr/bin/env bash
# Category: unit
# Language: Java
# Use case: Validate Java source and build metadata with static, no-install checks.
# Summary: Checks source discovery, public class filename consistency, and Maven/Gradle manifest presence.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t JAVA_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/target' -o -path '*/build' -o -path '*/qa/tests' \) -prune \
    -o -type f -name '*.java' -print 2>/dev/null | head -n 40
)

if [ "${#JAVA_FILES[@]}" -eq 0 ] && [ ! -f "$PROJECT_DIR/pom.xml" ] && [ ! -f "$PROJECT_DIR/build.gradle" ] && [ ! -f "$PROJECT_DIR/build.gradle.kts" ]; then
  for id in JV01 JV02 JV03 JV04; do skip "$id" "no Java files or build manifests found"; done
  exit 0
fi
ok "JV01 Java surface discovered"

if [ "${#JAVA_FILES[@]}" -eq 0 ]; then
  skip "JV02" "no Java source files to inspect"
else
  mismatch=()
  for file in "${JAVA_FILES[@]}"; do
    public_class=$(grep -E '^[[:space:]]*public[[:space:]]+(final[[:space:]]+|abstract[[:space:]]+)?class[[:space:]]+[A-Za-z_][A-Za-z_0-9]*' "$file" | head -n 1 | sed -E 's/.*class[[:space:]]+([A-Za-z_][A-Za-z_0-9]*).*/\1/')
    [ -z "$public_class" ] && continue
    [ "$(basename "$file" .java)" = "$public_class" ] || mismatch+=("${file#$PROJECT_DIR/}")
  done
  if [ "${#mismatch[@]}" -eq 0 ]; then
    ok "JV02 public class names match filenames"
  else
    fail "JV02" "public class filename mismatch: ${mismatch[*]}"
  fi
fi

if [ -f "$PROJECT_DIR/pom.xml" ] || [ -f "$PROJECT_DIR/build.gradle" ] || [ -f "$PROJECT_DIR/build.gradle.kts" ]; then
  ok "JV03 Java build manifest present"
else
  skip "JV03" "no Maven or Gradle manifest present"
fi

if [ -f "$PROJECT_DIR/pom.xml" ]; then
  if grep -q '<project' "$PROJECT_DIR/pom.xml" && grep -q '<dependencies\|<packaging\|<groupId' "$PROJECT_DIR/pom.xml"; then
    ok "JV04 pom.xml has expected Maven markers"
  else
    fail "JV04" "pom.xml lacks expected Maven markers"
  fi
else
  skip "JV04" "pom.xml not present"
fi
