#!/bin/bash

# Tests fork-terminal-herdr.sh's herdr-backend spawn call shapes against a
# hermetic `herdr` CLI stub (records every invocation, returns canned JSON
# matching the real CLI's response shape) -- no real herdr server required.
# Mirrors test-fork-terminal-worktree.sh's tmux-stub pattern for the tmux
# backend.

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

REPO_DIR=$(mktemp -d -t herdr-fork-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t herdr-fork-test-stubs-XXXX)
HERDR_LOG=$(mktemp -t herdr-fork-test-log-XXXX)
BUSY_COUNTER_FILE=$(mktemp -t herdr-fork-test-busy-counter-XXXX)
LOOP_ID="herdr-loop"

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$HERDR_LOG" "$BUSY_COUNTER_FILE"
}
trap cleanup EXIT

mkdir -p "$REPO_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<EOF
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
  "model": "sonnet",
  "effort": "medium",
  "fork_history": [],
  "spawned_sessions": [],
  "original_session_name": "",
  "backend": "herdr",
  "worktree_path": null
}
EOF
echo "test prompt" > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/prompt.txt"
echo "0" > "$BUSY_COUNTER_FILE"

# Stub herdr: records every call, returns canned JSON per subcommand.
# `agent start` fails with agent_pane_busy on its first 2 calls (simulating
# the fresh-pane race), succeeds on the 3rd -- exercises the retry/backoff.
cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{
  printf 'CALL: '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
} >> "$STUB_HERDR_LOG_PATH"

case "${1:-} ${2:-}" in
  "workspace create")
    echo '{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"wT:p1","workspace_id":"wT"},"workspace":{"workspace_id":"wT","label":"stub"},"type":"workspace_created"}}'
    exit 0
    ;;
  "workspace get")
    exit 0
    ;;
  "tab create")
    echo '{"id":"cli:tab:create","result":{"root_pane":{"pane_id":"wS:p9","tab_id":"wS:t9","workspace_id":"wS"},"tab":{"tab_id":"wS:t9","workspace_id":"wS","label":"stub"},"type":"tab_created"}}'
    exit 0
    ;;
  "pane run")
    # unset command or any other pane run -- no output needed, just record.
    exit 0
    ;;
  "agent start")
    COUNT=$(cat "$STUB_BUSY_COUNTER_PATH")
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$STUB_BUSY_COUNTER_PATH"
    if [[ "$COUNT" -lt 3 ]]; then
      echo '{"error":{"code":"agent_pane_busy","message":"agent target pane wT:p1 is not an available shell"},"id":"cli:agent:start"}' >&2
      exit 1
    fi
    echo '{"id":"cli:agent:start","result":{"agent":{"agent_status":"idle","name":"'"${3:-}"'","pane_id":"wT:p1","workspace_id":"wT"},"type":"agent_started"}}'
    exit 0
    ;;
  "agent prompt")
    exit 0
    ;;
  "agent send-keys")
    exit 0
    ;;
  "pane close")
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUBH
chmod +x "$STUB_DIR/herdr"
export STUB_HERDR_LOG_PATH="$HERDR_LOG"
export STUB_BUSY_COUNTER_PATH="$BUSY_COUNTER_FILE"
export PATH="$STUB_DIR:$PATH"

# Hermetic: the ambient herdr env (running the suite from a herdr pane) must not pick the tab path.
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID

echo -e "${YELLOW}Test 1: fork-terminal-herdr.sh spawns via herdr socket-API calls${NC}"

OUTPUT=$(bash "$FORK_SCRIPT" "$LOOP_ID" 2 "$REPO_DIR" 2>&1)
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

if grep -q -- "--env RALPH_LOOP_ACTIVE=1" "$HERDR_LOG"; then
  pass "workspace create passed --env RALPH_LOOP_ACTIVE=1"
else
  fail "workspace create did not set RALPH_LOOP_ACTIVE" "$(cat "$HERDR_LOG")"
fi

if grep -q "pane run" "$HERDR_LOG" && grep -q "unset" "$HERDR_LOG" && grep -q "CLAUDECODE" "$HERDR_LOG"; then
  pass "pane run unset CLAUDECODE/CLAUDE_CODE_* was invoked before agent start"
