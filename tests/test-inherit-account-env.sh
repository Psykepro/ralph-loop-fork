#!/bin/bash

# Tests parent-account env inheritance in lib-launch-profile.sh (launch_profile_begin), via
# fork-terminal-herdr.sh against a hermetic `herdr` stub and a stub project helper:
#   (a) no helper + parent env      => vars ride on `workspace create --env`
#   (b) no listed vars set          => create line identical to baseline
#   (c) helper non-empty env        => only helper env, no inherited vars (replace, not merge)
#   (d) helper env {}               => inherited vars kept
#   (e) custom RALPH_INHERIT_ENV    (f) empty list disables   (g) spaces round-trip   (h) bad name warned
#   (i) stderr note lists names, never values   (j) setup-ralph-loop-fork.sh sources the same function

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FORK_SCRIPT="$SCRIPT_DIR/scripts/fork-terminal-herdr.sh"
LIB="$SCRIPT_DIR/scripts/lib-launch-profile.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TESTS_PASSED=0; TESTS_FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

REPO_DIR=$(mktemp -d -t ie-test-repo-XXXX)
STUB_DIR=$(mktemp -d -t ie-test-stubs-XXXX)
HERDR_LOG=$(mktemp -t ie-test-log-XXXX)
LOOP_ID="ie-loop"
trap 'rm -rf "$REPO_DIR" "$STUB_DIR" "$HERDR_LOG"' EXIT

mkdir -p "$REPO_DIR/.claude/ralph-fork/$LOOP_ID"
cat > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/state.json" <<STATE
{
  "loop_id": "$LOOP_ID", "active": true, "total_budget": 100, "max_per_session": 1,
  "total_iterations": 0, "session_number": 1, "session_token": "old-token-1",
  "completion_promise": "DONE", "prompt": "test", "checklist_file": "checklist.md",
  "model": "sonnet", "effort": "medium", "fork_history": [], "spawned_sessions": [],
  "original_session_name": "", "backend": "herdr", "worktree_path": null
}
STATE
echo "test prompt" > "$REPO_DIR/.claude/ralph-fork/$LOOP_ID/prompt.txt"

cat > "$STUB_DIR/herdr" <<'STUBH'
#!/bin/bash
{ printf 'CALL: '; for arg in "$@"; do printf '%q ' "$arg"; done; printf '\n'; } >> "$STUB_HERDR_LOG_PATH"
case "${1:-} ${2:-}" in
  "workspace create")
    echo '{"result":{"root_pane":{"pane_id":"wT:p1","workspace_id":"wT"},"workspace":{"workspace_id":"wT","label":"stub"},"type":"workspace_created"}}' ;;
  "agent start")
    echo '{"result":{"agent":{"name":"'"${3:-}"'","pane_id":"wT:p1","workspace_id":"wT"},"type":"agent_started"}}' ;;
esac
exit 0
STUBH
chmod +x "$STUB_DIR/herdr"

write_helper() {
  mkdir -p "$REPO_DIR/.claude/hooks/lib"
  cat > "$REPO_DIR/.claude/hooks/lib/launch_profile.py" <<'PYEOF'
import os, sys
if sys.argv[1] == "plan":
    print(os.environ["LP_STUB_PLAN"])
PYEOF
}

export STUB_HERDR_LOG_PATH="$HERDR_LOG"
export PATH="$STUB_DIR:$PATH"
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID RALPH_INHERIT_ENV CLDY_SESSION AEOS_LAUNCH_PROFILE CLAUDE_CONFIG_DIR FOO_VAR OTHER_VAR

N=2
# run_spawn [ENV=VAL ...] => sets OUTPUT, CREATE_LINE
run_spawn() {
  : > "$HERDR_LOG"; N=$((N + 1))
  OUTPUT=$(env "$@" bash "$FORK_SCRIPT" "$LOOP_ID" "$N" "$REPO_DIR" 2>&1); RC=$?
  CREATE_LINE=$(grep "workspace create" "$HERDR_LOG")
}
env_flags() { grep -o -- '--env [^ ]*' <<< "$CREATE_LINE" | tr '\n' ' '; }

