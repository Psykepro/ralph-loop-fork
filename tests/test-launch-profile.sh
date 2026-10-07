#!/bin/bash

# Tests the optional launch-profile hook (lib-launch-profile.sh) as used by fork-terminal-herdr.sh,
# against a hermetic `herdr` stub and a stub project helper (`.claude/hooks/lib/launch_profile.py`):
#   - no helper                  => the herdr calls are exactly the pre-hook shape (no extra --env, no PATH export)
#   - helper returns a plan      => markers ride on `workspace create --env`, a PATH shim is exported before `agent start`
#   - helper refuses (exit 3)    => the script fails and makes no herdr call at all
#   - agent start fails          => the pane is closed and the shim removed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_SCRIPT="$SCRIPT_DIR/scripts/fork-terminal-herdr.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

REPO_DIR=$(mktemp -d -t lp-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t lp-test-stubs-XXXX)
SHIM_ROOT=$(mktemp -d -t lp-test-shims-XXXX)
HERDR_LOG=$(mktemp -t lp-test-log-XXXX)
LOOP_ID="lp-loop"

cleanup() {
  rm -rf "$REPO_DIR" "$STUB_DIR" "$SHIM_ROOT" "$HERDR_LOG"
}
trap cleanup EXIT

mkdir -p "$REPO_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<EOF
{
  "loop_id": "$LOOP_ID", "active": true, "total_budget": 100, "max_per_session": 1,
  "total_iterations": 0, "session_number": 1, "session_token": "old-token-1",
  "completion_promise": "DONE", "prompt": "test", "checklist_file": "checklist.md",
  "model": "sonnet", "effort": "medium", "fork_history": [], "spawned_sessions": [],
  "original_session_name": "", "backend": "herdr", "worktree_path": null
}
EOF
echo "test prompt" > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/prompt.txt"

cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{ printf 'CALL: '; for arg in "$@"; do printf '%q ' "$arg"; done; printf '\n'; } >> "$STUB_HERDR_LOG_PATH"
case "${1:-} ${2:-}" in
  "workspace create")
    echo '{"result":{"root_pane":{"pane_id":"wT:p1","workspace_id":"wT"},"workspace":{"workspace_id":"wT","label":"stub"},"type":"workspace_created"}}'
    ;;
  "agent start")
    if [[ "${STUB_AGENT_START_FAIL:-}" == "1" ]]; then
      echo '{"error":{"code":"boom","message":"no"}}' >&2
      exit 1
    fi
    echo '{"result":{"agent":{"name":"'"${3:-}"'","pane_id":"wT:p1","workspace_id":"wT"},"type":"agent_started"}}'
    ;;
esac
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"

# Stub project helper: `plan` echoes $LP_STUB_PLAN (or fails with $LP_STUB_FAIL), `shim` writes <SHIM_ROOT>/<pane>/claude.
write_helper() {
  mkdir -p "$REPO_DIR/.claude/hooks/lib"
  cat > "$REPO_DIR/.claude/hooks/lib/launch_profile.py" <<'PYEOF'
import os, sys
verb = sys.argv[1]
if verb == "plan":
    if os.environ.get("LP_STUB_FAIL"):
        print("profile rule invalid: stub reason", file=sys.stderr)
        sys.exit(3)
    print(os.environ["LP_STUB_PLAN"])
elif verb == "shim":
    d = os.path.join(os.environ["LP_STUB_SHIM_ROOT"], sys.argv[3].replace(":", "_"))
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "claude"), "w").write("#!/bin/sh\nexec wrapper \"$@\"\n")
    print(d)
elif verb == "shim-cleanup":
    import shutil
    shutil.rmtree(os.path.join(os.environ["LP_STUB_SHIM_ROOT"], sys.argv[2].replace(":", "_")), ignore_errors=True)
PYEOF
}

export STUB_HERDR_LOG_PATH="$HERDR_LOG"
export LP_STUB_SHIM_ROOT="$SHIM_ROOT"
export PATH="$STUB_DIR:$PATH"
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID LP_STUB_FAIL STUB_AGENT_START_FAIL RALPH_INHERIT_ENV CLDY_SESSION AEOS_LAUNCH_PROFILE CLAUDE_CONFIG_DIR

PLAN='{"profile":"personal","env":{"CLDY_SESSION":"personal","AEOS_LAUNCH_PROFILE":"personal"},"command_prefix":["wrapper","--"]}'

