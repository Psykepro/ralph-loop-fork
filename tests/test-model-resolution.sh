#!/bin/bash

# Unit tests for the 3-layer model/effort resolver in setup-ralph-loop-fork.sh
# Precedence (highest wins): P0 explicit flag > P1 AEOS model_policy.implementation
# > P2 plugin config file (project then user) > P3 built-in default.
# See _project/specs/feature-model-effort-3-layer-default-2026-07-24.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/scripts/setup-ralph-loop-fork.sh"
CANCEL_SCRIPT="$SCRIPT_DIR/scripts/cancel-ralph-loop-fork.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
pass() { echo -e "${GREEN}✓ PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}✗ FAIL${NC}: $1"; echo "  expected: $2"; echo "  got:      $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

WORK_DIR=$(mktemp -d -t model-resolution-XXXX)
FAKE_HOME=$(mktemp -d -t model-resolution-home-XXXX)
cleanup() { rm -rf "$WORK_DIR" "$FAKE_HOME"; }
trap cleanup EXIT

# Fresh, non-git, no-AEOS, no-config project dir for each case.
new_project() {
  local dir="$WORK_DIR/$1"
  mkdir -p "$dir"
  echo "- [ ] task" > "$dir/checklist.md"
  echo "$dir"
}

# Run setup (non-worktree, non-resume — no tmux spawn) and echo state.json path.
# Args after the project dir are passed straight to setup-ralph-loop-fork.sh.
run_setup() {
  local dir="$1"; shift
  local name="$1"; shift
  ( cd "$dir" && HOME="$FAKE_HOME" env -u CLAUDE_PROJECT_DIR bash "$SETUP_SCRIPT" \
      --checklist checklist.md --name "$name" "$@" )
}

state_field() {
  local dir="$1" name="$2" field="$3"
  jq -r ".$field // \"MISSING\"" "$dir/.claude/ralph-fork/$name/state.json" 2>/dev/null || echo "NO_STATE"
}

write_aeos_policy() {
  local dir="$1" model_json="$2" effort_json="$3"
  mkdir -p "$dir/_project"
  jq -n --argjson model "$model_json" --argjson effort "$effort_json" \
    '{"model_policy": {"implementation": ({} + (if $model != null then {model:$model} else {} end) + (if $effort != null then {effort:$effort} else {} end))}}' \
    > "$dir/_project/project-settings.json"
}

write_project_config() {
  local dir="$1" json="$2"
  mkdir -p "$dir/.claude/ralph-fork"
  printf '%s' "$json" > "$dir/.claude/ralph-fork/config.json"
}

write_user_config() {
  local json="$1"
  mkdir -p "$FAKE_HOME/.claude/ralph-fork"
  printf '%s' "$json" > "$FAKE_HOME/.claude/ralph-fork/config.json"
}

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}P3: built-in default, zero config anywhere${NC}"
D=$(new_project p3)
run_setup "$D" p3loop >/dev/null 2>&1
M=$(state_field "$D" p3loop model); E=$(state_field "$D" p3loop effort)
MS=$(state_field "$D" p3loop model_source); ES=$(state_field "$D" p3loop effort_source)
if [[ "$M" == "sonnet" && "$E" == "medium" && "$MS" == "default" && "$ES" == "default" ]]; then
  pass "P3 default: sonnet/medium, sources=default/default"
else
  fail "P3 default" "sonnet/medium default/default" "$M/$E $MS/$ES"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}P2 user config: used when no flag/AEOS/project-config${NC}"
D=$(new_project p2user)
write_user_config '{"model":"haiku","effort":"low"}'
run_setup "$D" p2uloop >/dev/null 2>&1
M=$(state_field "$D" p2uloop model); E=$(state_field "$D" p2uloop effort)
MS=$(state_field "$D" p2uloop model_source); ES=$(state_field "$D" p2uloop effort_source)
if [[ "$M" == "haiku" && "$E" == "low" && "$MS" == "config:user" && "$ES" == "config:user" ]]; then
  pass "P2 user config used, source=config:user"