echo -e "${YELLOW}Baseline: no helper, no listed vars${NC}"
run_spawn A_UNRELATED=1
BASE_FLAGS=$(env_flags)
[[ $RC -eq 0 ]] && pass "baseline spawn exited 0" || fail "baseline exited $RC" "$OUTPUT"
grep -q "CLDY_SESSION\|CLAUDE_CONFIG_DIR" <<< "$CREATE_LINE" && fail "baseline has account vars" "$CREATE_LINE" || pass "(b) no listed vars => no extra --env (flags: $BASE_FLAGS)"
grep -q "inherits account env" <<< "$OUTPUT" && fail "(b) note printed with nothing inherited" "$OUTPUT" || pass "(b) no note when nothing inherited"

echo -e "${YELLOW}(a) no helper, parent env => inherited${NC}"
run_spawn CLDY_SESSION=profile-a CLAUDE_CONFIG_DIR=/path/to/acct-a
if grep -q -- "--env CLDY_SESSION=profile-a" <<< "$CREATE_LINE" && grep -q -- "--env CLAUDE_CONFIG_DIR=/path/to/acct-a" <<< "$CREATE_LINE" && grep -q -- "--env RALPH_LOOP_ACTIVE=1" <<< "$CREATE_LINE"; then
  pass "(a) both vars on workspace create beside RALPH_LOOP_ACTIVE"
else
  fail "(a) vars missing" "$CREATE_LINE"
fi
if grep -qF "inherits account env: CLDY_SESSION CLAUDE_CONFIG_DIR" <<< "$OUTPUT"; then pass "(i) note lists names"; else fail "(i) note missing" "$OUTPUT"; fi
grep -q "profile-a\|/path/to/acct-a" <<< "$(grep 'inherits' <<< "$OUTPUT")" && fail "(i) note leaked values" "$OUTPUT" || pass "(i) note has no values"

echo -e "${YELLOW}(c) helper non-empty env => replaces inherited${NC}"
write_helper
PLAN_B='{"profile":"profile-b","env":{"CLDY_SESSION":"profile-b"},"command_prefix":[]}'
run_spawn LP_STUB_PLAN="$PLAN_B" CLDY_SESSION=profile-a CLAUDE_CONFIG_DIR=/path/to/acct-a
if grep -q -- "--env CLDY_SESSION=profile-b" <<< "$CREATE_LINE" && ! grep -q "profile-a\|CLAUDE_CONFIG_DIR" <<< "$CREATE_LINE"; then
  pass "(c) only the helper env appears"
else
  fail "(c) helper env did not replace" "$CREATE_LINE"
fi

echo -e "${YELLOW}(d) helper env {} => inherited kept${NC}"
run_spawn LP_STUB_PLAN='{"profile":"x","env":{},"command_prefix":[]}' CLDY_SESSION=profile-a CLAUDE_CONFIG_DIR=/path/to/acct-a
if grep -q -- "--env CLDY_SESSION=profile-a" <<< "$CREATE_LINE" && grep -q -- "--env CLAUDE_CONFIG_DIR=/path/to/acct-a" <<< "$CREATE_LINE"; then
  pass "(d) empty helper env keeps inherited vars"
else
  fail "(d) inherited vars dropped" "$CREATE_LINE"
fi
run_spawn LP_STUB_PLAN='{"profile":"x","command_prefix":[]}' CLDY_SESSION=profile-a
grep -q -- "--env CLDY_SESSION=profile-a" <<< "$CREATE_LINE" && pass "(d) absent helper .env keeps inherited vars" || fail "(d) absent .env dropped vars" "$CREATE_LINE"
rm -rf "$REPO_DIR/.claude/hooks"

