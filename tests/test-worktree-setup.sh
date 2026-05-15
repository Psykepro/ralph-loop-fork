#!/bin/bash

# End-to-end test for setup-worktree.sh (Phase 1 of --worktree mode)
# and the worktree-cancel hint in cancel-ralph-loop-fork.sh.
#
# This test does NOT launch claude or tmux — it exercises the file-system
# and state-manipulation parts of the worktree flow, which is what
# previously had only manual coverage.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_WT="$SCRIPT_DIR/scripts/setup-worktree.sh"
CANCEL="$SCRIPT_DIR/scripts/cancel-ralph-loop-fork.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

REPO_DIR=$(mktemp -d -t wt-setup-test-XXXX)
cleanup() {
  if [[ -n "${REPO_DIR:-}" ]] && [[ -d "$REPO_DIR" ]]; then
    git -C "$REPO_DIR" worktree list 2>/dev/null | awk '/^[^ ]/{print $1}' | while read -r wt; do
      [[ "$wt" == "$REPO_DIR" ]] && continue
      git -C "$REPO_DIR" worktree remove --force "$wt" 2>/dev/null
    done
    rm -rf "$REPO_DIR"
  fi
}
trap cleanup EXIT

# Build fixture repo with: CLAUDE.md, .claude/{skills,commands,settings*}, env
# files, checklist subdir, untracked extra dir for --copy-paths.
cd "$REPO_DIR"
git init -q -b main
git config user.email t@t.local
git config user.name t

echo "# Project rules" > CLAUDE.md
mkdir -p .claude/skills/foo .claude/commands
echo "foo skill" > .claude/skills/foo/SKILL.md
echo "cmd" > .claude/commands/test.md
echo '{"x":1}' > .claude/settings.json
echo '{"y":2}' > .claude/settings.local.json
# Ralph-fork dir with one OTHER loop already running, plus .archive that must NOT be copied.
mkdir -p .claude/ralph-fork/other-loop .claude/ralph-fork/.archive/archived-loop
echo '{"loop_id":"other-loop"}' > .claude/ralph-fork/other-loop/state.json
echo "archived" > .claude/ralph-fork/.archive/archived-loop/state.json
mkdir -p _project/progress/in-progress
cat > _project/progress/in-progress/checklist.md <<'EOF'
# Checklist
- [ ] Task 1
EOF
echo "EXAMPLE_KEY=v" > .env
echo "LOCAL=1" > .env.local
mkdir -p extras
echo "extra" > extras/note.md
git add CLAUDE.md .claude _project/progress _project/progress/in-progress/checklist.md
git add -f _project/progress/in-progress/checklist.md 2>/dev/null
git commit -qm "fixture"

echo -e "${YELLOW}Test 1: setup-worktree.sh creates worktree with correct payload${NC}"

ABS=$(bash "$SETUP_WT" "my-loop" ".worktrees/my-loop" "ralph/my-loop" \
        "_project/progress/in-progress" extras 2>/dev/null)
RC=$?

if [[ $RC -eq 0 ]]; then
  pass "setup-worktree.sh exited 0"
else
  fail "setup-worktree.sh exited $RC" ""
fi

if [[ -n "$ABS" ]] && [[ -d "$ABS" ]]; then
  pass "Returned absolute worktree path on stdout"
else
  fail "stdout did not yield a valid worktree path" "got: $ABS"
fi

BRANCH=$(git -C "$ABS" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ "$BRANCH" == "ralph/my-loop" ]]; then
  pass "Worktree is on the requested branch"
else
  fail "Worktree branch wrong" "got: $BRANCH"
fi

[[ -f "$ABS/CLAUDE.md" ]] && pass "CLAUDE.md copied" || fail "CLAUDE.md missing" ""
[[ -d "$ABS/.claude/skills/foo" ]] && pass ".claude/skills copied" || fail ".claude/skills missing" ""
[[ -d "$ABS/.claude/commands" ]] && pass ".claude/commands copied" || fail ".claude/commands missing" ""
[[ -f "$ABS/.claude/settings.json" ]] && pass ".claude/settings.json copied" || fail ".claude/settings.json missing" ""
[[ -f "$ABS/.claude/settings.local.json" ]] && pass ".claude/settings.local.json copied" || fail ".claude/settings.local.json missing" ""

[[ -d "$ABS/.claude/ralph-fork/other-loop" ]] && pass "other-loop state copied through" || fail "other-loop state missing" ""

# CRITICAL: ralph-fork/.archive must NOT be copied (avoids dragging nested .claude).
if [[ ! -d "$ABS/.claude/ralph-fork/.archive" ]]; then
  pass ".archive/ correctly excluded from copy"