else
  fail "P2 user config" "haiku/low config:user/config:user" "$M/$E $MS/$ES"
fi
rm -f "$FAKE_HOME/.claude/ralph-fork/config.json"

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}P2 project config: wins over user config${NC}"
D=$(new_project p2project)
write_user_config '{"model":"haiku","effort":"low"}'
write_project_config "$D" '{"model":"opus","effort":"xhigh"}'
run_setup "$D" p2ploop >/dev/null 2>&1
M=$(state_field "$D" p2ploop model); E=$(state_field "$D" p2ploop effort)
MS=$(state_field "$D" p2ploop model_source)
if [[ "$M" == "opus" && "$E" == "xhigh" && "$MS" == "config:project" ]]; then
  pass "P2 project config wins over user config"
else
  fail "P2 project wins over user" "opus/xhigh config:project" "$M/$E $MS"
fi
rm -f "$FAKE_HOME/.claude/ralph-fork/config.json"

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}P1 AEOS: wins over P2 config${NC}"
D=$(new_project p1aeos)
write_project_config "$D" '{"model":"opus","effort":"xhigh"}'
write_aeos_policy "$D" '"sonnet"' '"medium"'
run_setup "$D" p1loop >/dev/null 2>&1
M=$(state_field "$D" p1loop model); E=$(state_field "$D" p1loop effort)
MS=$(state_field "$D" p1loop model_source); ES=$(state_field "$D" p1loop effort_source)
if [[ "$M" == "sonnet" && "$E" == "medium" && "$MS" == "aeos:model_policy.implementation" && "$ES" == "aeos:model_policy.implementation" ]]; then
  pass "P1 AEOS wins over P2 config, source=aeos:model_policy.implementation"
else
  fail "P1 AEOS wins" "sonnet/medium aeos:.../aeos:..." "$M/$E $MS/$ES"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}P0 explicit flag: wins over AEOS${NC}"
D=$(new_project p0flag)
write_aeos_policy "$D" '"sonnet"' '"medium"'
run_setup "$D" p0loop --model opus --effort high >/dev/null 2>&1
M=$(state_field "$D" p0loop model); E=$(state_field "$D" p0loop effort)
MS=$(state_field "$D" p0loop model_source); ES=$(state_field "$D" p0loop effort_source)
if [[ "$M" == "opus" && "$E" == "high" && "$MS" == "flag" && "$ES" == "flag" ]]; then
  pass "P0 explicit --model/--effort wins over AEOS, source=flag"
else
  fail "P0 flag wins over AEOS" "opus/high flag/flag" "$M/$E $MS/$ES"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Independent resolution: AEOS sets model only, effort falls to project config${NC}"
D=$(new_project independent)
write_project_config "$D" '{"effort":"xhigh"}'
write_aeos_policy "$D" '"opus"' 'null'
run_setup "$D" indeploop >/dev/null 2>&1
M=$(state_field "$D" indeploop model); E=$(state_field "$D" indeploop effort)
MS=$(state_field "$D" indeploop model_source); ES=$(state_field "$D" indeploop effort_source)
if [[ "$M" == "opus" && "$MS" == "aeos:model_policy.implementation" && "$E" == "xhigh" && "$ES" == "config:project" ]]; then
  pass "Model/effort resolve independently across layers (AEOS model-only + project-config effort)"
else
  fail "Independent resolution" "opus(aeos)/xhigh(config:project)" "$M($MS)/$E($ES)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Un-seeded AEOS: project-settings.json present, no model_policy key -> inert, no warning${NC}"
D=$(new_project unseeded)
mkdir -p "$D/_project"
echo '{}' > "$D/_project/project-settings.json"
OUT=$(run_setup "$D" unseededloop 2>&1)
M=$(state_field "$D" unseededloop model); E=$(state_field "$D" unseededloop effort)
if [[ "$M" == "sonnet" && "$E" == "medium" ]] && ! grep -q "⚠️" <<< "$OUT"; then
  pass "Un-seeded AEOS file is inert (falls to default, no warning)"
