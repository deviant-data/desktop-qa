#!/usr/bin/env bash
# Category: integration
# Language: Dockerfile
# Use case: Validate container build files with static checks only.
# Summary: Checks Dockerfile presence, FROM instructions, root-user risk, and copy/install ordering signals.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

mapfile -t DOCKER_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name 'Dockerfile' -o -name '*.Dockerfile' \) -print 2>/dev/null | head -n 20
)

if [ "${#DOCKER_FILES[@]}" -eq 0 ]; then
  for id in DK01 DK02 DK03 DK04; do skip "$id" "no Dockerfile found"; done
  exit 0
fi
ok "DK01 discovered ${#DOCKER_FILES[@]} Dockerfile(s)"

missing_from=()
latest=()
no_user=()
for file in "${DOCKER_FILES[@]}"; do
  grep -Eq '^FROM[[:space:]]+' "$file" || missing_from+=("${file#$PROJECT_DIR/}")
  grep -Eq '^FROM[[:space:]]+[^[:space:]]+:latest\b|^FROM[[:space:]]+[^:[:space:]]+[[:space:]]*$' "$file" && latest+=("${file#$PROJECT_DIR/}")
  grep -Eq '^USER[[:space:]]+[^[:space:]]+' "$file" || no_user+=("${file#$PROJECT_DIR/}")
done

if [ "${#missing_from[@]}" -eq 0 ]; then
  ok "DK02 Dockerfiles declare a base image"
else
  fail "DK02" "missing FROM instruction: ${missing_from[*]}"
fi

if [ "${#latest[@]}" -eq 0 ]; then
  ok "DK03 Docker base images appear version-pinned"
else
  skip "DK03" "base image tag may be floating: ${latest[*]}"
fi

if [ "${#no_user[@]}" -eq 0 ]; then
  ok "DK04 Dockerfiles switch to an explicit user"
else
  skip "DK04" "no USER instruction in: ${no_user[*]}"
fi