echo -e "${YELLOW}(e) custom list${NC}"
run_spawn RALPH_INHERIT_ENV=FOO_VAR FOO_VAR=bar CLDY_SESSION=profile-a
if grep -q -- "--env FOO_VAR=bar" <<< "$CREATE_LINE" && ! grep -q "CLDY_SESSION" <<< "$CREATE_LINE"; then pass "(e) custom list copied, unlisted not"; else fail "(e) custom list wrong" "$CREATE_LINE"; fi
run_spawn "RALPH_INHERIT_ENV=FOO_VAR,OTHER_VAR" FOO_VAR=1 OTHER_VAR=2
grep -q -- "--env FOO_VAR=1" <<< "$CREATE_LINE" && grep -q -- "--env OTHER_VAR=2" <<< "$CREATE_LINE" && pass "(e) comma-separated list works" || fail "(e) comma list wrong" "$CREATE_LINE"

echo -e "${YELLOW}(f) empty list disables${NC}"
run_spawn RALPH_INHERIT_ENV= CLDY_SESSION=profile-a CLAUDE_CONFIG_DIR=/path/to/acct-a
[[ "$(env_flags)" == "$BASE_FLAGS" ]] && ! grep -q "inherits" <<< "$OUTPUT" && pass "(f) disabled => baseline flags, no note" || fail "(f) not disabled" "$CREATE_LINE"

echo -e "${YELLOW}(g) value with spaces and quotes${NC}"
run_spawn FOO_VAR="a b 'c' \"d\"" RALPH_INHERIT_ENV=FOO_VAR
LINE_VAL=$(bash -c "set -- $(sed 's/^CALL: //' <<< "$CREATE_LINE"); for a in \"\$@\"; do printf '%s\n' \"\$a\"; done" | grep '^FOO_VAR=')
[[ "$LINE_VAL" == "FOO_VAR=a b 'c' \"d\"" ]] && pass "(g) value round-trips as one argv word" || fail "(g) value mangled" "got: $LINE_VAL | $CREATE_LINE"

echo -e "${YELLOW}(h) invalid name skipped with warning${NC}"
run_spawn "RALPH_INHERIT_ENV=1BAD FOO_VAR a-b" FOO_VAR=ok
if grep -q -- "--env FOO_VAR=ok" <<< "$CREATE_LINE" && grep -q "skipping invalid name '1BAD'" <<< "$OUTPUT" && grep -q "skipping invalid name 'a-b'" <<< "$OUTPUT" && [[ $RC -eq 0 ]]; then
  pass "(h) invalid names skipped with stderr warning, valid kept"
else
  fail "(h) invalid-name handling wrong" "$OUTPUT"
fi

echo -e "${YELLOW}(j) setup script shares the function${NC}"
grep -q "lib-launch-profile.sh" "$SCRIPT_DIR/scripts/fork-terminal-herdr.sh" "$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh" >/dev/null \
  && [[ $(grep -c "launch_profile_begin" "$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh") -ge 1 ]] \
  && pass "(j) both call sites use launch_profile_begin from the one lib" || fail "(j) call-site wiring" ""
OUT=$(CLDY_SESSION=profile-a bash -c "source '$LIB'; launch_profile_begin '$REPO_DIR' '$REPO_DIR' 2>/dev/null; printf '%s ' \"\${LP_HERDR_ENV[@]}\"")
[[ "$OUT" == "--env CLDY_SESSION=profile-a " ]] && pass "(j) lib sourced standalone yields LP_HERDR_ENV" || fail "(j) standalone lib" "$OUT"

echo ""; echo "========================================"; echo "Test Results"; echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"; echo -e "${RED}Failed: $TESTS_FAILED${NC}"
[[ $TESTS_FAILED -gt 0 ]] && exit 1
echo -e "${GREEN}All tests passed!${NC}"; exit 0
