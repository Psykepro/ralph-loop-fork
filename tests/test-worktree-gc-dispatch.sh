#!/bin/bash

# Unit tests for stop-hook-fork.sh's `dispatch_worktree_gc` (Trigger 0,
# chore-worktree-gc-2026-08-05 in the AEOS "ai-agentic-coding-ready-now" repo).
#
# Stubs `python3` (the worktree-gc.py invocation) and `tmux` (pane pid
# resolution) on PATH so these tests are deterministic and never spawn a
# real detached process or touch a real tmux session/worktree.

set -euo pipefail

TEST_DIR=$(mktemp -d)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hooks/stop-hook-fork.sh"

cleanup() {
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

assert_equals() {
  local expected="$1" actual="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$expected" == "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $message"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local needle="$1" haystack="$2" message="$3"
  TESTS_RUN=$((TESTS_RUN + 1))
  if echo "$haystack" | grep -qF -- "$needle"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $message"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $message (expected to contain '$needle')"
  fi
}

# ── PATH shims ──────────────────────────────────────────────────────────
# Fake python3: logs its invocation (one line per call) to $SPAWN_LOG and
# exits immediately — never actually runs worktree-gc.py.
STUB_BIN="$TEST_DIR/bin"
mkdir -p "$STUB_BIN"
SPAWN_LOG="$TEST_DIR/spawn.log"

cat > "$STUB_BIN/python3" <<'EOF'
#!/bin/bash
echo "python3 $* CLAUDE_PROJECT_DIR=${CLAUDE_PROJECT_DIR:-<unset>}" >> "$SPAWN_LOG_FILE"
exit 0
EOF
chmod +x "$STUB_BIN/python3"

cat > "$STUB_BIN/tmux" <<'EOF'
#!/bin/bash
if [[ "$1" == "list-panes" ]]; then
  echo "88888"
  exit 0
fi
exit 0
EOF
chmod +x "$STUB_BIN/tmux"

export PATH="$STUB_BIN:$PATH"
export SPAWN_LOG_FILE="$SPAWN_LOG"

setup_test_env() {
  local loop_id="$1" test_name="$2"
  mkdir -p "$TEST_DIR/.claude/ralph-fork/$loop_id"
  mkdir -p "$TEST_DIR/transcripts"
  mkdir -p "$TEST_DIR/_project/signals"
  # Mimic <main>/.worktrees/<name> convention — dispatch derives main_root
  # from worktree_path by stripping this exact suffix shape.
  mkdir -p "$TEST_DIR/.claude/scripts"
  touch "$TEST_DIR/.claude/scripts/worktree-gc.py"
  echo "$TEST_DIR/transcripts/$test_name.jsonl"
}

# Args: loop_id checklist_file worktree_path preserve_final session_name
#       awaiting_checklist_update awaiting_confirmation executing_on_completion
#       on_completion_cmd
create_state_file() {
  local loop_id="$1"
  local checklist_file="${2:-}"
  local worktree_path="${3:-null}"
  local preserve_final="${4:-false}"
  local session_name="${5:-ralph-$loop_id-1}"
  local awaiting_checklist_update="${6:-false}"
  local awaiting_confirmation="${7:-false}"
  local executing_on_completion="${8:-false}"
  local on_completion_cmd="${9:-}"

  local state_file="$TEST_DIR/.claude/ralph-fork/$loop_id/state.json"
  local wt_json
  if [[ "$worktree_path" == "null" ]]; then
    wt_json="null"
  else
    wt_json="\"$worktree_path\""
  fi
  local on_completion_json
  if [[ -n "$on_completion_cmd" ]]; then
    on_completion_json="\"$on_completion_cmd\""
  else
    on_completion_json="null"
  fi

  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 1,
  "session_number": 1,
  "session_token": "abc123",
  "completion_promise": "ALL_COMPLETE",
  "prompt": "Test prompt",
  "checklist_file": "$checklist_file",
  "on_completion_command": $on_completion_json,
  "awaiting_checklist_update": $awaiting_checklist_update,
  "awaiting_confirmation": $awaiting_confirmation,
  "executing_on_completion": $executing_on_completion,
  "awaiting_background_agents": false,
  "bg_agent_block_count": 0,
  "worktree_path": $wt_json,
  "preserve_final_session": $preserve_final,
  "spawned_sessions": [{"name": "$session_name", "preserved": false}]
}
EOF
}

