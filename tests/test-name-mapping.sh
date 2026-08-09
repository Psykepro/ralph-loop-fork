#!/bin/bash

# Tests scripts/lib-herdr-backend.sh's herdr_derive_name() against
# adversarial inputs -- must always satisfy herdr's agent-name charset
# ^[a-z][a-z0-9_-]{0,31}$. Because fork-terminal-herdr.sh, stop-hook-fork.sh,
# and cancel-ralph-loop-fork.sh all source the SAME lib file, cross-script
# identity is structural (one function, not three copies) rather than
# something this test needs to separately assert.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../scripts/lib-herdr-backend.sh
source "$SCRIPT_DIR/scripts/lib-herdr-backend.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

CHARSET_RE='^[a-z][a-z0-9_-]{0,31}$'

check_charset() {
  local label="$1" loop_id="$2" session_number="$3"
  local name
  name=$(herdr_derive_name "$loop_id" "$session_number")
  local len=${#name}
  if [[ $len -gt 32 ]]; then
    fail "$label: name exceeds 32 chars" "name=$name len=$len"
    return
  fi
  if [[ "$name" =~ $CHARSET_RE ]]; then
    pass "$label: '$name' matches ^[a-z][a-z0-9_-]{0,31}\$ (len=$len)"
  else
    fail "$label: '$name' does NOT match required charset" "loop_id=$loop_id session=$session_number"
  fi
}

# Adversarial inputs: uppercase, >32 raw chars, digit-leading, embedded
# dots/slashes/spaces.
check_charset "uppercase loop id" "MyFeature" 1
check_charset "long loop id (research doc's own worked example)" "telegram-approval-eval-battery" 1
check_charset "digit-leading loop id" "123-feature" 1
check_charset "embedded dots/slashes/spaces" "my.feature/branch name" 2
check_charset "empty-ish loop id" "" 1
check_charset "very long session number" "x" 999999
check_charset "unicode-ish input" "café-münchen" 1

# Determinism: same inputs must always produce the same output (spawn and
# cleanup must independently derive the identical name for the identical
# (loop_id, session_number) pair).
NAME_A=$(herdr_derive_name "determinism-test" 5)
NAME_B=$(herdr_derive_name "determinism-test" 5)
if [[ "$NAME_A" == "$NAME_B" ]]; then
  pass "herdr_derive_name is deterministic for the same (loop_id, session_number)"
else
  fail "herdr_derive_name is NOT deterministic" "got '$NAME_A' vs '$NAME_B'"
fi

# Different session numbers must produce different names (no accidental
# collision from truncation swallowing the distinguishing suffix).
NAME_S1=$(herdr_derive_name "same-loop" 1)
NAME_S2=$(herdr_derive_name "same-loop" 2)
if [[ "$NAME_S1" != "$NAME_S2" ]]; then
  pass "different session numbers of the same loop produce different names"
else
  fail "session 1 and session 2 collided" "both: $NAME_S1"
fi

# Real research-doc worked example: ralph-telegram-approval-eval-battery-1
# is 38 raw chars -- confirm the derived name still fits.
check_charset "research doc's exact worked example (38 raw chars)" "telegram-approval-eval-battery" 1

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
