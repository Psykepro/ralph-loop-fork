#!/bin/bash

# Unit tests for ralph-loop-fork state tracking
# Run: bash tests/test-state-tracking.sh

# Note: Not using set -e because we need to handle test failures gracefully
set -uo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
  echo -e "${GREEN}✓ PASS${NC}: $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}✗ FAIL${NC}: $1"
  echo "  Expected: $2"
  echo "  Got: $3"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "Running state tracking unit tests..."
echo "Test directory: $TEST_DIR"
echo ""

# ============================================================================
# Test 1: update_state function (extracted from hook)
# ============================================================================
echo "=== Test 1: update_state function ==="

# Create the update_state function for testing
update_state() {
  local state_file="$1"
  local jq_filter="$2"

  if [[ ! -f "$state_file" ]]; then
    return 1
  fi

  if jq "$jq_filter" "$state_file" > "${state_file}.tmp" 2>/dev/null; then
    mv "${state_file}.tmp" "$state_file"
    return 0
  else
    rm -f "${state_file}.tmp"
    return 1
  fi
}

# Test 1a: Basic state update
STATE_FILE="$TEST_DIR/state1.json"
echo '{"loop_id": "test1", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" '.test_field = "value1"'
RESULT=$(jq -r '.test_field' "$STATE_FILE")
if [[ "$RESULT" == "value1" ]]; then
  pass "Basic state update"
else
  fail "Basic state update" "value1" "$RESULT"
fi

# Test 1b: Nested object update
STATE_FILE="$TEST_DIR/state2.json"
echo '{"loop_id": "test2", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" '.checklist_validation = {"checked": 5, "unchecked": 0, "passed": true}'
RESULT=$(jq -r '.checklist_validation.checked' "$STATE_FILE")
if [[ "$RESULT" == "5" ]]; then
  pass "Nested object update"
else
  fail "Nested object update" "5" "$RESULT"
fi

# Test 1c: Array append
STATE_FILE="$TEST_DIR/state3.json"
echo '{"loop_id": "test3", "fork_history": []}' > "$STATE_FILE"
update_state "$STATE_FILE" '.fork_history += [{"session": 1, "reason": "test"}]'
RESULT=$(jq -r '.fork_history | length' "$STATE_FILE")
if [[ "$RESULT" == "1" ]]; then
  pass "Array append"
else
  fail "Array append" "1" "$RESULT"
fi

# Test 1d: Multiple field update
STATE_FILE="$TEST_DIR/state4.json"
echo '{"loop_id": "test4", "active": true, "total_iterations": 0}' > "$STATE_FILE"
update_state "$STATE_FILE" '.active = false | .total_iterations = 5 | .completed = true'
ACTIVE=$(jq -r '.active' "$STATE_FILE")
ITERATIONS=$(jq -r '.total_iterations' "$STATE_FILE")
COMPLETED=$(jq -r '.completed' "$STATE_FILE")
if [[ "$ACTIVE" == "false" ]] && [[ "$ITERATIONS" == "5" ]] && [[ "$COMPLETED" == "true" ]]; then
  pass "Multiple field update"
else
  fail "Multiple field update" "active=false, iterations=5, completed=true" "active=$ACTIVE, iterations=$ITERATIONS, completed=$COMPLETED"
fi

echo ""

# ============================================================================
# Test 2: Checklist validation state tracking
# ============================================================================
echo "=== Test 2: Checklist validation tracking ==="

# Test 2a: Validation passed
STATE_FILE="$TEST_DIR/state_validation1.json"
echo '{"loop_id": "valid1", "active": true}' > "$STATE_FILE"
CHECKED=5
update_state "$STATE_FILE" ".checklist_validation = {
  \"checked\": $CHECKED,
  \"unchecked\": 0,
  \"passed\": true,
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
RESULT=$(jq -r '.checklist_validation.passed' "$STATE_FILE")
if [[ "$RESULT" == "true" ]]; then
  pass "Checklist validation passed tracking"
else
  fail "Checklist validation passed tracking" "true" "$RESULT"
fi

