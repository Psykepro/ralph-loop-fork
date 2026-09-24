#!/bin/bash

# Iterations must END their turn while background sub-agents run, never
# busy-wait. Guards the two halves of that contract across every launch
# site (session 1 + forks, tmux + herdr):
#   1. ScheduleWakeup is removed from the spawned session's tool list.
#   2. The iteration prompt tells the model to end its turn (the stop hook
#      defers silently since v0.8.0; it does not hold the session open).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$SCRIPT_DIR/scripts/lib-session-launch.sh"
LAUNCH_SCRIPTS=(
  "$SCRIPT_DIR/scripts/fork-terminal.sh"
  "$SCRIPT_DIR/scripts/fork-terminal-herdr.sh"
  "$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

echo -e "${YELLOW}Shared launch lib${NC}"
if [[ -f "$LIB" ]] && ( source "$LIB" && [[ "$RALPH_DISALLOWED_TOOLS_ARG" == "--disallowedTools=ScheduleWakeup" ]] ); then
  pass "lib defines RALPH_DISALLOWED_TOOLS_ARG in the = form (the flag is variadic)"
else
  fail "lib-session-launch.sh missing or RALPH_DISALLOWED_TOOLS_ARG wrong" "$LIB"
fi

SUBAGENT_TEXT=""
[[ -f "$LIB" ]] && SUBAGENT_TEXT=$(source "$LIB" && printf '%s' "${RALPH_PARALLEL_SUBAGENTS_TEXT:-}")
for needle in "END YOUR TURN" "ScheduleWakeup" "ListAgents" "sleep" "run_in_background" "integrated every"; do
  if grep -qF -- "$needle" <<< "$SUBAGENT_TEXT"; then
    pass "sub-agent prompt text mentions: $needle"
  else
    fail "sub-agent prompt text missing: $needle" "$SUBAGENT_TEXT"
  fi
done

echo -e "${YELLOW}Every launch site${NC}"
for script in "${LAUNCH_SCRIPTS[@]}"; do
  name=$(basename "$script")
  launches=$(grep -nE '(herdr agent start .*--kind claude|claude --dangerously-skip-permissions\$)' "$script" | grep -vE '^[0-9]+:\s*#')
  if [[ -z "$launches" ]]; then
    fail "$name: no claude launch line found (test pattern stale?)" ""
    continue
  fi
  missing=$(grep -v 'RALPH_DISALLOWED_TOOLS_ARG' <<< "$launches")
  if [[ -z "$missing" ]]; then
    pass "$name: every claude launch passes \$RALPH_DISALLOWED_TOOLS_ARG"
  else
    fail "$name: launch line(s) without \$RALPH_DISALLOWED_TOOLS_ARG" "$missing"
  fi
  if grep -q 'BLOCK-and-wait' "$script"; then
    fail "$name: still claims the stop hook holds the session open (BLOCK-and-wait)" "$(grep -n 'BLOCK-and-wait' "$script")"
  else
    pass "$name: no BLOCK-and-wait claim"
  fi
  uses=$(grep -c 'RALPH_PARALLEL_SUBAGENTS_TEXT' "$script")
  if [[ "$uses" -eq 2 ]]; then
    pass "$name: both prompt variants use the shared sub-agent text"
  else
    fail "$name: expected 2 uses of RALPH_PARALLEL_SUBAGENTS_TEXT" "got $uses"
  fi
done

echo ""
echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
