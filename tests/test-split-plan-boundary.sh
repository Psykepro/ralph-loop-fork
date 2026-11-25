#!/bin/bash
# Split-plan session boundary: a MASTER-CHECKLIST.md that tracks sub-checklists
# as status-table rows ("| 1 | sub-01-x.md | 🟢 completed | ...") runs ONE
# sub-checklist per session. When a sub's row turns 🟢 during a session the
# stop hook forks a fresh session for the next one; it never accepts the
# completion promise while any row is not 🟢; and no prompt tells the agent to
# keep going into the next sub in the same session. Flat checklists keep their
# behavior (regression cases at the end).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/hooks/stop-hook-fork.sh"
# The hook prefers CLAUDE_PLUGIN_ROOT for the fork script; pin it so this
# suite exercises this checkout, never a live install.
export CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR"

TEST_DIR=$(mktemp -d -t split-boundary-XXXX)
STUB_BIN=$(mktemp -d -t split-boundary-stubs-XXXX)
HERDR_LOG="$TEST_DIR/herdr-calls.log"
cat > "$STUB_BIN/herdr" <<STUBH
#!/bin/sh
echo "\$*" >> "$HERDR_LOG"
case "\$1 \$2" in
  "status "*) echo "status: running" ;;
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"wH:p1","workspace_id":"wH"},"workspace":{"workspace_id":"wH","label":"stub"}}}' ;;
  "tab create") echo '{"result":{"root_pane":{"pane_id":"wH:p1","tab_id":"wH:t1","workspace_id":"wH"},"tab":{"tab_id":"wH:t1","workspace_id":"wH","label":"stub"}}}' ;;
esac
exit 0
STUBH
chmod +x "$STUB_BIN/herdr"
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID
export PATH="$STUB_BIN:$PATH"
trap 'rm -rf "$TEST_DIR" "$STUB_BIN"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "FAIL: $1"; [[ -n "${2:-}" ]] && echo "  $2"; }
check() { if eval "$1"; then ok "$2"; else bad "$2" "condition: $1"; fi; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
loop_dir() { echo "$TEST_DIR/.claude/ralph-fork/$1"; }

# write_master <plan_dir> <row1-status> <row2-status> [extra trailing text]
write_master() {
  local plan="$1" s1="$2" s2="$3" extra="${4:-}"
  mkdir -p "$plan"
  cat > "$plan/MASTER-CHECKLIST.md" <<EOF
# Master Checklist: example feature

## Sub-checklists

| # | File | Status | Session | Tokens |
|---|------|--------|---------|--------|
| 1 | sub-01-alpha.md | $s1 | — | ~10k |
| 2 | sub-02-beta.md | $s2 | — | ~12k |
$extra
EOF
  cat > "$plan/sub-01-alpha.md" <<'EOF'
# Sub 01
- [x] step one
- [x] step two
EOF
  cat > "$plan/sub-02-beta.md" <<'EOF'
# Sub 02
- [ ] step one
- [ ] step two
EOF
}

write_flat() {
  local plan="$1" unchecked="$2"
  mkdir -p "$plan"
  { echo "# Flat checklist"; echo "- [x] done item"
    [[ "$unchecked" -gt 0 ]] && echo "- [ ] open item"; } > "$plan/CHECKLIST.md"
  return 0
}

# setup_loop <loop_id> <checklist_rel> <baseline|none> [max_per_session] [flags_json]
setup_loop() {
  local id="$1" checklist="$2" baseline="$3" max="${4:-1}" flags="${5:-}"
  [[ -z "$flags" ]] && flags='{}'
  local d; d=$(loop_dir "$id")
  mkdir -p "$d" "$TEST_DIR/transcripts"
  local base_json='{}'
  [[ "$baseline" != "none" ]] && base_json="{\"split_done_at_session_start\": $baseline}"
  jq -n --arg id "$id" --arg cl "$checklist" --argjson max "$max" \
     --argjson base "$base_json" --argjson flags "$flags" '{
    loop_id: $id, active: true, total_budget: 100, max_per_session: $max,
    total_iterations: 0, session_number: 1, session_token: "abc123",
    completion_promise: "ALL_DONE", prompt: "Test prompt", command: "/implement",
    checklist_file: $cl, on_completion_command: null,
    awaiting_checklist_update: false, awaiting_confirmation: false,
    executing_on_completion: false, awaiting_background_agents: false,
    bg_agent_block_count: 0, spawned_sessions: [], model: "sonnet", effort: "medium"
  } + $base + $flags' > "$d/state.json"
  cat > "$d/local.md" <<EOF
---
loop_id: $id
active: true
session_number: 1
session_token: abc123
iteration: 1
max_per_session: $max
completion_promise: "ALL_DONE"
started_at: "2026-01-22T12:00:00Z"
---

Test prompt
EOF
}

