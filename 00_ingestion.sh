#!/bin/bash
# 00_ingestion.sh — Stage 1 ingestion
#
# Scans the project directory and writes ingestion_summary.md to
# $PROJECT_DIR/qa/. Pure bash — no AI, no network.
#
# Usage:
#   bash 00_ingestion.sh /path/to/project
#
# Exit codes:
#   0  ingestion complete
#   1  usage error / bad project path
#   2  could not write output
#   3  unsupported bash version (requires bash 4+)

# --- Bash version guard --------------------------------------------------
# `detect_languages` uses `declare -A` (associative arrays), a bash 4+ feature.
# macOS ships bash 3.2 as /bin/bash for licensing reasons. On bash 3.x the
# `declare -A` call fails and — because `set -u` is on but `set -e` is not —
# the rest of the function silently aborts mid-write. The temp file ends up
# empty, the EXIT trap removes it, and the script exits 0 without producing
# ingestion_summary.md. Stage 2 then fails opaquely ("ingestion_summary.md
# not found") with no clear indication of the root cause.
#
# Fail fast and loud instead: check the version up front and give the user
# an actionable message. On macOS the fix is `brew install bash`; the
# Homebrew build goes into /opt/homebrew/bin or /usr/local/bin and can be
# invoked explicitly without replacing the system /bin/bash.
if [ -z "${BASH_VERSINFO[0]:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  echo "Error: bash 4+ required (found: ${BASH_VERSION:-unknown})." >&2
  echo "  On macOS the system bash is 3.2. Install a newer bash with:" >&2
  echo "    brew install bash" >&2
  echo "  Then invoke this script with the newer bash, e.g.:" >&2
  echo "    /opt/homebrew/bin/bash 00_ingestion.sh /path/to/project" >&2
  exit 3
fi

set -u
# Intentionally not `set -e`: inspection failures on a single heuristic must
# not abort the whole summary. Individual sections degrade gracefully.

# --- Argument parsing ----------------------------------------------------
PROJECT_DIR="${1:-}"

if [ -z "$PROJECT_DIR" ]; then
  echo "Usage: bash 00_ingestion.sh /path/to/project" >&2
  exit 1
fi

if [ ! -d "$PROJECT_DIR" ]; then
  echo "Error: '$PROJECT_DIR' is not a directory." >&2
  exit 1
fi

PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"
QA_DIR="$PROJECT_DIR/qa"
OUT_FILE="$QA_DIR/ingestion_summary.md"

mkdir -p "$QA_DIR" || { echo "Error: cannot create $QA_DIR" >&2; exit 2; }

# --- Helpers -------------------------------------------------------------

# Pick the first path in $PROJECT_DIR matching a set of globs. Prints
# project-relative paths, one per line. Skips common noise directories.
find_files() {
  local pattern="$1"
  find "$PROJECT_DIR" \
    \( -path '*/node_modules' -o \
       -path '*/.git' -o \
       -path '*/venv' -o \
       -path '*/.venv' -o \
       -path '*/__pycache__' -o \
       -path '*/dist' -o \
       -path '*/build' -o \
       -path '*/target' -o \
       -path '*/.next' -o \
       -path '*/.nuxt' \) -prune \
    -o -type f -name "$pattern" -print 2>/dev/null \
    | sed "s|^$PROJECT_DIR/||"
}

# Count occurrences of files matching a pattern (excluding pruned dirs).
count_files() {
  find_files "$1" | wc -l | tr -d ' '
}

# Print first non-empty line of a file safely, escaped for Markdown.
first_line() {
  [ -f "$1" ] && head -n1 "$1" 2>/dev/null | tr -d '\r'
}

# --- Section: top-level listing -----------------------------------------
top_level_listing() {
  (cd "$PROJECT_DIR" && ls -1A 2>/dev/null | sed 's/^/- /')
}

# --- Section: language detection ----------------------------------------
# Score each language by file count. Report the top non-zero languages.
detect_languages() {
  declare -A counts
  counts[JavaScript]=$(count_files '*.js')
  counts[TypeScript]=$(( $(count_files '*.ts') + $(count_files '*.tsx') ))
  counts[Python]=$(count_files '*.py')
  counts[Java]=$(count_files '*.java')
  counts[Go]=$(count_files '*.go')
  counts[Ruby]=$(count_files '*.rb')
  counts[Rust]=$(count_files '*.rs')
  counts[Shell]=$(( $(count_files '*.sh') + $(count_files '*.bash') ))
  counts[C]=$(count_files '*.c')
  counts[Cpp]=$(( $(count_files '*.cpp') + $(count_files '*.cc') + $(count_files '*.cxx') ))
  counts[CSharp]=$(count_files '*.cs')
  counts[PHP]=$(count_files '*.php')

  # Build the scored list once, then decide whether it's empty.
  local scored
  scored=$(
    for lang in "${!counts[@]}"; do
      local n="${counts[$lang]}"
      if [ "$n" -gt 0 ]; then
        printf '%s\t%s\n' "$n" "$lang"
      fi
    done | sort -rn | head -n 3
  )

  if [ -z "$scored" ]; then
    echo "- (none detected)"
  else
    echo "$scored" | awk -F'\t' '{printf "- %s (%s files)\n", $2, $1}'
  fi
}

# --- Section: framework / runtime detection -----------------------------
detect_framework() {
  local pkg="$PROJECT_DIR/package.json"
  local req="$PROJECT_DIR/requirements.txt"
  local pom="$PROJECT_DIR/pom.xml"
  local gomod="$PROJECT_DIR/go.mod"
  local cargo="$PROJECT_DIR/Cargo.toml"
  local gemfile="$PROJECT_DIR/Gemfile"

  if [ -f "$pkg" ]; then
    # Cheap substring checks — avoid jq dependency.
    local matched=0
    for fw in react next vue nuxt express fastify koa nestjs svelte remix angular; do
      if grep -qiE "\"$fw\"" "$pkg" 2>/dev/null; then
        echo "- Framework: $fw (from package.json)"
        matched=1
        break
      fi
    done
    [ "$matched" = 0 ] && echo "- Framework: Node.js project (no well-known framework detected)"
  elif [ -f "$req" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    local src="$req"
    [ -f "$src" ] || src="$PROJECT_DIR/pyproject.toml"
    for fw in django flask fastapi starlette pyramid tornado aiohttp; do
      if grep -qiE "^[[:space:]]*$fw([=<>~!]|$|[[:space:]])" "$src" 2>/dev/null \
         || grep -qiE "\"$fw\"" "$src" 2>/dev/null; then
        echo "- Framework: $fw (from $(basename "$src"))"
        return
      fi
    done
    echo "- Framework: Python project (no well-known framework detected)"
  elif [ -f "$pom" ]; then
    if grep -qi 'spring-boot' "$pom" 2>/dev/null; then
      echo "- Framework: Spring Boot (from pom.xml)"
    else
      echo "- Framework: Java/Maven project"
    fi
  elif [ -f "$gomod" ]; then
    echo "- Framework: Go module ($(first_line "$gomod"))"
  elif [ -f "$cargo" ]; then
    echo "- Framework: Rust crate"
  elif [ -f "$gemfile" ]; then
    if grep -qi 'rails' "$gemfile" 2>/dev/null; then
      echo "- Framework: Ruby on Rails"
    else
      echo "- Framework: Ruby project"
    fi
  else
    echo "- Framework: (not identified from manifests)"
  fi
}

# Runtime version pinning hints (from manifests / version files).
detect_runtime_version() {
  if [ -f "$PROJECT_DIR/.nvmrc" ]; then
    echo "- Node: $(first_line "$PROJECT_DIR/.nvmrc") (from .nvmrc)"
  fi
  if [ -f "$PROJECT_DIR/.python-version" ]; then
    echo "- Python: $(first_line "$PROJECT_DIR/.python-version") (from .python-version)"
  fi
  if [ -f "$PROJECT_DIR/package.json" ]; then
    local engines
    engines=$(grep -E '"node"[[:space:]]*:' "$PROJECT_DIR/package.json" 2>/dev/null | head -n1 | sed 's/[[:space:]]*$//')
    [ -n "$engines" ] && echo "- package.json engines: $engines"
  fi
  if [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    local pyreq
    pyreq=$(grep -E '^python[[:space:]]*=' "$PROJECT_DIR/pyproject.toml" 2>/dev/null | head -n1)
    [ -n "$pyreq" ] && echo "- pyproject.toml: $pyreq"
  fi
}

# --- Section: entry point detection -------------------------------------
detect_entry_points() {
  local -a entries=()
  local main_entry=""

  # package.json "main"
  if [ -f "$PROJECT_DIR/package.json" ]; then
    main_entry=$(grep -E '"main"[[:space:]]*:' "$PROJECT_DIR/package.json" 2>/dev/null | head -n1 | sed 's/.*"main"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    if [ -n "$main_entry" ]; then
      entries+=("$main_entry (package.json main)")
    fi
  fi

  # Conventional filenames at project root and in src/
  local candidate
  for candidate in index.js index.ts server.js server.ts app.js app.ts \
                   main.py app.py manage.py wsgi.py asgi.py \
                   App.tsx App.jsx \
                   main.go main.rs Main.java \
                   src/index.js src/index.ts src/main.ts src/main.py \
                   src/App.tsx src/App.jsx; do
    if [ -f "$PROJECT_DIR/$candidate" ] && [ "$candidate" != "$main_entry" ]; then
      entries+=("$candidate")
    fi
  done

  # Shell entry points. Conventional names for pipeline / CLI / wrapper
  # projects where the "application" IS a shell script. Without this block,
  # pure-shell projects end up with "(no conventional entry point found)",
  # which downstream tests (cli_api_test.sh, run_sh_test.sh, negative_test.sh
  # etc.) read as "no entry point to probe" and then silently skip every
  # sub-test that depends on one. That's how a correct pipeline ends up
  # reporting ~15 bogus SKIPs on a perfectly healthy project. Recognising
  # shell entries here converts those skips back into real PASS/FAIL signal.
  #
  # Rule: only count a candidate if it's non-empty AND has a shell shebang.
  # The shebang check is what keeps this from lighting up on a random
  # `setup.sh` dotfile or an empty placeholder — an entry point must at
  # minimum be a runnable script. `setup.sh` itself (conventionally a
  # one-time installer, not the thing you invoke per-run) is deliberately
  # not in the candidate list; projects that genuinely use it as the main
  # entry are free to rename or add it to `bin/`.
  for candidate in run.sh main.sh start.sh entrypoint.sh \
                   bin/run bin/start bin/main bin/run.sh bin/main.sh; do
    if [ -f "$PROJECT_DIR/$candidate" ] \
       && [ -s "$PROJECT_DIR/$candidate" ] \
       && [ "$candidate" != "$main_entry" ] \
       && head -n1 "$PROJECT_DIR/$candidate" 2>/dev/null \
            | grep -qE '^#!/(usr/)?(bin/)?(env +)?(ba)?sh'; then
      entries+=("$candidate (shell entry)")
    fi
  done

  if [ "${#entries[@]}" -eq 0 ]; then
    echo "- (no conventional entry point found)"
  else
    printf -- '- %s\n' "${entries[@]}"
  fi
}

# --- Section: existing tests --------------------------------------------
detect_tests() {
  local test_dirs=()
  for d in test tests spec __tests__ qa/tests; do
    [ -d "$PROJECT_DIR/$d" ] && test_dirs+=("$d")
  done

  if [ "${#test_dirs[@]}" -gt 0 ]; then
    echo "- Location: ${test_dirs[*]}"
  else
    echo "- Location: (no dedicated test directory)"
  fi

  # Sniff framework hints from package.json / requirements
  if [ -f "$PROJECT_DIR/package.json" ]; then
    for tf in jest vitest mocha jasmine ava playwright cypress; do
      if grep -qiE "\"$tf\"" "$PROJECT_DIR/package.json" 2>/dev/null; then
        echo "- Framework: $tf (package.json)"
        break
      fi
    done
  fi
  if [ -f "$PROJECT_DIR/requirements.txt" ] || [ -f "$PROJECT_DIR/pyproject.toml" ]; then
    for tf in pytest unittest nose; do
      if grep -qiE "(^|[\"[:space:]])$tf" \
           "$PROJECT_DIR/requirements.txt" "$PROJECT_DIR/pyproject.toml" 2>/dev/null; then
        echo "- Framework: $tf"
        break
      fi
    done
  fi

  # Rough coverage estimate: ratio of test files to source files.
  local test_count
  test_count=$(( $(count_files '*.test.js') + $(count_files '*.test.ts') \
                + $(count_files '*.spec.js') + $(count_files '*.spec.ts') \
                + $(count_files 'test_*.py') + $(count_files '*_test.py') \
                + $(count_files '*_test.go') ))
  echo "- Test files counted: $test_count"
  echo "- Coverage (estimated): not measured in Stage 1"
}

# --- Section: documentation ---------------------------------------------
detect_docs() {
  local found=0
  for f in README README.md README.rst README.txt \
           CONTRIBUTING.md CHANGELOG.md ARCHITECTURE.md \
           docs/ openapi.yaml openapi.yml swagger.yaml swagger.yml \
           openapi.json swagger.json api.md API.md; do
    if [ -e "$PROJECT_DIR/$f" ]; then
      echo "- $f"
      found=1
    fi
  done
  [ "$found" = 0 ] && echo "- (no documentation files found)"
}

# --- Section: dependency manifest ---------------------------------------
detect_manifest() {
  local manifests=(package.json requirements.txt pyproject.toml Pipfile \
                   pom.xml build.gradle build.gradle.kts \
                   go.mod Cargo.toml Gemfile composer.json)
  local found=0
  for m in "${manifests[@]}"; do
    if [ -f "$PROJECT_DIR/$m" ]; then
      echo "- File: $m"
      found=1
      # Emit a few notable dependency names for the common cases.
      case "$m" in
        package.json)
          local deps
          deps=$(grep -oE '"[a-zA-Z0-9@/_-]+"[[:space:]]*:[[:space:]]*"[\^~]?[0-9][^"]*"' \
                  "$PROJECT_DIR/$m" 2>/dev/null \
                | awk -F'"' '{print $2}' \
                | grep -v '^$' \
                | head -n 10)
          if [ -n "$deps" ]; then
            echo "- Notable dependencies (first 10):"
            echo "$deps" | sed 's/^/  - /'
          fi
          ;;
        requirements.txt)
          local deps
          deps=$(grep -vE '^\s*(#|$)' "$PROJECT_DIR/$m" | head -n 10)
          if [ -n "$deps" ]; then
            echo "- Notable dependencies (first 10):"
            echo "$deps" | sed 's/^/  - /'
          fi
          ;;
      esac
    fi
  done
  [ "$found" = 0 ] && echo "- File: (none found)"
}

# --- Section: flags & observations --------------------------------------
detect_flags() {
  local any=0

  # Monorepo indicators
  if [ -f "$PROJECT_DIR/pnpm-workspace.yaml" ] \
     || [ -f "$PROJECT_DIR/lerna.json" ] \
     || [ -f "$PROJECT_DIR/turbo.json" ] \
     || [ -f "$PROJECT_DIR/nx.json" ]; then
    echo "- Monorepo structure detected (pnpm/lerna/turbo/nx config present)"
    any=1
  fi
  if [ -f "$PROJECT_DIR/package.json" ] && grep -q '"workspaces"' "$PROJECT_DIR/package.json" 2>/dev/null; then
    echo "- Monorepo structure detected (npm/yarn workspaces)"
    any=1
  fi

  # .env handling
  if [ -f "$PROJECT_DIR/.env" ]; then
    echo "- .env file present at project root — may contain real secrets; do not log contents"
    any=1
  fi
  if [ -f "$PROJECT_DIR/.env.example" ] || [ -f "$PROJECT_DIR/.env.sample" ]; then
    echo "- .env.example present — usable for Stage 2 environment setup"
    any=1
  else
    # Flag only if the project *also* looks like it wants env vars.
    if [ -f "$PROJECT_DIR/.env" ] || \
       grep -rqE "process\.env\.|os\.environ" "$PROJECT_DIR" --include='*.js' --include='*.ts' --include='*.py' 2>/dev/null; then
      echo "- No .env.example found, but env-var usage detected — Stage 2 may need manual config"
      any=1
    fi
  fi

  # Hardcoded-secret heuristic (very conservative: obvious high-entropy patterns only)
  local secret_hits
  secret_hits=$(grep -rEl \
      -e 'sk-[A-Za-z0-9]{20,}' \
      -e 'AKIA[0-9A-Z]{16}' \
      -e 'AIza[0-9A-Za-z_-]{35}' \
      "$PROJECT_DIR" \
      --include='*.js' --include='*.ts' --include='*.py' \
      --include='*.sh' --include='*.env' --include='*.yaml' --include='*.yml' \
      2>/dev/null \
      | head -n 3)
  if [ -n "$secret_hits" ]; then
    echo "- Possible hardcoded secrets detected in:"
    echo "$secret_hits" | sed "s|^$PROJECT_DIR/|  - |"
    any=1
  fi

  # Missing core config files for the detected stack
  if [ -f "$PROJECT_DIR/package.json" ] && [ ! -f "$PROJECT_DIR/package-lock.json" ] \
     && [ ! -f "$PROJECT_DIR/yarn.lock" ] && [ ! -f "$PROJECT_DIR/pnpm-lock.yaml" ]; then
    echo "- package.json present but no lockfile — installs may be non-deterministic"
    any=1
  fi

  [ "$any" = 0 ] && echo "- (no unusual flags detected)"
}

# --- Compose the report --------------------------------------------------

TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_OUT"' EXIT

{
  echo "# Ingestion Summary"
  echo
  echo "_Generated by 00_ingestion.sh on $(date -u +'%Y-%m-%dT%H:%M:%SZ')_"
  echo "_Project: ${PROJECT_DIR}_"
  echo

  echo "## Top-Level Listing"
  top_level_listing
  echo

  echo "## Stack"
  echo "### Languages (by file count)"
  detect_languages
  echo
  echo "### Framework"
  detect_framework
  echo
  echo "### Runtime version hints"
  rv_output=$(detect_runtime_version)
  if [ -n "$rv_output" ]; then
    echo "$rv_output"
  else
    echo "- (no pinned runtime version found)"
  fi
  echo

  echo "## Entry Points"
  detect_entry_points
  echo

  echo "## Existing Tests"
  detect_tests
  echo

  echo "## Documentation Found"
  detect_docs
  echo

  echo "## Dependency Manifest"
  detect_manifest
  echo

  echo "## Flags & Observations"
  detect_flags
  echo
} > "$TMP_OUT"

mv "$TMP_OUT" "$OUT_FILE" || { echo "Error: cannot write $OUT_FILE" >&2; exit 2; }
trap - EXIT

echo "Wrote $OUT_FILE"
echo "INGESTION COMPLETE"
