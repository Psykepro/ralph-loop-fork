#!/bin/bash

# Cancel Ralph Loop Fork
# Supports three modes:
#   --list                List all active loops (read-only)
#   <LOOP_ID>             Cancel a specific loop (kill tmux sessions + remove state dir)
#   --all                 Cancel every loop (kill tmux sessions + remove all state dirs,
#                         preserving the .archive/ directory)
#
# Robustness:
# - Tolerates missing tmux (warns, continues)
# - Tolerates missing jq (falls back to `tmux ls | grep` for session names)
# - Tolerates already-dead sessions
# - Never aborts on a failed kill-session

# NOTE: -e intentionally NOT enabled. kill-session can legitimately fail
# (session already dead) and we must continue.
set -uo pipefail

RALPH_FORK_DIR=".claude/ralph-fork"
ARCHIVE_DIR_NAME=".archive"

# ============================================================================
# Dependency checks (soft — we degrade gracefully)
# ============================================================================
HAS_TMUX=true
if ! command -v tmux >/dev/null 2>&1; then
  HAS_TMUX=false
  echo "Warning: tmux not found - skipping tmux session cleanup" >&2
fi

HAS_JQ=true
if ! command -v jq >/dev/null 2>&1; then
  HAS_JQ=false
  echo "Warning: jq not found - using tmux-only fallback for session discovery" >&2
fi

# ============================================================================
# Helpers
# ============================================================================

# Kill a single tmux session if it exists. Never fails the script.
kill_tmux_session() {
  local session_name="$1"

  if [[ -z "$session_name" ]] || [[ "$session_name" == "null" ]]; then
    return 0
  fi

  if [[ "$HAS_TMUX" != "true" ]]; then
    return 0
  fi

  if tmux kill-session -t "$session_name" 2>/dev/null; then
    echo "  Killed tmux session: $session_name"
  fi
}

# Collect tmux session names to kill for a given loop.
# Priority:
#   1) state.json .spawned_sessions[].name + .original_session_name (if jq + state.json)
#   2) fallback: `tmux ls | grep "^ralph-<LOOP_ID>-"`
# Outputs newline-separated, deduped, non-empty session names.
collect_sessions_for_loop() {
  local loop_id="$1"
  local state_file="$RALPH_FORK_DIR/$loop_id/state.json"
  local sessions=""

  if [[ "$HAS_JQ" == "true" ]] && [[ -f "$state_file" ]]; then
    local spawned
    spawned=$(jq -r '.spawned_sessions[]?.name // empty' "$state_file" 2>/dev/null || true)
    local original
    original=$(jq -r '.original_session_name // empty' "$state_file" 2>/dev/null || true)

    if [[ -n "$spawned" ]]; then
      sessions="$spawned"
    fi
    if [[ -n "$original" ]] && [[ "$original" != "null" ]]; then
      if [[ -n "$sessions" ]]; then
        sessions="$sessions
$original"
      else
        sessions="$original"
      fi
    fi
  fi

  # Always also include anything matching the naming convention from `tmux ls`
  # (covers cases where state.json is missing/corrupt and is a cheap belt-and-braces).
  if [[ "$HAS_TMUX" == "true" ]]; then
    local from_tmux
    from_tmux=$(tmux ls -F '#S' 2>/dev/null | grep "^ralph-${loop_id}-" || true)
    if [[ -n "$from_tmux" ]]; then
      if [[ -n "$sessions" ]]; then
        sessions="$sessions
$from_tmux"
      else
        sessions="$from_tmux"
      fi
    fi
  fi

  # Deduplicate, strip empties.
  if [[ -n "$sessions" ]]; then
    printf '%s\n' "$sessions" | awk 'NF && !seen[$0]++'
  fi
}

# Print a one-line summary of a loop directory.
print_loop_summary() {
  local loop_id="$1"
  local state_file="$RALPH_FORK_DIR/$loop_id/state.json"

  if [[ "$HAS_JQ" == "true" ]] && [[ -f "$state_file" ]]; then
    local active sessions iterations budget
    active=$(jq -r '.active // false' "$state_file" 2>/dev/null || echo "unknown")
    sessions=$(jq -r '.session_number // 0' "$state_file" 2>/dev/null || echo "0")
    iterations=$(jq -r '.total_iterations // 0' "$state_file" 2>/dev/null || echo "0")
    budget=$(jq -r '.total_budget // 0' "$state_file" 2>/dev/null || echo "0")
    echo "  $loop_id: active=$active, sessions=$sessions, iterations=$iterations/$budget"
  else
    echo "  $loop_id: (state.json unreadable)"
  fi
}