# run_stop <loop_id> <assistant_text> [stop_hook_active]
run_stop() {
  local id="$1" text="$2" active="${3:-false}"
  local t="$TEST_DIR/transcripts/$id.jsonl"
  jq -nc --arg id "$id" '{type:"user",message:{role:"user",content:("RALPH LOOP CONTEXT (Loop: " + $id + ", Session 1, Token: abc123): Test")}}' > "$t"
  jq -nc --arg txt "$text" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$txt}]}}' >> "$t"
  : > "$HERDR_LOG"
  (cd "$TEST_DIR" && jq -n --arg t "$t" --argjson a "$active" '{stop_hook_active:$a, transcript_path:$t}' \
     | bash "$HOOK_SCRIPT" 2>&1) || true
}

state() { jq -r "$2" "$(loop_dir "$1")/state.json" 2>/dev/null; }
forked() { grep -q '^agent start' "$HERDR_LOG" 2>/dev/null; }

assert_forked_to_session_2() {
  local id="$1" out="$2" label="$3"
  check 'forked' "$label: a new session was spawned (herdr agent start)"
  check '[[ "$(state "$id" .session_number)" == "2" ]]' "$label: session_number advanced to 2"
  check '[[ -f "$(loop_dir "$id")/local.md" ]]' "$label: new session local.md written"
  check '! grep -q "\"decision\": \"block\"" <<<"$out"' "$label: no block issued (no same-session re-feed)"
  check '[[ "$(state "$id" .active)" == "true" ]]' "$label: loop still active (not completed)"
  check '[[ "$(state "$id" ".termination_reason // \"none\"")" == "none" ]]' "$label: no termination_reason"
  local p; p=$(cat "$(loop_dir "$id")/prompt.txt" 2>/dev/null)
  check 'grep -q "sub-02-beta.md" <<<"$p"' "$label: forked prompt names the next sub (sub-02-beta.md)"
  check '! grep -q "until complete" <<<"$p"' "$label: forked prompt has no 'until complete' wording"
}

# ---------------------------------------------------------------------------
echo "== S1: sub-01 turned 🟢 this session, no promise → fork =="
write_master "$TEST_DIR/p1" "🟢 completed" "🔴 pending"
setup_loop s1 "p1/MASTER-CHECKLIST.md" 0
out=$(run_stop s1 "Finished sub-01, committed, row marked completed.")
assert_forked_to_session_2 s1 "$out" "S1"

echo "== S2: sub-01 turned 🟢 and the promise is output → fork, never complete =="
write_master "$TEST_DIR/p2" "🟢 completed" "🔴 pending"
setup_loop s2 "p2/MASTER-CHECKLIST.md" 0
out=$(run_stop s2 "Done. <promise>ALL_DONE</promise>")
assert_forked_to_session_2 s2 "$out" "S2"
check '! grep -q "CONFIRMATION REQUIRED" <<<"$out"' "S2: no confirmation prompt"
check '[[ "$(state s2 .awaiting_confirmation)" != "true" ]]' "S2: not awaiting confirmation"

echo "== S3: no sub finished this session, iteration limit → split-aware update prompt =="
write_master "$TEST_DIR/p3" "🟢 completed" "🟡 in progress"
setup_loop s3 "p3/MASTER-CHECKLIST.md" 1
out=$(run_stop s3 "Worked on sub-02, not finished yet.")
check 'grep -q "\"decision\": \"block\"" <<<"$out"' "S3: hook blocks for the checklist update"
check 'grep -q "sub-02-beta.md" <<<"$out"' "S3: prompt names the current sub (sub-02-beta.md)"
check '! grep -q "ALL items" <<<"$out"' "S3: no 'ALL items' wording"
check '! grep -q "EVERY SINGLE" <<<"$out"' "S3: no 'EVERY SINGLE' wording"
check 'grep -q "1 unchecked" <<<"$out"' "S3: status counts the open sub row as unchecked"