else
  fail "env-sanitation pane run was not invoked" "$(cat "$HERDR_LOG")"
fi

AGENT_START_CALLS=$(grep -c "agent start" "$HERDR_LOG")
if [[ "$AGENT_START_CALLS" -eq 3 ]]; then
  pass "agent start retried exactly 3 times (2 agent_pane_busy + 1 success)"
else
  fail "expected 3 agent start attempts (retry/backoff)" "got: $AGENT_START_CALLS"
fi

if grep -q -- "--dangerously-skip-permissions" "$HERDR_LOG" && grep -q -- "--model sonnet" "$HERDR_LOG" && grep -q -- "--effort medium" "$HERDR_LOG"; then
  pass "agent start passed --dangerously-skip-permissions --model --effort"
else
  fail "agent start missing required flags" "$(cat "$HERDR_LOG")"
fi

if grep -q "agent prompt" "$HERDR_LOG"; then
  PROMPT_LINE=$(grep "agent prompt" "$HERDR_LOG")
  if grep -q -- "--wait" <<< "$PROMPT_LINE"; then
    fail "agent prompt should NOT pass --wait (fire-and-forget)" "$PROMPT_LINE"
  else
    pass "agent prompt called without --wait (bare = fire-and-forget)"
  fi
else
  fail "agent prompt was not invoked" "$(cat "$HERDR_LOG")"
fi

if grep -q "agent send-keys" "$HERDR_LOG" && grep -q "Enter" "$HERDR_LOG"; then
  pass "agent send-keys ... Enter was invoked after agent prompt (bracketed-paste fix)"
else
  fail "mandatory follow-up Enter after multi-line prompt was not sent" "$(cat "$HERDR_LOG")"
fi

if grep -q "agent kill" "$HERDR_LOG"; then
  fail "invoked non-existent 'agent kill' subcommand" "$(cat "$HERDR_LOG")"
else
  pass "never called the fabricated 'agent kill' subcommand"
fi

NEW_STATE=$(jq -r '.spawned_sessions[-1].workspace_id // "MISSING"' "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json")
if [[ "$NEW_STATE" == "wT" ]]; then
  pass "spawned_sessions[] recorded workspace_id from the real spawn response"
else
  fail "spawned_sessions[] did not record workspace_id" "got: $NEW_STATE"
fi

PANE_ID_RECORDED=$(jq -r '.spawned_sessions[-1].pane_id // "MISSING"' "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json")
if [[ "$PANE_ID_RECORDED" == "wT:p1" ]]; then
  pass "spawned_sessions[] recorded pane_id (authoritative teardown target)"
else
  fail "spawned_sessions[] did not record pane_id" "got: $PANE_ID_RECORDED"
fi

echo -e "${YELLOW}Test 2: inside a herdr pane, the session spawns as a TAB of the spawner's workspace${NC}"

: > "$HERDR_LOG"
OUTPUT=$(HERDR_WORKSPACE_ID=wS bash "$FORK_SCRIPT" "$LOOP_ID" 3 "$REPO_DIR" 2>&1)
RC=$?
[[ $RC -eq 0 ]] && pass "tab-mode spawn exited 0" || fail "tab-mode spawn exited $RC" "$OUTPUT"

if grep -q "tab create --workspace wS" "$HERDR_LOG"; then
  pass "tab create targeted the spawner's workspace"
else
  fail "tab create did not target the spawner's workspace" "$(cat "$HERDR_LOG")"
fi
if grep -q "workspace create" "$HERDR_LOG"; then
  fail "tab-mode spawn still created a new workspace" "$(cat "$HERDR_LOG")"
else
  pass "tab-mode spawn created no new workspace"
fi
if [[ "$(jq -r '.spawned_sessions[-1].pane_id' "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json")" == "wS:p9" ]]; then
  pass "tab-mode recorded the tab's pane_id"
else
  fail "tab-mode did not record the tab's pane_id" "$(jq -c '.spawned_sessions' "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json")"
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
