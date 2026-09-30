#!/bin/bash

# Spawn-lineage tests: fork scripts record loop-node lineage rows, export the
# SPAWN_* env to the child, and never break a spawn. Hermetic herdr/tmux stubs;
# the fixture repo has NO AEOS files (standalone plugin use).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HERDR_FORK="$SCRIPT_DIR/scripts/fork-terminal-herdr.sh"
TMUX_FORK="$SCRIPT_DIR/scripts/fork-terminal.sh"
BIND_HOOK="$SCRIPT_DIR/hooks/spawn-bind-hook.py"
SWEEP_HOOK="$SCRIPT_DIR/hooks/spawn-sweep-hook.py"
REG="$SCRIPT_DIR/scripts/spawn_registry.py"

GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
PASSED=0; FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; FAILED=$((FAILED + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1" "${3:-}"; fi; }

TMP=$(mktemp -d -t spawn-lineage-XXXX)
trap 'rm -rf "$TMP"' EXIT
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID SPAWN_ID SPAWN_REGISTRY_DIR SPAWN_REGISTRY_DISABLE CLAUDE_PROJECT_DIR

STUBS="$TMP/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/herdr" <<'H'
#!/bin/bash
{ printf 'CALL: '; for a in "$@"; do printf '%q ' "$a"; done; printf '\n'; } >> "$STUB_LOG"
case "${1:-} ${2:-}" in
  "workspace create") echo '{"result":{"root_pane":{"pane_id":"wT:p1","workspace_id":"wT"},"workspace":{"workspace_id":"wT"}}}';;
  "agent start") echo "ROWS_AT_AGENT_START=$(cat "$PWD"/.claude/spawn-registry/spawns*.jsonl 2>/dev/null | grep -c '"type":"spawn"')" >> "$STUB_LOG"
    [[ -n "${STUB_FAIL_START:-}" ]] && exit 1; echo '{"result":{}}';;
esac
exit 0
H
cat > "$STUBS/tmux" <<'T'
#!/bin/bash
{ printf 'CALL: '; for a in "$@"; do printf '%q ' "$a"; done; printf '\n'; } >> "$STUB_LOG"
exit 0
T
chmod +x "$STUBS"/*
export STUB_LOG="$TMP/stub.log"

# Standalone fixture: a git repo with a loop and NO AEOS files.
mk_repo() {
  local repo="$1" launcher="${2:-launcher-sess-1}"
  mkdir -p "$repo/.claude/ralph-fork/lp"
  git -C "$repo" init -q
  cat > "$repo/.claude/ralph-fork/lp/state.json" <<EOF
{"loop_id":"lp","active":true,"total_budget":100,"max_per_session":1,"total_iterations":0,
 "session_number":1,"completion_promise":"DONE","prompt":"t","checklist_file":"c.md",
 "model":"sonnet","effort":"medium","fork_history":[],"spawned_sessions":[],
 "original_session_name":"","backend":"herdr","worktree_path":null,"launcher_session_id":"$launcher"}
EOF
  echo p > "$repo/.claude/ralph-fork/lp/prompt.txt"
}
rows() { cat "$1"/.claude/spawn-registry/spawns*.jsonl 2>/dev/null; }

echo "Test 1: herdr fork records a loop-node iteration row + exports SPAWN_* to the child"
R1="$TMP/r1"; mk_repo "$R1"; : > "$STUB_LOG"
OUT=$(PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 2 "$R1" 2>&1); RC=$?
check "fork exits 0" "[[ $RC -eq 0 ]]" "$OUT"
check "workspace create carries SPAWN_ID" "grep -q -- '--env SPAWN_ID=sp-' '$STUB_LOG'" "$(cat "$STUB_LOG")"
check "workspace create carries absolute SPAWN_REGISTRY_DIR (standalone default)" \
  "grep -q -- \"--env SPAWN_REGISTRY_DIR=.*/r1/.claude/spawn-registry\" '$STUB_LOG'" "$(cat "$STUB_LOG")"
check "RALPH_LOOP_ACTIVE still set" "grep -q -- '--env RALPH_LOOP_ACTIVE=1' '$STUB_LOG'"
ROW1=$(rows "$R1" | grep '"type":"spawn"' | head -1)
check "spawn row has loop_id lp / iteration 2" "[[ \$(jq -r '.loop.loop_id' <<<'$ROW1') == lp && \$(jq -r '.loop.iteration' <<<'$ROW1') == 2 ]]" "$ROW1"
check "spawn row parent is the launcher session" "[[ \$(jq -r '.parent.session_id' <<<'$ROW1') == launcher-sess-1 ]]" "$ROW1"
check "spawn row is written BEFORE agent start (bind race)" "grep -q 'ROWS_AT_AGENT_START=1' '$STUB_LOG'" "$(grep ROWS_AT "$STUB_LOG")"
SID1=$(jq -r '.spawn_id' <<<"$ROW1")
check "state.json spawned_sessions[-1].spawn_id matches the row" \
  "[[ \$(jq -r '.spawned_sessions[-1].spawn_id' '$R1/.claude/ralph-fork/lp/state.json') == '$SID1' ]]"

echo "Test 2: next iteration links prev_spawn_id (N -> N-1)"
: > "$STUB_LOG"
PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 3 "$R1" >/dev/null 2>&1
ROW2=$(rows "$R1" | grep '"type":"spawn"' | tail -1)
check "iteration 3 prev_spawn_id == iteration 2 spawn_id" "[[ \$(jq -r '.loop.prev_spawn_id' <<<'$ROW2') == '$SID1' ]]" "$ROW2"

