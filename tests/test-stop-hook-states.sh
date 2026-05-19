#!/bin/bash

# Unit tests for ralph-loop-fork stop hook state machine
# Tests all state transitions and edge cases

set -euo pipefail

# Test configuration
TEST_DIR=$(mktemp -d)
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hooks/stop-hook-fork.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Setup test environment
setup_test_env() {
  local loop_id="$1"
  local test_name="$2"

  # Create loop directory structure
  mkdir -p "$TEST_DIR/.claude/ralph-fork/$loop_id"

  # Create mock transcript with RALPH LOOP CONTEXT
  mkdir -p "$TEST_DIR/transcripts"
  local transcript_file="$TEST_DIR/transcripts/$test_name.jsonl"

  echo "$transcript_file"
}

# Create a mock state.json
# Args: loop_id total_budget total_iterations awaiting_checklist_update awaiting_confirmation
#        executing_on_completion on_completion_cmd checklist_file
#        awaiting_background_agents bg_agent_block_count
create_state_file() {
  local loop_id="$1"
  local total_budget="${2:-100}"
  local total_iterations="${3:-0}"
  local awaiting_checklist_update="${4:-false}"
  local awaiting_confirmation="${5:-false}"
  local executing_on_completion="${6:-false}"
  local on_completion_cmd="${7:-}"
  local checklist_file="${8:-}"
  local awaiting_background_agents="${9:-false}"
  local bg_agent_block_count="${10:-0}"

  local state_file="$TEST_DIR/.claude/ralph-fork/$loop_id/state.json"

  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": $total_budget,
  "max_per_session": 1,
  "total_iterations": $total_iterations,
  "session_number": 1,
  "session_token": "abc123",
  "completion_promise": "ALL_COMPLETE",
  "prompt": "Test prompt",
  "checklist_file": "$checklist_file",
  "on_completion_command": $(if [[ -n "$on_completion_cmd" ]]; then echo "\"$on_completion_cmd\""; else echo "null"; fi),
  "awaiting_checklist_update": $awaiting_checklist_update,
  "awaiting_confirmation": $awaiting_confirmation,
  "executing_on_completion": $executing_on_completion,
  "awaiting_background_agents": $awaiting_background_agents,
  "bg_agent_block_count": $bg_agent_block_count,
  "spawned_sessions": []
}
EOF
}

# Create a mock local.md
create_local_file() {
  local loop_id="$1"
  local iteration="${2:-1}"
  local completion_promise="${3:-ALL_COMPLETE}"

  local local_file="$TEST_DIR/.claude/ralph-fork/$loop_id/local.md"

  cat > "$local_file" <<EOF
---
loop_id: $loop_id
active: true
session_number: 1
session_token: abc123
iteration: $iteration
max_per_session: 1
completion_promise: "$completion_promise"
started_at: "2026-01-22T12:00:00Z"
---

Test prompt
EOF
}

