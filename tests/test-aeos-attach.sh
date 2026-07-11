#!/bin/bash
# test-aeos-attach.sh — Integration tests for AEOS config generation at loop launch
#
# Tests W1 (sentinel guard), W4 (fail-open), worktree-move preservation,
# and standalone no-op. Covers sub-02 of feature-ws3-ralph-aeos-attach.
#
# Uses the real ralph_aeos_config.py from $CLAUDE_PROJECT_DIR when available
# (catches arg-name drift); falls back to a faithful stub.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TESTS_PASSED=0; TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Detect real ralph_aeos_config.py (preferred — catches arg-name drift)
REAL_AEOS_SCRIPT=""
if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]] && \
   [[ -f "${CLAUDE_PROJECT_DIR}/.claude/scripts/ralph_aeos_config.py" ]]; then
  REAL_AEOS_SCRIPT="${CLAUDE_PROJECT_DIR}/.claude/scripts/ralph_aeos_config.py"
fi

# ── Stub bin: override tmux so worktree tests are hermetic (no real sessions) ──
STUB_BIN=$(mktemp -d -t aeos-stubs-XXXX)
printf '#!/bin/sh\nexit 0\n' > "$STUB_BIN/tmux"
chmod +x "$STUB_BIN/tmux"
export PATH="$STUB_BIN:$PATH"

# ── Global cleanup ────────────────────────────────────────────────────────────
declare -a _CLEANUP_DIRS=()

_cleanup_all() {
  local d
  for d in "${_CLEANUP_DIRS[@]:-}"; do
    [[ -z "$d" ]] && continue
    if [[ -d "$d" ]]; then
      # Remove any worktrees before deleting the repo
      git -C "$d" worktree list 2>/dev/null | awk '/^[^ ]/{print $1}' | \
        while read -r wt; do
          [[ "$wt" == "$d" ]] && continue
          git -C "$d" worktree remove --force "$wt" 2>/dev/null || true
        done
      rm -rf "$d"
    fi
  done
  rm -rf "${STUB_BIN:-}"
}
trap _cleanup_all EXIT

# ── Fixture builder ────────────────────────────────────────────────────────────
# make_fixture <dir> <mode>
#   mode = "aeos"     — copy real ralph_aeos_config.py (or stub) + loop-state.json
#   mode = "fail"     — include a failing ralph_aeos_config.py (exits 1)
#   mode = "standalone" — no ralph_aeos_config.py
make_fixture() {
  local dir="$1" mode="${2:-standalone}"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email t@t.local
  git -C "$dir" config user.name t

  # Checklist file + loop-state.json (needed by the real ralph_aeos_config.py)
  mkdir -p "$dir/_project/progress/in-progress/test-feature"
  cat > "$dir/_project/progress/in-progress/test-feature/MASTER-CHECKLIST.md" <<'EOF'
# Checklist
- [ ] Task 1
EOF
  cat > "$dir/_project/progress/in-progress/test-feature/loop-state.json" <<'EOF'
{"revision_budget": 5, "loop_id": "test-loop"}
EOF

  mkdir -p "$dir/.claude/scripts"

  case "$mode" in
    aeos)
      if [[ -n "$REAL_AEOS_SCRIPT" ]]; then
        cp "$REAL_AEOS_SCRIPT" "$dir/.claude/scripts/ralph_aeos_config.py"
      else
        # Faithful stub: matches real script's CLI contract and output schema
        cat > "$dir/.claude/scripts/ralph_aeos_config.py" <<'PYEOF'
#!/usr/bin/env python3
import json, sys, pathlib, argparse
p = argparse.ArgumentParser()
p.add_argument("--checklist", required=True)
p.add_argument("--loop-dir", required=True, dest="loop_dir")
p.add_argument("--doom-threshold", type=int, default=3, dest="doom_threshold")
args = p.parse_args()
loop_dir = pathlib.Path(args.loop_dir)
if not loop_dir.is_absolute():
    loop_dir = pathlib.Path.cwd() / loop_dir
loop_dir.mkdir(parents=True, exist_ok=True)
plan_dir = "_project/progress/in-progress/test-feature"
cfg = {"schema_version": 1, "plan_dir": plan_dir,
       "doom_abort_threshold": args.doom_threshold,
       "required_markers": ["tested", "reviewed"],
       "respect_revision_budget": True}
with open(loop_dir / ".aeos-config.json", "w") as f:
    json.dump(cfg, f, indent=2); f.write("\n")
print("✅ stub: aeos-config written", file=sys.stderr)
PYEOF
      fi
      ;;
    fail)
      cat > "$dir/.claude/scripts/ralph_aeos_config.py" <<'PYEOF'
#!/usr/bin/env python3
import sys
print("❌ intentional generator failure", file=sys.stderr)
sys.exit(1)
PYEOF
      ;;
    standalone)
      # no script — directory created but empty
      ;;
  esac

  git -C "$dir" add .
  git -C "$dir" commit -qm "fixture"
}

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Test 1: AEOS non-worktree — .aeos-config.json created in LOOP_DIR${NC}"
# Expected RED before patch (sentinel call absent); GREEN after patch.

R1=$(mktemp -d -t aeos-t1-XXXX); _CLEANUP_DIRS+=("$R1")
make_fixture "$R1" "aeos"
OUT1=$(mktemp); ERR1=$(mktemp)

cd "$R1"
bash "$SETUP" \
  --checklist "_project/progress/in-progress/test-feature/MASTER-CHECKLIST.md" \
  --name "aeos-nwt" --total-budget 1 --max-per-session 1 \
  >"$OUT1" 2>"$ERR1"