# Test 2b: Validation failed
STATE_FILE="$TEST_DIR/state_validation2.json"
echo '{"loop_id": "valid2", "active": true}' > "$STATE_FILE"
CHECKED=3
UNCHECKED=2
update_state "$STATE_FILE" ".checklist_validation = {
  \"checked\": $CHECKED,
  \"unchecked\": $UNCHECKED,
  \"passed\": false,
  \"timestamp\": \"2026-01-22T10:00:00Z\",
  \"reason\": \"unchecked_items_remain\"
} | .promise_detected = true | .completion_rejected = true"
PASSED=$(jq -r '.checklist_validation.passed' "$STATE_FILE")
REJECTED=$(jq -r '.completion_rejected' "$STATE_FILE")
if [[ "$PASSED" == "false" ]] && [[ "$REJECTED" == "true" ]]; then
  pass "Checklist validation failed tracking"
else
  fail "Checklist validation failed tracking" "passed=false, rejected=true" "passed=$PASSED, rejected=$REJECTED"
fi

echo ""

# ============================================================================
# Test 3: On-completion command tracking
# ============================================================================
echo "=== Test 3: On-completion tracking ==="

# Test 3a: On-completion success
STATE_FILE="$TEST_DIR/state_oncomp1.json"
echo '{"loop_id": "oncomp1", "active": true}' > "$STATE_FILE"
ON_COMPLETION_CMD="echo test"
ON_COMPLETION_CMD_JSON=$(echo "$ON_COMPLETION_CMD" | jq -Rs .)
update_state "$STATE_FILE" ".on_completion = {
  \"executed\": true,
  \"result\": \"success\",
  \"command\": $ON_COMPLETION_CMD_JSON,
  \"tmux_session\": \"ralph-oncomp1-1\",
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
EXECUTED=$(jq -r '.on_completion.executed' "$STATE_FILE")
RESULT=$(jq -r '.on_completion.result' "$STATE_FILE")
if [[ "$EXECUTED" == "true" ]] && [[ "$RESULT" == "success" ]]; then
  pass "On-completion success tracking"
else
  fail "On-completion success tracking" "executed=true, result=success" "executed=$EXECUTED, result=$RESULT"
fi

# Test 3b: On-completion session not found
STATE_FILE="$TEST_DIR/state_oncomp2.json"
echo '{"loop_id": "oncomp2", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".on_completion = {
  \"executed\": false,
  \"result\": \"session_not_found\",
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
EXECUTED=$(jq -r '.on_completion.executed' "$STATE_FILE")
RESULT=$(jq -r '.on_completion.result' "$STATE_FILE")
if [[ "$EXECUTED" == "false" ]] && [[ "$RESULT" == "session_not_found" ]]; then
  pass "On-completion session not found tracking"
else
  fail "On-completion session not found tracking" "executed=false, result=session_not_found" "executed=$EXECUTED, result=$RESULT"
fi

# Test 3c: On-completion not configured
STATE_FILE="$TEST_DIR/state_oncomp3.json"
echo '{"loop_id": "oncomp3", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".on_completion = {
  \"executed\": false,
  \"result\": \"not_configured\",
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
RESULT=$(jq -r '.on_completion.result' "$STATE_FILE")
if [[ "$RESULT" == "not_configured" ]]; then
  pass "On-completion not configured tracking"
else
  fail "On-completion not configured tracking" "not_configured" "$RESULT"
fi

echo ""

# ============================================================================
# Test 4: Fork history tracking
# ============================================================================
echo "=== Test 4: Fork history tracking ==="

STATE_FILE="$TEST_DIR/state_fork.json"
echo '{"loop_id": "fork1", "fork_history": []}' > "$STATE_FILE"

# First fork
update_state "$STATE_FILE" ".fork_history += [{
  \"from_session\": 1,
  \"to_session\": 2,
  \"iteration\": 1,
  \"reason\": \"max_per_session_reached\",
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}]"

# Second fork
update_state "$STATE_FILE" ".fork_history += [{
  \"from_session\": 2,
  \"to_session\": 3,
  \"iteration\": 2,
  \"reason\": \"max_per_session_reached\",
  \"timestamp\": \"2026-01-22T10:01:00Z\"
}]"

FORK_COUNT=$(jq -r '.fork_history | length' "$STATE_FILE")
FIRST_FROM=$(jq -r '.fork_history[0].from_session' "$STATE_FILE")
SECOND_TO=$(jq -r '.fork_history[1].to_session' "$STATE_FILE")

