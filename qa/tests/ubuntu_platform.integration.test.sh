#!/usr/bin/env bash
# Category: integration
# Language: Ubuntu
# Use case: Validate Ubuntu-oriented shell and container setup conventions.
# Summary: Ignores comments/instructional text, then checks real apt commands for noninteractive and cleanup patterns.

set -u
source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

apt_lines() {
  file="$1"
  awk '
    /^[[:space:]]*#/ {next}
    /^[[:space:]]*(echo|printf|log)[[:space:]]/ {next}
    /apt-get[[:space:]]+(update|install)|apt[[:space:]]+(update|install)|ubuntu/ {print}
  ' "$file" 2>/dev/null
}

mapfile -t CANDIDATES < <(
  find "$PROJECT_DIR" \
    \( -path '*/.git' -o -path '*/node_modules' -o -path '*/qa/tests' \) -prune \
    -o -type f \( -name 'Dockerfile' -o -name '*.Dockerfile' -o -name '*.sh' -o -name '*.bash' \) -print 2>/dev/null
)

UBUNTU_FILES=()
for file in "${CANDIDATES[@]}"; do
  if apt_lines "$file" | grep -Eiq 'ubuntu|apt-get|apt '; then
    UBUNTU_FILES+=("$file")
  fi
done

if [ "${#UBUNTU_FILES[@]}" -eq 0 ]; then
  for id in UB01 UB02 UB03 UB04; do skip "$id" "no executable Ubuntu or apt-oriented content found"; done
  exit 0
fi
ok "UB01 discovered ${#UBUNTU_FILES[@]} Ubuntu/apt-oriented file(s)"

missing_noninteractive=()
missing_clean=()
floating_base=()
for file in "${UBUNTU_FILES[@]}"; do
  lines="$(apt_lines "$file")"
  if printf '%s\n' "$lines" | grep -Eq 'apt-get[[:space:]]+install|apt[[:space:]]+install'; then
    if ! printf '%s\n' "$lines" | grep -Eq 'DEBIAN_FRONTEND=noninteractive|apt(-get)?[[:space:]]+install[^#]*( -y| --yes)'; then
      missing_noninteractive+=("${file#$PROJECT_DIR/}")
    fi
  fi
  if printf '%s\n' "$lines" | grep -Eq 'apt-get[[:space:]]+(update|install)|apt[[:space:]]+(update|install)'; then
    if ! grep -Eq 'rm -rf /var/lib/apt/lists|apt-get[[:space:]]+clean|apt[[:space:]]+clean' "$file" 2>/dev/null; then
      missing_clean+=("${file#$PROJECT_DIR/}")
    fi
  fi
  if grep -Eq '^FROM[[:space:]]+ubuntu([[:space:]]|$)|^FROM[[:space:]]+ubuntu:latest([[:space:]]|$)' "$file" 2>/dev/null; then
    floating_base+=("${file#$PROJECT_DIR/}")
  fi
done

if [ "${#missing_noninteractive[@]}" -eq 0 ]; then
  ok "UB02 executable apt install commands are noninteractive"
else
  fail "UB02" "apt install may prompt interactively: ${missing_noninteractive[*]}"
fi

if [ "${#missing_clean[@]}" -eq 0 ]; then
  ok "UB03 apt cache cleanup is present after executable apt use"
else
  skip "UB03" "apt cleanup not obvious in: ${missing_clean[*]}"
fi

if [ "${#floating_base[@]}" -eq 0 ]; then
  ok "UB04 Ubuntu base images avoid implicit latest tag"
else
  skip "UB04" "Ubuntu base image is not version-pinned: ${floating_base[*]}"
fi
