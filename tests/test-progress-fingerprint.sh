#!/bin/bash
# test-progress-fingerprint.sh — the doom-detector progress fingerprint
# (stop-hook-fork.sh --fingerprint) must ignore bookkeeping (every
# CONTEXT-MAP.md at any depth, MASTER notes) and move on real progress
# (code commits, ticked checklist items anywhere in the plan dir).
#
# Origin: a loop that only wrote notes + mandatory root CONTEXT-MAP.md
# changelog commits (48 of 50 commits) never tripped the doom detector.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STOP_HOOK="$SCRIPT_DIR/hooks/stop-hook-fork.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
TESTS_PASSED=0; TESTS_FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

declare -a _DIRS=()
trap 'for d in "${_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d"; done' EXIT

# make_repo <dir>: plan dir with MASTER + sub-checklist, root and nested CONTEXT-MAP.md, one src file.
make_repo() {
  local d="$1"
  mkdir -p "$d/plan" "$d/_project/architecture" "$d/src"
  git -C "$d" init -q
  cat > "$d/plan/MASTER.md" <<'EOF'
# Master

| # | Sub | Status |
|---|-----|--------|
| 1 | sub-01.md | 🔴 pending |
| 2 | sub-02.md | 🔴 pending |

- [ ] item one
- [ ] item two

## Constraints
original constraint line

### Session 1 Notes
baseline notes
EOF
  printf '# Sub 01\n- [ ] a\n- [ ] b\n' > "$d/plan/sub-01.md"
  printf '# Map\nchangelog 0\n' > "$d/CONTEXT-MAP.md"
  printf '# Arch map\nrow 0\n' > "$d/_project/architecture/CONTEXT-MAP.md"
  printf 'print(0)\n' > "$d/src/app.py"
  echo '{}' > "$d/cfg.json"
  git -C "$d" add -A
  git -C "$d" -c user.email=t@t -c user.name=t commit -qm init
}
commit_all() { git -C "$1" add -A; git -C "$1" -c user.email=t@t -c user.name=t commit -qm "$2"; }
# fp <repo> [worktree]
fp() { bash "$STOP_HOOK" --fingerprint "${3:-$1}/plan/MASTER.md" "$1" "$1/cfg.json" "${2:-}"; }
new_repo() { local d; d=$(mktemp -d -t fpt-XXXX); _DIRS+=("$d"); make_repo "$d"; echo "$d"; }
assert_same() { # name a b
  if [[ -n "$2" && "$2" == "$3" ]]; then pass "$1"; else fail "$1" "before=$2 after=$3"; fi
}
assert_diff() {
  if [[ -n "$2" && -n "$3" && "$2" != "$3" ]]; then pass "$1"; else fail "$1" "before=$2 after=$3"; fi
}

echo -e "${YELLOW}Test 1: notes + root CONTEXT-MAP.md commits (the notes-only-loop shape) leave the fingerprint unchanged${NC}"
R=$(new_repo)
base=$(fp "$R")
for n in 1 2 3; do
  printf 'changelog %s\n' "$n" >> "$R/CONTEXT-MAP.md"
  printf '\n### Session %s Notes\nPhase 2 still blocked on dependency\n' "$((n+1))" >> "$R/plan/MASTER.md"
  commit_all "$R" "notes $n"
  assert_same "N=$n committed root CONTEXT-MAP.md + MASTER notes commit" "$base" "$(fp "$R")"
done
printf 'uncommitted changelog\n' >> "$R/CONTEXT-MAP.md"
assert_same "uncommitted edit to tracked root CONTEXT-MAP.md (git diff HEAD path)" "$base" "$(fp "$R")"
printf 'x\n' > "$R/NEW-untracked-map-sibling.txt"
assert_diff "control: an untracked real file DOES move the fingerprint" "$base" "$(fp "$R")"

echo -e "${YELLOW}Test 2: nested CONTEXT-MAP.md is bookkeeping too${NC}"
R=$(new_repo)
base=$(fp "$R")
printf 'row 1\n' >> "$R/_project/architecture/CONTEXT-MAP.md"
assert_same "uncommitted nested CONTEXT-MAP.md edit" "$base" "$(fp "$R")"
commit_all "$R" "nested map"
assert_same "committed nested-only CONTEXT-MAP.md commit" "$base" "$(fp "$R")"

echo -e "${YELLOW}Test 3: a real code commit moves the fingerprint${NC}"
R=$(new_repo)
base=$(fp "$R")
printf 'print(1)\n' >> "$R/src/app.py"
assert_diff "uncommitted code edit" "$base" "$(fp "$R")"
commit_all "$R" "code"
assert_diff "committed code change (with CONTEXT-MAP.md alongside)" "$base" "$(fp "$R")"
R=$(new_repo)
base=$(fp "$R")
printf 'print(1)\n' >> "$R/src/app.py"; printf 'changelog\n' >> "$R/CONTEXT-MAP.md"
commit_all "$R" "code + map"
assert_diff "code + root CONTEXT-MAP.md commit still counts as progress" "$base" "$(fp "$R")"