if [[ "$FORK_COUNT" == "2" ]] && [[ "$FIRST_FROM" == "1" ]] && [[ "$SECOND_TO" == "3" ]]; then
  pass "Fork history tracking"
else
  fail "Fork history tracking" "count=2, first_from=1, second_to=3" "count=$FORK_COUNT, first_from=$FIRST_FROM, second_to=$SECOND_TO"
fi

echo ""

# ============================================================================
# Test 5: Budget exhaustion tracking
# ============================================================================
echo "=== Test 5: Budget exhaustion tracking ==="

STATE_FILE="$TEST_DIR/state_budget.json"
echo '{"loop_id": "budget1", "active": true, "total_budget": 10}' > "$STATE_FILE"
update_state "$STATE_FILE" ".active = false | .budget_exhausted = true | .final_session = 3 | .final_iterations = 10 | .termination_reason = \"budget_exhausted\""

ACTIVE=$(jq -r '.active' "$STATE_FILE")
EXHAUSTED=$(jq -r '.budget_exhausted' "$STATE_FILE")
REASON=$(jq -r '.termination_reason' "$STATE_FILE")

if [[ "$ACTIVE" == "false" ]] && [[ "$EXHAUSTED" == "true" ]] && [[ "$REASON" == "budget_exhausted" ]]; then
  pass "Budget exhaustion tracking"
else
  fail "Budget exhaustion tracking" "active=false, exhausted=true, reason=budget_exhausted" "active=$ACTIVE, exhausted=$EXHAUSTED, reason=$REASON"
fi

echo ""

# ============================================================================
# Test 6: Progress detection tracking
# ============================================================================
echo "=== Test 6: Progress detection tracking ==="

# Test 6a: Progress detected
STATE_FILE="$TEST_DIR/state_progress1.json"
echo '{"loop_id": "prog1", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".checklist_hash = \"newhash123\" | .progress_detection = {
  \"changed\": true,
  \"session\": 1,
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
CHANGED=$(jq -r '.progress_detection.changed' "$STATE_FILE")
if [[ "$CHANGED" == "true" ]]; then
  pass "Progress detected tracking"
else
  fail "Progress detected tracking" "true" "$CHANGED"
fi

# Test 6b: No progress
STATE_FILE="$TEST_DIR/state_progress2.json"
echo '{"loop_id": "prog2", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".progress_detection = {
  \"changed\": false,
  \"warning\": \"no_progress\",
  \"session\": 2,
  \"timestamp\": \"2026-01-22T10:00:00Z\"
}"
CHANGED=$(jq -r '.progress_detection.changed' "$STATE_FILE")
WARNING=$(jq -r '.progress_detection.warning' "$STATE_FILE")
if [[ "$CHANGED" == "false" ]] && [[ "$WARNING" == "no_progress" ]]; then
  pass "No progress warning tracking"
else
  fail "No progress warning tracking" "changed=false, warning=no_progress" "changed=$CHANGED, warning=$WARNING"
fi

echo ""

# ============================================================================
# Test 7: Complete workflow state
# ============================================================================
echo "=== Test 7: Complete workflow state ==="

STATE_FILE="$TEST_DIR/state_complete.json"
cat > "$STATE_FILE" << 'EOF'
{
  "loop_id": "complete-test",
  "active": true,
  "total_budget": 100,
  "total_iterations": 0,
  "session_number": 1,
  "completion_promise": "Task complete",
  "on_completion_command": "echo done",
  "fork_history": []
}
EOF

# Simulate workflow: checklist validation → promise matched → on-completion
update_state "$STATE_FILE" ".checklist_validation = {\"checked\": 5, \"unchecked\": 0, \"passed\": true}"
update_state "$STATE_FILE" ".promise_detected = true | .promise_matched = true"
update_state "$STATE_FILE" ".active = false | .final_session = 1 | .final_iterations = 1"
update_state "$STATE_FILE" ".on_completion = {\"executed\": true, \"result\": \"success\"}"

# Verify complete state
ACTIVE=$(jq -r '.active' "$STATE_FILE")
PROMISE_MATCHED=$(jq -r '.promise_matched' "$STATE_FILE")
CHECKLIST_PASSED=$(jq -r '.checklist_validation.passed' "$STATE_FILE")
ON_COMP_EXEC=$(jq -r '.on_completion.executed' "$STATE_FILE")