# Cancel one loop: kill its tmux sessions, then remove its state dir.
cancel_loop() {
  local loop_id="$1"
  local loop_dir="$RALPH_FORK_DIR/$loop_id"

  if [[ ! -d "$loop_dir" ]]; then
    echo "Error: Loop not found: $loop_id" >&2
    return 1
  fi

  echo "Cancelling loop: $loop_id"
  print_loop_summary "$loop_id"

  # IMPORTANT ORDER OF OPERATIONS:
  # 1. Collect session names into a variable FIRST (while state.json is intact).
  # 2. Remove the state directory NEXT, so a failure mid-cleanup (e.g. our own
  #    shell getting SIGHUP'd because we kill its host tmux session) still
  #    leaves the loop fully cancelled from the user's point of view.
  # 3. Kill tmux sessions LAST. We may kill our own host session — that's fine;
  #    by then the durable cleanup is already done.
  local sessions
  sessions=$(collect_sessions_for_loop "$loop_id")

  if [[ -n "$loop_id" ]] && [[ -d "$loop_dir" ]]; then
    rm -rf -- "$loop_dir"
    echo "  Removed state directory: $loop_dir"
  fi

  if [[ -n "$sessions" ]]; then
    while IFS= read -r session_name; do
      kill_tmux_session "$session_name"
    done <<< "$sessions"
  else
    echo "  No tmux sessions found to kill."
  fi

  return 0
}

# ============================================================================
# Mode dispatch
# ============================================================================
MODE="${1:-}"

case "$MODE" in
  ""|--list|-l)
    # ----- LIST MODE (read-only) -----
    if [[ ! -d "$RALPH_FORK_DIR" ]]; then
      echo "No active Ralph Loop Fork sessions."
      exit 0
    fi

    echo "Active Ralph Loop Fork sessions:"
    found_any=false
    for dir in "$RALPH_FORK_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      loop_id=$(basename "$dir")
      # Skip the archive directory if present
      if [[ "$loop_id" == "$ARCHIVE_DIR_NAME" ]]; then
        continue
      fi
      print_loop_summary "$loop_id"
      found_any=true
    done

    if [[ "$found_any" == "false" ]]; then
      echo "  (none)"
    fi
    exit 0
    ;;

  --all|-a)
    # ----- CANCEL ALL -----
    if [[ ! -d "$RALPH_FORK_DIR" ]]; then
      echo "No active Ralph Loop Fork sessions."
      exit 0
    fi

    cancelled=0
    for dir in "$RALPH_FORK_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      loop_id=$(basename "$dir")
      # IMPORTANT: never touch the .archive/ directory
      if [[ "$loop_id" == "$ARCHIVE_DIR_NAME" ]]; then
        continue
      fi
      cancel_loop "$loop_id" || true
      cancelled=$((cancelled + 1))
      echo ""
    done

    echo "Cancelled $cancelled loop(s). Archive directory preserved."
    exit 0
    ;;

  -h|--help)
    cat <<'HELP_EOF'
Cancel Ralph Loop Fork

Usage:
  /ralph-loop-fork:cancel-ralph-fork --list      List all active loops (read-only)
  /ralph-loop-fork:cancel-ralph-fork LOOP_ID     Cancel a specific loop
  /ralph-loop-fork:cancel-ralph-fork --all       Cancel all loops

Cancelling a loop:
  - Kills every tmux session associated with the loop (spawned sessions and the
    original launcher session) using state.json as the source of truth, with a
    fallback to `tmux ls | grep "^ralph-<LOOP_ID>-"` if state is unreadable.
  - Removes the loop's state directory.
  - The .archive/ directory is preserved (it contains completed loops).
HELP_EOF
    exit 0
    ;;

  --*)
    echo "Error: Unknown option: $MODE" >&2
    echo "Use --list, --all, or pass a LOOP_ID. See --help." >&2
    exit 1
    ;;

  *)
    # ----- CANCEL A SPECIFIC LOOP -----
    LOOP_ID="$MODE"

    # Reject path-traversal / weird input early. (Belt and braces: setup-ralph-loop-fork.sh
    # already sanitizes --name down to [a-z0-9-], so a "bad" LOOP_ID can only get here if
    # someone hand-edited .claude/ralph-fork/. Still cheap to check.)
    if [[ "$LOOP_ID" == *"/"* ]] || [[ "$LOOP_ID" == "." ]] || [[ "$LOOP_ID" == ".." ]] || [[ "$LOOP_ID" == ".."* ]]; then
      echo "Error: Invalid LOOP_ID: $LOOP_ID" >&2
      exit 1
    fi

    if [[ ! -d "$RALPH_FORK_DIR/$LOOP_ID" ]]; then
      echo "Error: Loop not found: $LOOP_ID" >&2
      echo "Run with --list to see active loops." >&2
      exit 1
    fi

    cancel_loop "$LOOP_ID"
    exit 0
    ;;
esac
