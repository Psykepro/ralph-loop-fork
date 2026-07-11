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

# Resolve the on-disk directory for a loop_id. Looks in the current repo's
# .claude/ralph-fork/ first; if not found, walks every git worktree and
# returns the first match. Prints the resolved path, or empty if not found.
resolve_loop_dir() {
  local loop_id="$1"

  if [[ -d "$RALPH_FORK_DIR/$loop_id" ]]; then
    printf '%s\n' "$RALPH_FORK_DIR/$loop_id"
    return 0
  fi

  # Worktree fallback: --worktree mode moves the state dir into the worktree.
  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      if [[ -d "$wt/.claude/ralph-fork/$loop_id" ]]; then
        printf '%s\n' "$wt/.claude/ralph-fork/$loop_id"
        return 0
      fi
    done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  fi

  return 0
}

# Enumerate every loop_id known to this repo: every direct child of
# .claude/ralph-fork/ in the current dir AND in every linked worktree.
# Outputs newline-separated, deduped loop_ids (excluding the archive dir).
enumerate_all_loop_ids() {
  local out=""

  if [[ -d "$RALPH_FORK_DIR" ]]; then
    for dir in "$RALPH_FORK_DIR"/*/; do
      [[ -d "$dir" ]] || continue
      local name
      name=$(basename "$dir")
      [[ "$name" == "$ARCHIVE_DIR_NAME" ]] && continue
      out+="$name"$'\n'
    done
  fi

  if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r wt; do
      [[ -z "$wt" ]] && continue
      [[ "$wt" == "$(pwd)" ]] && continue
      local wt_ralph="$wt/.claude/ralph-fork"
      [[ -d "$wt_ralph" ]] || continue
      for dir in "$wt_ralph"/*/; do
        [[ -d "$dir" ]] || continue
        local name
        name=$(basename "$dir")
        [[ "$name" == "$ARCHIVE_DIR_NAME" ]] && continue
        out+="$name"$'\n'
      done
    done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}')
  fi

  if [[ -n "$out" ]]; then
    printf '%s' "$out" | awk 'NF && !seen[$0]++'
  fi
}

# Kill a single tmux session if it exists. Never fails the script.
kill_tmux_session() {
  local session_name="$1"

  if [[ -z "$session_name" ]] || [[ "$session_name" == "null" ]]; then
    return 0
  fi

  if [[ "$HAS_TMUX" != "true" ]]; then
    return 0
  fi

  if tmux kill-session -t "=$session_name" 2>/dev/null; then
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
  local loop_dir
  loop_dir=$(resolve_loop_dir "$loop_id")
  local state_file=""
  if [[ -n "$loop_dir" ]]; then
    state_file="$loop_dir/state.json"
  fi
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
  local loop_dir
  loop_dir=$(resolve_loop_dir "$loop_id")
  local state_file=""
  if [[ -n "$loop_dir" ]]; then
    state_file="$loop_dir/state.json"
  fi

  if [[ "$HAS_JQ" == "true" ]] && [[ -f "$state_file" ]]; then
    local active sessions iterations budget worktree
    active=$(jq -r '.active // false' "$state_file" 2>/dev/null || echo "unknown")
    sessions=$(jq -r '.session_number // 0' "$state_file" 2>/dev/null || echo "0")
    iterations=$(jq -r '.total_iterations // 0' "$state_file" 2>/dev/null || echo "0")
    budget=$(jq -r '.total_budget // 0' "$state_file" 2>/dev/null || echo "0")
    worktree=$(jq -r '.worktree_path // empty' "$state_file" 2>/dev/null || echo "")
    if [[ -n "$worktree" ]]; then
      echo "  $loop_id: active=$active, sessions=$sessions, iterations=$iterations/$budget, worktree=$worktree"
    else
      echo "  $loop_id: active=$active, sessions=$sessions, iterations=$iterations/$budget"
    fi
  else
    echo "  $loop_id: (state.json unreadable)"
  fi
}