if [[ "$ACTIVE" == "false" ]] && [[ "$PROMISE_MATCHED" == "true" ]] && [[ "$CHECKLIST_PASSED" == "true" ]] && [[ "$ON_COMP_EXEC" == "true" ]]; then
  pass "Complete workflow state"
else
  fail "Complete workflow state" "all true" "active=$ACTIVE, promise=$PROMISE_MATCHED, checklist=$CHECKLIST_PASSED, oncomp=$ON_COMP_EXEC"
fi

echo ""

# ============================================================================
# Test 8: Confirmation flow tracking
# ============================================================================
echo "=== Test 8: Confirmation flow tracking ==="

# Test 8a: Awaiting confirmation
STATE_FILE="$TEST_DIR/state_confirm1.json"
echo '{"loop_id": "confirm1", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".awaiting_confirmation = true | .confirmation_requested_at = \"2026-01-22T10:00:00Z\""
AWAITING=$(jq -r '.awaiting_confirmation' "$STATE_FILE")
if [[ "$AWAITING" == "true" ]]; then
  pass "Awaiting confirmation tracking"
else
  fail "Awaiting confirmation tracking" "true" "$AWAITING"
fi

# Test 8b: Confirmation received
STATE_FILE="$TEST_DIR/state_confirm2.json"
echo '{"loop_id": "confirm2", "active": true, "awaiting_confirmation": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".confirmation_received = true | .confirmation_text = \"YES, all 5 items are 100% complete\" | .confirmed_at = \"2026-01-22T10:01:00Z\" | .awaiting_confirmation = false"
RECEIVED=$(jq -r '.confirmation_received' "$STATE_FILE")
AWAITING=$(jq -r '.awaiting_confirmation' "$STATE_FILE")
if [[ "$RECEIVED" == "true" ]] && [[ "$AWAITING" == "false" ]]; then
  pass "Confirmation received tracking"
else
  fail "Confirmation received tracking" "received=true, awaiting=false" "received=$RECEIVED, awaiting=$AWAITING"
fi

echo ""

# ============================================================================
# Test 9: Checklist review before fork tracking
# ============================================================================
echo "=== Test 9: Checklist review tracking ==="

# Test 9a: Review pending
STATE_FILE="$TEST_DIR/state_review1.json"
echo '{"loop_id": "review1", "active": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".checklist_review_pending = true | .checklist_review_requested_at = \"2026-01-22T10:00:00Z\""
PENDING=$(jq -r '.checklist_review_pending' "$STATE_FILE")
if [[ "$PENDING" == "true" ]]; then
  pass "Checklist review pending tracking"
else
  fail "Checklist review pending tracking" "true" "$PENDING"
fi

# Test 9b: Review completed
STATE_FILE="$TEST_DIR/state_review2.json"
echo '{"loop_id": "review2", "active": true, "checklist_review_pending": true}' > "$STATE_FILE"
update_state "$STATE_FILE" ".checklist_review_pending = false | .checklist_review_completed_at = \"2026-01-22T10:01:00Z\""
PENDING=$(jq -r '.checklist_review_pending' "$STATE_FILE")
COMPLETED_AT=$(jq -r '.checklist_review_completed_at' "$STATE_FILE")
if [[ "$PENDING" == "false" ]] && [[ "$COMPLETED_AT" == "2026-01-22T10:01:00Z" ]]; then
  pass "Checklist review completed tracking"
else
  fail "Checklist review completed tracking" "pending=false" "pending=$PENDING"
fi

echo ""

# ============================================================================
# Test 10: Full workflow with confirmation
# ============================================================================
echo "=== Test 10: Full workflow with confirmation ==="

STATE_FILE="$TEST_DIR/state_full_confirm.json"
cat > "$STATE_FILE" << 'EOF'
{
  "loop_id": "full-confirm-test",
  "active": true,
  "total_budget": 100,
  "total_iterations": 0,
  "session_number": 1,
  "completion_promise": "All done",
  "fork_history": []
}
EOF

