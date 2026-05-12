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
create_state_file() {
  local loop_id="$1"
  local total_budget="${2:-100}"
  local total_iterations="${3:-0}"
  local awaiting_checklist_update="${4:-false}"
  local awaiting_confirmation="${5:-false}"
  local executing_on_completion="${6:-false}"
  local on_completion_cmd="${7:-}"
  local checklist_file="${8:-}"

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

# Run the hook with mock environment
run_hook() {
  local transcript_file="$1"
  local hook_input="${2:-{}}"

  # Create hook input JSON
  local input_json=$(jq -n \
    --arg transcript "$transcript_file" \
    '{
      "stop_hook_active": false,
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
  echo -e "${YELLOW}Test 2: executing_on_completion=true → cleanup & exit${NC}"

  local loop_id="test-on-completion"
  local transcript_file=$(setup_test_env "$loop_id" "on_completion_test")

  create_state_file "$loop_id" 100 1 false false true
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "On-completion executed"

  local output=$(run_hook "$transcript_file")

  assert_contains "loop complete" "$output" "Output indicates loop complete"
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive"
  assert_state_flag "$loop_id" "termination_reason" "on_completion_executed" "Termination reason set"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 3: awaiting_confirmation + <confirmed>YES + all boxes → on-completion
# -----------------------------------------------------------------------------
test_confirmation_success_with_on_completion() {
  echo -e "${YELLOW}Test 3: awaiting_confirmation + confirmed YES + all boxes → on-completion${NC}"

  local loop_id="test-confirm-success"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_success_test")
  local checklist_file="$TEST_DIR/checklist-confirm.md"

  create_checklist "$checklist_file" 0 3  # 0 unchecked, 3 checked
  create_state_file "$loop_id" 100 1 false true false "/reflect-learn" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  local output=$(run_hook "$transcript_file")

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
  echo -e "${YELLOW}Test 4: awaiting_confirmation + confirmed YES + missing boxes → spawn${NC}"

  local loop_id="test-confirm-missing"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_missing_test")
  local checklist_file="$TEST_DIR/checklist-missing.md"

  create_checklist "$checklist_file" 2 3  # 2 unchecked, 3 checked
  create_state_file "$loop_id" 100 1 false true false "/reflect-learn" "$checklist_file"
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  local output=$(run_hook "$transcript_file")

  assert_contains "still unchecked" "$output" "Output mentions unchecked items"
  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation flag cleared"
  # Note: spawn would fail in test because tmux not available, but flag cleared

  echo ""
}

# -----------------------------------------------------------------------------
# Test 5: awaiting_confirmation + no confirmed tag → spawn
# -----------------------------------------------------------------------------
test_confirmation_no_tag() {
  echo -e "${YELLOW}Test 5: awaiting_confirmation + no confirmed tag → spawn${NC}"

  local loop_id="test-confirm-no-tag"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_no_tag_test")

  create_state_file "$loop_id" 100 1 false true false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "I continued working on the task"

  local output=$(run_hook "$transcript_file")

  assert_contains "No confirmation received" "$output" "Output mentions no confirmation"
  assert_state_flag "$loop_id" "awaiting_confirmation" "false" "awaiting_confirmation flag cleared"

  echo ""
}

# -----------------------------------------------------------------------------
# Test 6: awaiting_checklist_update=true → spawn
# -----------------------------------------------------------------------------
test_awaiting_checklist_update() {
  echo -e "${YELLOW}Test 6: awaiting_checklist_update=true → spawn${NC}"

  local loop_id="test-checklist-update"
  local transcript_file=$(setup_test_env "$loop_id" "checklist_update_test")

  create_state_file "$loop_id" 100 1 true false false
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "Updated the checklist"

  local output=$(run_hook "$transcript_file")

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

  assert_contains "Session ending" "$output" "Output mentions session ending"
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
  echo -e "${YELLOW}Test 10: Confirmation without on-completion → complete${NC}"

  local loop_id="test-confirm-no-cmd"
  local transcript_file=$(setup_test_env "$loop_id" "confirm_no_cmd_test")
  local checklist_file="$TEST_DIR/checklist-no-cmd.md"

  create_checklist "$checklist_file" 0 3  # All checked
  create_state_file "$loop_id" 100 1 false true false "" "$checklist_file"  # No on-completion
  create_local_file "$loop_id" 1
  create_transcript "$transcript_file" "$loop_id" "<confirmed>YES</confirmed>"

  local output=$(run_hook "$transcript_file")

  assert_contains "loop complete" "$output" "Output indicates loop complete"
  assert_state_flag "$loop_id" "active" "false" "Loop marked inactive"

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
