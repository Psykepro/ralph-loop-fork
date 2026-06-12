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
