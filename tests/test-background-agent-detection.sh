#!/bin/bash

# Unit tests for background agent detection in the stop hook.
# Verifies that pending background Agent calls block instead of fork.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hooks/stop-hook-fork.sh"
TEST_DIR=$(mktemp -d)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { echo -e "${GREEN}PASS${NC}: $1"; ((TESTS_PASSED++)) || true; ((TESTS_RUN++)) || true; }
fail() { echo -e "${RED}FAIL${NC}: $1"; ((TESTS_FAILED++)) || true; ((TESTS_RUN++)) || true; }
section() { echo -e "\n${YELLOW}$1${NC}"; }

# Hex token that satisfies extract_loop_from_transcript's [a-fA-F0-9]* pattern
TEST_TOKEN="abc123deadbeef00"

# Create minimal state.json
make_state() {
  local loop_id="$1"
  local awaiting_bg="${2:-false}"
  local bg_count="${3:-0}"
  mkdir -p "$TEST_DIR/.claude/ralph-fork/$loop_id"
  cat > "$TEST_DIR/.claude/ralph-fork/$loop_id/state.json" <<EOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 0,
  "session_number": 1,
  "session_token": "$TEST_TOKEN",
  "completion_promise": "DONE",
  "prompt": "test",
  "checklist_file": "",
  "on_completion_command": null,
  "stop_hook_reminders": null,
  "preserve_final_session": false,
  "no_cleanup": false,
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": false,
  "awaiting_background_agents": $awaiting_bg,
  "bg_agent_block_count": $bg_count,
  "spawned_sessions": []
}
EOF
}

# Create minimal local.md
make_local() {
  local loop_id="$1"
  cat > "$TEST_DIR/.claude/ralph-fork/$loop_id/local.md" <<EOF
---
loop_id: $loop_id
active: true
session_number: 1
session_token: $TEST_TOKEN
iteration: 1
max_per_session: 1
completion_promise: "DONE"
---
Test prompt
EOF
}

# Build a transcript with RALPH LOOP CONTEXT + optional bg agents/notifications
make_transcript() {
  local file="$1"
  local loop_id="$2"
  local bg_agents="${3:-0}"   # number of background agents to include
  local resolved="${4:-0}"    # number that are resolved (have task-notification)
  local last_text="${5:-No promise here}"

  > "$file"

  # Build bg agent IDs array (IFS-safe, no associative arrays needed)
  local content_items='{"type":"text","text":"RALPH LOOP CONTEXT (Loop: '"$loop_id"', Session 1, Token: '"$TEST_TOKEN"'): working"}'
  local agent_ids_list=""
  for ((i=1; i<=bg_agents; i++)); do
    local id="toolu_bg$(printf '%03d' $i)"
    agent_ids_list="${agent_ids_list}${id}"$'\n'
    content_items+=',{"type":"tool_use","id":"'"$id"'","name":"Agent","input":{"description":"research","run_in_background":true}}'
  done

  echo '{"message":{"role":"assistant","content":['"$content_items"']}}' >> "$file"

  # Immediate tool_results (launched confirmations)
  if [[ -n "$agent_ids_list" ]]; then
    while IFS= read -r id; do
      [[ -z "$id" ]] && continue
      echo '{"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"'"$id"'","content":[{"type":"text","text":"Async agent launched successfully.\nagentId: fake123"}]}]}}' >> "$file"
    done <<< "$agent_ids_list"
  fi

  # Task-notification completions for resolved ones
  local i=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    i=$((i+1))
    [[ $i -gt $resolved ]] && break
    echo '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>fake123</task-id>\n<tool-use-id>'"$id"'</tool-use-id>\n<status>completed</status>\n<summary>done</summary>"}' >> "$file"
  done <<< "$agent_ids_list"

  # Final assistant text
  echo '{"message":{"role":"assistant","content":[{"type":"text","text":"'"$last_text"'"}]}}' >> "$file"
}