# Cancel one loop: kill its tmux sessions, then remove its state dir.
cancel_loop() {
  local loop_id="$1"
  local loop_dir
  loop_dir=$(resolve_loop_dir "$loop_id")

  if [[ -z "$loop_dir" ]] || [[ ! -d "$loop_dir" ]]; then
    echo "Error: Loop not found: $loop_id" >&2
    return 1
  fi

  echo "Cancelling loop: $loop_id"
  print_loop_summary "$loop_id"

  # IMPORTANT ORDER OF OPERATIONS:
  # 1. Snapshot info we need AFTER state.json is gone (sessions, worktree_path).
  # 2. Remove the state directory NEXT, so a failure mid-cleanup (e.g. our own
  #    shell getting SIGHUP'd because we kill its host tmux session) still
  #    leaves the loop fully cancelled from the user's point of view.
  # 3. Kill tmux sessions LAST. We may kill our own host session — that's fine;
  #    by then the durable cleanup is already done.
  # 4. Print worktree cleanup hint AFTER kill (the worktree dir itself is left
  #    in place so the user can inspect it before removing).
  local sessions worktree_path
  sessions=$(collect_sessions_for_loop "$loop_id")

  worktree_path=""
  local state_file="$loop_dir/state.json"
  if [[ "$HAS_JQ" == "true" ]] && [[ -f "$state_file" ]]; then
    worktree_path=$(jq -r '.worktree_path // empty' "$state_file" 2>/dev/null || true)
  fi

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

  # Worktree cleanup hint (worktree itself is NOT auto-removed — user may want
  # to inspect or merge before discarding).
  if [[ -n "$worktree_path" ]]; then
    if [[ -d "$worktree_path" ]]; then
      local branch
      branch=""
      if command -v git >/dev/null 2>&1; then
        branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
      fi
      echo ""
      echo "Worktree detected at: $worktree_path${branch:+ (branch: $branch)}"
      echo "To merge and remove:"
      if [[ -n "$branch" ]]; then
        echo "  git merge $branch"
        echo "  git worktree remove $worktree_path"
        echo "  git branch -D $branch"
      else
        echo "  git worktree remove $worktree_path"
      fi
    else
      # Worktree dir was manually removed but the branch may still exist.
      # Surface a hint so the user can clean up the leftover branch.
      local guessed_branch="ralph/$loop_id"
      if command -v git >/dev/null 2>&1 && git rev-parse --verify "refs/heads/$guessed_branch" >/dev/null 2>&1; then
        echo ""
        echo "Worktree directory $worktree_path no longer exists."
        echo "Branch $guessed_branch still exists. To remove:"
        echo "  git worktree prune"
        echo "  git branch -D $guessed_branch"
      fi
    fi
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
    echo "Active Ralph Loop Fork sessions:"
    found_any=false
    while IFS= read -r loop_id; do
      [[ -z "$loop_id" ]] && continue
      print_loop_summary "$loop_id"
      found_any=true
    done < <(enumerate_all_loop_ids)

    if [[ "$found_any" == "false" ]]; then
      echo "  (none)"
    fi
    exit 0
    ;;

  --all|-a)
    # ----- CANCEL ALL -----
    cancelled=0
    while IFS= read -r loop_id; do
      [[ -z "$loop_id" ]] && continue
      cancel_loop "$loop_id" || true
      cancelled=$((cancelled + 1))
      echo ""
    done < <(enumerate_all_loop_ids)

    if [[ "$cancelled" -eq 0 ]]; then
      echo "No active Ralph Loop Fork sessions."
    else
      echo "Cancelled $cancelled loop(s). Archive directory preserved."
    fi
    exit 0
    ;;

  --stuck|--all-stuck)
    # ----- CANCEL STUCK LOOPS (active=true + executing_on_completion=true OR awaiting_confirmation=true) -----
    if [[ "$HAS_JQ" != "true" ]]; then
      echo "Error: jq is required for --all-stuck mode" >&2
      exit 1
    fi

    cleaned=0
    stuck_loop_dir=""
    stuck_state_file=""
    stuck_active=""
    stuck_eoc=""
    stuck_ac=""
    stuck_now=""
    while IFS= read -r loop_id; do
      [[ -z "$loop_id" ]] && continue
      stuck_loop_dir=$(resolve_loop_dir "$loop_id")
      [[ -z "$stuck_loop_dir" ]] && continue
      stuck_state_file="$stuck_loop_dir/state.json"
      [[ -f "$stuck_state_file" ]] || continue

      stuck_active=$(jq -r '.active // false' "$stuck_state_file" 2>/dev/null || echo "false")
      stuck_eoc=$(jq -r '.executing_on_completion // false' "$stuck_state_file" 2>/dev/null || echo "false")
      stuck_ac=$(jq -r '.awaiting_confirmation // false' "$stuck_state_file" 2>/dev/null || echo "false")

      if [[ "$stuck_active" == "true" ]] && [[ "$stuck_eoc" == "true" || "$stuck_ac" == "true" ]]; then
        echo "Found stuck loop: $loop_id (active=true, executing_on_completion=$stuck_eoc, awaiting_confirmation=$stuck_ac)"

        # Write cancellation state before removing directory
        stuck_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if jq --arg ts "$stuck_now" \
          '.active = false | .completed_at = $ts | .termination_reason = "user_cancelled_stuck"' \
          "$stuck_state_file" > "${stuck_state_file}.tmp" 2>/dev/null; then
          mv "${stuck_state_file}.tmp" "$stuck_state_file"
        else
          rm -f "${stuck_state_file}.tmp"
          echo "  Warning: failed to write termination state for $loop_id — cancelling anyway" >&2
        fi

        cancel_loop "$loop_id" || true
        cleaned=$((cleaned + 1))
        echo ""
      fi
    done < <(enumerate_all_loop_ids)

    if [[ "$cleaned" -eq 0 ]]; then
      echo "No stuck loops found."
    else
      echo "Cleaned $cleaned stuck loop(s)."
    fi
    exit 0
    ;;

  -h|--help)
    cat <<'HELP_EOF'