echo "== S4: promise while a row is not 🟢 (no sub finished) → rejected, split-aware =="
write_master "$TEST_DIR/p4" "🟢 completed" "🔴 pending"
setup_loop s4 "p4/MASTER-CHECKLIST.md" 1
out=$(run_stop s4 "<promise>ALL_DONE</promise>")
check 'grep -q "COMPLETION REJECTED" <<<"$out"' "S4: completion rejected"
check '[[ "$(state s4 .awaiting_confirmation)" != "true" ]]' "S4: not awaiting confirmation"
check 'grep -q "sub-02-beta.md" <<<"$out"' "S4: reject prompt names the current sub"
check '! grep -q "EVERY SINGLE" <<<"$out"' "S4: no 'EVERY SINGLE' wording"

echo "== S5: every row 🟢 + promise → confirmation flow (completion reachable) =="
write_master "$TEST_DIR/p5" "🟢 completed" "🟢 completed" "
## Handoff log

| Session | File | Note |
|---|---|---|
| 2 | sub-02-beta.md | in progress at start, finished later |"
setup_loop s5 "p5/MASTER-CHECKLIST.md" 1
out=$(run_stop s5 "<promise>ALL_DONE</promise>")
check 'grep -q "CONFIRMATION REQUIRED" <<<"$out"' "S5: confirmation requested"
check '! forked' "S5: no fork"
check '[[ "$(state s5 .awaiting_confirmation)" == "true" ]]' "S5: awaiting confirmation"

echo "== S6: sub finished during a continuation turn → fork via normal flow =="
write_master "$TEST_DIR/p6" "🟢 completed" "🔴 pending"
setup_loop s6 "p6/MASTER-CHECKLIST.md" 0
out=$(run_stop s6 "Finished sub-01." true)
assert_forked_to_session_2 s6 "$out" "S6"

echo "== S7: missing baseline → loud fallback, baseline recorded =="
write_master "$TEST_DIR/p7" "🟢 completed" "🔴 pending"
setup_loop s7 "p7/MASTER-CHECKLIST.md" none
out=$(run_stop s7 "Working.")
check 'grep -qi "baseline" <<<"$out"' "S7: fallback is announced"
check '[[ "$(state s7 .split_done_at_session_start)" == "1" ]]' "S7: baseline written back to state"

echo "== S8: a fork records the next session's baseline =="
check '[[ "$(state s1 .split_done_at_session_start)" == "1" ]]' "S8: baseline after fork = completed rows (1)"

echo "== S9: setup scopes session 1 to the first open sub and records its baseline =="
write_master "$TEST_DIR/proj9/plan" "🟢 completed" "🔴 pending"
FAKE_HOME="$TEST_DIR/home9"; mkdir -p "$FAKE_HOME"
(cd "$TEST_DIR/proj9" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR bash "$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh" \
   --checklist plan/MASTER-CHECKLIST.md --name s9loop >/dev/null 2>&1) || true
s9_state="$TEST_DIR/proj9/.claude/ralph-fork/s9loop/state.json"
check '[[ "$(jq -r .split_done_at_session_start "$s9_state" 2>/dev/null)" == "1" ]]' "S9: setup records baseline 1"
check 'grep -q "ONLY on sub-02-beta.md" "$TEST_DIR/proj9/.claude/ralph-fork/s9loop/local.md"' "S9: session-1 prompt names sub-02-beta.md"
check '! grep -q "until complete" "$TEST_DIR/proj9/.claude/ralph-fork/s9loop/local.md"' "S9: session-1 prompt has no 'until complete'"

echo "== S10: worktree mode, empty transcript, sub finished → fork, no status prompt =="
P10="$TEST_DIR/proj10"
write_master "$P10/plan" "🟢 completed" "🔴 pending"
mkdir -p "$P10/.claude/ralph-fork/s10"
jq -n --arg wt "$P10" '{loop_id:"s10", active:true, total_budget:100, max_per_session:1,
  total_iterations:0, session_number:1, session_id:"abc123", completion_promise:"ALL_DONE",
  command:"/implement", checklist_file:"plan/MASTER-CHECKLIST.md", on_completion_command:null,
  worktree_path:$wt, split_done_at_session_start:0, spawned_sessions:[], model:"sonnet", effort:"medium"}' \
  > "$P10/.claude/ralph-fork/s10/state.json"