run_hook() {
  local loop_id="$1"
  local transcript="$2"
  local stop_hook_active="${3:-false}"
  # Optional: JSON array literal for the native background_tasks field (e.g.
  # '[]' or '[{"id":"x","type":"subagent","status":"running"}]'). Omit/empty
  # to build hook input WITHOUT the key at all (exercises the legacy fallback
  # per D2.3 — this is what tests 1-7 below do, unmodified).
  local background_tasks_json="${4:-}"

  local hook_input
  if [[ -n "$background_tasks_json" ]]; then
    hook_input=$(jq -n \
      --arg tp "$transcript" \
      --argjson sha "$stop_hook_active" \
      --argjson bt "$background_tasks_json" \
      '{"transcript_path": $tp, "stop_hook_active": $sha, "background_tasks": $bt}')
  else
    hook_input=$(jq -n \
      --arg tp "$transcript" \
      --argjson sha "$stop_hook_active" \
      '{"transcript_path": $tp, "stop_hook_active": $sha}')
  fi

  # cd to TEST_DIR so find_project_root() can locate .claude/ralph-fork/<loop_id>
  (cd "$TEST_DIR" && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" bash "$HOOK_SCRIPT" <<< "$hook_input" 2>/dev/null)
}

# ─────────────────────────────────────────────────────────────────────────────
section "Test 1: No background agents → normal flow (no block)"
LOOP="test-bg-1"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t1.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 0 0 "No promise here"

OUTPUT=$(run_hook "$LOOP" "$T" false)
if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  # Should only block for checklist update (normal flow), NOT for bg agents
  REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
  if echo "$REASON" | grep -qi "background"; then
    fail "Unexpectedly blocked for background agents when none present"
  else
    pass "No bg-agent block issued (normal checklist/fork flow)"
  fi
else
  pass "No block issued for no-bg-agent case"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 2: 2 pending background agents → defer silently (no block, empty output)"
LOOP="test-bg-2"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t2.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 2 0 "I launched the agents"

OUTPUT=$(run_hook "$LOOP" "$T" false)
if [[ -z "$OUTPUT" ]]; then
  pass "Correctly defers (silent, no output) for 2 pending background agents"
else
  fail "Expected silent defer for pending background agents, got: $OUTPUT"
fi

# Verify state was updated
STATE=$(cat "$TEST_DIR/.claude/ralph-fork/$LOOP/state.json")
if echo "$STATE" | jq -e '.awaiting_background_agents == true' >/dev/null 2>&1; then
  pass "awaiting_background_agents set to true in state"
else
  fail "awaiting_background_agents not set in state"
fi
if echo "$STATE" | jq -e '.bg_agent_block_count == 1' >/dev/null 2>&1; then
  pass "bg_agent_block_count set to 1"
else
  fail "bg_agent_block_count not 1: $(echo "$STATE" | jq '.bg_agent_block_count')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 3: 2 launched, 1 resolved → still defers (1 pending)"
LOOP="test-bg-3"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t3.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 2 1 "One agent done"

OUTPUT=$(run_hook "$LOOP" "$T" false)
if [[ -z "$OUTPUT" ]]; then
  pass "Correctly defers when 1 of 2 agents still pending"
else
  fail "Expected silent defer for 1 pending agent, got: $OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 4: All agents resolved → normal flow (no bg-agent block)"
LOOP="test-bg-4"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t4.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 2 2 "All agents done, no promise"

OUTPUT=$(run_hook "$LOOP" "$T" false)
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null || echo "")
if echo "$REASON" | grep -qi "background"; then
  fail "Should not block for background agents when all resolved: $REASON"
else
  pass "No bg-agent block when all agents resolved"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 5: Continuation cycle with awaiting_background_agents=true, still pending → re-defer"
LOOP="test-bg-5"
make_state "$LOOP" true 1
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t5.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 2 0 "Still waiting for agents"

OUTPUT=$(run_hook "$LOOP" "$T" true)
if [[ -z "$OUTPUT" ]]; then
  pass "Correctly re-defers in continuation cycle for still-pending agents"
else
  fail "Expected silent re-defer in continuation cycle, got: $OUTPUT"
fi

STATE=$(cat "$TEST_DIR/.claude/ralph-fork/$LOOP/state.json")
if echo "$STATE" | jq -e '.bg_agent_block_count == 2' >/dev/null 2>&1; then
  pass "bg_agent_block_count incremented to 2"
else
  fail "bg_agent_block_count not incremented: $(echo "$STATE" | jq '.bg_agent_block_count')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 6: Continuation cycle with awaiting_background_agents=true, all resolved → resumes"
LOOP="test-bg-6"
make_state "$LOOP" true 1
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t6.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 2 2 "All done now"

OUTPUT=$(run_hook "$LOOP" "$T" true)
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null || echo "")
if echo "$REASON" | grep -qi "background.*still\|background.*pending"; then
  fail "Should not re-block for resolved agents in continuation cycle: $REASON"
else
  pass "No bg-agent re-block when agents resolved in continuation cycle"
fi

STATE=$(cat "$TEST_DIR/.claude/ralph-fork/$LOOP/state.json")
if echo "$STATE" | jq -e '.awaiting_background_agents == false' >/dev/null 2>&1; then
  pass "awaiting_background_agents cleared after resolution"
else
  fail "awaiting_background_agents not cleared: $(echo "$STATE" | jq '.awaiting_background_agents')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 7: High wait count (e.g. 10) with agents still pending → still re-defers (no cap)"
LOOP="test-bg-7"
make_state "$LOOP" true 10
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t7.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 4 0 "Still waiting, no cap"

