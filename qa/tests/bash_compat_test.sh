#!/usr/bin/env bash
# bash_compat_test.sh — Unit tests for shell-file portability.
#
# Only meaningful for projects with shell scripts; skips cleanly on
# non-shell stacks. The checks target the kind of silent failure the
# desktop-qa project itself hit (BUG-001): bash 3.2 on macOS vs bash 4+
# elsewhere. A portable shell project either avoids bash 4-only features,
# or guards against them explicitly — this test surfaces the gap either
# way without requiring bash 3.2 to actually be installed.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Collect up to 20 shell files under the project. 20 is a soft cap — a
# huge monorepo might have hundreds, and scanning all of them would slow
# the suite without adding signal. The sample is enough to catch any
# pervasive pattern.
mapfile -t SHELL_FILES < <(
  find "$PROJECT_DIR" \
    \( -path '*/node_modules' -o -path '*/.git' -o \
       -path '*/venv' -o -path '*/.venv' -o \
       -path '*/__pycache__' -o -path '*/dist' -o \
       -path '*/build' -o -path '*/target' -o \
       -path '*/qa/tests' \) -prune \
    -o -type f \( -name '*.sh' -o -name '*.bash' \) -print 2>/dev/null \
  | head -n 20
)

if [ "${#SHELL_FILES[@]}" -eq 0 ]; then
  skip "U01" "no shell files found in project"
  skip "U02" "no shell files found in project"
  skip "U03" "no shell files found in project"
  exit 0
fi

# U01: Every shell file passes `bash -n` (syntax check). A syntax error
# in any script means the whole pipeline can fail unpredictably.
BAD_SYNTAX=()
for f in "${SHELL_FILES[@]}"; do
  bash -n "$f" 2>/dev/null || BAD_SYNTAX+=("$f")
done
if [ "${#BAD_SYNTAX[@]}" -eq 0 ]; then
  ok "U01 all ${#SHELL_FILES[@]} sampled shell files pass bash -n"
else
  fail "U01" "${#BAD_SYNTAX[@]} file(s) have syntax errors: ${BAD_SYNTAX[*]#$PROJECT_DIR/}"
fi

# U02: Files that use bash-4-only features (`declare -A`, `mapfile`,
# `readarray`, `&>>`, `${var,,}`) include a version guard. The guard can
# take many shapes — we look for a check against BASH_VERSINFO or an
# explicit mention of "bash 4" in stderr context near the top of the file.
NEEDS_V4=()
MISSING_GUARD=()
for f in "${SHELL_FILES[@]}"; do
  # Does this file use a bash-4+ feature?
  if grep -qE '(^|[^#])(declare -A|mapfile |readarray |\&>>|\$\{[A-Za-z_][A-Za-z_0-9]*,,\})' "$f"; then
    NEEDS_V4+=("$f")
    # Is there a version guard somewhere in the first 30 lines?
    if ! head -n 30 "$f" | grep -qE 'BASH_VERSINFO|bash 4\+ required|bash_4|requires bash 4'; then
      MISSING_GUARD+=("$f")
    fi
  fi
done
if [ "${#NEEDS_V4[@]}" -eq 0 ]; then
  ok "U02 no files use bash-4+ constructs (portable to bash 3.2)"
elif [ "${#MISSING_GUARD[@]}" -eq 0 ]; then
  ok "U02 all ${#NEEDS_V4[@]} files using bash-4+ constructs have a version guard"
else
  fail "U02" "${#MISSING_GUARD[@]} file(s) use bash-4+ features without a version guard: ${MISSING_GUARD[*]#$PROJECT_DIR/}"
fi

# U03: Every shell file handles `set -u` cleanly on its declared shebang —
# or, if `set -u` isn't used at all, that's also acceptable (we don't
# mandate a style; we just flag scripts that enable `set -u` but then
# reference variables without a default, which is the common way to get
# "unbound variable" crashes). This is a shallow heuristic: if the script
# enables `set -u` and references `$1`, `$2`, or `$ARG` somewhere, we want
# to see at least one `:-` default or a bounds check.
POTENTIAL_U_BUGS=()
for f in "${SHELL_FILES[@]}"; do
  if grep -qE '^[[:space:]]*set [^#]*u' "$f"; then
    # Look for common unguarded positional references. False positives are
    # possible — this is a smoke test, not a theorem prover.
    if grep -qE '\$[0-9]' "$f" && ! grep -qE '\$\{[0-9]+:-|\$\{[A-Za-z_][A-Za-z_0-9]*:-|\[ -z \"?\$' "$f"; then
      POTENTIAL_U_BUGS+=("$f")
    fi
  fi
done
if [ "${#POTENTIAL_U_BUGS[@]}" -eq 0 ]; then
  ok "U03 no obvious unguarded positionals under set -u"
else
  # We report this as a SKIP rather than a FAIL — it's a heuristic that
  # can produce false positives (e.g. scripts that validate $# before
  # using $1 but use a form the regex doesn't match).
  skip "U03" "heuristic flagged ${#POTENTIAL_U_BUGS[@]} file(s) — review manually: ${POTENTIAL_U_BUGS[*]#$PROJECT_DIR/}"
fi