printf -- '---\nloop_id: s10\nactive: true\nsession_number: 1\nsession_id: abc123\niteration: 1\nmax_per_session: 1\ncompletion_promise: "ALL_DONE"\n---\n\nTest\n' \
  > "$P10/.claude/ralph-fork/s10/local.md"
: > "$P10/empty.jsonl"
: > "$HERDR_LOG"
out=$(cd "$P10" && jq -n --arg t "$P10/empty.jsonl" '{stop_hook_active:false, transcript_path:$t}' \
  | RALPH_LOOP_ACTIVE=1 bash "$HOOK_SCRIPT" 2>&1) || true
check 'forked' "S10: forked"
check '! grep -q "STATUS DECLARATION" <<<"$out"' "S10: no status-declaration block that would name the next sub"
check '[[ "$(jq -r .session_number "$P10/.claude/ralph-fork/s10/state.json")" == "2" ]]' "S10: session_number 2"

# --- flat checklist regression --------------------------------------------
echo "== F1: flat, unchecked item, iteration limit → update prompt without contradiction =="
write_flat "$TEST_DIR/f1" 1
setup_loop f1 "f1/CHECKLIST.md" none
out=$(run_stop f1 "Did some work.")
check 'grep -q "SESSION ENDING" <<<"$out"' "F1: update prompt issued"
check 'grep -q "1 checked, 1 unchecked" <<<"$out"' "F1: counts unchanged"
check '! grep -q "EVERY SINGLE ONE" <<<"$out"' "F1: no 'work through ALL items' instruction next to 'you may exit'"
check '! grep -qi "baseline" <<<"$out"' "F1: no split baseline noise for flat checklists"
check '[[ "$(state f1 ".split_done_at_session_start // \"absent\"")" == "absent" ]]' "F1: no baseline stored for flat checklists"

echo "== F2: flat, promise with unchecked item → rejected =="
write_flat "$TEST_DIR/f2" 1
setup_loop f2 "f2/CHECKLIST.md" none
out=$(run_stop f2 "<promise>ALL_DONE</promise>")
check 'grep -q "COMPLETION REJECTED" <<<"$out"' "F2: rejected"

echo "== F3: flat, all checked + promise → confirmation =="
write_flat "$TEST_DIR/f3" 0
setup_loop f3 "f3/CHECKLIST.md" none
out=$(run_stop f3 "<promise>ALL_DONE</promise>")
check 'grep -q "CONFIRMATION REQUIRED" <<<"$out"' "F3: confirmation requested"

echo "== F4: flat fork prompt keeps the flat wording =="
write_flat "$TEST_DIR/f4" 1
setup_loop f4 "f4/CHECKLIST.md" none 1 '{"awaiting_checklist_update": true}'
out=$(run_stop f4 "Updated." true)
check 'forked' "F4: forked"
check '! grep -q "SPLIT PLAN" "$(loop_dir f4)/prompt.txt"' "F4: flat prompt has no split-plan block"
check 'grep -q "until complete" "$(loop_dir f4)/prompt.txt"' "F4: flat prompt keeps 'work through the checklist until complete'"
check '[[ "$(state f4 ".split_done_at_session_start // \"absent\"")" == "absent" ]]' "F4: fork stores no baseline for flat checklists"

echo "== R1: max_per_session=2 — the stop after a same-session re-feed is not dropped =="
write_flat "$TEST_DIR/r1" 1
setup_loop r1 "r1/CHECKLIST.md" none 2
out=$(run_stop r1 "Partial work.")
check 'grep -q "CONTINUE WORKING" <<<"$out"' "R1: first stop re-feeds the same session"
out=$(run_stop r1 "More partial work." true)
check 'grep -q "SESSION ENDING" <<<"$out"' "R1: stop after the re-feed reaches the iteration limit (update prompt), not a silent exit"
out=$(run_stop r1 "Updated the checklist." true)
check 'forked' "R1: the checklist update then forks the next session"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[[ $FAIL -eq 0 ]]