OUTPUT=$(run_hook "$LOOP" "$T" true)
if [[ -z "$OUTPUT" ]]; then
  pass "Correctly re-defers even at high wait count (no cap) — waits for all agents"
else
  fail "Expected continued silent re-defer at high wait count, got: $OUTPUT"
fi

STATE=$(cat "$TEST_DIR/.claude/ralph-fork/$LOOP/state.json")
if echo "$STATE" | jq -e '.bg_agent_block_count == 11' >/dev/null 2>&1; then
  pass "bg_agent_block_count incremented to 11 (unbounded counter)"
else
  fail "bg_agent_block_count not incremented correctly: $(echo "$STATE" | jq '.bg_agent_block_count')"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 8 (AC1): native background_tasks non-empty (modern CC) → defer"
LOOP="test-bg-8"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t8.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 0 0 "No promise here"

OUTPUT=$(run_hook "$LOOP" "$T" false '[{"id":"a1","type":"subagent","status":"running","description":"x","agent_type":"general-purpose"}]')
if [[ -z "$OUTPUT" ]]; then
  pass "Native background_tasks presence correctly defers (AC1)"
else
  fail "Expected silent defer for non-empty background_tasks, got: $OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 9 (AC1): native background_tasks empty array (modern CC) → no bg block"
LOOP="test-bg-9"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t9.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 0 0 "No promise here"

OUTPUT=$(run_hook "$LOOP" "$T" false '[]')
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null || echo "")
if echo "$REASON" | grep -qi "background"; then
  fail "Should not block for background agents when background_tasks is empty: $REASON"
else
  pass "No bg-agent block when native background_tasks is empty"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 10 (AC2, finish-vs-integrate race): background_tasks empty (agent just finished) BUT a"
section "  task-notification is enqueued AFTER the last assistant message → still defer"
LOOP="test-bg-10"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t10.XXXXXX.jsonl")

# Build a transcript by hand: assistant message announcing the launch, THEN a
# task-notification enqueue with nothing after it (not yet integrated) — the
# exact race the bug report calls out. background_tasks is passed as empty
# (the harness's own view: the agent already finished) to prove D2.2 alone
# catches what native presence misses.
{
  echo '{"message":{"role":"assistant","content":[{"type":"text","text":"RALPH LOOP CONTEXT (Loop: '"$LOOP"', Session 1, Token: '"$TEST_TOKEN"'): waiting for the agent"}]}}'
  echo '{"type":"queue-operation","operation":"enqueue","content":"<task-notification>\n<task-id>fake123</task-id>\n<tool-use-id>toolu_bg001</tool-use-id>\n<status>completed</status>\n<summary>done</summary>"}'
} > "$T"

OUTPUT=$(run_hook "$LOOP" "$T" false '[]')
if [[ -z "$OUTPUT" ]]; then
  pass "D2.2 correctly defers on undelivered notification even though background_tasks is empty (AC2)"
else
  fail "Expected silent defer for undelivered notification, got: $OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 11 (AC3): background_tasks key entirely absent (legacy CC) → legacy fallback"
section "  still catches a modern background-agent launch"
LOOP="test-bg-11"
make_state "$LOOP"
make_local "$LOOP"
T=$(mktemp "$TEST_DIR/t11.XXXXXX.jsonl")
make_transcript "$T" "$LOOP" 1 0 "Still launching"

OUTPUT=$(run_hook "$LOOP" "$T" false)
if [[ -z "$OUTPUT" ]]; then
  pass "Legacy fallback (no background_tasks key) still catches pending agent, defers (AC3)"
else
  fail "Expected silent defer from legacy fallback, got: $OUTPUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Test 12 (D3 regression): BG-pending gate must run BEFORE the AEOS doom-loop block"
BG_LINE=$(grep -n '^BG_PENDING=\$(compute_pending_background_work' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
DOOM_LINE=$(grep -n '^# AEOS DOOM-LOOP + REVISION-BUDGET CHECK' "$HOOK_SCRIPT" | head -1 | cut -d: -f1)
if [[ -n "$BG_LINE" ]] && [[ -n "$DOOM_LINE" ]] && [[ "$BG_LINE" -lt "$DOOM_LINE" ]]; then
  pass "BG-pending gate (line $BG_LINE) precedes AEOS doom-loop block (line $DOOM_LINE)"
else
  fail "Expected BG-pending gate before doom-loop block, got BG=$BG_LINE DOOM=$DOOM_LINE"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
echo "Test Results"
echo "=============================================="
echo "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Tests failed: ${RED}${TESTS_FAILED}${NC}"
echo ""
if [[ $TESTS_FAILED -eq 0 ]]; then
  echo -e "${GREEN}ALL TESTS PASSED${NC}"
  exit 0
else
  echo -e "${RED}SOME TESTS FAILED${NC}"
  exit 1
fi
