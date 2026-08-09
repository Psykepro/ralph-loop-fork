#!/bin/bash

# Tests that two concurrent --backend herdr loops' cleanup paths never
# cross-close each other's panes/workspaces. Hermetic herdr CLI stub, no
# real server required -- exercises cleanup_ralph_sessions()'s herdr branch
# directly against two independent state.json fixtures.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STOP_HOOK="$SCRIPT_DIR/hooks/stop-hook-fork.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

REPO_DIR=$(mktemp -d -t concurrent-herdr-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t concurrent-herdr-test-stubs-XXXX)
HERDR_LOG=$(mktemp -t concurrent-herdr-test-log-XXXX)

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$HERDR_LOG"
}
trap cleanup EXIT

LOOP_A="loop-alpha"
LOOP_B="loop-beta"

mkdir -p "$REPO_DIR/.claude/ralph-fork/$LOOP_A" "$REPO_DIR/.claude/ralph-fork/$LOOP_B"

cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_A/state.json" <<EOF
{
  "loop_id": "$LOOP_A",
  "active": true,
  "backend": "herdr",
  "preserve_final_session": false,
  "no_cleanup": false,
  "spawned_sessions": [
    {"name": "agent-a1", "pane_id": "wA1:p1", "session_number": 1, "spawned_at": "2026-08-09T00:00:00Z"},
    {"name": "agent-a2", "pane_id": "wA2:p1", "session_number": 2, "spawned_at": "2026-08-09T00:01:00Z"}
  ],
  "original_session_name": ""
}
EOF

cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_B/state.json" <<EOF
{
  "loop_id": "$LOOP_B",
  "active": true,
  "backend": "herdr",
  "preserve_final_session": false,
  "no_cleanup": false,
  "spawned_sessions": [
    {"name": "agent-b1", "pane_id": "wB1:p1", "session_number": 1, "spawned_at": "2026-08-09T00:00:00Z"},
    {"name": "agent-b2", "pane_id": "wB2:p1", "session_number": 2, "spawned_at": "2026-08-09T00:01:00Z"}
  ],
  "original_session_name": ""
}
EOF

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

echo -e "${YELLOW}Test: two loops' cleanup_ralph_sessions() calls stay isolated${NC}"

# Fixture sanity check: the two loops' pane_ids must be genuinely disjoint
# for this test to prove anything.
PANES_A=$(jq -r '.spawned_sessions[].pane_id' "$REPO_DIR/.claude/ralph-fork/$LOOP_A/state.json")
PANES_B=$(jq -r '.spawned_sessions[].pane_id' "$REPO_DIR/.claude/ralph-fork/$LOOP_B/state.json")

OVERLAP=$(comm -12 <(sort <<< "$PANES_A") <(sort <<< "$PANES_B"))
if [[ -z "$OVERLAP" ]]; then
  pass "loop-alpha and loop-beta's pane_ids are disjoint (fixture sanity check)"
else
  fail "fixture itself has overlapping pane_ids" "$OVERLAP"
fi

# Real end-to-end isolation test: cancel loop-alpha for real via the CLI
# (not via sourcing internals -- neither cancel-ralph-loop-fork.sh nor
# stop-hook-fork.sh are designed to be sourced as libraries, both run a
# top-level argument dispatch immediately on source) and confirm
# loop-beta's state directory and panes are untouched.
CANCEL_SCRIPT="$SCRIPT_DIR/scripts/cancel-ralph-loop-fork.sh"
cd "$REPO_DIR" || exit 1
OUTPUT=$(bash "$CANCEL_SCRIPT" "$LOOP_A" 2>&1)

if grep -q "wA1:p1" "$HERDR_LOG" && grep -q "wA2:p1" "$HERDR_LOG"; then
  pass "cancelling loop-alpha closed loop-alpha's own panes"
else
  fail "cancelling loop-alpha did not close its own panes" "$(cat "$HERDR_LOG")"
fi

if grep -q "wB1:p1" "$HERDR_LOG" || grep -q "wB2:p1" "$HERDR_LOG"; then
  fail "cancelling loop-alpha ALSO closed a loop-beta pane (cross-loop leak)" "$(cat "$HERDR_LOG")"
else
  pass "cancelling loop-alpha did NOT touch any loop-beta pane"
fi

if [[ -d "$REPO_DIR/.claude/ralph-fork/$LOOP_B" ]]; then
  pass "loop-beta's state directory survives loop-alpha's cancellation"
else
  fail "loop-beta's state directory was removed by loop-alpha's cancellation" "expected: still present"
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