echo -e "${YELLOW}Test 1: no helper => no markers, no PATH export${NC}"
: > "$HERDR_LOG"
OUTPUT=$(bash "$FORK_SCRIPT" "$LOOP_ID" 2 "$REPO_DIR" 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "spawn exited 0" || fail "spawn exited $RC" "$OUTPUT"
if grep -q "CLDY_SESSION\|AEOS_LAUNCH_PROFILE\|export PATH" "$HERDR_LOG"; then
  fail "no-helper spawn leaked profile calls" "$(cat "$HERDR_LOG")"
else
  pass "no-helper spawn adds no marker env and no PATH export"
fi

echo -e "${YELLOW}Test 2: helper plan => markers on create, shim exported before agent start${NC}"
write_helper
: > "$HERDR_LOG"
OUTPUT=$(LP_STUB_PLAN="$PLAN" bash "$FORK_SCRIPT" "$LOOP_ID" 3 "$REPO_DIR" 2>&1); RC=$?
[[ $RC -eq 0 ]] && pass "spawn exited 0" || fail "spawn exited $RC" "$OUTPUT"
CREATE_LINE=$(grep "workspace create" "$HERDR_LOG")
if grep -q -- "--env CLDY_SESSION=personal" <<< "$CREATE_LINE" && grep -q -- "--env AEOS_LAUNCH_PROFILE=personal" <<< "$CREATE_LINE" && grep -q -- "--env RALPH_LOOP_ACTIVE=1" <<< "$CREATE_LINE"; then
  pass "workspace create carries the markers beside RALPH_LOOP_ACTIVE"
else
  fail "workspace create is missing marker env" "$CREATE_LINE"
fi
EXPORT_N=$(grep -n "export.*PATH=$SHIM_ROOT" "$HERDR_LOG" | head -1 | cut -d: -f1)
START_N=$(grep -n "agent start" "$HERDR_LOG" | head -1 | cut -d: -f1)
if [[ -n "$EXPORT_N" && -n "$START_N" && "$EXPORT_N" -lt "$START_N" ]]; then
  pass "PATH shim exported before agent start"
else
  fail "PATH export missing or after agent start" "$(cat "$HERDR_LOG")"
fi
if grep "agent start" "$HERDR_LOG" | grep -q -- "-- --dangerously-skip-permissions --model sonnet --effort medium"; then
  pass "agent start flags unchanged"
else
  fail "agent start flags changed" "$(grep 'agent start' "$HERDR_LOG")"
fi

echo -e "${YELLOW}Test 3: helper refuses => nonzero exit, no herdr call${NC}"
: > "$HERDR_LOG"
OUTPUT=$(LP_STUB_FAIL=1 bash "$FORK_SCRIPT" "$LOOP_ID" 4 "$REPO_DIR" 2>&1); RC=$?
[[ $RC -ne 0 ]] && pass "refused spawn exited nonzero ($RC)" || fail "refused spawn exited 0" "$OUTPUT"
grep -q "stub reason" <<< "$OUTPUT" && pass "refusal reason is shown" || fail "refusal reason not shown" "$OUTPUT"
[[ ! -s "$HERDR_LOG" ]] && pass "no herdr call after a refusal" || fail "herdr was called after a refusal" "$(cat "$HERDR_LOG")"

echo -e "${YELLOW}Test 4: agent start failure => pane closed, shim removed${NC}"
: > "$HERDR_LOG"
rm -rf "${SHIM_ROOT:?}"/*
OUTPUT=$(LP_STUB_PLAN="$PLAN" STUB_AGENT_START_FAIL=1 bash "$FORK_SCRIPT" "$LOOP_ID" 5 "$REPO_DIR" 2>&1); RC=$?
[[ $RC -ne 0 ]] && pass "failed start exited nonzero ($RC)" || fail "failed start exited 0" "$OUTPUT"
grep -q "pane close wT:p1" "$HERDR_LOG" && pass "pane closed" || fail "pane not closed" "$(cat "$HERDR_LOG")"
[[ -z "$(ls -A "$SHIM_ROOT")" ]] && pass "shim dir removed" || fail "shim dir leaked" "$(ls -A "$SHIM_ROOT")"

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
[[ $TESTS_FAILED -gt 0 ]] && exit 1
echo -e "${GREEN}All tests passed!${NC}"
exit 0