# Simulate: checklist passes → awaiting confirmation → confirmation received → complete
update_state "$STATE_FILE" ".checklist_validation = {\"checked\": 3, \"unchecked\": 0, \"passed\": true}"
update_state "$STATE_FILE" ".awaiting_confirmation = true"
update_state "$STATE_FILE" ".confirmation_received = true | .confirmation_text = \"YES\" | .awaiting_confirmation = false"
update_state "$STATE_FILE" ".promise_detected = true | .promise_matched = true"
update_state "$STATE_FILE" ".active = false | .final_session = 1"

ACTIVE=$(jq -r '.active' "$STATE_FILE")
CONFIRMED=$(jq -r '.confirmation_received' "$STATE_FILE")
PROMISE=$(jq -r '.promise_matched' "$STATE_FILE")

if [[ "$ACTIVE" == "false" ]] && [[ "$CONFIRMED" == "true" ]] && [[ "$PROMISE" == "true" ]]; then
  pass "Full workflow with confirmation"
else
  fail "Full workflow with confirmation" "active=false, confirmed=true, promise=true" "active=$ACTIVE, confirmed=$CONFIRMED, promise=$PROMISE"
fi

echo ""

# ============================================================================
# Test 11: setup script model/effort defaults in state.json
# ============================================================================
echo "=== Test 11: setup script model/effort defaults ==="

SETUP_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/setup-ralph-loop-fork.sh"
SETUP_DIR="$TEST_DIR/setup-fixture"
mkdir -p "$SETUP_DIR"
echo "- [ ] task" > "$SETUP_DIR/checklist.md"

# Test 11a: no --model/--effort → defaults sonnet/medium persisted
(cd "$SETUP_DIR" && env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
  --checklist checklist.md --name deftest >/dev/null 2>&1)
STATE_FILE="$SETUP_DIR/.claude/ralph-fork/deftest/state.json"
MODEL_VAL=$(jq -r '.model // "MISSING"' "$STATE_FILE" 2>/dev/null || echo "NO_STATE")
EFFORT_VAL=$(jq -r '.effort // "MISSING"' "$STATE_FILE" 2>/dev/null || echo "NO_STATE")
if [[ "$MODEL_VAL" == "sonnet" ]] && [[ "$EFFORT_VAL" == "medium" ]]; then
  pass "Defaults: model=sonnet effort=medium persisted when flags omitted"
else
  fail "Defaults: model=sonnet effort=medium persisted when flags omitted" \
    "model=sonnet effort=medium" "model=$MODEL_VAL effort=$EFFORT_VAL"
fi

# Test 11b: explicit --model/--effort override the defaults
(cd "$SETUP_DIR" && env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
  --checklist checklist.md --name ovrtest --model opus --effort high >/dev/null 2>&1)
STATE_FILE="$SETUP_DIR/.claude/ralph-fork/ovrtest/state.json"
MODEL_VAL=$(jq -r '.model // "MISSING"' "$STATE_FILE" 2>/dev/null || echo "NO_STATE")
EFFORT_VAL=$(jq -r '.effort // "MISSING"' "$STATE_FILE" 2>/dev/null || echo "NO_STATE")
if [[ "$MODEL_VAL" == "opus" ]] && [[ "$EFFORT_VAL" == "high" ]]; then
  pass "Overrides: --model opus --effort high persisted"
else
  fail "Overrides: --model opus --effort high persisted" \
    "model=opus effort=high" "model=$MODEL_VAL effort=$EFFORT_VAL"
fi

# Test 11c: invalid --effort value is rejected loudly, no state written
SETUP_OUT=$( (cd "$SETUP_DIR" && env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
  --checklist checklist.md --name badtest --effort turbo 2>&1) )
SETUP_RC=$?
if [[ $SETUP_RC -ne 0 ]] && grep -q "effort" <<< "$SETUP_OUT" \
   && [[ ! -f "$SETUP_DIR/.claude/ralph-fork/badtest/state.json" ]]; then
  pass "Invalid --effort rejected (nonzero exit, loud error, no state)"
else
  fail "Invalid --effort rejected (nonzero exit, loud error, no state)" \
    "rc!=0, error mentions effort, no state file" \
    "rc=$SETUP_RC state=$([[ -f "$SETUP_DIR/.claude/ralph-fork/badtest/state.json" ]] && echo present || echo absent)"
fi

echo ""

# ============================================================================
# Summary
# ============================================================================
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
