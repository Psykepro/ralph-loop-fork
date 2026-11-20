#!/bin/bash
# Unit test for move_checklist_to_done (stop-hook-fork.sh): a flat checklist and a split plan's
# MASTER move to done/; a sub-checklist of a split plan moves nothing (its siblings are still open).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/hooks/stop-hook-fork.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

debug_log() { :; }
info() { :; }
# Load only the helper, not the whole hook (the hook runs on source).
eval "$(sed -n '/^move_checklist_to_done() {$/,/^}$/p' "$HOOK")"
declare -F move_checklist_to_done >/dev/null || { echo "FAIL: helper not found in $HOOK"; exit 1; }

FAILED=0
check() {
  if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; FAILED=$((FAILED + 1)); fi
}

root="$TEST_DIR/progress"
mkdir -p "$root/in-progress/plan-a" "$root/in-progress/plan-b"
printf -- '- [x] a\n' > "$root/in-progress/flat.md"
printf -- '- [x] m\n' > "$root/in-progress/plan-a/MASTER-CHECKLIST.md"
printf -- '- [x] s\n' > "$root/in-progress/plan-b/sub-01-part.md"
printf -- '- [ ] s\n' > "$root/in-progress/plan-b/sub-02-part.md"
printf -- '- [ ] m\n' > "$root/in-progress/plan-b/MASTER-CHECKLIST.md"

move_checklist_to_done "$root/in-progress/flat.md" || true
check "flat checklist moves to done/" '[[ -f "$root/done/flat.md" && ! -e "$root/in-progress/flat.md" ]]'

move_checklist_to_done "$root/in-progress/plan-a/MASTER-CHECKLIST.md" || true
check "split plan MASTER moves the plan folder" '[[ -d "$root/done/plan-a" && ! -e "$root/in-progress/plan-a" ]]'

rc=0
move_checklist_to_done "$root/in-progress/plan-b/sub-01-part.md" || rc=$?
check "sub-checklist leaves the plan folder in place" '[[ -f "$root/in-progress/plan-b/sub-01-part.md" && ! -e "$root/done/plan-b" ]]'
check "sub-checklist returns non-zero (nothing moved)" '[[ $rc -ne 0 ]]'

if [[ $FAILED -eq 0 ]]; then echo "✅ all passed"; else echo "❌ $FAILED failed"; exit 1; fi