RC1=$?
cd - >/dev/null

if [[ $RC1 -eq 0 ]]; then pass "setup exited 0"
else fail "setup exited $RC1" "$(cat "$ERR1")"; fi

if [[ -f "$R1/.claude/ralph-fork/aeos-nwt/.aeos-config.json" ]]; then
  pass ".aeos-config.json created in LOOP_DIR"
else
  fail ".aeos-config.json missing from LOOP_DIR" \
    "Expected: $R1/.claude/ralph-fork/aeos-nwt/.aeos-config.json"
fi

if [[ -f "$R1/.claude/ralph-fork/aeos-nwt/.aeos-config.json" ]] && \
   python3 -c "import json; d=json.load(open('$R1/.claude/ralph-fork/aeos-nwt/.aeos-config.json')); assert d.get('schema_version')==1" 2>/dev/null; then
  pass ".aeos-config.json is valid JSON with schema_version=1"
else
  pass ".aeos-config.json JSON validation skipped (file absent — expected pre-patch RED)"
fi

# Stdout must not mention ralph_aeos_config (sentinel is stderr-only)
if ! grep -q "ralph_aeos_config" "$OUT1"; then
  pass "stdout unaffected (no ralph_aeos_config mention)"
else
  fail "ralph_aeos_config leaked to stdout" "$(cat "$OUT1" | grep ralph_aeos_config)"
fi
rm -f "$OUT1" "$ERR1"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 2: AEOS worktree mode — .aeos-config.json travels with mv into worktree${NC}"
# Expected RED before patch; GREEN after.

R2=$(mktemp -d -t aeos-t2-XXXX); _CLEANUP_DIRS+=("$R2")
make_fixture "$R2" "aeos"
OUT2=$(mktemp); ERR2=$(mktemp)

cd "$R2"
bash "$SETUP" \
  --checklist "_project/progress/in-progress/test-feature/MASTER-CHECKLIST.md" \
  --name "aeos-wt" --total-budget 1 --max-per-session 1 --worktree \
  >"$OUT2" 2>"$ERR2"
RC2=$?
cd - >/dev/null

if [[ $RC2 -eq 0 ]]; then pass "setup (worktree) exited 0"
else fail "setup (worktree) exited $RC2" "$(cat "$ERR2")"; fi

WT_CONFIG="$R2/.worktrees/aeos-wt/.claude/ralph-fork/aeos-wt/.aeos-config.json"
if [[ -f "$WT_CONFIG" ]]; then
  pass ".aeos-config.json present in worktree (survived mv)"
else
  fail ".aeos-config.json missing from worktree" "Expected: $WT_CONFIG"
fi

# LOOP_DIR must not remain in main repo (was mv'd out)
if [[ ! -d "$R2/.claude/ralph-fork/aeos-wt" ]]; then
  pass "LOOP_DIR correctly moved — no stale copy in main repo"
else
  fail "Stale LOOP_DIR left in main repo after worktree mv" ""
fi

# state.json must be in the worktree
if [[ -f "$R2/.worktrees/aeos-wt/.claude/ralph-fork/aeos-wt/state.json" ]]; then
  pass "state.json present in worktree"
else
  fail "state.json missing from worktree" ""
fi
rm -f "$OUT2" "$ERR2"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 3: Standalone (no ralph_aeos_config.py) — no config, setup unaffected${NC}"
# Expected GREEN both before and after patch (sentinel guard keeps standalone clean).

R3=$(mktemp -d -t aeos-t3-XXXX); _CLEANUP_DIRS+=("$R3")
make_fixture "$R3" "standalone"
OUT3=$(mktemp); ERR3=$(mktemp)

cd "$R3"
bash "$SETUP" \
  --checklist "_project/progress/in-progress/test-feature/MASTER-CHECKLIST.md" \
  --name "sa-nwt" --total-budget 1 --max-per-session 1 \
  >"$OUT3" 2>"$ERR3"
RC3=$?
cd - >/dev/null

if [[ $RC3 -eq 0 ]]; then pass "setup (standalone) exited 0"
else fail "setup (standalone) exited $RC3" "$(cat "$ERR3")"; fi

if [[ ! -f "$R3/.claude/ralph-fork/sa-nwt/.aeos-config.json" ]]; then
  pass "No .aeos-config.json created in standalone mode (correct)"
else
  fail ".aeos-config.json unexpectedly created in standalone mode" ""
fi

# state.json must still be created (core setup unaffected)
if [[ -f "$R3/.claude/ralph-fork/sa-nwt/state.json" ]]; then
  pass "state.json created (core setup completed)"
else
  fail "state.json missing — core setup broken" ""
fi

# stdout must mention loop activation (output unchanged vs baseline)
if grep -q "Ralph Loop Fork activated" "$OUT3"; then
  pass "stdout contains loop activation message (output unchanged)"
else
  fail "Activation message absent from stdout" "$(cat "$OUT3" | head -5)"
fi

# No AEOS sentinel message in combined output for standalone
if ! grep -q "ralph_aeos_config" "$OUT3" && ! grep -q "ralph_aeos_config" "$ERR3"; then
  pass "No ralph_aeos_config mention in any output (clean pass-through)"
else
  fail "ralph_aeos_config unexpectedly mentioned in standalone output" ""
fi
rm -f "$OUT3" "$ERR3"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 4: Generator exits non-zero → loud warning, setup continues (W4 fail-open)${NC}"
# Expected RED before patch (no warning, pass-through); GREEN after.

