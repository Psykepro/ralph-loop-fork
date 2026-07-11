#!/bin/bash
# Regression test: tmux target flags must use exact-match syntax (-t "=name").
#
# BUG (2026-07-11, self-improving-os loop): `tmux kill-session -t "$name"`
# falls back to PREFIX matching when no exact match exists. The fork-terminal
# cleanup loop killing long-dead "ralph-<loop>-2" prefix-matched the freshly
# spawned "ralph-<loop>-20"/"-21" and killed it ~5s after spawn — the loop ran
# 19 iterations fine and then died deterministically at session 20.
#
# Two layers:
#   1. Static: no unprefixed -t "$var" targets remain in hooks/ or scripts/.
#   2. Behavioral: live tmux proves prefix-kill happens without "=" and is
#      prevented with "=" (skipped if tmux unavailable).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0

check() {
  local desc="$1" ok="$2"
  if [[ "$ok" == "0" ]]; then
    echo "  ✅ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ❌ $desc"
    FAIL=$((FAIL + 1))
  fi
}

echo "── static: no prefix-match tmux targets ──"

# Any kill-session/has-session/send-keys -t targeting a variable must use "=$
UNPREFIXED=$(grep -rnE '(kill-session|has-session|send-keys) -t "(\$|\\")' \
  "$ROOT/hooks" "$ROOT/scripts" 2>/dev/null | grep -v '"=' || true)
[[ -z "$UNPREFIXED" ]]
check "no unprefixed variable tmux targets in hooks/ + scripts/ ${UNPREFIXED:+→ $UNPREFIXED}" $?

# The fork-terminal cleanup loop specifically must use the escaped exact form
grep -q 'kill-session -t \\"=\\\$s\\"' "$ROOT/scripts/fork-terminal.sh"
check "fork-terminal.sh cleanup loop uses exact-match kill" $?

echo "── behavioral: tmux exact-match semantics ──"

if command -v tmux >/dev/null 2>&1; then
  SUFFIX="$$"
  LIVE="ralph-exactmatch-test-${SUFFIX}-21"
  DEAD="ralph-exactmatch-test-${SUFFIX}-2"

  # Bug shape: killing dead "-2" without "=" prefix-matches live "-21"
  TMUX= tmux new-session -d -s "$LIVE" 'sleep 30' 2>/dev/null
  tmux kill-session -t "$DEAD" 2>/dev/null
  ! tmux has-session -t "=$LIVE" 2>/dev/null
  check "without '=': dead-name kill prefix-matches and kills live session (bug shape confirmed)" $?
  tmux kill-session -t "=$LIVE" 2>/dev/null || true

  # Fix shape: with "=" the dead-name kill fails and the live session survives
  TMUX= tmux new-session -d -s "$LIVE" 'sleep 30' 2>/dev/null
  ! tmux kill-session -t "=$DEAD" 2>/dev/null && tmux has-session -t "=$LIVE" 2>/dev/null
  check "with '=': dead-name kill fails, live session survives" $?
  tmux kill-session -t "=$LIVE" 2>/dev/null || true
else
  echo "  ⚠️  tmux not available — behavioral checks skipped"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
