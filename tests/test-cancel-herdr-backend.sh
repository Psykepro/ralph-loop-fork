#!/bin/bash

# Tests cancel-ralph-loop-fork.sh's herdr-backend branch: a loop whose
# state.json has "backend": "herdr" must be cancelled via `herdr pane
# close <pane_id>` (the stored, authoritative pane_id), never via `tmux
# kill-session`. Hermetic `herdr` CLI stub, no real server required.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CANCEL_SCRIPT="$SCRIPT_DIR/scripts/cancel-ralph-loop-fork.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

REPO_DIR=$(mktemp -d -t cancel-herdr-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t cancel-herdr-test-stubs-XXXX)
HERDR_LOG=$(mktemp -t cancel-herdr-test-log-XXXX)
LOOP_ID="herdr-cancel-loop"

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$HERDR_LOG"
}
trap cleanup EXIT

mkdir -p "$REPO_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<EOF
{
  "loop_id": "$LOOP_ID",
  "active": true,
  "backend": "herdr",
  "spawned_sessions": [
    {"name": "ralph-herdr-cancel-loop-1-aaaaaa", "agent_name": "ralph-herdr-cancel-loop-1-aaaaaa", "workspace_id": "wA", "pane_id": "wA:p1", "spawned_at": "2026-08-09T00:00:00Z"},
    {"name": "ralph-herdr-cancel-loop-2-bbbbbb", "agent_name": "ralph-herdr-cancel-loop-2-bbbbbb", "workspace_id": "wB", "pane_id": "wB:p1", "spawned_at": "2026-08-09T00:01:00Z"}
  ],
  "original_session_name": "",
  "worktree_path": null
}
EOF

# Stub tmux: if this is ever called, that's a bug (herdr-backend loops must
# never touch tmux). Fails loudly so the test catches a backend-dispatch
# regression.
cat > "$STUB_DIR/tmux" <<'STUBT'
#!/bin/bash
echo "TMUX CALLED (should never happen for a herdr-backend loop): $*" >&2
exit 1
STUBT
chmod +x "$STUB_DIR/tmux"

# Stub herdr: records every call, succeeds on pane close.
cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{
  printf 'CALL: '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
} >> "$STUB_HERDR_LOG_PATH"
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"
export STUB_HERDR_LOG_PATH="$HERDR_LOG"
export PATH="$STUB_DIR:$PATH"

echo -e "${YELLOW}Test 1: cancelling a herdr-backend loop closes panes, never touches tmux${NC}"

cd "$REPO_DIR" || exit 1
OUTPUT=$(bash "$CANCEL_SCRIPT" "$LOOP_ID" 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
  pass "cancel-ralph-loop-fork.sh exited 0"
else
  fail "cancel-ralph-loop-fork.sh exited $RC" "$OUTPUT"
fi

if grep -q "TMUX CALLED" <<< "$OUTPUT"; then
  fail "tmux was invoked for a herdr-backend loop" "$OUTPUT"
else
  pass "tmux was never invoked (correct backend dispatch)"
fi

if grep -q "pane close wA:p1" "$HERDR_LOG"; then
  pass "herdr pane close wA:p1 (stored pane_id) was invoked"
else
  fail "did not close pane wA:p1" "$(cat "$HERDR_LOG")"
fi

if grep -q "pane close wB:p1" "$HERDR_LOG"; then
  pass "herdr pane close wB:p1 (stored pane_id) was invoked"
else
  fail "did not close pane wB:p1" "$(cat "$HERDR_LOG")"
fi

if grep -q "agent kill" "$HERDR_LOG"; then
  fail "invoked non-existent 'agent kill' subcommand" "$(cat "$HERDR_LOG")"
else
  pass "never called the fabricated 'agent kill' subcommand"
fi

if [[ ! -d "$REPO_DIR/.claude/ralph-fork/$LOOP_ID" ]]; then
  pass "loop state directory removed"
else
  fail "loop state directory still exists" "expected removed: $REPO_DIR/.claude/ralph-fork/$LOOP_ID"
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