create_local_file() {
  local loop_id="$1"
  cat > "$TEST_DIR/.claude/ralph-fork/$loop_id/local.md" <<EOF
---
loop_id: $loop_id
active: true
session_number: 1
session_token: abc123
iteration: 1
max_per_session: 1
completion_promise: "ALL_COMPLETE"
started_at: "2026-01-22T12:00:00Z"
---

Test prompt
EOF
}

create_transcript() {
  local transcript_file="$1" loop_id="$2" text="$3"
  cat > "$transcript_file" <<EOF
{"type":"user","message":{"role":"user","content":"RALPH LOOP CONTEXT (Loop: $loop_id, Session 1, Token: abc123): Test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"$text"}]}}
EOF
}

create_checklist() {
  local checklist_file="$1"
  cat > "$checklist_file" <<EOF
# Test Checklist
- [x] done
EOF
}

run_hook() {
  local transcript_file="$1"
  local stop_hook_active_val="${2:-true}"
  local input_json
  input_json=$(jq -n --arg t "$transcript_file" --argjson sha "$stop_hook_active_val" \
    '{"stop_hook_active": $sha, "transcript_path": $t}')
  cd "$TEST_DIR"
  echo "$input_json" | bash "$HOOK_SCRIPT" 2>&1 || true
}

spawn_count() {
  if [[ ! -f "$SPAWN_LOG" ]]; then
    echo 0
    return
  fi
  local c
  c=$(grep -cF -- "worktree-gc.py" "$SPAWN_LOG" 2>/dev/null) || true
  echo "${c:-0}"
}

# -----------------------------------------------------------------------------
# Test 1: eligible reason (checklist_moved) with worktree_path set → dispatches
# -----------------------------------------------------------------------------
test_checklist_moved_dispatches() {
  echo -e "${YELLOW}Test 1: checklist_moved (eligible) + worktree_path set → dispatches${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-checklist-moved"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "checklist_moved")
  create_state_file "$loop_id" "$TEST_DIR/nonexistent-checklist.md" \
    "$TEST_DIR/.worktrees/$loop_id" "false" "ralph-$loop_id-1" "true" "false" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "moved"

  run_hook "$transcript_file" true > /dev/null
  sleep 1  # detached spawn is async

  assert_equals "1" "$(spawn_count)" "exactly one worktree-gc.py dispatch for checklist_moved"
  assert_contains "--apply" "$(cat "$SPAWN_LOG" 2>/dev/null)" "dispatch includes --apply"
  assert_contains "--only" "$(cat "$SPAWN_LOG" 2>/dev/null)" "dispatch includes --only"
  assert_contains "--after-pid" "$(cat "$SPAWN_LOG" 2>/dev/null)" "dispatch includes --after-pid"
  assert_contains "--kill-session tmux:ralph-$loop_id-1" "$(cat "$SPAWN_LOG" 2>/dev/null)" "dispatch includes --kill-session tmux:<name>"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 1b (round-5 zero-issue-loop Reliability CRITICAL): the Stop hook can
# itself be running with CLAUDE_PROJECT_DIR set to the WORKTREE (the
# find_project_root() PWD-walk hazard) — the nohup'd worktree-gc.py child
# must NOT inherit that; it must be forced to main_root regardless of what
# the parent hook's own environment holds.
# -----------------------------------------------------------------------------
test_dispatch_forces_main_root_project_dir() {
  echo -e "${YELLOW}Test 1b: dispatch forces CLAUDE_PROJECT_DIR=main_root even if parent env has worktree path${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-project-dir-force"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "project-dir-force")
  create_state_file "$loop_id" "$TEST_DIR/nonexistent-checklist.md" \
    "$TEST_DIR/.worktrees/$loop_id" "false" "ralph-$loop_id-1" "true" "false" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "moved"

  CLAUDE_PROJECT_DIR="$TEST_DIR/.worktrees/$loop_id" run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "1" "$(spawn_count)" "exactly one worktree-gc.py dispatch"
  assert_contains "CLAUDE_PROJECT_DIR=$TEST_DIR" "$(cat "$SPAWN_LOG" 2>/dev/null)" \
    "worktree-gc.py child sees CLAUDE_PROJECT_DIR forced to main_root, not the inherited worktree path"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 2: worktree_path=null (non-worktree run) → never dispatches
# -----------------------------------------------------------------------------
test_null_worktree_path_no_dispatch() {
  echo -e "${YELLOW}Test 2: worktree_path=null → no dispatch${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-null-path"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "null_path")
  create_state_file "$loop_id" "$TEST_DIR/nonexistent-checklist.md" "null" "false" \
    "ralph-$loop_id-1" "true" "false" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "moved"

  run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "0" "$(spawn_count)" "no dispatch when worktree_path is null"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 3: preserve_final_session=true → never dispatches (session stays alive,
# worktree stays intact — DEFERRED by construction)
# -----------------------------------------------------------------------------
test_preserve_final_session_no_dispatch() {
  echo -e "${YELLOW}Test 3: preserve_final_session=true → no dispatch${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-preserve"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "preserve")
  create_state_file "$loop_id" "$TEST_DIR/nonexistent-checklist.md" \
    "$TEST_DIR/.worktrees/$loop_id" "true" "ralph-$loop_id-1" "true" "false" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "moved"

  run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "0" "$(spawn_count)" "no dispatch when preserve_final_session=true"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 3b: eligible reason (on_completion_executed) → dispatches
# -----------------------------------------------------------------------------
test_on_completion_executed_dispatches() {
  echo -e "${YELLOW}Test 3b: on_completion_executed (eligible) + worktree_path set → dispatches${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-on-completion"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "on_completion")
  # executing_on_completion=true + stop_hook_active=true → the continuation
  # cycle's "on-completion command was executed" branch, not the stale-state
  # orphaned-recovery branch (that needs stop_hook_active=false).
  create_state_file "$loop_id" "" "$TEST_DIR/.worktrees/$loop_id" "false" \
    "ralph-$loop_id-1" "false" "false" "true"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "on-completion executed"

  run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "1" "$(spawn_count)" "exactly one worktree-gc.py dispatch for on_completion_executed"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 3c: eligible reason (completed_no_checklist) → dispatches
# -----------------------------------------------------------------------------
test_completed_no_checklist_dispatches() {
  echo -e "${YELLOW}Test 3c: completed_no_checklist (eligible) + worktree_path set → dispatches${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-no-checklist"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "no_checklist")
  # awaiting_confirmation=true + <confirmed>YES</confirmed> in transcript +
  # empty checklist_file + no on_completion_cmd → "No checklist to verify"
  # → completed_no_checklist.
  create_state_file "$loop_id" "" "$TEST_DIR/.worktrees/$loop_id" "false" \
    "ralph-$loop_id-1" "false" "true" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "1" "$(spawn_count)" "exactly one worktree-gc.py dispatch for completed_no_checklist"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 4: ineligible reason (orphaned_executing_on_completion) → never dispatches
# even with worktree_path set
# -----------------------------------------------------------------------------
test_orphaned_ineligible_no_dispatch() {
  echo -e "${YELLOW}Test 4: orphaned_executing_on_completion (ineligible) → no dispatch${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-orphaned"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "orphaned")

  local state_file="$TEST_DIR/.claude/ralph-fork/$loop_id/state.json"
  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 1,
  "session_number": 1,
  "session_token": "abc123",
  "completion_promise": "ALL_COMPLETE",
  "prompt": "Test prompt",
  "checklist_file": "",
  "on_completion_command": null,
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": true,
  "awaiting_background_agents": false,
  "bg_agent_block_count": 0,
  "worktree_path": "$TEST_DIR/.worktrees/$loop_id",
  "preserve_final_session": false,
  "spawned_sessions": [{"name": "ralph-$loop_id-1", "preserved": false}]
}
EOF
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "orphaned"

  # stop_hook_active=false triggers the stale-state orphaned-recovery path
  run_hook "$transcript_file" false > /dev/null
  sleep 1

  assert_equals "0" "$(spawn_count)" "no dispatch on the ineligible orphaned_executing_on_completion path"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 5: double-fire (hook invoked twice for the same loop) → exactly one dispatch
# -----------------------------------------------------------------------------
test_double_fire_single_dispatch() {
  echo -e "${YELLOW}Test 5: double-fire (PreToolUse + PostToolUse) → exactly one helper spawn${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-doublefire"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "doublefire")
  create_state_file "$loop_id" "$TEST_DIR/nonexistent-checklist.md" \
    "$TEST_DIR/.worktrees/$loop_id" "false" "ralph-$loop_id-1" "true" "false" "false"
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "moved"

  # First fire — real dispatch, writes the marker file next to state.json.
  run_hook "$transcript_file" true > /dev/null
  sleep 1
  # Second fire: PreToolUse/PostToolUse invoke this same hook twice for one
  # logical Stop event (ralph-aeos-contract.double-fire.md). Re-run the
  # exact same hook invocation against the SAME (still-present) loop dir —
  # the marker file dispatch_worktree_gc wrote on the first fire must make
  # this second call a silent no-op rather than a second helper spawn.
  # (state.json now has active=false/termination_reason set from the first
  # fire, but the checklist_moved branch re-checks AWAITING_CHECKLIST_UPDATE
  # from the same on-disk state.json, which is still "true" here since only
  # dispatch_worktree_gc's own marker — not this flag — gates the re-fire;
  # this reproduces the real double-fire shape where both fires observe the
  # same pre-archival state.)
  run_hook "$transcript_file" true > /dev/null
  sleep 1

  assert_equals "1" "$(spawn_count)" "double-fire produces exactly one helper spawn (marker guard held)"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 6: budget_exhausted (never eligible, no emit_signal even) → no dispatch
# -----------------------------------------------------------------------------
test_budget_exhausted_no_dispatch() {
  echo -e "${YELLOW}Test 6: budget_exhausted → no dispatch${NC}"
  rm -f "$SPAWN_LOG"
  local loop_id="test-wtgc-budget"
  local transcript_file
  transcript_file=$(setup_test_env "$loop_id" "budget")

  local state_file="$TEST_DIR/.claude/ralph-fork/$loop_id/state.json"
  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": 5,
  "max_per_session": 1,
  "total_iterations": 5,
  "session_number": 1,
  "session_token": "abc123",
  "completion_promise": "ALL_COMPLETE",
  "prompt": "Test prompt",
  "checklist_file": "",
  "on_completion_command": null,
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": false,
  "awaiting_background_agents": false,
  "bg_agent_block_count": 0,
  "worktree_path": "$TEST_DIR/.worktrees/$loop_id",
  "preserve_final_session": false,
  "spawned_sessions": [{"name": "ralph-$loop_id-1", "preserved": false}]
}
EOF
  create_local_file "$loop_id"
  create_transcript "$transcript_file" "$loop_id" "budget"

  run_hook "$transcript_file" false > /dev/null
  sleep 1

  assert_equals "0" "$(spawn_count)" "no dispatch on budget_exhausted (BLOCKER.md territory, never eligible)"

  echo ""
}

echo "=============================================="
echo "worktree-gc Trigger 0 dispatch tests"
echo "=============================================="
echo ""

test_checklist_moved_dispatches
test_dispatch_forces_main_root_project_dir
test_null_worktree_path_no_dispatch
test_preserve_final_session_no_dispatch
test_on_completion_executed_dispatches
test_completed_no_checklist_dispatches
test_orphaned_ineligible_no_dispatch
test_double_fire_single_dispatch
test_budget_exhausted_no_dispatch

echo "=============================================="
echo "Test Results"
echo "=============================================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
fi