Cancel Ralph Loop Fork

Usage:
  /ralph-loop-fork:cancel-ralph-fork --list        List all loops (read-only)
  /ralph-loop-fork:cancel-ralph-fork LOOP_ID       Cancel a specific loop
  /ralph-loop-fork:cancel-ralph-fork --all         Cancel all loops
  /ralph-loop-fork:cancel-ralph-fork --all-stuck   Cancel stuck loops only
  /ralph-loop-fork:cancel-ralph-fork --stuck       Alias for --all-stuck

Cancelling a loop:
  - Kills every tmux session associated with the loop (spawned sessions and the
    original launcher session) using state.json as the source of truth, with a
    fallback to `tmux ls | grep "^ralph-<LOOP_ID>-"` if state is unreadable.
  - Removes the loop's state directory.
  - The .archive/ directory is preserved (it contains completed loops).

--all-stuck / --stuck:
  Targets only loops where active=true AND (executing_on_completion=true OR
  awaiting_confirmation=true). These are loops whose continuation cycle never
  fired (e.g., the terminal was closed mid-BLOCK). Requires jq.
  Writes termination_reason="user_cancelled_stuck" before removing state.
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

    RESOLVED=$(resolve_loop_dir "$LOOP_ID")
    if [[ -z "$RESOLVED" ]] || [[ ! -d "$RESOLVED" ]]; then
      echo "Error: Loop not found: $LOOP_ID" >&2
      echo "Run with --list to see active loops." >&2
      exit 1
    fi

    cancel_loop "$LOOP_ID"
    exit 0
    ;;
esac
