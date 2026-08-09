#!/bin/bash

# Tests run_cleanup_detached()'s embedded cleanup script (the CLEANUP_EOF
# heredoc in hooks/stop-hook-fork.sh) for the herdr backend. This is the
# code path that actually fires when a ralph loop completes -- a real bug
# was found here on 2026-08-09: the heredoc was 100% hardcoded to
# `tmux kill-session`, silently leaking every herdr pane on loop completion
# (confirmed via a live spawn: workspace stayed listed as agent_status=done
# after the loop archived). This test extracts the heredoc verbatim from
# the real script (so it can never silently drift from production) and
# runs it against a hermetic herdr/tmux stub.

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

WORK_DIR=$(mktemp -d -t detached-cleanup-herdr-test-XXXX)
STUB_DIR=$(mktemp -d -t detached-cleanup-herdr-stubs-XXXX)
CALL_LOG=$(mktemp -t detached-cleanup-herdr-calls-XXXX)

cleanup() {
  rm -rf "$WORK_DIR" "$STUB_DIR" "$CALL_LOG"
}
trap cleanup EXIT

# Extract the embedded cleanup script verbatim between the CLEANUP_EOF
# markers -- proves the test exercises the actual production code, not a
# reimplementation that could silently drift.
CLEANUP_SCRIPT="$WORK_DIR/cleanup.sh"
awk '/cat > "\$cleanup_script" << .CLEANUP_EOF.$/{flag=1; next} /^CLEANUP_EOF$/{flag=0} flag' "$STOP_HOOK" > "$CLEANUP_SCRIPT"

if [[ ! -s "$CLEANUP_SCRIPT" ]]; then
  fail "heredoc extraction" "extracted script is empty -- markers in stop-hook-fork.sh may have changed"
  echo "Failed: $TESTS_FAILED"
  exit 1
fi
chmod +x "$CLEANUP_SCRIPT"
pass "extracted CLEANUP_EOF heredoc from stop-hook-fork.sh (non-empty)"

cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{
  printf 'CALL: '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
} >> "$STUB_CALL_LOG"
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"

cat > "$STUB_DIR/tmux" <<'STUBT'
#!/bin/bash
{
  printf 'TMUX CALL (SHOULD NEVER HAPPEN FOR HERDR BACKEND): '
  for arg in "$@"; do
    printf '%q ' "$arg"
  done
  printf '\n'
} >> "$STUB_CALL_LOG"
exit 1
STUBT
chmod +x "$STUB_DIR/tmux"

export STUB_CALL_LOG="$CALL_LOG"
export PATH="$STUB_DIR:$PATH"

STATE_FILE="$WORK_DIR/state.json"
LOOP_DIR="$WORK_DIR/loop"
mkdir -p "$LOOP_DIR"
cat > "$STATE_FILE" <<EOF
{
  "loop_id": "cleanuptest",
  "active": true,
  "backend": "herdr",
  "original_session_name": "",
  "spawned_sessions": [
    {"name": "ralph-cleanuptest-1-aaaaaa", "pane_id": "wA:p1", "session_number": 1, "spawned_at": "2026-08-09T00:00:00Z"},
    {"name": "ralph-cleanuptest-2-bbbbbb", "pane_id": "wB:p1", "session_number": 2, "spawned_at": "2026-08-09T00:01:00Z"}
  ]
}
EOF

LOG_FILE="$WORK_DIR/detached.log"

echo -e "${YELLOW}Test: herdr-backend detached cleanup closes panes via herdr, never tmux${NC}"

bash "$CLEANUP_SCRIPT" "cleanuptest" "$STATE_FILE" "false" "false" "$LOOP_DIR" "$WORK_DIR" "$LOG_FILE" >/dev/null 2>&1

if grep -q "wA:p1" "$CALL_LOG" && grep -q "wB:p1" "$CALL_LOG"; then
  pass "both spawned panes closed via herdr pane close"
else
  fail "not all panes were closed via herdr" "$(cat "$CALL_LOG" 2>/dev/null)"
fi

if grep -q "^CALL: pane close" "$CALL_LOG"; then
  pass "herdr invoked with 'pane close' subcommand"
else
  fail "herdr not invoked with expected 'pane close' subcommand" "$(cat "$CALL_LOG" 2>/dev/null)"
fi

if grep -q "TMUX CALL" "$CALL_LOG"; then
  fail "tmux was called for a herdr-backend loop (regression of the 2026-08-09 bug)" "$(cat "$CALL_LOG" 2>/dev/null)"
else
  pass "tmux was never called for herdr-backend cleanup"
fi

if [[ -f "$STATE_FILE" ]] && [[ "$(jq -r '.spawned_sessions | length' "$STATE_FILE")" == "0" ]]; then
  pass "state.json spawned_sessions cleared after cleanup"
else
  fail "state.json spawned_sessions not cleared" "$(cat "$STATE_FILE")"
fi

echo -e "${YELLOW}Test: preserve_final=true skips the last session's pane${NC}"

: > "$CALL_LOG"
cat > "$STATE_FILE" <<EOF
{
  "loop_id": "cleanuptest2",
  "active": true,
  "backend": "herdr",
  "original_session_name": "",
  "spawned_sessions": [
    {"name": "ralph-cleanuptest2-1-cccccc", "pane_id": "wC:p1", "session_number": 1, "spawned_at": "2026-08-09T00:00:00Z"},
    {"name": "ralph-cleanuptest2-2-dddddd", "pane_id": "wD:p1", "session_number": 2, "spawned_at": "2026-08-09T00:01:00Z"}
  ]
}
EOF

# The cleanup script deletes itself as its last action -- re-extract for
# this second invocation.
awk '/cat > "\$cleanup_script" << .CLEANUP_EOF.$/{flag=1; next} /^CLEANUP_EOF$/{flag=0} flag' "$STOP_HOOK" > "$CLEANUP_SCRIPT"
chmod +x "$CLEANUP_SCRIPT"

bash "$CLEANUP_SCRIPT" "cleanuptest2" "$STATE_FILE" "true" "false" "$LOOP_DIR" "$WORK_DIR" "$LOG_FILE" >/dev/null 2>&1

if grep -q "wC:p1" "$CALL_LOG" && ! grep -q "wD:p1" "$CALL_LOG"; then
  pass "preserve_final=true closed the non-final pane and preserved the final one"
else
  fail "preserve_final semantics wrong for herdr backend" "$(cat "$CALL_LOG" 2>/dev/null)"
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
