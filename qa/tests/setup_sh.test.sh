#!/usr/bin/env bash
# setup_sh.test.sh — Unit tests for dependency-manifest sanity.
#
# Renamed only in spirit: the original tested desktop-qa's setup.sh. The
# new body checks the project-under-test's dependency manifest (whatever
# kind it has) for common problems:
#   - manifest is parseable
#   - manifest isn't empty
#   - lockfile is present when the manifest exists (reproducibility)
#
# Skips cleanly for projects with no manifest at all (e.g. pure shell).

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Detect manifest. We check in priority order: a project with both
# pyproject.toml AND package.json exists (e.g. a JS tool wrapping a
# Python core), so picking one deterministic "primary" manifest keeps
# assertions crisp.
MANIFEST=""
MANIFEST_KIND=""
for pair in \
  "package.json:node" \
  "requirements.txt:python" \
  "pyproject.toml:python" \
  "Pipfile:python" \
  "pom.xml:maven" \
  "build.gradle:gradle" \
  "build.gradle.kts:gradle" \
  "go.mod:go" \
  "Cargo.toml:rust" \
  "Gemfile:ruby"; do
  file="${pair%%:*}"
  kind="${pair##*:}"
  if [ -f "$PROJECT_DIR/$file" ]; then
    MANIFEST="$file"
    MANIFEST_KIND="$kind"
    break
  fi
done

# U01: Is there a manifest to check? For pure-shell projects there isn't,
# and that's fine — the test exits with all-skips so it doesn't penalise
# projects that genuinely have no deps.
if [ -z "$MANIFEST" ]; then
  skip "U01" "no dependency manifest found (shell / library project)"
  skip "U02" "no manifest to inspect"
  skip "U03" "no manifest to inspect"
  exit 0
fi

ok "U01 manifest detected: $MANIFEST ($MANIFEST_KIND)"

# U02: Manifest is non-empty and minimally well-formed. We don't call a
# language-specific parser (jq/python -c) unless the tool is already on
# PATH — the test must run in minimal environments.
MANIFEST_PATH="$PROJECT_DIR/$MANIFEST"
if [ ! -s "$MANIFEST_PATH" ]; then
  fail "U02" "$MANIFEST is empty"
else
  case "$MANIFEST" in
    package.json)
      # JSON: try jq if available, otherwise a naive brace check.
      if has_command jq; then
        if jq -e . "$MANIFEST_PATH" >/dev/null 2>&1; then
          ok "U02 $MANIFEST parses as valid JSON"
        else
          fail "U02" "$MANIFEST is not valid JSON"
        fi
      elif head -c 1 "$MANIFEST_PATH" | grep -q '{' \
           && tail -c 2 "$MANIFEST_PATH" | grep -q '}'; then
        ok "U02 $MANIFEST looks like a JSON object (jq unavailable, naive check)"
      else
        fail "U02" "$MANIFEST doesn't start with { or end with } (jq unavailable)"
      fi
      ;;
    *.toml|*.txt|*.gradle|*.gradle.kts|Pipfile|Gemfile|go.mod|pom.xml)
      # No portable parser for these; require non-empty and readable.
      if [ -r "$MANIFEST_PATH" ]; then
        ok "U02 $MANIFEST is readable and non-empty"
      else
        fail "U02" "$MANIFEST is not readable"
      fi
      ;;
  esac
fi

# U03: Lockfile present? Reproducibility is a common gap. We report this
# as a FAIL for manifests where a lockfile is the normal default (npm,
# pip, poetry, etc.) and as a SKIP where the lockfile is optional.
LOCK=""
case "$MANIFEST_KIND" in
  node)
    for lf in package-lock.json yarn.lock pnpm-lock.yaml; do
      [ -f "$PROJECT_DIR/$lf" ] && LOCK="$lf" && break
    done
    if [ -n "$LOCK" ]; then
      ok "U03 lockfile present ($LOCK)"
    else
      fail "U03" "package.json present but no lockfile — installs will drift"
    fi
    ;;
  python)
    for lf in Pipfile.lock poetry.lock requirements.txt; do
      [ -f "$PROJECT_DIR/$lf" ] && LOCK="$lf" && break
    done
    if [ -n "$LOCK" ]; then
      ok "U03 dependency pin file present ($LOCK)"
    else
      skip "U03" "no pin file found (Python lockfile conventions vary)"
    fi
    ;;
  rust|go)
    # Cargo and Go module tooling generate lockfiles automatically.
    if [ -f "$PROJECT_DIR/Cargo.lock" ] || [ -f "$PROJECT_DIR/go.sum" ]; then
      ok "U03 toolchain-generated lockfile present"
    else
      skip "U03" "lockfile not yet generated (run the toolchain once)"
    fi
    ;;
  *)
    skip "U03" "lockfile conventions not defined for $MANIFEST_KIND"
    ;;
esac