echo -e "${YELLOW}Test 4: ticking a checklist item or flipping a status row moves the fingerprint${NC}"
R=$(new_repo)
base=$(fp "$R")
sed -i.bak 's/- \[ \] item one/- [x] item one/' "$R/plan/MASTER.md"; rm -f "$R/plan/MASTER.md.bak"
assert_diff "uncommitted MASTER tick - [ ] -> - [x]" "$base" "$(fp "$R")"
commit_all "$R" "tick"
tick1=$(fp "$R")
assert_diff "committed MASTER tick" "$base" "$tick1"
sed -i.bak 's/| 🔴 pending |/| 🟢 completed |/' "$R/plan/MASTER.md"; rm -f "$R/plan/MASTER.md.bak"
assert_diff "MASTER row flip pending -> completed (uncommitted)" "$tick1" "$(fp "$R")"
commit_all "$R" "row"
row1=$(fp "$R")
sed -i.bak 's/- \[ \] item two/- [X] item two/' "$R/plan/MASTER.md"; rm -f "$R/plan/MASTER.md.bak"
assert_diff "capital - [X] counts" "$row1" "$(fp "$R")"
commit_all "$R" "tick2"
sub_before=$(fp "$R")
sed -i.bak 's/- \[ \] a/- [x] a/' "$R/plan/sub-01.md"; rm -f "$R/plan/sub-01.md.bak"
assert_diff "tick in a sub-checklist (any .md in the plan dir)" "$sub_before" "$(fp "$R")"
R=$(new_repo)
base=$(fp "$R")
printf '| 3 | sub-03.md | 🟢 completed |\n' >> "$R/plan/sub-01.md"
assert_diff "completed row in a non-MASTER plan-dir .md" "$base" "$(fp "$R")"

echo -e "${YELLOW}Test 5: editing a non-notes MASTER line without ticking does NOT move it${NC}"
R=$(new_repo)
base=$(fp "$R")
sed -i.bak 's/original constraint line/rewritten constraint line/' "$R/plan/MASTER.md"; rm -f "$R/plan/MASTER.md.bak"
assert_same "uncommitted non-tick MASTER edit" "$base" "$(fp "$R")"
commit_all "$R" "reword"
assert_same "committed non-tick MASTER edit" "$base" "$(fp "$R")"

echo -e "${YELLOW}Test 5b: ticked-looking lines inside Session Notes are not progress; a tick after a ## heading is${NC}"
R=$(new_repo)
base=$(fp "$R")
printf '\n### Session 2 Notes\n- [x] verified the blocker again\n| 9 | x | 🟢 completed |\n' >> "$R/plan/MASTER.md"
assert_same "ticks/completed rows copied into a Session Notes section" "$base" "$(fp "$R")"
printf '\n## Execution Log\n- [ ] late item\n' >> "$R/plan/MASTER.md"
before_late=$(fp "$R")
sed -i.bak 's/- \[ \] late item/- [x] late item/' "$R/plan/MASTER.md"; rm -f "$R/plan/MASTER.md.bak"
assert_diff "tick under a ## heading that follows a notes section still counts" "$before_late" "$(fp "$R")"

echo -e "${YELLOW}Test 6: linked worktree (INC-031 shape): notes + CONTEXT-MAP.md commits in the worktree leave it unchanged${NC}"
R=$(new_repo)
WT="$R-wt"; _DIRS+=("$WT")
git -C "$R" worktree add -q -b wtbranch "$WT"
base=$(fp "$R" "$WT" "$WT")
for n in 1 2 3; do
  printf 'changelog %s\n' "$n" >> "$WT/CONTEXT-MAP.md"
  printf '\n### Session %s Notes\nstill blocked\n' "$((n+1))" >> "$WT/plan/MASTER.md"
  commit_all "$WT" "wt notes $n"
  assert_same "worktree notes+CONTEXT-MAP.md commit $n" "$base" "$(fp "$R" "$WT" "$WT")"
done
printf 'print(2)\n' >> "$WT/src/app.py"; commit_all "$WT" "wt code"
assert_diff "control: a real code commit in the worktree moves it" "$base" "$(fp "$R" "$WT" "$WT")"
git -C "$R" worktree remove --force "$WT" 2>/dev/null || true

echo -e "${YELLOW}Test 7: fail-open${NC}"
R=$(new_repo)
out=$(bash "$STOP_HOOK" --fingerprint "$R/nonexistent-dir/M.md" "$R" "$R/cfg.json" 2>&1); rc=$?
if [[ $rc -eq 0 && -n "$out" ]]; then pass "missing checklist dir: exit 0, fingerprint still emitted"; else fail "missing checklist dir" "rc=$rc out=$out"; fi
out=$(bash "$STOP_HOOK" --fingerprint "$R/plan/MASTER.md" "$R/not-a-repo" "$R/cfg.json" 2>&1); rc=$?
if [[ $rc -eq 0 ]]; then pass "non-git project root: exit 0"; else fail "non-git project root" "rc=$rc out=$out"; fi
Z=$(new_repo)
printf '# no ticks at all\n' > "$Z/plan/MASTER.md"; rm -f "$Z/plan/sub-01.md"; commit_all "$Z" "zero"
z0=$(fp "$Z")
sed -i.bak 's/no ticks at all/no ticks at all\n- [x] one/' "$Z/plan/MASTER.md"; rm -f "$Z/plan/MASTER.md.bak"
assert_diff "zero ticks is a valid count (not an error): first tick moves it" "$z0" "$(fp "$Z")"

echo ""
echo "Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
[[ $TESTS_FAILED -eq 0 ]]