else
  fail "Un-seeded AEOS inert" "sonnet/medium, no ⚠️ warning" "$M/$E, out=$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Invalid AEOS model value -> loud warning, falls through to default${NC}"
D=$(new_project invalidaeos)
write_aeos_policy "$D" '"bad model!!"' 'null'
OUT=$(run_setup "$D" invalidloop 2>&1)
M=$(state_field "$D" invalidloop model)
if [[ "$M" == "sonnet" ]] && grep -qi "⚠️" <<< "$OUT" && grep -qi "invalid" <<< "$OUT"; then
  pass "Invalid AEOS model warns loudly and falls through to default"
else
  fail "Invalid AEOS model falls through" "sonnet + warning" "$M, out=$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Invalid project-config effort value -> loud warning, falls through to default${NC}"
D=$(new_project invalidcfg)
write_project_config "$D" '{"effort":"turbo"}'
OUT=$(run_setup "$D" invalidcfgloop 2>&1)
E=$(state_field "$D" invalidcfgloop effort)
if [[ "$E" == "medium" ]] && grep -qi "⚠️" <<< "$OUT" && grep -qi "invalid" <<< "$OUT"; then
  pass "Invalid project-config effort warns loudly and falls through to default"
else
  fail "Invalid project-config effort falls through" "medium + warning" "$E, out=$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Dated model id in AEOS -> honored, but with a dedicated warning${NC}"
D=$(new_project dated)
write_aeos_policy "$D" '"claude-sonnet-4-20250514"' 'null'
OUT=$(run_setup "$D" datedloop 2>&1)
M=$(state_field "$D" datedloop model)
if [[ "$M" == "claude-sonnet-4-20250514" ]] && grep -qi "dated version" <<< "$OUT"; then
  pass "Dated model id honored with a dedicated warning"
else
  fail "Dated model id honored + warned" "claude-sonnet-4-20250514 + 'dated version' warning" "$M, out=$OUT"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Malformed JSON in AEOS file -> loud warning, resolution continues, loop still starts${NC}"
D=$(new_project malformed)
mkdir -p "$D/_project"
echo '{not valid json' > "$D/_project/project-settings.json"
OUT=$(run_setup "$D" malformedloop 2>&1)
RC=$?
M=$(state_field "$D" malformedloop model)
if [[ $RC -eq 0 && "$M" == "sonnet" ]]; then
  pass "Malformed AEOS JSON does not block the loop (fail-open to default)"
else
  fail "Malformed AEOS JSON fail-open" "rc=0, model=sonnet" "rc=$RC, model=$M"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Standalone regression: no AEOS/config files anywhere -> byte-identical default behavior${NC}"
D=$(new_project standalone)
run_setup "$D" standaloneloop >/dev/null 2>&1
M=$(state_field "$D" standaloneloop model); E=$(state_field "$D" standaloneloop effort)
if [[ "$M" == "sonnet" && "$E" == "medium" ]]; then
  pass "Standalone regression: sonnet/medium with nothing configured"
else
  fail "Standalone regression" "sonnet/medium" "$M/$E"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}config.json does not collide with the loop-dir glob (*/state.json)${NC}"
D=$(new_project collision)
write_project_config "$D" '{"model":"opus"}'
run_setup "$D" collisionloop >/dev/null 2>&1
LOOP_LIST_OUT=$( (cd "$D" && bash "$CANCEL_SCRIPT" --list 2>&1) )
if grep -q "collisionloop" <<< "$LOOP_LIST_OUT" && ! grep -q "config.json\|config\b" <<< "$LOOP_LIST_OUT"; then
  pass "config.json is not enumerated as a loop by cancel --list (no glob collision)"
else
  fail "config.json glob non-collision" "collisionloop listed, no 'config' entry" "$LOOP_LIST_OUT"
fi

echo ""
echo "========================================"
echo "Test Results"
echo "========================================"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
echo -e "${RED}Failed: $TESTS_FAILED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
fi
echo -e "${GREEN}All tests passed!${NC}"
exit 0