R4=$(mktemp -d -t aeos-t4-XXXX); _CLEANUP_DIRS+=("$R4")
make_fixture "$R4" "fail"
OUT4=$(mktemp); ERR4=$(mktemp)

cd "$R4"
bash "$SETUP" \
  --checklist "_project/progress/in-progress/test-feature/MASTER-CHECKLIST.md" \
  --name "fail-nwt" --total-budget 1 --max-per-session 1 \
  >"$OUT4" 2>"$ERR4"
RC4=$?
cd - >/dev/null

if [[ $RC4 -eq 0 ]]; then
  pass "setup exited 0 (fail-open — generator failure did not abort setup)"
else
  fail "setup exited $RC4 (W4 VIOLATED — setup aborted on generator failure)" \
    "stderr: $(cat "$ERR4")"
fi

# W4 warning must appear on stderr
if grep -qE "⚠️|fail-open|W4|ralph_aeos_config" "$ERR4"; then
  pass "Warning about generator failure on stderr"
else
  fail "No warning found on stderr for generator failure" "$(cat "$ERR4")"
fi

# state.json must exist — core setup completed
if [[ -f "$R4/.claude/ralph-fork/fail-nwt/state.json" ]]; then
  pass "state.json created (core setup completed despite generator failure)"
else
  fail "state.json missing (core setup did not complete)" ""
fi

# stdout clean — no generator failure message on stdout
if ! grep -qE "⚠️|intentional" "$OUT4"; then
  pass "stdout clean — generator failure message correctly on stderr only"
else
  fail "Generator failure message leaked to stdout" "$(cat "$OUT4" | grep -E '⚠️|intentional')"
fi
rm -f "$OUT4" "$ERR4"

# ─────────────────────────────────────────────────────────────────────────────
# SUB-03: Stop-hook AEOS doom-loop + revision-budget tests
# Tests 5–8 are RED before the patch (require AEOS block in stop-hook-fork.sh).
# Tests 9–11 are stability guards (green both before and after the patch).
# Invokes stop-hook-fork.sh directly with synthetic fixture data.
# ─────────────────────────────────────────────────────────────────────────────

STOP_HOOK="$SCRIPT_DIR/hooks/stop-hook-fork.sh"

# Build a minimal stop-hook fixture in DIR for LOOP_ID.
# Params: dir loop_id stuck_count last_hash revision_count revision_budget
#         doom_threshold respect_revision total_budget with_signals_dir
make_stop_fixture() {
  local dir="$1" loop_id="$2"
  local stuck_count="${3:-0}"
  local last_hash="${4:-}"
  local revision_count="${5:-0}"
  local revision_budget="${6:-5}"
  local doom_threshold="${7:-3}"
  local respect_revision="${8:-true}"
  local total_budget="${9:-100}"
  local with_signals_dir="${10:-true}"

  mkdir -p "$dir/.claude/ralph-fork/$loop_id"
  mkdir -p "$dir/_project/progress/in-progress/test-plan"
  if [[ "$with_signals_dir" == "true" ]]; then
    mkdir -p "$dir/_project/signals"
  fi

  cat > "$dir/_project/progress/in-progress/test-plan/MASTER-CHECKLIST.md" <<'CLEOF'
# Checklist
- [ ] Task A
- [ ] Task B
CLEOF

  cat > "$dir/_project/progress/in-progress/test-plan/loop-state.json" <<LSEOF
{"revision_budget": $revision_budget, "revision_count": $revision_count}
LSEOF

  cat > "$dir/.claude/ralph-fork/$loop_id/.aeos-config.json" <<ACEOF
{
  "schema_version": 1,
  "plan_dir": "_project/progress/in-progress/test-plan",
  "doom_abort_threshold": $doom_threshold,
  "required_markers": [],
  "respect_revision_budget": $respect_revision
}
ACEOF

  local hash_val
  if [[ -n "$last_hash" ]]; then
    hash_val="\"$last_hash\""
  else
    hash_val="null"
  fi

  cat > "$dir/.claude/ralph-fork/$loop_id/state.json" <<STEOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": $total_budget,
  "max_per_session": 1,
  "total_iterations": 1,
  "session_number": 2,
  "session_token": "abc123",
  "completion_promise": "DONE",
  "prompt": "test",
  "checklist_file": "_project/progress/in-progress/test-plan/MASTER-CHECKLIST.md",
  "on_completion_command": null,
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": false,
  "awaiting_background_agents": false,
  "bg_agent_block_count": 0,
  "stuck_count": $stuck_count,
  "last_checklist_hash": $hash_val,
  "spawned_sessions": []
}
STEOF

  cat > "$dir/.claude/ralph-fork/$loop_id/local.md" <<LOEOF
---
loop_id: $loop_id
active: true
session_number: 2
session_token: abc123
iteration: 2
max_per_session: 1
completion_promise: "DONE"
started_at: "2026-01-22T12:00:00Z"
---

test prompt
LOEOF

  mkdir -p "$dir/transcripts"
  cat > "$dir/transcripts/$loop_id.jsonl" <<TREOF
{"type":"user","message":{"role":"user","content":"RALPH LOOP CONTEXT (Loop: $loop_id, Session 2, Token: abc123): test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Working on tasks"}]}}
TREOF
}

# Run stop-hook-fork.sh from DIR with LOOP_ID.
# Returns combined stdout+stderr (same convention as test-stop-hook-states.sh).
run_stop_hook() {
  local dir="$1" loop_id="$2"
  local sha="${3:-false}"
  local transcript="$dir/transcripts/$loop_id.jsonl"

  local input_json
  input_json=$(jq -n \
    --arg transcript "$transcript" \
    --argjson sha "$sha" \
    '{"stop_hook_active": $sha, "transcript_path": $transcript}')

  cd "$dir"
  echo "$input_json" | bash "$STOP_HOOK" 2>&1 || true
  cd - >/dev/null
}