# Create a mock transcript
create_transcript() {
  local transcript_file="$1"
  local loop_id="$2"
  local assistant_output="$3"

  # Create user message with RALPH LOOP CONTEXT
  cat > "$transcript_file" <<EOF
{"type":"user","message":{"role":"user","content":"RALPH LOOP CONTEXT (Loop: $loop_id, Session 1, Token: abc123): Test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"$assistant_output"}]}}
EOF
}

# Create a mock checklist file
create_checklist() {
  local checklist_file="$1"
  local unchecked="${2:-0}"
  local checked="${3:-3}"

  cat > "$checklist_file" <<EOF
# Test Checklist

## Tasks
EOF

  for ((i=1; i<=checked; i++)); do
    echo "- [x] Task $i complete" >> "$checklist_file"
  done

  for ((i=1; i<=unchecked; i++)); do
    echo "- [ ] Task $((checked + i)) pending" >> "$checklist_file"
  done
}

# Run the hook with mock environment.
# stop_hook_active_val: "false" (default, fresh session) or "true" (continuation cycle).
run_hook() {
  local transcript_file="$1"
  local stop_hook_active_val="${2:-false}"

  # Create hook input JSON
  local input_json
  input_json=$(jq -n \
    --arg transcript "$transcript_file" \
    --argjson sha "$stop_hook_active_val" \
    '{
      "stop_hook_active": $sha,
      "transcript_path": $transcript
    }')

  # Run hook from test directory
  cd "$TEST_DIR"
  echo "$input_json" | bash "$HOOK_SCRIPT" 2>&1 || true
}

# Assert function
assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="$3"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$expected" == "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $message"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $message"
    echo "  Expected: $expected"
    echo "  Actual:   $actual"
    return 1
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"

  TESTS_RUN=$((TESTS_RUN + 1))

  if echo "$haystack" | grep -q "$needle"; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: $message"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $message"
    echo "  Expected to contain: $needle"
    return 1
  fi
}

find_state_file() {
  local loop_id="$1"

  local state_file="$TEST_DIR/.claude/ralph-fork/$loop_id/state.json"

  if [[ -f "$state_file" ]]; then
    echo "$state_file"
    return 0
  fi

  # Check archive directory for state file (loop may have been archived)
  local archive_dir="$TEST_DIR/.claude/ralph-fork/.archive"
  if [[ -d "$archive_dir" ]]; then
    # Find most recent archive for this loop
    local archive_state=$(find "$archive_dir" -path "*$loop_id*" -name "state.json" 2>/dev/null | head -1)
    if [[ -n "$archive_state" ]]; then
      echo "$archive_state"
      return 0
    fi
  fi

  return 1
}

assert_state_flag() {
  local loop_id="$1"
  local flag="$2"
  local expected="$3"
  local message="$4"

  local state_file
  state_file=$(find_state_file "$loop_id")

  if [[ -z "$state_file" ]]; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: $message"
    echo "  State file not found for loop: $loop_id"
    return 1
  fi

  local actual=$(jq -r ".$flag // false" "$state_file" 2>/dev/null || echo "error")

  assert_equals "$expected" "$actual" "$message"
}

# ============================================================================
# TEST CASES
# ============================================================================

echo "=============================================="
echo "Ralph Loop Fork Stop Hook - State Machine Tests"
echo "=============================================="
echo ""

# -----------------------------------------------------------------------------
# Test 1: Budget exhausted → exits cleanly
# -----------------------------------------------------------------------------
test_budget_exhausted() {
  echo -e "${YELLOW}Test 1: Budget exhausted → exits cleanly${NC}"

  local loop_id="test-budget"
  local transcript_file=$(setup_test_env "$loop_id" "budget_test")

  # Create state with budget=5, iterations=5 (next will be 6, exceeding budget)
  create_state_file "$loop_id" 5 5 false false false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Some work done"

  local output=$(run_hook "$transcript_file")

  assert_contains "budget" "$output" "Output mentions budget exhausted"
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive"
  assert_state_flag "$loop_id" "budget_exhausted" "true" "Budget exhausted flag set"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 2: executing_on_completion=true → cleanup & exit
# -----------------------------------------------------------------------------
test_executing_on_completion() {
  echo -e "${YELLOW}Test 2: executing_on_completion=true + stop_hook_active=false → stale recovery${NC}"

  local loop_id="test-on-completion"
  local transcript_file=$(setup_test_env "$loop_id" "on_completion_test")

  create_state_file "$loop_id" 100 1 false false true
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "On-completion executed"

  local output=$(run_hook "$transcript_file")

  # Stale-state detector fires before the old line-923 handler; no BLOCK decision emitted.
  assert_contains "orphaned" "$output" "Output indicates stale orphaned recovery"
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive"
  assert_state_flag "$loop_id" "termination_reason" "orphaned_executing_on_completion" "Stale termination reason set"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 3: awaiting_confirmation + <confirmed>YES + all boxes → on-completion
# -----------------------------------------------------------------------------
test_confirmation_success_with_on_completion() {
  echo -e "${YELLOW}Test 3: awaiting_confirmation + confirmed YES + all boxes → on-completion (continuation cycle)${NC}"

  local loop_id="test-confirm-success"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_success_test")
  local checklist_file="$TEST_DIR/checklist-confirm.md"

  create_checklist "$checklist_file" 0 3  # 0 unchecked, 3 checked
  create_state_file "$loop_id" 100 1 false true false "/reflect-learn" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  # Use stop_hook_active=true: AWAITING_CONFIRMATION is processed in the continuation cycle.
  local output=$(run_hook "$transcript_file" true)

  assert_contains "Confirmation verified" "$output" "Confirmation verified message"
  assert_state_flag "$loop_id" "executing_on_completion" "true" "executing_on_completion flag set"
  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation flag cleared"
  assert_contains "block" "$output" "Hook returns BLOCK decision for on-completion"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 4: awaiting_confirmation + <confirmed>YES + missing boxes → spawn
# -----------------------------------------------------------------------------
test_confirmation_with_missing_boxes() {
  echo -e "${YELLOW}Test 4: awaiting_confirmation + confirmed YES + missing boxes → spawn (continuation cycle)${NC}"

  local loop_id="test-confirm-missing"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_missing_test")
  local checklist_file="$TEST_DIR/checklist-missing.md"

  create_checklist "$checklist_file" 2 3  # 2 unchecked, 3 checked
  create_state_file "$loop_id" 100 1 false true false "/reflect-learn" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  # Use stop_hook_active=true: AWAITING_CONFIRMATION is processed in the continuation cycle.
  local output=$(run_hook "$transcript_file" true)

  assert_contains "still unchecked" "$output" "Output mentions unchecked items"
  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation flag cleared"
  # Note: spawn would fail in test because tmux not available, but flag cleared

  echo ""
}

# -----------------------------------------------------------------------------
# Test 5: awaiting_confirmation + no confirmed tag → spawn
# -----------------------------------------------------------------------------
test_confirmation_no_tag() {
  echo -e "${YELLOW}Test 5: awaiting_confirmation + no confirmed tag → spawn (continuation cycle)${NC}"

  local loop_id="test-confirm-no-tag"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_no_tag_test")

  create_state_file "$loop_id" 100 1 false true false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "I continued working on the task"

  # Use stop_hook_active=true: AWAITING_CONFIRMATION is processed in the continuation cycle.
  local output=$(run_hook "$transcript_file" true)

  assert_contains "No confirmation received" "$output" "Output mentions no confirmation"
  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation flag cleared"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 6: awaiting_checklist_update=true → spawn
# -----------------------------------------------------------------------------
test_awaiting_checklist_update() {
  echo -e "${YELLOW}Test 6: awaiting_checklist_update=true → spawn (continuation cycle)${NC}"

  local loop_id="test-checklist-update"
  local transcript_file=$(setup_test_env "$loop_id" "checklist_update_test")

  create_state_file "$loop_id" 100 1 true false false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Updated the checklist"

  # Use stop_hook_active=true: awaiting_checklist_update is processed in the continuation cycle.
  local output=$(run_hook "$transcript_file" true)

  assert_contains "Checklist updated" "$output" "Output mentions checklist updated"
  assert_state_flag "$loop_id" "awaiting_checklist_update" "false" "awaiting_checklist_update flag cleared"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 7: Promise found → set awaiting_confirmation
# -----------------------------------------------------------------------------
test_promise_found() {
  echo -e "${YELLOW}Test 7: Promise found → set awaiting_confirmation${NC}"

  local loop_id="test-promise-found"
  local transcript_file=$(setup_test_env "$loop_id" "promise_found_test")
  local checklist_file="$TEST_DIR/checklist-promise.md"

  create_checklist "$checklist_file" 0 3  # All checked
  create_state_file "$loop_id" 100 1 false false false "" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<promise>ALL_COMPLETE</promise>"

  local output=$(run_hook "$transcript_file")

  assert_contains "Promise detected" "$output" "Output mentions promise detected"
  assert_state_flag "$loop_id" "awaiting_confirmation" "true" "awaiting_confirmation flag set"
  assert_contains "block" "$output" "Hook returns BLOCK decision for confirmation"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 8: No promise → set awaiting_checklist_update
# -----------------------------------------------------------------------------
test_no_promise() {
  echo -e "${YELLOW}Test 8: No promise → set awaiting_checklist_update${NC}"

  local loop_id="test-no-promise"
  local transcript_file=$(setup_test_env "$loop_id" "no_promise_test")
  local checklist_file="$TEST_DIR/checklist-no-promise.md"

  create_checklist "$checklist_file" 2 3
  create_state_file "$loop_id" 100 1 false false false "" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "I worked on some tasks but not done yet"

  local output=$(run_hook "$transcript_file")

  assert_contains "SESSION ENDING" "$output" "Output mentions session ending"
  assert_state_flag "$loop_id" "awaiting_checklist_update" "true" "awaiting_checklist_update flag set"
  assert_contains "block" "$output" "Hook returns BLOCK decision for checklist update"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 9: Promise found but unchecked items → reject and ask to update
# -----------------------------------------------------------------------------
test_promise_with_unchecked_items() {
  echo -e "${YELLOW}Test 9: Promise found but unchecked items → reject${NC}"

  local loop_id="test-promise-unchecked"
  local transcript_file=$(setup_test_env "$loop_id" "promise_unchecked_test")
  local checklist_file="$TEST_DIR/checklist-unchecked.md"

  create_checklist "$checklist_file" 2 3  # 2 unchecked
  create_state_file "$loop_id" 100 1 false false false "" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<promise>ALL_COMPLETE</promise>"

  local output=$(run_hook "$transcript_file")

  assert_contains "items unchecked" "$output" "Output mentions unchecked items"
  assert_state_flag "$loop_id" "awaiting_checklist_update" "true" "awaiting_checklist_update flag set"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 10: Confirmation without on-completion command → complete loop
# -----------------------------------------------------------------------------
test_confirmation_no_on_completion() {
  echo -e "${YELLOW}Test 10: Confirmation without on-completion → complete (continuation cycle)${NC}"

  local loop_id="test-confirm-no-cmd"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_no_cmd_test")
  local checklist_file="$TEST_DIR/checklist-no-cmd.md"

  create_checklist "$checklist_file" 0 3  # All checked
  create_state_file "$loop_id" 100 1 false true false "" "$checklist_file"  # No on-completion
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  # Use stop_hook_active=true: AWAITING_CONFIRMATION is processed in the continuation cycle.
  local output=$(run_hook "$transcript_file" true)

  assert_contains "loop complete" "$output" "Output indicates loop complete"
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive"

  echo ""
}

# -----------------------------------------------------------------------------
# Test A: stop_hook_active=false + executing_on_completion=true → stale recovery
# -----------------------------------------------------------------------------
test_stale_executing_on_completion() {
  echo -e "${YELLOW}Test A: stale executing_on_completion=true → orphaned recovery, no BLOCK${NC}"

  local loop_id="test-stale-eoc"
  local transcript_file=$(setup_test_env "$loop_id" "stale_eoc_test")

  # executing_on_completion=true, stop_hook_active=false (default)
  create_state_file "$loop_id" 100 1 false false true
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Some output after on-completion"

  local output=$(run_hook "$transcript_file")

  # Stale detector fires: no "decision" key should appear in stdout JSON
  if echo "$output" | grep -q '"decision"'; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: No decision block in output (stale detector should not BLOCK)"
    echo "  Got decision in: $output"
  else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: No decision block emitted (stale recovery exits cleanly)"
  fi
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive by stale detector"
  assert_state_flag "$loop_id" "termination_reason" "orphaned_executing_on_completion" "Stale termination reason set"

  echo ""
}

# -----------------------------------------------------------------------------
# Test B: stop_hook_active=false + awaiting_confirmation=true, no promise in transcript
# -----------------------------------------------------------------------------
test_stale_awaiting_confirmation() {
  echo -e "${YELLOW}Test B: stale awaiting_confirmation=true → flag cleared, no confirmation BLOCK${NC}"

  local loop_id="test-stale-ac"
  local transcript_file=$(setup_test_env "$loop_id" "stale_ac_test")

  # awaiting_confirmation=true, no promise in transcript, stop_hook_active=false
  create_state_file "$loop_id" 100 1 false true false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Continuing some work without any tags"

  local output=$(run_hook "$transcript_file")

  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation cleared by stale detector"
  # Output should not contain a confirmation-request block (no "confirmed" prompt)
  if echo "$output" | grep -qi "confirm.*100"; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: Output should not contain confirmation BLOCK request"
  else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: No confirmation BLOCK request emitted"
  fi

  echo ""
}

# -----------------------------------------------------------------------------
# Test C: stop_hook_active=false + awaiting_background_agents=true
# -----------------------------------------------------------------------------
test_stale_awaiting_background_agents() {
  echo -e "${YELLOW}Test C: stale awaiting_background_agents=true → flags cleared, no stale BLOCK${NC}"

  local loop_id="test-stale-aba"
  local transcript_file=$(setup_test_env "$loop_id" "stale_aba_test")

  # awaiting_background_agents=true, bg_agent_block_count=3, stop_hook_active=false
  create_state_file "$loop_id" 100 1 false false false "" "" true 3
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Some output with no pending agents"

  local output=$(run_hook "$transcript_file")

  assert_state_flag "$loop_id" "awaiting_background_agents" "false" "awaiting_background_agents cleared by stale detector"
  assert_state_flag "$loop_id" "bg_agent_block_count" "0" "bg_agent_block_count reset to 0"

  echo ""
}

# -----------------------------------------------------------------------------
# Test D (regression): stop_hook_active=true + awaiting_checklist_update=true +
#   awaiting_background_agents=true → after spawn: bg flags cleared
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Test E: stop_hook_active=false + awaiting_checklist_update=true → flag cleared (stale Case 3)
# -----------------------------------------------------------------------------
test_stale_awaiting_checklist_update() {
  echo -e "${YELLOW}Test E: stale awaiting_checklist_update=true → falls through to RUNNING (not old spawn)${NC}"

  local loop_id="test-stale-acu"
  local transcript_file=$(setup_test_env "$loop_id" "stale_acu_test")

  # awaiting_checklist_update=true, stop_hook_active=false (default)
  create_state_file "$loop_id" 100 1 true false false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Continuing some work without any promise tag"

  local output=$(run_hook "$transcript_file")

  # The stale detector clears the flag and falls through; RUNNING state re-evaluates.
  # No promise found → RUNNING state sets awaiting_checklist_update=true (that's OK) and issues BLOCK.
  # Key: output comes from RUNNING state, NOT the old handler ("Checklist updated").
  if echo "$output" | grep -q "Checklist updated, spawning new session"; then
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: Old direct-spawn handler should NOT fire — stale detector must fall through"
  else
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: Old direct-spawn path did not fire (stale detector fell through to RUNNING)"
  fi
  # RUNNING state issued a block (decision:block in JSON output)
  assert_contains '"decision"' "$output" "RUNNING state issued a block decision"
  # RUNNING state re-set awaiting_checklist_update=true after stale-detector cleared it
  assert_state_flag "$loop_id" "awaiting_checklist_update" "true" "awaiting_checklist_update re-set by RUNNING state"

  echo ""
}

# -----------------------------------------------------------------------------
# Test F: --all-stuck cancels loops with executing_on_completion=true
# Test G: --all-stuck cancels loops with awaiting_confirmation=true
# Test H: --all-stuck does NOT cancel loops that are not stuck
# -----------------------------------------------------------------------------
CANCEL_SCRIPT="$SCRIPT_DIR/scripts/cancel-ralph-loop-fork.sh"

test_all_stuck_cancels_eoc() {
  echo -e "${YELLOW}Test F: --all-stuck cancels loop with executing_on_completion=true${NC}"

  # Use isolated tmp dir so accumulated state from earlier tests doesn't interfere
  local cancel_dir
  cancel_dir=$(mktemp -d)
  local loop_id="stuck-eoc-cancel"
  mkdir -p "$cancel_dir/.claude/ralph-fork/$loop_id"
  local state_file="$cancel_dir/.claude/ralph-fork/$loop_id/state.json"

  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "executing_on_completion": true,
  "awaiting_confirmation": false,
  "spawned_sessions": []
}
EOF

  local output
  output=$(cd "$cancel_dir" && bash "$CANCEL_SCRIPT" --all-stuck 2>&1)

  assert_contains "Cleaned 1 stuck loop" "$output" "Reports 1 loop cleaned"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ ! -d "$cancel_dir/.claude/ralph-fork/$loop_id" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: State directory removed after --all-stuck"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: State directory should be removed after --all-stuck"
  fi
  rm -rf "$cancel_dir"

  echo ""
}

test_all_stuck_cancels_awaiting_confirmation() {
  echo -e "${YELLOW}Test G: --all-stuck cancels loop with awaiting_confirmation=true${NC}"

  local cancel_dir
  cancel_dir=$(mktemp -d)
  local loop_id="stuck-ac-cancel"
  mkdir -p "$cancel_dir/.claude/ralph-fork/$loop_id"
  local state_file="$cancel_dir/.claude/ralph-fork/$loop_id/state.json"

  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "executing_on_completion": false,
  "awaiting_confirmation": true,
  "spawned_sessions": []
}
EOF

  local output
  output=$(cd "$cancel_dir" && bash "$CANCEL_SCRIPT" --all-stuck 2>&1)

  assert_contains "Cleaned 1 stuck loop" "$output" "Reports 1 loop cleaned"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ ! -d "$cancel_dir/.claude/ralph-fork/$loop_id" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: State directory removed after --all-stuck"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: State directory should be removed after --all-stuck"
  fi
  rm -rf "$cancel_dir"

  echo ""
}

test_all_stuck_skips_non_stuck() {
  echo -e "${YELLOW}Test H: --all-stuck skips loop that is active but not stuck${NC}"

  local cancel_dir
  cancel_dir=$(mktemp -d)
  local loop_id="active-not-stuck"
  mkdir -p "$cancel_dir/.claude/ralph-fork/$loop_id"
  local state_file="$cancel_dir/.claude/ralph-fork/$loop_id/state.json"

  cat > "$state_file" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "executing_on_completion": false,
  "awaiting_confirmation": false,
  "spawned_sessions": []
}
EOF

  local output
  output=$(cd "$cancel_dir" && bash "$CANCEL_SCRIPT" --all-stuck 2>&1)

  assert_contains "No stuck loops found" "$output" "Reports no stuck loops"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -d "$cancel_dir/.claude/ralph-fork/$loop_id" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "${GREEN}PASS${NC}: Non-stuck state directory preserved"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "${RED}FAIL${NC}: Non-stuck state directory should be preserved"
  fi
  rm -rf "$cancel_dir"

  echo ""
}

test_malformed_message_spawn_site() {
  echo -e "${YELLOW}Test I: malformed-message spawn site clears awaiting_background_agents${NC}"

  local loop_id="test-malformed-spawn"
  local transcript_file=$(setup_test_env "$loop_id" "malformed_spawn_test")

  # awaiting_background_agents=true (stale), executing_on_completion=false
  create_state_file "$loop_id" 100 1 false false false "" "" true 1
  create_local_file "$loop_id" 1

  # Transcript with tool_use-only content — no text output from assistant
  cat > "$transcript_file" <<EOF
{"type":"user","message":{"role":"user","content":"RALPH LOOP CONTEXT (Loop: $loop_id, Session 1, Token: abc123): Test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo test"}}]}}
EOF

  local output=$(run_hook "$transcript_file")

  # Stale detector (Case 4) clears aba; malformed-message spawn site also clears it
  assert_state_flag "$loop_id" "awaiting_background_agents" "false" "awaiting_background_agents cleared"
  # Malformed-message handler sets awaiting_checklist_update=true and issues a BLOCK
  assert_state_flag "$loop_id" "awaiting_checklist_update" "true" "awaiting_checklist_update set by malformed-message handler"
  assert_contains '"decision"' "$output" "Malformed-message handler issued a block decision"

  echo ""
}

test_spawn_site_clears_orphan_flags() {
  echo -e "${YELLOW}Test D: spawn site clears awaiting_background_agents + executing_on_completion${NC}"

  local loop_id="test-spawn-site"
  local transcript_file=$(setup_test_env "$loop_id" "spawn_site_test")

  # awaiting_checklist_update=true, executing_on_completion=true (stale), awaiting_background_agents=true, stop_hook_active=true
  # executing_on_completion=true here tests that the spawn site ACTUALLY clears it (non-tautological).
  create_state_file "$loop_id" 100 1 true false true "" "" true 2
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Updated the checklist"

  # stop_hook_active=true: continuation cycle fires, spawns new session
  local output=$(run_hook "$transcript_file" true)

  # After spawn: awaiting_background_agents and executing_on_completion must be cleared
  assert_state_flag "$loop_id" "awaiting_background_agents" "false" "awaiting_background_agents cleared at spawn site"
  assert_state_flag "$loop_id" "executing_on_completion" "false" "executing_on_completion cleared at spawn site"

  echo ""
}

# ============================================================================
# RUN ALL TESTS
# ============================================================================

test_budget_exhausted
test_executing_on_completion
test_confirmation_success_with_on_completion
test_confirmation_with_missing_boxes
test_confirmation_no_tag
test_awaiting_checklist_update
test_promise_found
test_no_promise
test_promise_with_unchecked_items
test_confirmation_no_on_completion
test_stale_executing_on_completion
test_stale_awaiting_confirmation
test_stale_awaiting_background_agents
test_stale_awaiting_checklist_update
test_all_stuck_cancels_eoc
test_all_stuck_cancels_awaiting_confirmation
test_all_stuck_skips_non_stuck
test_malformed_message_spawn_site
test_spawn_site_clears_orphan_flags

# ============================================================================
# SUMMARY
# ============================================================================

echo "=============================================="
echo "Test Results"
echo "=============================================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo ""

# Cleanup
rm -rf "$TEST_DIR"

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
fi