echo "Test 3: failed agent start closes the row (no lingering unbound spawn)"
R3="$TMP/r3"; mk_repo "$R3"; : > "$STUB_LOG"
STUB_FAIL_START=1 PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 2 "$R3" >/dev/null 2>&1
check "an end row follows the spawn row" "rows '$R3' | grep -q '\"type\":\"end\"'" "$(rows "$R3")"

echo "Test 4: kill-switch => no env, no rows, spawn still works"
R4="$TMP/r4"; mk_repo "$R4"; : > "$STUB_LOG"
OUT=$(SPAWN_REGISTRY_DISABLE=1 PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 2 "$R4" 2>&1); RC=$?
check "exit 0" "[[ $RC -eq 0 ]]" "$OUT"
check "no SPAWN_ID exported" "! grep -q 'SPAWN_ID' '$STUB_LOG'"
check "no registry rows" "[[ -z \$(rows '$R4') ]]"

echo "Test 5: unusable registry never breaks the spawn, and says so"
R5="$TMP/r5"; mk_repo "$R5"; : > "$STUB_LOG"
OUT=$(SPAWN_REGISTRY_DIR=relative/dir PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 2 "$R5" 2>&1); RC=$?
check "exit 0 despite bad SPAWN_REGISTRY_DIR" "[[ $RC -eq 0 ]]" "$OUT"
check "visible ⚠️ lineage line on stderr" "grep -q 'lineage' <<<'$OUT'" "$OUT"

echo "Test 6: tmux fork passes -e SPAWN_* and records the row"
R6="$TMP/r6"; mk_repo "$R6"; : > "$STUB_LOG"
OUT=$(PATH="$STUBS:$PATH" bash "$TMUX_FORK" lp 2 "$R6" 2>&1); RC=$?
check "exit 0" "[[ $RC -eq 0 ]]" "$OUT"
check "tmux new-session has -e SPAWN_ID=" "grep 'new-session' '$STUB_LOG' | grep -q -- '-e SPAWN_ID=sp-'" "$(cat "$STUB_LOG")"
check "row recorded" "rows '$R6' | grep -q '\"loop_id\":\"lp\"'" "$(rows "$R6")"

echo "Test 7: SessionStart bind hook"
R7="$TMP/r7"; mk_repo "$R7"; mkdir -p "$R7/.claude/spawn-registry"
echo '{"session_id":"child-sess","source":"startup"}' | SPAWN_ID=sp-abc123abc123 SPAWN_REGISTRY_DIR="$R7/.claude/spawn-registry" CLAUDE_PROJECT_DIR="$R7" python3 "$BIND_HOOK"
check "bind row written" "rows '$R7' | grep '\"type\":\"bind\"' | grep -q child-sess" "$(rows "$R7")"
mkdir -p "$R7/.claude/hooks/session-start"; : > "$R7/.claude/hooks/session-start/spawn-bind.py"
: > "$R7/.claude/spawn-registry/spawns.jsonl"
echo '{"session_id":"child-sess","source":"startup"}' | SPAWN_ID=sp-abc123abc123 SPAWN_REGISTRY_DIR="$R7/.claude/spawn-registry" CLAUDE_PROJECT_DIR="$R7" python3 "$BIND_HOOK"
check "sentinel present => plugin hook no-ops (bind written once)" "[[ -z \$(rows '$R7') ]]" "$(rows "$R7")"
echo '{}' | env -u SPAWN_ID CLAUDE_PROJECT_DIR="$R7" python3 "$BIND_HOOK"
check "no SPAWN_ID => silent no-op exit 0" "[[ \$? -eq 0 ]]"
if [[ -x /usr/bin/python3 ]]; then
  check "plugin module + hooks import under /usr/bin/python3 (3.9 floor)" \
    "/usr/bin/python3 -c \"import sys;sys.path.insert(0,'$SCRIPT_DIR/scripts');import spawn_registry\" && /usr/bin/python3 -m py_compile '$BIND_HOOK' '$SWEEP_HOOK'"
fi

echo "Test 8: Stop-hook sweep fires before the no-loop early exit"
R8="$TMP/r8"; mk_repo "$R8"; mkdir -p "$R8/.claude/spawn-registry"
rm -f "$R8/.claude/spawn-registry/.last-sweep"
echo '{"transcript_path":"/nonexistent"}' | CLAUDE_PROJECT_DIR="$R8" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" bash "$SCRIPT_DIR/hooks/stop-hook-fork.sh" >/dev/null 2>&1
check "sweep stamp touched by the Stop hook" "[[ -f '$R8/.claude/spawn-registry/.last-sweep' ]]"
R9="$TMP/r9"; mkdir -p "$R9"; git -C "$R9" init -q
echo '{"transcript_path":"/nonexistent"}' | CLAUDE_PROJECT_DIR="$R9" CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR" bash "$SCRIPT_DIR/hooks/stop-hook-fork.sh" >/dev/null 2>&1
check "non-ralph repo untouched (no registry dir created)" "[[ ! -e '$R9/.claude' ]]"

echo "Test 9: registry writes must not register as loop progress (fingerprint)"
R10="$TMP/r10"; mk_repo "$R10"; echo x > "$R10/c.md"; git -C "$R10" add -A >/dev/null 2>&1
git -C "$R10" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
FP_A=$(bash "$SCRIPT_DIR/hooks/stop-hook-fork.sh" --fingerprint "$R10/c.md" "$R10" /nonexistent)
PATH="$STUBS:$PATH" bash "$HERDR_FORK" lp 2 "$R10" >/dev/null 2>&1
FP_B=$(bash "$SCRIPT_DIR/hooks/stop-hook-fork.sh" --fingerprint "$R10/c.md" "$R10" /nonexistent)
check "fingerprint unchanged after a spawn row is appended" "[[ -n '$FP_A' && '$FP_A' == '$FP_B' ]]" "$FP_A vs $FP_B"

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
