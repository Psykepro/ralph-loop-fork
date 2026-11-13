#!/bin/bash

# Tests that fork-terminal-herdr.sh honours PROJECT_ROOT (i.e., the worktree
# path) when launching the next session. Uses a `herdr` stub that records its
# args instead of launching anything, so the test is hermetic and fast.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_SCRIPT="$SCRIPT_DIR/scripts/fork-terminal-herdr.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Layout: a fake repo + fake worktree, both with state dirs prepared.
REPO_DIR=$(mktemp -d -t fork-test-repo-XXXX)
WORKTREE_DIR="$REPO_DIR/.worktrees/wt-test"
STUB_DIR=$(mktemp -d -t fork-test-stubs-XXXX)
HERDR_LOG=$(mktemp -t fork-test-herdr-log-XXXX)
LOOP_ID="wt-loop"

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$HERDR_LOG"
}
trap cleanup EXIT

mkdir -p "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<STATEEOF
{
  "loop_id": "$LOOP_ID",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 0,
  "session_number": 1,
  "session_token": "old-token-1",
  "completion_promise": "DONE",
  "prompt": "test",
  "checklist_file": "checklist.md",
  "fork_history": [],
  "spawned_sessions": [],
  "original_session_name": "",
  "backend": "herdr",
  "worktree_path": "$WORKTREE_DIR"
}
STATEEOF
echo "test prompt" > "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/prompt.txt"

# Stub herdr: records every call (args + cwd) and returns canned JSON.
cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{
  printf 'CALL: '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\nCWD: %s\n' "$(pwd)"
} >> "$STUB_HERDR_LOG_PATH"

case "${1:-} ${2:-}" in
  "workspace create")
    echo '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"wT:p1","workspace_id":"wT"},"workspace":{"workspace_id":"wT","label":"stub"},"type":"workspace_created"}}'
    ;;
  "agent start")
    echo '{"id":"cli:agent:start","result":{"agent":{"agent_status":"idle","name":"'"${3:-}"'","pane_id":"wT:p1","workspace_id":"wT"},"type":"agent_started"}}'
    ;;
esac
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"
export STUB_HERDR_LOG_PATH="$HERDR_LOG"
export PATH="$STUB_DIR:$PATH"

# Hermetic: the ambient herdr env must not pick the tab path.
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID

STATE_JSON="$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json"

echo -e "${YELLOW}Test 1: fork-terminal-herdr.sh launches inside the worktree${NC}"

OUTPUT=$(bash "$FORK_SCRIPT" "$LOOP_ID" 2 "$WORKTREE_DIR" 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
  pass "fork-terminal-herdr.sh exited 0"
else
  fail "fork-terminal-herdr.sh exited $RC" "$OUTPUT"
fi

if grep -q "workspace create" "$HERDR_LOG"; then
  pass "herdr workspace create was invoked"
else
  fail "herdr workspace create was not invoked" "$(cat "$HERDR_LOG")"
fi

# Confirm herdr was told to launch in the worktree, not in the repo root.
if grep -q -- "--cwd $WORKTREE_DIR" "$HERDR_LOG"; then
  pass "workspace created with --cwd <worktree-dir>"
else
  fail "workspace --cwd did not point at the worktree" "$(cat "$HERDR_LOG")"
fi

# The new session must be recorded in state.json under spawned_sessions, and
# fork_history must have been appended.
NEW_STATE=$(jq -r '.spawned_sessions[-1].pane_id // "MISSING"' "$STATE_JSON")
if [[ "$NEW_STATE" == "wT:p1" ]]; then
  pass "spawned_sessions[] in state.json includes the new pane"
else
  fail "spawned_sessions[] did not record new pane" "got: $NEW_STATE"
fi

FORK_COUNT=$(jq -r '.fork_history | length' "$STATE_JSON")
if [[ "$FORK_COUNT" == "1" ]]; then
  pass "fork_history[] in state.json grew by one"
else
  fail "fork_history[] did not grow" "length=$FORK_COUNT"
fi

# The local.md for the new session must exist (forked Claude reads it).
if [[ -f "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/local.md" ]]; then
  pass "local.md created for new session"
else
  fail "local.md not created" "expected at $WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/local.md"
fi

echo ""
echo -e "${YELLOW}Test 2: old state.json without model/effort keys -> BOTH fall back to the${NC}"
echo -e "${YELLOW}  built-in default (sonnet/medium), symmetrically, with a warning${NC}"

SPAWN2_LINE=$(grep "agent start" "$HERDR_LOG" | head -1)
if grep -qE -- '--effort medium' <<< "$SPAWN2_LINE"; then
  pass "agent start contains --effort medium (missing-key fallback)"
else
  fail "agent start missing --effort medium fallback" "$SPAWN2_LINE"
fi
if grep -qE -- '--model sonnet' <<< "$SPAWN2_LINE"; then
  pass "agent start contains --model sonnet (missing-key fallback, symmetric with effort)"
else
  fail "--model sonnet fallback missing for model-less state (this is the leak)" "$SPAWN2_LINE"
fi
if grep -q "no model in" <<< "$OUTPUT"; then
  pass "Warned about missing model in state.json before falling back"
else
  fail "Expected a warning about missing model in state.json" "$OUTPUT"
fi

echo ""
echo -e "${YELLOW}Test 3: state.json model/effort are read back into agent start${NC}"

jq '.model = "opus" | .effort = "high"' "$STATE_JSON" > "$STATE_JSON.tmp" \
  && mv "$STATE_JSON.tmp" "$STATE_JSON"
: > "$HERDR_LOG"

OUTPUT3=$(bash "$FORK_SCRIPT" "$LOOP_ID" 3 "$WORKTREE_DIR" 2>&1)
RC3=$?
if [[ $RC3 -eq 0 ]]; then
  pass "fork-terminal-herdr.sh exited 0 with model+effort in state"
else
  fail "fork-terminal-herdr.sh exited $RC3" "$OUTPUT3"
fi

SPAWN3_LINE=$(grep "agent start" "$HERDR_LOG" | head -1)
if grep -qE -- '--model opus' <<< "$SPAWN3_LINE" && grep -qE -- '--effort high' <<< "$SPAWN3_LINE"; then
  pass "agent start contains --model opus --effort high from state.json"
else
  fail "agent start missing persisted model/effort flags" "$SPAWN3_LINE"
fi

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
exit 0