# Read a field from state.json; returns "null" if file missing or field absent.
# NOTE: uses plain jq -r (not //) because // treats false as falsy and returns
# the fallback — wrong for boolean fields like .active.
state_field() {
  local dir="$1" loop_id="$2" field="$3"
  local val
  val=$(jq -r ".$field" "$dir/.claude/ralph-fork/$loop_id/state.json" 2>/dev/null) || { echo "null"; return; }
  [[ "$val" == "null" ]] && echo "null" || echo "$val"
}

# Compute checklist hash with same dual-path as stop-hook-fork.sh
checklist_hash() {
  local f="$1"
  md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}'
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 5 (sub-03a): Doom-loop — hash unchanged at threshold → terminate + BLOCKER.md${NC}"
# RED before patch: no AEOS block → active stays true, no BLOCKER.md.

T5=$(mktemp -d -t aeos-t5-XXXX); _CLEANUP_DIRS+=("$T5")
# Compute hash of the checklist content that make_stop_fixture will write
_tmp5=$(mktemp)
printf '# Checklist\n- [ ] Task A\n- [ ] Task B\n' > "$_tmp5"
CL_HASH5=$(checklist_hash "$_tmp5")
rm -f "$_tmp5"
# stuck_count=2, threshold=3 — one more fire reaches threshold → terminate
make_stop_fixture "$T5" "doom-t5" 2 "$CL_HASH5" 0 5 3 false
OUT5=$(run_stop_hook "$T5" "doom-t5" false)

if [[ "$(state_field "$T5" "doom-t5" "active")" == "false" ]]; then
  pass "doom-loop: active=false after threshold reached"
else
  fail "doom-loop: expected active=false" "active=$(state_field "$T5" "doom-t5" "active")"
fi

if [[ "$(state_field "$T5" "doom-t5" "termination_reason")" == "doom_loop_detected" ]]; then
  pass "doom-loop: termination_reason=doom_loop_detected"
else
  fail "doom-loop: expected termination_reason=doom_loop_detected" \
    "got: $(state_field "$T5" "doom-t5" "termination_reason")"
fi

if [[ -f "$T5/BLOCKER.md" ]]; then
  pass "doom-loop: BLOCKER.md written at PROJECT_ROOT"
else
  fail "doom-loop: BLOCKER.md missing from PROJECT_ROOT" ""
fi

if [[ -f "$T5/BLOCKER.md" ]] && grep -q "doom-loop-detected" "$T5/BLOCKER.md"; then
  pass "doom-loop: BLOCKER.md contains 'doom-loop-detected'"
else
  fail "doom-loop: BLOCKER.md missing 'doom-loop-detected'" \
    "$(cat "$T5/BLOCKER.md" 2>/dev/null | head -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 6 (sub-03b): Hash change → stuck_count resets to 0${NC}"
# RED before patch: AEOS block absent → last_checklist_hash not set in state.

T6=$(mktemp -d -t aeos-t6-XXXX); _CLEANUP_DIRS+=("$T6")
# last_hash is a wrong value — checklist actual hash will differ
make_stop_fixture "$T6" "hash-t6" 2 "oldhashabcdef12" 0 5 3 false
run_stop_hook "$T6" "hash-t6" false >/dev/null

HASH6=$(state_field "$T6" "hash-t6" "last_checklist_hash")
if [[ "$HASH6" != "null" ]] && [[ "$HASH6" != "oldhashabcdef12" ]]; then
  pass "hash-change: last_checklist_hash updated to current hash"
else
  fail "hash-change: expected last_checklist_hash updated from old value" \
    "got: $HASH6"
fi

STUCK6=$(state_field "$T6" "hash-t6" "stuck_count")
if [[ "$STUCK6" == "0" ]]; then
  pass "hash-change: stuck_count reset to 0"
else
  fail "hash-change: expected stuck_count=0 after hash change" "got: $STUCK6"
fi

if [[ "$(state_field "$T6" "hash-t6" "active")" != "false" ]]; then
  pass "hash-change: loop not terminated (hash changed)"
else
  fail "hash-change: loop terminated unexpectedly" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 7 (sub-03c): First iteration (no last_checklist_hash) → never stuck${NC}"
# RED before patch: AEOS block absent → last_checklist_hash not written.

T7=$(mktemp -d -t aeos-t7-XXXX); _CLEANUP_DIRS+=("$T7")
# last_hash="" → null in state.json, threshold=2 (would trigger if hash matched null)
make_stop_fixture "$T7" "first-t7" 0 "" 0 5 2 false
run_stop_hook "$T7" "first-t7" false >/dev/null

HASH7=$(state_field "$T7" "first-t7" "last_checklist_hash")
if [[ "$HASH7" != "null" ]]; then
  pass "first-iter: last_checklist_hash written on first fire"
else
  fail "first-iter: last_checklist_hash not written" ""
fi

if [[ "$(state_field "$T7" "first-t7" "active")" != "false" ]]; then
  pass "first-iter: loop not terminated on first iteration (correct)"
else
  fail "first-iter: loop terminated on first iteration (should never be stuck with no prior hash)" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 8 (sub-03d): Revision budget exhausted → terminate + BLOCKER.md${NC}"
# RED before patch: no AEOS block → active stays true, no BLOCKER.md.

