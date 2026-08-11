#!/bin/bash

# Tests the default-backend flip (2026-08-11): --backend defaults to
# "herdr" now, tmux is the explicit opt-in via --backend tmux. Covers:
#   - no --backend -> state.json backend == herdr (when herdr reachable)
#   - --backend tmux -> state.json backend == tmux, no herdr required
#   - herdr binary missing -> loud error, exit nonzero, no state written
#   - herdr binary present but server unreachable -> loud error (same)
#   - tmux binary missing + default (herdr) backend -> setup SUCCEEDS
#     (regression guard: tmux must no longer be unconditionally required)
#   - tmux binary missing + explicit --backend tmux -> loud error (unchanged)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

WORK_DIR=$(mktemp -d -t backend-default-XXXX)
FAKE_HOME=$(mktemp -d -t backend-default-home-XXXX)
cleanup() { rm -rf "$WORK_DIR" "$FAKE_HOME"; }
trap cleanup EXIT

new_project() {
  local dir="$WORK_DIR/$1"
  mkdir -p "$dir"
  echo "- [ ] task" > "$dir/checklist.md"
  echo "$dir"
}

# Builds a PATH identical to the real one but with every directory that
# contains $1 removed -- everything else stays exactly as in the real
# environment. (A flaky "no --backend defaults to herdr" failure was
# chased into this function at one point, but it reproduced identically
# with a completely untouched PATH -- root cause was a transient herdr
# socket round-trip delay under back-to-back-invocation load, unrelated to
# PATH content; fixed with a retry in setup-ralph-loop-fork.sh itself.)
path_without() {
  local exclude_bin="$1"
  local dir new_path=""
  IFS=':' read -ra dirs <<< "$PATH"
  for dir in "${dirs[@]}"; do
    [[ -x "$dir/$exclude_bin" ]] && continue
    new_path="${new_path:+$new_path:}$dir"
  done
  echo "$new_path"
}

echo -e "${YELLOW}Test: no --backend, herdr reachable -> defaults to herdr${NC}"
D1=$(new_project "d1")
( cd "$D1" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d1test >/dev/null 2>&1 )
BACKEND1=$(jq -r '.backend // "MISSING"' "$D1/.claude/ralph-fork/d1test/state.json" 2>/dev/null || echo "NO_STATE")
if [[ "$BACKEND1" == "herdr" ]]; then
  pass "no --backend defaults to herdr"
else
  fail "no --backend defaults to herdr" "got: $BACKEND1"
fi

echo -e "${YELLOW}Test: --backend tmux -> explicit opt-out honored${NC}"
D2=$(new_project "d2")
( cd "$D2" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d2test --backend tmux >/dev/null 2>&1 )
BACKEND2=$(jq -r '.backend // "MISSING"' "$D2/.claude/ralph-fork/d2test/state.json" 2>/dev/null || echo "NO_STATE")
if [[ "$BACKEND2" == "tmux" ]]; then
  pass "--backend tmux honored"
else
  fail "--backend tmux honored" "got: $BACKEND2"
fi

echo -e "${YELLOW}Test: herdr binary missing -> loud error, no state written${NC}"
D3=$(new_project "d3")
SANDBOX3=$(path_without herdr)
OUT3=$( ( cd "$D3" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR PATH="$SANDBOX3" bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d3test 2>&1 ) )
RC3=$?
if [[ $RC3 -ne 0 ]] && grep -qi "herdr" <<< "$OUT3" && [[ ! -f "$D3/.claude/ralph-fork/d3test/state.json" ]]; then
  pass "herdr binary missing: loud error, nonzero exit, no state"
else
  fail "herdr binary missing: loud error, nonzero exit, no state" "rc=$RC3 out=$OUT3"
fi

echo -e "${YELLOW}Test: herdr present but unreachable -> loud error${NC}"
D4=$(new_project "d4")
STUB4="$WORK_DIR/stub4"
mkdir -p "$STUB4"
cat > "$STUB4/herdr" <<'STUBH'
#!/bin/bash
if [[ "$1" == "status" ]]; then
  echo "client:"
  echo "  version: 0.0.0"
  echo "server:"
  echo "  status: unreachable"
  exit 1
fi
exit 1
STUBH
chmod +x "$STUB4/herdr"
OUT4=$( ( cd "$D4" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR PATH="$STUB4:$PATH" bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d4test 2>&1 ) )
RC4=$?
if [[ $RC4 -ne 0 ]] && grep -qi "not reachable" <<< "$OUT4" && [[ ! -f "$D4/.claude/ralph-fork/d4test/state.json" ]]; then
  pass "herdr unreachable: loud error, nonzero exit, no state"
else
  fail "herdr unreachable: loud error, nonzero exit, no state" "rc=$RC4 out=$OUT4"
fi

echo -e "${YELLOW}Test: tmux missing + default backend (herdr) -> setup SUCCEEDS (regression guard)${NC}"
D5=$(new_project "d5")
SANDBOX5=$(path_without tmux)
OUT5=$( ( cd "$D5" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR PATH="$SANDBOX5" bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d5test 2>&1 ) )
RC5=$?
BACKEND5=$(jq -r '.backend // "MISSING"' "$D5/.claude/ralph-fork/d5test/state.json" 2>/dev/null || echo "NO_STATE")
if [[ $RC5 -eq 0 ]] && [[ "$BACKEND5" == "herdr" ]]; then
  pass "tmux missing, default (herdr) backend: setup succeeds without tmux"
else
  fail "tmux missing, default (herdr) backend: setup succeeds without tmux" "rc=$RC5 backend=$BACKEND5 out=$OUT5"
fi

echo -e "${YELLOW}Test: tmux missing + explicit --backend tmux -> loud error (unchanged)${NC}"
D6=$(new_project "d6")
SANDBOX6=$(path_without tmux)
OUT6=$( ( cd "$D6" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR PATH="$SANDBOX6" bash "$SETUP_SCRIPT" \
    --checklist checklist.md --name d6test --backend tmux 2>&1 ) )
RC6=$?
if [[ $RC6 -ne 0 ]] && grep -qi "tmux is required" <<< "$OUT6" && [[ ! -f "$D6/.claude/ralph-fork/d6test/state.json" ]]; then
  pass "tmux missing, --backend tmux explicit: loud error, nonzero exit, no state"
else
  fail "tmux missing, --backend tmux explicit: loud error, nonzero exit, no state" "rc=$RC6 out=$OUT6"
fi

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
exit 0