else
  fail ".archive/ leaked into worktree" "$(ls -la "$ABS/.claude/ralph-fork/.archive")"
fi

# CRITICAL: the loop-id's own dir must NOT exist yet in the worktree (caller
# will mv the fresh state in); we should have cleared any pre-existing one.
if [[ ! -d "$ABS/.claude/ralph-fork/my-loop" ]]; then
  pass "Stale state for this loop_id pre-cleared at dest"
else
  fail "Stale state still present at dest" ""
fi

[[ -f "$ABS/_project/progress/in-progress/checklist.md" ]] && pass "Checklist dir copied" || fail "Checklist dir not copied" ""
[[ -f "$ABS/.env" ]] && pass ".env copied" || fail ".env missing" ""
[[ -f "$ABS/.env.local" ]] && pass ".env.local copied" || fail ".env.local missing" ""

# --copy-paths "extras" should land as a flat dir in the worktree, not nested.
if [[ -f "$ABS/extras/note.md" ]] && [[ ! -f "$ABS/extras/extras/note.md" ]]; then
  pass "--copy-paths entry copied without nesting"
else
  fail "--copy-paths nested or missing" "$(find "$ABS/extras" 2>/dev/null)"
fi

echo ""
echo -e "${YELLOW}Test 2: CHECKLIST_DIR=\".\" does not drag .git into worktree${NC}"

# A second worktree, this time with a root-level checklist (CHECKLIST_DIR=".").
ABS2=$(bash "$SETUP_WT" "root-loop" ".worktrees/root-loop" "ralph/root-loop" "." 2>/dev/null)
if [[ -n "$ABS2" ]] && [[ -d "$ABS2" ]]; then
  pass "setup-worktree handled CHECKLIST_DIR=\".\" without aborting"
else
  fail "setup-worktree refused or failed on root-level checklist" "stdout: $ABS2"
fi

# The worktree's own .git linkage must remain a FILE (gitlink), not the
# main repo's .git/ directory hierarchy. If "." had been copied, this would
# be a directory containing main repo contents.
if [[ -f "$ABS2/.git" ]]; then
  pass ".git linkage intact (file, not a directory) — main .git was NOT copied over"
else
  fail "Worktree .git was clobbered by root-level checklist copy" "$(ls -la "$ABS2/.git")"
fi

echo ""
echo -e "${YELLOW}Test 3: cancel script discovers state inside worktree${NC}"

# Move the fresh state dir into the my-loop worktree the way setup-ralph-loop-fork.sh would.
mkdir -p "$REPO_DIR/.claude/ralph-fork/my-loop"
cat > "$REPO_DIR/.claude/ralph-fork/my-loop/state.json" <<EOF
{
  "loop_id": "my-loop",
  "active": true,
  "total_budget": 100,
  "max_per_session": 1,
  "total_iterations": 0,
  "session_number": 1,
  "spawned_sessions": [],
  "worktree_path": "$ABS"
}
EOF
mv "$REPO_DIR/.claude/ralph-fork/my-loop" "$ABS/.claude/ralph-fork/my-loop"

# --list should now find my-loop via the git worktree walk.
LIST_OUT=$(cd "$REPO_DIR" && bash "$CANCEL" --list 2>&1)
if grep -q "my-loop" <<< "$LIST_OUT"; then
  pass "cancel --list finds worktree-resident loop"
else
  fail "cancel --list missed worktree-resident loop" "$LIST_OUT"
fi
if grep -q "worktree=" <<< "$LIST_OUT"; then
  pass "cancel --list output includes worktree= path"
else
  fail "cancel --list output missing worktree= field" "$LIST_OUT"
fi

# Cancelling my-loop should remove the moved state dir and print merge hints.
CANCEL_OUT=$(cd "$REPO_DIR" && bash "$CANCEL" my-loop 2>&1)
if grep -q "git worktree remove" <<< "$CANCEL_OUT"; then
  pass "cancel prints 'git worktree remove' hint"
else
  fail "cancel did not print worktree-remove hint" "$CANCEL_OUT"
fi
if grep -q "git branch -D ralph/my-loop" <<< "$CANCEL_OUT"; then
  pass "cancel prints 'git branch -D ralph/my-loop' hint"
else
  fail "cancel did not print branch-D hint" "$CANCEL_OUT"
fi
if [[ ! -d "$ABS/.claude/ralph-fork/my-loop" ]]; then
  pass "cancel removed the worktree-resident state dir"
else
  fail "state dir survived cancel" ""
fi
# Worktree itself must remain (cancel does NOT auto-remove it).
if [[ -d "$ABS" ]]; then
  pass "Worktree directory left in place for inspection"
else
  fail "Worktree directory was auto-removed (regression!)" ""
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