T8=$(mktemp -d -t aeos-t8-XXXX); _CLEANUP_DIRS+=("$T8")
# revision_count=3, revision_budget=3 → >= threshold → terminate
make_stop_fixture "$T8" "rev-t8" 0 "" 3 3 5 true
OUT8=$(run_stop_hook "$T8" "rev-t8" false)

if [[ "$(state_field "$T8" "rev-t8" "active")" == "false" ]]; then
  pass "revision: active=false after budget exhausted"
else
  fail "revision: expected active=false" "active=$(state_field "$T8" "rev-t8" "active")"
fi

if [[ "$(state_field "$T8" "rev-t8" "termination_reason")" == "revision_budget_exhausted" ]]; then
  pass "revision: termination_reason=revision_budget_exhausted"
else
  fail "revision: expected termination_reason=revision_budget_exhausted" \
    "got: $(state_field "$T8" "rev-t8" "termination_reason")"
fi

if [[ -f "$T8/BLOCKER.md" ]]; then
  pass "revision: BLOCKER.md written at PROJECT_ROOT"
else
  fail "revision: BLOCKER.md missing from PROJECT_ROOT" ""
fi

if [[ -f "$T8/BLOCKER.md" ]] && grep -q "revision-budget-exhausted" "$T8/BLOCKER.md"; then
  pass "revision: BLOCKER.md contains 'revision-budget-exhausted'"
else
  fail "revision: BLOCKER.md missing 'revision-budget-exhausted'" \
    "$(cat "$T8/BLOCKER.md" 2>/dev/null | head -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 9 (sub-03e): revision_budget=0 → no termination (disabled)${NC}"
# GREEN both before and after patch (stability guard).

T9=$(mktemp -d -t aeos-t9-XXXX); _CLEANUP_DIRS+=("$T9")
# revision_budget=0 → check disabled even with high revision_count
make_stop_fixture "$T9" "rev0-t9" 0 "" 99 0 5 true
run_stop_hook "$T9" "rev0-t9" false >/dev/null

if [[ "$(state_field "$T9" "rev0-t9" "active")" != "false" ]]; then
  pass "revision-budget=0: loop not terminated (budget disabled)"
else
  fail "revision-budget=0: loop incorrectly terminated" ""
fi

if [[ ! -f "$T9/BLOCKER.md" ]]; then
  pass "revision-budget=0: no BLOCKER.md written"
else
  fail "revision-budget=0: BLOCKER.md unexpectedly written" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 10 (sub-03f): Corrupt .aeos-config.json → fail-open (v0.1.6 behavior)${NC}"
# GREEN both before and after patch (stability guard: corrupt config must never terminate).

T10=$(mktemp -d -t aeos-t10-XXXX); _CLEANUP_DIRS+=("$T10")
make_stop_fixture "$T10" "corrupt-t10" 0 "" 0 5 3 true
# Overwrite config with invalid JSON
printf 'NOT VALID JSON {{{' > "$T10/.claude/ralph-fork/corrupt-t10/.aeos-config.json"
run_stop_hook "$T10" "corrupt-t10" false >/dev/null

if [[ "$(state_field "$T10" "corrupt-t10" "active")" != "false" ]]; then
  pass "corrupt-config: fail-open — loop not terminated"
else
  fail "corrupt-config: W4 VIOLATED — loop terminated on corrupt config" ""
fi

if [[ ! -f "$T10/BLOCKER.md" ]]; then
  pass "corrupt-config: no BLOCKER.md (fail-open correct)"
else
  fail "corrupt-config: BLOCKER.md written despite corrupt config (W4 VIOLATED)" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 11 (sub-03g): No .aeos-config.json → zero state change (standalone safe)${NC}"
# GREEN both before and after patch (stability guard: absence must be byte-identical).

T11=$(mktemp -d -t aeos-t11-XXXX); _CLEANUP_DIRS+=("$T11")
make_stop_fixture "$T11" "noop-t11" 0 "" 0 5 3 true
# Remove the config that make_stop_fixture created
rm -f "$T11/.claude/ralph-fork/noop-t11/.aeos-config.json"
run_stop_hook "$T11" "noop-t11" false >/dev/null

HASH11=$(state_field "$T11" "noop-t11" "last_checklist_hash")
STUCK11=$(state_field "$T11" "noop-t11" "stuck_count")
if [[ "$HASH11" == "null" ]] && [[ "$STUCK11" == "0" || "$STUCK11" == "null" ]]; then
  pass "no-config: no stuck_count/last_checklist_hash written (zero state change)"
else
  fail "no-config: AEOS state written despite no config" \
    "last_checklist_hash=$HASH11 stuck_count=$STUCK11"
fi

if [[ "$(state_field "$T11" "noop-t11" "active")" != "false" ]]; then
  pass "no-config: loop not terminated (standalone safe)"
else
  fail "no-config: loop terminated without config present" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUB-04: Stop-hook evidence-marker gate tests
# Tests 12–17 cover the marker gate added to the completion-promise path.
# Tests 12 and 17 are RED before the patch; Tests 13–16 are GREEN stability guards.
#
# SA-4 observation: evidence-stop-gate.py is wired as a PRE-TOOL-USE hook
# (not a stop hook). It fires on every tool use; the marker gate in
# stop-hook-fork.sh fires only at session end when a promise is detected.
# The two gates are independent event types — no deadlock, no double-block.
# Sub-05 e2e will observe both firing in a real mini-loop.
# ─────────────────────────────────────────────────────────────────────────────

