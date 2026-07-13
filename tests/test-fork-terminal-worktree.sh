#!/bin/bash

# Tests that fork-terminal.sh honours PROJECT_ROOT (i.e., the worktree path)
# when launching the next session. Uses a `tmux` stub that records its args
# instead of actually launching anything, so the test is hermetic and fast.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_SCRIPT="$SCRIPT_DIR/scripts/fork-terminal.sh"

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
TMUX_LOG=$(mktemp -t fork-test-tmux-log-XXXX)
LOOP_ID="wt-loop"

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$TMUX_LOG"
}
trap cleanup EXIT

mkdir -p "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<EOF
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
  "worktree_path": "$WORKTREE_DIR"
}
EOF
echo "test prompt" > "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/prompt.txt"

# Stub tmux that records every call to a log and returns appropriately for
# the subcommands fork-terminal.sh uses.
cat > "$STUB_DIR/tmux" <<'STUBT'
#!/bin/bash
{
  printf 'CALL: '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\nCWD: %s\n' "$(pwd)"
} >> "$STUB_TMUX_LOG_PATH"

case "${1:-}" in
  has-session)
    # No sessions exist in this hermetic test.
    exit 1
    ;;
  *)
    exit 0
    ;;
esac
STUBT
chmod +x "$STUB_DIR/tmux"
export STUB_TMUX_LOG_PATH="$TMUX_LOG"
export PATH="$STUB_DIR:$PATH"

echo -e "${YELLOW}Test 1: fork-terminal.sh launches inside the worktree${NC}"

# fork-terminal.sh launches a delayed cleanup background subshell — give it a
# fast no-op tmux stub so the cleanup is harmless.
OUTPUT=$(bash "$FORK_SCRIPT" "$LOOP_ID" 2 "$WORKTREE_DIR" 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
  pass "fork-terminal.sh exited 0"
else
  fail "fork-terminal.sh exited $RC" "$OUTPUT"
fi

if grep -q "Forking to new session: ralph-${LOOP_ID}-2" <<< "$OUTPUT"; then
  pass "Announces correct session name (ralph-${LOOP_ID}-2)"
else
  fail "Did not announce ralph-${LOOP_ID}-2 session" "$OUTPUT"
fi

if grep -q "new-session" "$TMUX_LOG"; then
  pass "tmux new-session was invoked"
else
  fail "tmux new-session was not invoked" "$(cat "$TMUX_LOG")"
fi

# Confirm tmux was told to launch in the worktree, not in the repo root.
if grep -q -- "-c $WORKTREE_DIR" "$TMUX_LOG"; then
  pass "tmux session launched with -c <worktree-dir>"
else
  fail "tmux -c arg did not point at the worktree" "$(cat "$TMUX_LOG")"
fi

# Confirm fork-terminal cd'd to the worktree itself (the recorded CWD).
if grep -q "CWD: $WORKTREE_DIR" "$TMUX_LOG"; then
  pass "fork-terminal.sh ran tmux from the worktree (pwd == worktree)"
else
  fail "fork-terminal.sh did not cd to the worktree before tmux" "$(cat "$TMUX_LOG")"
fi

# The new session must be recorded in state.json under spawned_sessions, and
# fork_history must have been appended.
NEW_STATE=$(jq -r '.spawned_sessions[-1].name // "MISSING"' "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json")
if [[ "$NEW_STATE" == "ralph-${LOOP_ID}-2" ]]; then
  pass "spawned_sessions[] in state.json includes the new session"
else
  fail "spawned_sessions[] did not record new session" "got: $NEW_STATE"
fi

FORK_COUNT=$(jq -r '.fork_history | length' "$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json")
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
echo -e "${YELLOW}Test 2: old state.json without effort key → --effort medium fallback, no crash${NC}"

# Test 1's state.json predates the effort field entirely (and has no model
# pin). The spawn must still succeed and default effort to medium, while
# leaving the model unpinned (resumed old loops keep their model behavior).
SPAWN2_LINE=$(grep "new-session" "$TMUX_LOG" | grep "ralph-${LOOP_ID}-2")
if grep -qE -- '\-\-effort\\? medium' <<< "$SPAWN2_LINE"; then
  pass "FORK_CMD contains --effort medium (missing-key fallback)"
else
  fail "FORK_CMD missing --effort medium fallback" "$SPAWN2_LINE"
fi
if ! grep -q -- "--model" <<< "$SPAWN2_LINE"; then
  pass "Unpinned old state stays unpinned (no --model injected)"
else
  fail "--model unexpectedly injected for model-less state" "$SPAWN2_LINE"
fi

echo ""
echo -e "${YELLOW}Test 3: state.json model/effort are read back into FORK_CMD${NC}"

STATE_JSON="$WORKTREE_DIR/.claude/ralph-fork/$LOOP_ID/state.json"
jq '.model = "sonnet" | .effort = "medium"' "$STATE_JSON" > "$STATE_JSON.tmp" \
  && mv "$STATE_JSON.tmp" "$STATE_JSON"

OUTPUT3=$(bash "$FORK_SCRIPT" "$LOOP_ID" 3 "$WORKTREE_DIR" 2>&1)
RC3=$?
if [[ $RC3 -eq 0 ]]; then
  pass "fork-terminal.sh exited 0 with model+effort in state"
else
  fail "fork-terminal.sh exited $RC3" "$OUTPUT3"
fi

SPAWN3_LINE=$(grep "new-session" "$TMUX_LOG" | grep "ralph-${LOOP_ID}-3")
if grep -qE -- '\-\-model\\? sonnet' <<< "$SPAWN3_LINE" \
   && grep -qE -- '\-\-effort\\? medium' <<< "$SPAWN3_LINE"; then
  pass "FORK_CMD contains --model sonnet --effort medium from state.json"
else
  fail "FORK_CMD missing persisted model/effort flags" "$SPAWN3_LINE"
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
