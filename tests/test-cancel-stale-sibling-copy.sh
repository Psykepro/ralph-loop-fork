#!/bin/bash

# Regression test for a live bug (2026-09-16): setup-worktree.sh's
# untracked-file overlay copies EVERY sibling loop directory under
# .claude/ralph-fork/ (minus .archive) into a freshly created worktree, so
# a concurrently-launched sibling loop's state gets snapshotted — frozen —
# inside a worktree that is not its own. cancel-ralph-loop-fork.sh's
# resolve_loop_dir() used to walk `git worktree list` and return the FIRST
# directory matching the loop_id, with no check that it was the live one.
# When the stray, frozen copy sorted before the real one, `cancel <id>`
# silently removed the harmless stray and left the real, active loop
# completely untouched — a no-op cancel reported as success.
#
# Reproduces: two real git worktrees, WT-A (name "loop-a") carrying a
# frozen, foreign snapshot of "loop-b" (worktree_path unset, exactly as
# setup-worktree.sh's overlay would leave it), and WT-B (name "loop-b")
# holding the REAL, live "loop-b" state (worktree_path pointing at itself).
# `cancel loop-b` must resolve and remove WT-B's copy, never WT-A's.

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

REPO_DIR=$(mktemp -d -t cancel-stale-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t cancel-stale-test-stubs-XXXX)

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR"
}
trap cleanup EXIT

# --- Real git repo with two worktrees, named after the two loop ids -------
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" commit -q --allow-empty -m "initial"
git -C "$REPO_DIR" worktree add -q -b "ralph/loop-a" "$REPO_DIR/.worktrees/loop-a" >/dev/null 2>&1
git -C "$REPO_DIR" worktree add -q -b "ralph/loop-b" "$REPO_DIR/.worktrees/loop-b" >/dev/null 2>&1

WT_A="$REPO_DIR/.worktrees/loop-a"
WT_B="$REPO_DIR/.worktrees/loop-b"

# --- Stray snapshot of loop-b, frozen inside loop-a's worktree (exactly
# what setup-worktree.sh's sibling-copy step produces: no worktree_path
# yet, session 1, empty fork_history) ---------------------------------------
mkdir -p "$WT_A/.claude/ralph-fork/loop-b"
cat > "$WT_A/.claude/ralph-fork/loop-b/state.json" <<'EOF'
{
  "loop_id": "loop-b",
  "active": true,
  "backend": "herdr",
  "session_number": 1,
  "fork_history": [],
  "spawned_sessions": [],
  "worktree_path": null
}
EOF

# --- The REAL, live loop-b state, in its own worktree ----------------------
mkdir -p "$WT_B/.claude/ralph-fork/loop-b"
cat > "$WT_B/.claude/ralph-fork/loop-b/state.json" <<EOF
{
  "loop_id": "loop-b",
  "active": true,
  "backend": "herdr",
  "session_number": 4,
  "fork_history": [{"session": 4}],
  "spawned_sessions": [
    {"name": "ralph-loop-b-4-cccccc", "agent_name": "ralph-loop-b-4-cccccc", "workspace_id": "wC", "pane_id": "wC:p1", "spawned_at": "2026-09-16T13:08:31Z"}
  ],
  "worktree_path": "$WT_B"
}
EOF

# Stub herdr: records every call, succeeds on pane/workspace close.
cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
echo "herdr $*" >> "$HERDR_LOG"
if [[ "$1" == "pane" && "$2" == "close" ]]; then
  echo '{"id":"cli:pane:close","result":{"type":"ok"}}'
  exit 0
fi
if [[ "$1" == "workspace" && "$2" == "close" ]]; then
  echo '{"id":"cli:workspace:close","result":{"type":"ok"}}'
  exit 0
fi
if [[ "$1" == "pane" && "$2" == "list" ]]; then
  echo '[]'
  exit 0
fi
if [[ "$1" == "workspace" && "$2" == "list" ]]; then
  echo '[]'
  exit 0
fi
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"

HERDR_LOG=$(mktemp -t cancel-stale-test-herdr-log-XXXX)
export HERDR_LOG
export PATH="$STUB_DIR:$PATH"

cd "$REPO_DIR" || exit 1

OUTPUT=$(bash "$CANCEL_SCRIPT" loop-b 2>&1)
EXIT_CODE=$?

echo "--- cancel output ---"
echo "$OUTPUT"
echo "---------------------"

if [[ "$EXIT_CODE" -eq 0 ]]; then
  pass "cancel-ralph-loop-fork.sh exited 0"
else
  fail "cancel-ralph-loop-fork.sh exited 0" "got exit $EXIT_CODE"
fi

if [[ ! -d "$WT_B/.claude/ralph-fork/loop-b" ]]; then
  pass "the REAL loop-b state dir (in its own worktree) was removed"
else
  fail "the REAL loop-b state dir (in its own worktree) was removed" "still present at $WT_B/.claude/ralph-fork/loop-b — cancel hit the wrong copy"
fi

if [[ -d "$WT_A/.claude/ralph-fork/loop-b" ]]; then
  pass "the STALE sibling copy (in loop-a's worktree) was left alone"
else
  fail "the STALE sibling copy (in loop-a's worktree) was left alone" "it was removed instead of the real one — cancel still resolving the wrong directory"
fi

if echo "$OUTPUT" | grep -q "stray"; then
  pass "cancel surfaced a warning about the stray candidate it skipped"
else
  fail "cancel surfaced a warning about the stray candidate it skipped" "no 'stray' warning in output"
fi

rm -f "$HERDR_LOG"

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Failed: $TESTS_FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