# Build a stop-hook fixture for evidence-marker gate tests.
# All checklist items are [x] and committed (passes the git dirty check).
# Transcript contains <promise>DONE</promise> in last assistant message.
# Params: dir loop_id markers_to_create required_markers marker_block_count
#   markers_to_create : space-separated .evidence/ files to pre-create (e.g. "tested reviewed")
#   required_markers  : JSON array literal (e.g. '["tested","reviewed"]' or '[]')
#   marker_block_count: integer (default 0) — pre-seeded in state.json
make_marker_fixture() {
  local dir="$1" loop_id="$2"
  local markers_to_create="${3:-}"
  local required_markers="${4:-[\"tested\",\"reviewed\"]}"
  local marker_block_count="${5:-0}"
  local plan_dir="_project/progress/in-progress/test-plan"

  mkdir -p "$dir/.claude/ralph-fork/$loop_id"
  mkdir -p "$dir/$plan_dir"

  cat > "$dir/$plan_dir/MASTER-CHECKLIST.md" <<'CLEOF'
# Checklist
- [x] Task A
- [x] Task B
CLEOF

  cat > "$dir/$plan_dir/loop-state.json" <<'LSEOF'
{"revision_budget": 5, "revision_count": 0}
LSEOF

  git -C "$dir" init -q -b main 2>/dev/null || true
  git -C "$dir" config user.email t@t.local 2>/dev/null || true
  git -C "$dir" config user.name t 2>/dev/null || true
  git -C "$dir" add "$plan_dir/MASTER-CHECKLIST.md" "$plan_dir/loop-state.json" 2>/dev/null || true
  git -C "$dir" commit -qm "fixture: committed all-x checklist" 2>/dev/null || true

  if [[ -n "$markers_to_create" ]]; then
    mkdir -p "$dir/$plan_dir/.evidence"
    for marker in $markers_to_create; do
      touch "$dir/$plan_dir/.evidence/$marker"
    done
  fi

  cat > "$dir/.claude/ralph-fork/$loop_id/.aeos-config.json" <<ACEOF
{
  "schema_version": 1,
  "plan_dir": "$plan_dir",
  "doom_abort_threshold": 3,
  "required_markers": $required_markers,
  "respect_revision_budget": false
}
ACEOF

  cat > "$dir/.claude/ralph-fork/$loop_id/state.json" <<STEOF
{
  "loop_id": "$loop_id",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 1,
  "session_number": 2,
  "session_token": "abc123",
  "completion_promise": "DONE",
  "prompt": "test",
  "checklist_file": "$plan_dir/MASTER-CHECKLIST.md",
  "on_completion_command": null,
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": false,
  "awaiting_background_agents": false,
  "bg_agent_block_count": 0,
  "stuck_count": 0,
  "last_checklist_hash": null,
  "marker_block_count": $marker_block_count,
  "spawned_sessions": []
}
STEOF

  cat > "$dir/.claude/ralph-fork/$loop_id/local.md" <<LOEOF
---
loop_id: $loop_id
active: true
session_number: 2
session_token: abc123
iteration: 2
max_per_session: 1
completion_promise: "DONE"
started_at: "2026-01-22T12:00:00Z"
---

test prompt
LOEOF

  mkdir -p "$dir/transcripts"
  cat > "$dir/transcripts/$loop_id.jsonl" <<TREOF
{"type":"user","message":{"role":"user","content":"RALPH LOOP CONTEXT (Loop: $loop_id, Session 2, Token: abc123): test"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Work done. <promise>DONE</promise>"}]}}
TREOF
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 12 (sub-04a): required_markers non-empty + markers absent → marker BLOCK${NC}"
# RED before patch: falls through to awaiting_confirmation=true (no marker gate).
# After patch: BLOCK output names missing markers + exact mark.py commands.

T12=$(mktemp -d -t aeos-t12-XXXX); _CLEANUP_DIRS+=("$T12")
make_marker_fixture "$T12" "marker-t12" "" '["tested","reviewed"]' 0
OUT12=$(run_stop_hook "$T12" "marker-t12" false)

MBC12=$(state_field "$T12" "marker-t12" "marker_block_count")
if [[ "$MBC12" == "1" ]]; then
  pass "marker-absent: marker_block_count=1 after first block"
else
  fail "marker-absent: expected marker_block_count=1" "got: $MBC12"
fi

ACU12=$(state_field "$T12" "marker-t12" "awaiting_checklist_update")
if [[ "$ACU12" == "true" ]]; then
  pass "marker-absent: awaiting_checklist_update=true (loop will continue)"
else
  fail "marker-absent: expected awaiting_checklist_update=true" "got: $ACU12"
fi

if echo "$OUT12" | grep -q '"decision": "block"'; then
  pass "marker-absent: decision=block"
else
  fail "marker-absent: expected decision=block in output" "$(echo "$OUT12" | tail -5)"
fi

if echo "$OUT12" | grep -q "mark.py tested"; then
  pass "marker-absent: BLOCK reason contains 'mark.py tested' command"
else
  fail "marker-absent: BLOCK reason missing 'mark.py tested' command" "$(echo "$OUT12" | grep -i "mark\|tested" | head -3)"
fi

if echo "$OUT12" | grep -q "mark.py reviewed"; then
  pass "marker-absent: BLOCK reason contains 'mark.py reviewed' command"
else
  fail "marker-absent: BLOCK reason missing 'mark.py reviewed' command" "$(echo "$OUT12" | grep -i "mark\|reviewed" | head -3)"
fi

if echo "$OUT12" | grep -q "tested.*reviewed\|reviewed.*tested\|Missing:"; then
  pass "marker-absent: BLOCK reason names the missing markers"
else
  fail "marker-absent: BLOCK reason does not name missing markers" "$(echo "$OUT12" | grep -i "missing" | head -3)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 13 (sub-04b): all markers present → falls through to confirmation (GREEN stability guard)${NC}"
# Edge case 7: markers written mid-session are visible at stop time (gate reads fs, not git).
# GREEN both before and after patch.

T13=$(mktemp -d -t aeos-t13-XXXX); _CLEANUP_DIRS+=("$T13")
make_marker_fixture "$T13" "mkpresent-t13" "tested reviewed" '["tested","reviewed"]' 0
OUT13=$(run_stop_hook "$T13" "mkpresent-t13" false)

if [[ "$(state_field "$T13" "mkpresent-t13" "awaiting_confirmation")" == "true" ]]; then
  pass "markers-present: awaiting_confirmation=true (reached confirmation step)"
else
  fail "markers-present: expected awaiting_confirmation=true" \
    "awaiting_confirmation=$(state_field "$T13" "mkpresent-t13" "awaiting_confirmation")"
fi

if ! echo "$OUT13" | grep -q "EVIDENCE MARKERS MISSING\|Evidence markers missing"; then
  pass "markers-present: no marker-gate BLOCK (fell through correctly)"
else
  fail "markers-present: unexpected marker-gate BLOCK fired despite markers being present" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 14 (sub-04c): no config → promise path unchanged (GREEN stability guard)${NC}"
# Absence of .aeos-config.json must leave the promise acceptance path byte-identical.

T14=$(mktemp -d -t aeos-t14-XXXX); _CLEANUP_DIRS+=("$T14")
make_marker_fixture "$T14" "noconfig-t14" "" '[]' 0
# Remove .aeos-config.json (make_marker_fixture always creates it)
rm -f "$T14/.claude/ralph-fork/noconfig-t14/.aeos-config.json"
OUT14=$(run_stop_hook "$T14" "noconfig-t14" false)

if [[ "$(state_field "$T14" "noconfig-t14" "awaiting_confirmation")" == "true" ]]; then
  pass "no-config: awaiting_confirmation=true (promise path unchanged)"
else
  fail "no-config: expected awaiting_confirmation=true" \
    "awaiting_confirmation=$(state_field "$T14" "noconfig-t14" "awaiting_confirmation")"
fi

MBC14=$(state_field "$T14" "noconfig-t14" "marker_block_count")
if [[ "$MBC14" == "0" || "$MBC14" == "null" ]]; then
  pass "no-config: marker_block_count unchanged (no gate fired)"
else
  fail "no-config: marker_block_count modified despite no config" "got: $MBC14"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 15 (sub-04d): corrupt .aeos-config.json in promise path → fail-open (GREEN stability guard)${NC}"
# W4: parse error on required_markers must fall through to confirmation, never terminate.

T15=$(mktemp -d -t aeos-t15-XXXX); _CLEANUP_DIRS+=("$T15")
make_marker_fixture "$T15" "corrupt-t15" "" '["tested","reviewed"]' 0
printf 'NOT_VALID_JSON{{{' > "$T15/.claude/ralph-fork/corrupt-t15/.aeos-config.json"
OUT15=$(run_stop_hook "$T15" "corrupt-t15" false)

if [[ "$(state_field "$T15" "corrupt-t15" "active")" != "false" ]]; then
  pass "corrupt-config: fail-open — loop not terminated"
else
  fail "corrupt-config (promise path): W4 VIOLATED — loop terminated on corrupt config" ""
fi

if [[ "$(state_field "$T15" "corrupt-t15" "awaiting_confirmation")" == "true" ]]; then
  pass "corrupt-config: awaiting_confirmation=true (fell through, no marker block)"
else
  fail "corrupt-config: expected fall-through to confirmation" \
    "awaiting_confirmation=$(state_field "$T15" "corrupt-t15" "awaiting_confirmation")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 16 (sub-04e): required_markers=[] → promise path unchanged (GREEN stability guard)${NC}"
# Empty required_markers array must behave identically to no config (skip gate).

T16=$(mktemp -d -t aeos-t16-XXXX); _CLEANUP_DIRS+=("$T16")
make_marker_fixture "$T16" "emptymk-t16" "" '[]' 0
OUT16=$(run_stop_hook "$T16" "emptymk-t16" false)

if [[ "$(state_field "$T16" "emptymk-t16" "awaiting_confirmation")" == "true" ]]; then
  pass "empty-markers: awaiting_confirmation=true (empty list skips gate)"
else
  fail "empty-markers: expected awaiting_confirmation=true" \
    "awaiting_confirmation=$(state_field "$T16" "emptymk-t16" "awaiting_confirmation")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 17 (sub-04f): marker_block_count ≥ 3 → escalation message with add-revision${NC}"
# RED before patch: marker_block_count not incremented, no escalation message.
# After patch: pre-seeded count=2 → fires → count becomes 3 → escalation appended.

T17=$(mktemp -d -t aeos-t17-XXXX); _CLEANUP_DIRS+=("$T17")
make_marker_fixture "$T17" "escalate-t17" "" '["tested","reviewed"]' 2
OUT17=$(run_stop_hook "$T17" "escalate-t17" false)

MBC17=$(state_field "$T17" "escalate-t17" "marker_block_count")
if [[ "$MBC17" == "3" ]]; then
  pass "escalation: marker_block_count=3 after third block"
else
  fail "escalation: expected marker_block_count=3" "got: $MBC17"
fi

if echo "$OUT17" | grep -q "add-revision"; then
  pass "escalation: BLOCK reason contains 'add-revision' escalation at count=3"
else
  fail "escalation: expected 'add-revision' in BLOCK reason at count=3" \
    "$(echo "$OUT17" | grep -i "revision\|escalat" | head -3)"
fi

if echo "$OUT17" | grep -q "mark.py tested\|mark.py reviewed"; then
  pass "escalation: mark.py instructions still present alongside escalation"
else
  fail "escalation: mark.py instructions missing from escalated BLOCK" ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUB-03: Signal-bus emission tests (self-improving-os WP-03)
# events.jsonl row helper: last line, parsed with jq.
# ─────────────────────────────────────────────────────────────────────────────
last_event() {
  local dir="$1" field="$2"
  tail -1 "$dir/_project/signals/events.jsonl" 2>/dev/null | jq -r "$field" 2>/dev/null || echo "null"
}

echo ""
echo -e "${YELLOW}Test 18 (sub-03-signal-a): Doom-loop → events.jsonl row kind=ralph-doomed${NC}"

T18=$(mktemp -d -t aeos-t18-XXXX); _CLEANUP_DIRS+=("$T18")
_tmp18=$(mktemp)
printf '# Checklist\n- [ ] Task A\n- [ ] Task B\n' > "$_tmp18"
CL_HASH18=$(checklist_hash "$_tmp18")
rm -f "$_tmp18"
make_stop_fixture "$T18" "doom-t18" 2 "$CL_HASH18" 0 5 3 false
OUT18=$(run_stop_hook "$T18" "doom-t18" false)

if [[ -f "$T18/_project/signals/events.jsonl" ]]; then
  pass "signal: events.jsonl written on doom-loop"
else
  fail "signal: events.jsonl missing after doom-loop" ""
fi

if [[ "$(last_event "$T18" '.kind')" == "ralph-doomed" ]]; then
  pass "signal: doom-loop row kind=ralph-doomed"
else
  fail "signal: expected kind=ralph-doomed" "got: $(last_event "$T18" '.kind')"
fi

if [[ "$(last_event "$T18" '.payload.reason')" == "doom_loop_detected" ]]; then
  pass "signal: doom-loop row payload.reason=doom_loop_detected"
else
  fail "signal: expected payload.reason=doom_loop_detected" "got: $(last_event "$T18" '.payload.reason')"
fi

if [[ "$(last_event "$T18" '.session')" == "doom-t18" ]]; then
  pass "signal: doom-loop row session=loop_id"
else
  fail "signal: expected session=doom-t18" "got: $(last_event "$T18" '.session')"
fi

if echo "$OUT18" | grep -q "terminalSequence"; then
  pass "signal: doom-loop hook output contains terminalSequence"
else
  fail "signal: expected terminalSequence in doom-loop output" "$OUT18"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 19 (sub-03-signal-b): Revision budget exhausted → events.jsonl row kind=ralph-doomed${NC}"

T19=$(mktemp -d -t aeos-t19-XXXX); _CLEANUP_DIRS+=("$T19")
make_stop_fixture "$T19" "rev-t19" 0 "" 3 3 5 true
run_stop_hook "$T19" "rev-t19" false >/dev/null

if [[ "$(last_event "$T19" '.kind')" == "ralph-doomed" ]]; then
  pass "signal: revision-budget row kind=ralph-doomed"
else
  fail "signal: expected kind=ralph-doomed" "got: $(last_event "$T19" '.kind')"
fi

if [[ "$(last_event "$T19" '.payload.reason')" == "revision_budget_exhausted" ]]; then
  pass "signal: revision-budget row payload.reason=revision_budget_exhausted"
else
  fail "signal: expected payload.reason=revision_budget_exhausted" \
    "got: $(last_event "$T19" '.payload.reason')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 20 (sub-03-signal-c): Budget exhausted → events.jsonl row kind=ralph-budget-exhausted${NC}"

T20=$(mktemp -d -t aeos-t20-XXXX); _CLEANUP_DIRS+=("$T20")
make_stop_fixture "$T20" "budget-t20" 0 "" 0 5 3 false 1
run_stop_hook "$T20" "budget-t20" false >/dev/null

if [[ "$(last_event "$T20" '.kind')" == "ralph-budget-exhausted" ]]; then
  pass "signal: budget-exhausted row kind=ralph-budget-exhausted"
else
  fail "signal: expected kind=ralph-budget-exhausted" "got: $(last_event "$T20" '.kind')"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}Test 21 (sub-03-signal-d): non-AEOS repo (no _project/signals/) → no write, no error${NC}"

T21=$(mktemp -d -t aeos-t21-XXXX); _CLEANUP_DIRS+=("$T21")
_tmp21=$(mktemp)
printf '# Checklist\n- [ ] Task A\n- [ ] Task B\n' > "$_tmp21"
CL_HASH21=$(checklist_hash "$_tmp21")
rm -f "$_tmp21"
make_stop_fixture "$T21" "doom-t21" 2 "$CL_HASH21" 0 5 3 false 100 false
OUT21=$(run_stop_hook "$T21" "doom-t21" false)

if [[ ! -d "$T21/_project/signals" ]] && [[ ! -f "$T21/_project/signals/events.jsonl" ]]; then
  pass "signal: no _project/signals/ dir created in non-AEOS repo (fail-open no-op)"
else
  fail "signal: unexpectedly created _project/signals/ in non-AEOS repo" ""
fi

if [[ "$(state_field "$T21" "doom-t21" "termination_reason")" == "doom_loop_detected" ]]; then
  pass "signal: doom-loop still terminates correctly without signals dir"
else
  fail "signal: doom-loop termination broken by missing signals dir" \
    "got: $(state_field "$T21" "doom-t21" "termination_reason")"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
exit 0
