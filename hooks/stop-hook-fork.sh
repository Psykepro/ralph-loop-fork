#!/bin/bash

# Ralph Loop Fork Stop Hook - State Machine Implementation (FIXED)
# FIXED: All informational messages go to stderr, only JSON goes to stdout
#
# On stop event, FORKS to a new terminal session instead of re-feeding prompt
# This maximizes context window by starting fresh each iteration
#
# STATE MACHINE:
# - RUNNING (default): Check for promise, decide next state
# - AWAITING_CHECKLIST_UPDATE: LLM updated checklist, spawn new session
# - AWAITING_CONFIRMATION: LLM confirmed, verify boxes, trigger on-completion or spawn
# - EXECUTING_ON_COMPLETION: On-completion was sent, cleanup and exit
# - COMPLETED / BUDGET_EXHAUSTED: Terminal states
#
# TRANSITIONS:
# RUNNING + no promise → AWAITING_CHECKLIST_UPDATE (BLOCK: update checklist)
# RUNNING + promise → AWAITING_CONFIRMATION (BLOCK: confirm 100%)
# AWAITING_CHECKLIST_UPDATE + next hook → spawn + RUNNING
# AWAITING_CONFIRMATION + confirmed + boxes ok → EXECUTING_ON_COMPLETION (BLOCK: slash cmd)
# AWAITING_CONFIRMATION + confirmed + boxes bad → spawn + RUNNING
# AWAITING_CONFIRMATION + no confirmed → spawn + RUNNING
# EXECUTING_ON_COMPLETION + next hook → COMPLETED (cleanup + exit)
# any + budget exhausted → BUDGET_EXHAUSTED (cleanup + exit)

# NOTE: -e intentionally NOT enabled. Non-zero exits occur in normal operation
# (jq fallbacks, grep with no match, perl, spawn helpers) and must not abort
# the hook. Any genuinely fatal condition must exit explicitly.
set -uo pipefail

# ============================================================================
# HELPER: Output to stderr (for informational messages)
# ============================================================================
info() {
  echo "$@" >&2
}

# ============================================================================
# LOG ROTATION
# ============================================================================
LOG_RETENTION_DAYS="${RALPH_LOG_RETENTION_DAYS:-90}"
# Log directory is configurable via RALPH_FORK_LOG_DIR; defaults to
# ${TMPDIR:-/tmp}/ralph-fork-logs for portability across macOS and Linux.
LOG_DIR="${RALPH_FORK_LOG_DIR:-${TMPDIR:-/tmp}/ralph-fork-logs}"

get_log_file() {
  mkdir -p "$LOG_DIR"
  echo "$LOG_DIR/ralph-fork-$(date +%Y-%m-%d).log"
}

rotate_logs() {
  if [[ -d "$LOG_DIR" ]]; then
    find "$LOG_DIR" -name "ralph-fork-*.log" -type f -mtime +$LOG_RETENTION_DAYS -delete 2>/dev/null || true
  fi
}

DEBUG_LOG=$(get_log_file)
rotate_logs

debug_log() {
  echo "[$(date -Iseconds)] $1" >> "$DEBUG_LOG"
}

# ============================================================================
# SIGNAL BUS EMISSION (self-improving-os WP-03)
# Appends one row to $PROJECT_ROOT/_project/signals/events.jsonl — schema is
# SSOT'd at _project/rules/signals-protocol/signals-protocol.md. Fail-open +
# only when the dir exists: the plugin must behave byte-identically in
# non-AEOS repos (no _project/signals/ dir → no-op, same as the AEOS config
# sentinel pattern used elsewhere in this file). Mirrors aeos-watch.py's own
# append_event() write shape exactly (single "a"-mode write() call = one
# O_APPEND-atomic line, per the multi-writer discipline the schema mandates)
# so both writers stay byte-compatible without sharing code across repos.
# Called only from PROJECT_ROOT/LOOP_ID being already resolved.
# ============================================================================
emit_signal() {
  local kind="$1" payload_json="${2:-{\}}"
  local signals_dir="$PROJECT_ROOT/_project/signals"
  [[ -d "$signals_dir" ]] || return 0
  python3 -c '
import json, sys
from datetime import datetime, timezone

kind, session, payload_json, events_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
try:
    payload = json.loads(payload_json)
except json.JSONDecodeError:
    payload = {}
row = {
    "ts": datetime.now(timezone.utc).isoformat(),
    "kind": kind, "source": "ralph-loop-fork", "session": session,
    "payload": payload,
}
try:
    with open(events_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row) + "\n")
except OSError:
    pass
' "$kind" "$LOOP_ID" "$payload_json" "$signals_dir/events.jsonl" 2>/dev/null || true
}

# ============================================================================
# TERMINAL NOTIFICATION (self-improving-os WP-03)
# Builds an OSC 777 escape sequence for the harness-native `terminalSequence`
# hook JSON output field (urxvt/Ghostty/Warp desktop notification; verified
# against the Claude Code hooks reference — allowlisted escape, terminated
# with BEL). Call sites print `{"terminalSequence": "<seq>"}` to stdout
# themselves (kept one line, no extra helper, per spec constraint 9's DRY
# split — aeos_notify.py in the main AEOS repo owns the richer notify path).
# ============================================================================
build_terminal_sequence() {
  local title="$1" body="$2"
  printf '\033]777;notify;%s;%s\007' "$title" "$body"
}

# ============================================================================
# CHECKLIST COUNTING FUNCTION
# ============================================================================
count_checklist_items() {
  local checklist_file="$1"

  if [[ ! -f "$checklist_file" ]]; then
    echo "0:0"
    return 1
  fi

  local unchecked
  unchecked=$(grep -c '^\s*-\s*\[ \]' "$checklist_file" 2>/dev/null) || true
  unchecked="${unchecked:-0}"

  local checked
  checked=$(grep -c '^\s*-\s*\[[xX]\]' "$checklist_file" 2>/dev/null) || true
  checked="${checked:-0}"

  echo "$unchecked:$checked"
}

# ============================================================================
# GIT DIRTY CHECK FOR CHECKLIST FILE
# Returns 0 (true) if the checklist file has uncommitted git changes.
# Returns 1 (false) if git is unavailable, not a git repo, or file is clean.
# ============================================================================
checklist_is_git_dirty() {
  local file="$1"
  [[ -z "$file" ]] && return 1
  [[ ! -f "$file" ]] && return 1
  command -v git >/dev/null 2>&1 || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  local status
  status=$(git status --porcelain -- "$file" 2>/dev/null) || return 1
  [[ -n "$status" ]]
}

# ============================================================================
# READ CHECKLIST CONTENT HELPER
# ============================================================================
read_checklist_content() {
  local checklist_file="$1"

  if [[ ! -f "$checklist_file" ]]; then
    echo "[Checklist file not found: $checklist_file]"
    return 1
  fi

  cat "$checklist_file"
}

# ============================================================================
# MOVE CHECKLIST TO done/ HELPER (project-convention helper, safe no-op otherwise)
# ============================================================================
# If the checklist lives at <somewhere>/in-progress/foo.md or
# <somewhere>/in-progress/foo/MASTER.md it is moved to a sibling done/ dir on
# completion. For projects that don't use this in-progress/ + done/ layout the
# function silently returns 1 and the loop completes normally.
move_checklist_to_done() {
  local checklist_path="$1"

  if [[ -z "$checklist_path" ]] || [[ ! -e "$checklist_path" ]]; then
    debug_log "move_checklist_to_done: No valid checklist path: $checklist_path"
    return 1
  fi

  local parent_dir
  parent_dir=$(dirname "$checklist_path")
  local parent_name
  parent_name=$(basename "$parent_dir")
  local grandparent_dir
  grandparent_dir=$(dirname "$parent_dir")
  local grandparent_name
  grandparent_name=$(basename "$grandparent_dir")

  local source_path=""
  local done_dir=""

  if [[ "$parent_name" == "in-progress" ]]; then
    # Single file: checklists/in-progress/feature-foo.md
    source_path="$checklist_path"
    done_dir="$parent_dir/../done"
    debug_log "move_checklist_to_done: Single file detected: $source_path"
  elif [[ "$grandparent_name" == "in-progress" ]]; then
    # Split-plan directory: checklists/in-progress/feature-foo/MASTER.md
    source_path="$parent_dir"
    done_dir="$grandparent_dir/../done"
    debug_log "move_checklist_to_done: Split-plan directory detected: $source_path"
  else
    debug_log "move_checklist_to_done: Checklist not under in-progress/ - skipping (parent=$parent_name, grandparent=$grandparent_name)"
    return 1
  fi

  # Create done/ directory and resolve to absolute path
  mkdir -p "$done_dir" 2>/dev/null
  done_dir=$(cd "$done_dir" 2>/dev/null && pwd)

  if [[ -z "$done_dir" ]]; then
    debug_log "move_checklist_to_done: Failed to create/resolve done/ directory"
    return 1
  fi

  local dest_path="$done_dir/$(basename "$source_path")"

  if mv "$source_path" "$dest_path" 2>/dev/null; then
    debug_log "move_checklist_to_done: Moved $source_path → $dest_path"
    info "   Moved checklist to done/: $(basename "$source_path")"
    return 0
  else
    debug_log "move_checklist_to_done: Failed to move $source_path → $dest_path"
    return 1
  fi
}

# ============================================================================
# STATE UPDATE HELPER
# ============================================================================
update_state() {
  local state_file="$1"
  local jq_filter="$2"

  if [[ ! -f "$state_file" ]]; then
    debug_log "Warning: Cannot update state - file not found: $state_file"
    return 1
  fi

  if jq "$jq_filter" "$state_file" > "${state_file}.tmp" 2>/dev/null; then
    mv "${state_file}.tmp" "$state_file"
    debug_log "State updated: $jq_filter"
    return 0
  else
    rm -f "${state_file}.tmp"
    debug_log "Warning: Failed to update state with: $jq_filter"
    return 1
  fi
}

# ============================================================================
# CLEANUP CURRENT SESSION - Removes just the current session (before forking)
# ============================================================================
cleanup_current_session() {
  local loop_id="$1"
  local session_number="$2"

  local session_name="ralph-${loop_id}-${session_number}"
  debug_log "Cleaning up current session: $session_name"

  if tmux kill-session -t "=$session_name" 2>/dev/null; then
    info "   Removed previous session: $session_name"
    return 0
  else
    debug_log "Session $session_name not found or already removed"
    return 0
  fi
}

# ============================================================================
# CLEANUP FUNCTION - Uses spawned_sessions array for reliable cleanup
# ============================================================================
cleanup_ralph_sessions() {
  local loop_id="$1"
  local state_file="$2"
  local preserve_final="${3:-false}"
  local no_cleanup="${4:-false}"

  debug_log "cleanup_ralph_sessions called with loop_id=$loop_id, preserve_final=$preserve_final, no_cleanup=$no_cleanup"

  if [[ "$no_cleanup" == "true" ]]; then
    info "Cleanup disabled (--no-cleanup). Sessions preserved for: $loop_id"
    debug_log "no_cleanup=true, skipping cleanup"
    return
  fi

  if [[ ! -f "$state_file" ]]; then
    debug_log "State file not found, returning"
    return
  fi

  info "Cleaning up ralph sessions for loop: $loop_id..."

  # Get spawned session names from state.json
  local session_names
  session_names=$(jq -r '.spawned_sessions[]?.name // empty' "$state_file" 2>/dev/null)
  debug_log "Sessions to cleanup: $session_names"

  # Read original session name (for single-session completions with no forks)
  local original_session
  original_session=$(jq -r '.original_session_name // empty' "$state_file" 2>/dev/null)
  debug_log "Original session: $original_session"

  # Handle case where no forks occurred (spawned_sessions is empty)
  if [[ -z "$session_names" ]] && [[ -n "$original_session" ]]; then
    if [[ "$preserve_final" == "true" ]]; then
      debug_log "No forks occurred - preserving original session: $original_session"
      info "   Preserving original session: $original_session (--preserve-final-session, no forks)"
    else
      debug_log "No forks occurred - removing original session: $original_session"
      if tmux kill-session -t "=$original_session" 2>/dev/null; then
        info "   Removed original session: $original_session"
        debug_log "Successfully removed original: $original_session"
      else
        debug_log "Failed to remove or not found: $original_session"
      fi
    fi
    info "   Cleanup complete."
    debug_log "cleanup_ralph_sessions finished (no-fork path)"
    return
  fi

  # Get the last session name if we need to preserve it
  local last_session=""
  if [[ "$preserve_final" == "true" ]]; then
    last_session=$(jq -r '.spawned_sessions[-1]?.name // empty' "$state_file" 2>/dev/null)
    debug_log "Preserving final session: $last_session"
    info "   Preserving final session: $last_session (--preserve-final-session)"
  fi

  # Remove each spawned session (except final if preserve_final is true)
  for session_name in $session_names; do
    if [[ -n "$session_name" ]]; then
      if [[ "$preserve_final" == "true" ]] && [[ "$session_name" == "$last_session" ]]; then
        debug_log "Skipping final session: $session_name"
        continue
      fi
      debug_log "Removing session: $session_name"
      if tmux kill-session -t "=$session_name" 2>/dev/null; then
        info "   Removed: $session_name"
        debug_log "Successfully removed: $session_name"
      else
        debug_log "Failed to remove or not found: $session_name"
      fi
    fi
  done

  # Also remove the original session (if not preserved and forks occurred)
  if [[ -n "$original_session" ]] && [[ "$preserve_final" != "true" ]]; then
    debug_log "Removing original session: $original_session"
    if tmux kill-session -t "=$original_session" 2>/dev/null; then
      info "   Removed original: $original_session"
    else
      debug_log "Original session already removed or not found: $original_session"
    fi
  fi

  # Clear the spawned_sessions array after cleanup (keep final if preserved)
  if [[ "$preserve_final" == "true" ]] && [[ -n "$last_session" ]]; then
    update_state "$state_file" ".spawned_sessions = [{\"name\": \"$last_session\", \"preserved\": true}]"
  else
    update_state "$state_file" ".spawned_sessions = []"
  fi

  info "   Cleanup complete."
  debug_log "cleanup_ralph_sessions finished"
}

# ============================================================================
# ARCHIVE FUNCTION
# ============================================================================
archive_loop_directory() {
  local loop_id="$1"
  local loop_dir="$2"

  if [[ ! -d "$loop_dir" ]]; then
    debug_log "Loop directory not found for archival: $loop_dir"
    return 1
  fi

  local archive_dir="$PROJECT_ROOT/.claude/ralph-fork/.archive"
  local timestamp=$(date +%Y%m%d-%H%M%S)
  local archive_path="$archive_dir/${loop_id}-${timestamp}"

  mkdir -p "$archive_dir"

  if mv "$loop_dir" "$archive_path" 2>/dev/null; then
    debug_log "Archived loop $loop_id to $archive_path"
    info "   Archived loop to: $archive_path"
    return 0
  else
    debug_log "Failed to archive loop $loop_id"
    return 1
  fi
}

cleanup_old_archives() {
  local archive_dir="$PROJECT_ROOT/.claude/ralph-fork/.archive"
  local max_archives="${RALPH_MAX_ARCHIVES:-20}"

  if [[ ! -d "$archive_dir" ]]; then
    return 0
  fi

  local archive_count=$(find "$archive_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

  if [[ $archive_count -gt $max_archives ]]; then
    local to_delete=$((archive_count - max_archives))
    debug_log "Cleaning up $to_delete old archives (keeping $max_archives)"

    find "$archive_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n "$to_delete" | while read old_archive; do
      rm -rf "$old_archive"
      debug_log "Deleted old archive: $old_archive"
    done
  fi
}

# ============================================================================
# DETACHED CLEANUP - Runs cleanup in separate process group to avoid self-kill
# ============================================================================
run_cleanup_detached() {
  local loop_id="$1"
  local state_file="$2"
  local preserve_final="$3"
  local no_cleanup="$4"
  local loop_dir="$5"
  local project_root="$6"
  local log_file="$DEBUG_LOG"

  debug_log "DETACHED CLEANUP: Spawning background process for $loop_id"

  # Create a temporary cleanup script.
  # NOTE: Split local/assignment so mktemp failure is visible — bash `local var=$(cmd)`
  # always returns 0, masking the exit code of cmd.
  local cleanup_script
  cleanup_script=$(mktemp "${TMPDIR:-/tmp}/ralph-cleanup-XXXXXX.sh") || {
    debug_log "DETACHED CLEANUP: mktemp failed for $loop_id — cleanup skipped (state already marked inactive)"
    return 1
  }

  cat > "$cleanup_script" << 'CLEANUP_EOF'
#!/bin/bash
# Detached cleanup script for ralph-loop-fork
# This runs in a separate process group so killing the parent tmux won't kill this

LOOP_ID="$1"
STATE_FILE="$2"
PRESERVE_FINAL="$3"
NO_CLEANUP="$4"
LOOP_DIR="$5"
PROJECT_ROOT="$6"
LOG_FILE="$7"

log() {
  echo "[$(date -Iseconds)] DETACHED: $1" >> "$LOG_FILE"
}

log "Cleanup starting for loop $LOOP_ID"

# Wait a moment for the parent hook to finish outputting JSON
sleep 2

# Skip if no_cleanup is set
if [[ "$NO_CLEANUP" == "true" ]]; then
  log "no_cleanup=true, skipping session removal"
else
  # Read session info from state file
  if [[ -f "$STATE_FILE" ]]; then
    SESSION_NAMES=$(jq -r '.spawned_sessions[]?.name // empty' "$STATE_FILE" 2>/dev/null)
    ORIGINAL_SESSION=$(jq -r '.original_session_name // empty' "$STATE_FILE" 2>/dev/null)
    LAST_SESSION=$(jq -r '.spawned_sessions[-1]?.name // empty' "$STATE_FILE" 2>/dev/null)

    log "Sessions to cleanup: $SESSION_NAMES"
    log "Original session: $ORIGINAL_SESSION"
    log "Last session (preserve if needed): $LAST_SESSION"

    # Remove spawned sessions (except last if preserve_final)
    for session_name in $SESSION_NAMES; do
      if [[ -n "$session_name" ]]; then
        if [[ "$PRESERVE_FINAL" == "true" ]] && [[ "$session_name" == "$LAST_SESSION" ]]; then
          log "Preserving final session: $session_name"
          continue
        fi
        log "Removing session: $session_name"
        if tmux kill-session -t "=$session_name" 2>/dev/null; then
          log "Removed: $session_name"
        else
          log "Failed to remove or not found: $session_name"
        fi
      fi
    done

    # NEW: Remove original session if preserving final and spawned sessions exist
    if [[ "$PRESERVE_FINAL" == "true" ]] && [[ -n "$ORIGINAL_SESSION" ]] && [[ -n "$LAST_SESSION" ]]; then
      log "Removing original session (launcher): $ORIGINAL_SESSION"
      if tmux kill-session -t "=$ORIGINAL_SESSION" 2>/dev/null; then
        log "Removed original session: $ORIGINAL_SESSION"
      else
        log "Failed to remove original session (may not exist): $ORIGINAL_SESSION"
      fi
    fi

    # Remove original session if not preserving (cleanup all mode)
    if [[ -n "$ORIGINAL_SESSION" ]] && [[ "$PRESERVE_FINAL" != "true" ]]; then
      log "Removing original session (no-preserve mode): $ORIGINAL_SESSION"
      if tmux kill-session -t "=$ORIGINAL_SESSION" 2>/dev/null; then
        log "Removed original: $ORIGINAL_SESSION"
      else
        log "Original already removed or not found: $ORIGINAL_SESSION"
      fi
    fi

    # Update state file
    if [[ "$PRESERVE_FINAL" == "true" ]] && [[ -n "$LAST_SESSION" ]]; then
      jq ".spawned_sessions = [{\"name\": \"$LAST_SESSION\", \"preserved\": true}]" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
      jq ".spawned_sessions = []" "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
  fi
fi

# Archive the loop directory
if [[ -d "$LOOP_DIR" ]]; then
  ARCHIVE_DIR="$PROJECT_ROOT/.claude/ralph-fork/.archive"
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)
  ARCHIVE_PATH="$ARCHIVE_DIR/${LOOP_ID}-${TIMESTAMP}"

  mkdir -p "$ARCHIVE_DIR"

  if mv "$LOOP_DIR" "$ARCHIVE_PATH" 2>/dev/null; then
    log "Archived loop to: $ARCHIVE_PATH"
  else
    log "Failed to archive loop"
  fi

  # Cleanup old archives (keep max 20)
  MAX_ARCHIVES=20
  ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  if [[ $ARCHIVE_COUNT -gt $MAX_ARCHIVES ]]; then
    TO_DELETE=$((ARCHIVE_COUNT - MAX_ARCHIVES))
    log "Cleaning up $TO_DELETE old archives"
    find "$ARCHIVE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | head -n "$TO_DELETE" | while read old_archive; do
      rm -rf "$old_archive"
      log "Deleted old archive: $old_archive"
    done
  fi
else
  log "Loop directory not found for archival: $LOOP_DIR"
fi

log "Cleanup complete for loop $LOOP_ID"

# Self-cleanup
rm -f "$0"
CLEANUP_EOF

  chmod +x "$cleanup_script"

  # Run the cleanup script detached from the current process
  # Use subshell + nohup + disown for macOS compatibility (setsid not available on macOS)
  ( nohup "$cleanup_script" "$loop_id" "$state_file" "$preserve_final" "$no_cleanup" "$loop_dir" "$project_root" "$log_file" </dev/null >/dev/null 2>&1 & )

  debug_log "DETACHED CLEANUP: Background process spawned"
}

# ============================================================================
# ERROR DETECTION FUNCTIONS
# ============================================================================
# FIX (2026-02-03): Only check LAST 30 lines of transcript, not entire session.
# This prevents old rate limits (recovered from) from blocking completion flow.
# See: copytrader-tui-dashboard bug where early rate limit blocked on-completion.
# ============================================================================
detect_connection_error() {
  local transcript="$1"

  # Only check final messages, not entire session history
  local last_lines=$(tail -30 "$transcript" 2>/dev/null)

  if echo "$last_lines" | grep -q '"type":"summary"' 2>/dev/null; then
    if echo "$last_lines" | grep '"type":"summary"' 2>/dev/null | grep -qi "connection error\|network error\|api connection error"; then
      debug_log "CONNECTION ERROR DETECTED (in final messages) - NOT forking"
      return 0
    fi
  fi
  return 1
}

detect_rate_limit() {
  local transcript="$1"

  # Only check final messages, not entire session history
  local last_lines=$(tail -30 "$transcript" 2>/dev/null)

  if echo "$last_lines" | grep -q '"type":"queue-operation".*"/rate-limit-options"' 2>/dev/null; then
    debug_log "RATE LIMIT DETECTED (queue-operation in final messages) - NOT forking"
    return 0
  fi

  if echo "$last_lines" | grep -q '"type":"summary"' 2>/dev/null; then
    if echo "$last_lines" | grep '"type":"summary"' 2>/dev/null | grep -q "You've hit your limit\|You.ve hit your limit"; then
      debug_log "RATE LIMIT DETECTED (summary in final messages) - NOT forking"
      return 0
    fi
  fi

  return 1
}

detect_api_error() {
  local transcript="$1"

  if detect_connection_error "$transcript"; then
    return 0
  fi

  if detect_rate_limit "$transcript"; then
    return 0
  fi

  return 1
}

# ============================================================================
# BACKGROUND AGENT DETECTION
# Returns count of background Agent calls with no matching task-notification.
# Transcript format verified against real JSONL: tool_use has
#   .input.run_in_background == true (JSON boolean, snake_case)
# Completions appear as queue-operation lines containing
#   <task-notification>...<tool-use-id>toolu_xxx</tool-use-id>
# ============================================================================
count_pending_background_agents() {
  local transcript="$1"

  [[ ! -f "$transcript" ]] && echo "0" && return 0

  # Collect IDs of background Agent tool_use calls from assistant messages
  local bg_ids
  bg_ids=$(grep '"role":"assistant"' "$transcript" 2>/dev/null | \
    jq -r '
      .message.content[]? |
      select(
        .type == "tool_use" and
        .name == "Agent" and
        (.input.run_in_background == true)
      ) |
      .id
    ' 2>/dev/null | sort -u) || bg_ids=""

  [[ -z "$bg_ids" ]] && echo "0" && return 0

  # Collect tool-use IDs from task-notification completion entries
  local done_ids
  done_ids=$(grep 'task-notification' "$transcript" 2>/dev/null | \
    grep -oE '<tool-use-id>[^<]+</tool-use-id>' | \
    sed 's|<tool-use-id>||;s|</tool-use-id>||' | \
    sort -u) || done_ids=""

  # Count pending (bg_ids not in done_ids)
  local pending=0
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! printf '%s\n' "$done_ids" | grep -qxF "$id"; then
      pending=$((pending + 1))
      debug_log "BG AGENT PENDING: $id"
    fi
  done <<< "$bg_ids"

  echo "$pending"
}

# ============================================================================
# TRANSCRIPT-BASED LOOP ID EXTRACTION
# ============================================================================
extract_loop_from_transcript() {
  local transcript_path="$1"

  if [[ -z "$transcript_path" ]] || [[ ! -f "$transcript_path" ]]; then
    debug_log "No transcript file for loop detection: $transcript_path"
    return 1
  fi

  local full_marker=$(grep -o "RALPH LOOP CONTEXT (Loop: [^,]*, Session [0-9]*, Token: [a-fA-F0-9]*)" "$transcript_path" 2>/dev/null | head -1)

  if [[ -n "$full_marker" ]]; then
    local loop_id=$(echo "$full_marker" | sed -n 's/.*Loop: \([^,]*\),.*/\1/p')
    local session_token=$(echo "$full_marker" | sed -n 's/.*Token: \([a-fA-F0-9]*\).*/\1/p')

    debug_log "Extracted loop ID from transcript: $loop_id"
    debug_log "Extracted token from transcript: $session_token"

    # Find state file by traversing up from PWD (handles cd into subdirectories)
    local state_file=""
    local search_dir="$PWD"
    while [[ "$search_dir" != "/" ]]; do
      if [[ -f "$search_dir/.claude/ralph-fork/$loop_id/state.json" ]]; then
        state_file="$search_dir/.claude/ralph-fork/$loop_id/state.json"
        break
      fi
      search_dir=$(dirname "$search_dir")
    done

    if [[ -n "$state_file" ]]; then
      local expected_token=$(jq -r '.session_token // ""' "$state_file" 2>/dev/null)
      if [[ -n "$expected_token" ]] && [[ "$session_token" != "$expected_token" ]]; then
        debug_log "Token mismatch! Transcript: $session_token, Expected: $expected_token"
        debug_log "This is likely a false match from reading ralph files - ignoring"
        return 1
      fi
      debug_log "Token verified successfully (state: $state_file)"
    else
      debug_log "WARNING: Could not find state.json for $loop_id from PWD=$PWD - rejecting to prevent double-spawn"
      return 1
    fi

    echo "$loop_id"
    return 0
  fi

  # Fallback: old format without token
  local loop_id=$(grep -o "RALPH LOOP CONTEXT (Loop: [^,)]*" "$transcript_path" 2>/dev/null | head -1 | sed 's/.*Loop: //')

  if [[ -n "$loop_id" ]]; then
    debug_log "Extracted loop ID from transcript (old format): $loop_id"
    echo "$loop_id"
    return 0
  fi

  debug_log "No RALPH LOOP CONTEXT found in transcript - not a ralph session"
  return 1
}

# ============================================================================
# WORKTREE FALLBACK: LOOP ID DETECTION VIA STATE.JSON
# ============================================================================
# When `claude --dangerously-skip-permissions 'message'` launches a fresh
# tmux session in a worktree, the initial CLI message is NOT written to the
# .jsonl transcript (only the ai-title line is written). This means the
# RALPH LOOP CONTEXT marker -- which lives in the prompt FILE, not in the
# CLI message -- is never present in the transcript, causing transcript-based
# detection to fail and the stop hook to exit without forking.
#
# Fallback: scan .claude/ralph-fork/*/state.json from PWD for an active loop
# whose worktree_path matches the current directory.
extract_loop_from_worktree_state() {
  local current_pwd
  current_pwd="$(cd "$(pwd)" 2>/dev/null && pwd)" || return 1

  local found_id=""
  for state_file in .claude/ralph-fork/*/state.json; do
    [[ -f "$state_file" ]] || continue
    local is_active worktree_path loop_id
    is_active=$(jq -r '.active // false' "$state_file" 2>/dev/null) || continue
    [[ "$is_active" == "true" ]] || continue
    worktree_path=$(jq -r '.worktree_path // ""' "$state_file" 2>/dev/null) || continue
    [[ -n "$worktree_path" ]] && [[ "$worktree_path" != "null" ]] || continue
    local worktree_abs
    worktree_abs="$(cd "$worktree_path" 2>/dev/null && pwd)" || continue
    if [[ "$worktree_abs" == "$current_pwd" ]]; then
      loop_id=$(jq -r '.loop_id // ""' "$state_file" 2>/dev/null) || continue
      [[ -n "$loop_id" ]] && [[ "$loop_id" != "null" ]] || continue
      debug_log "WORKTREE FALLBACK: matched active loop '$loop_id' via worktree_path=$worktree_path"
      echo "$loop_id"
      return 0
    fi
  done
  debug_log "WORKTREE FALLBACK: no active state.json matched current PWD=$current_pwd"
  return 1
}

# ============================================================================
# SPAWN NEW SESSION HELPER
# ============================================================================
spawn_new_session() {
  local loop_id="$1"
  local session_number="$2"
  local state_file="$3"
  local plugin_root="$4"
  local project_root="$5"

  debug_log "SPAWNING new session $session_number for loop $loop_id"
  debug_log "PROJECT_ROOT for fork: $project_root"

  # Execute fork script - MUST pass project_root so it can cd there first
  # This fixes the bug where hook runs from subdirectory after Claude cd's
  "$plugin_root/scripts/fork-terminal.sh" "$loop_id" "$session_number" "$project_root"

  info "Ralph Loop Fork [$loop_id]: Spawned session $session_number"
}

# ============================================================================
# MAIN HOOK LOGIC
# ============================================================================

debug_log "========================================"
debug_log "STOP HOOK TRIGGERED (State Machine - FIXED)"
debug_log "PWD: $(pwd)"
debug_log "CLAUDE_PLUGIN_ROOT: ${CLAUDE_PLUGIN_ROOT:-not set}"

# Read hook input
HOOK_INPUT=$(cat)
debug_log "Hook input received: ${#HOOK_INPUT} bytes"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"

# Check stop_hook_active to prevent infinite BLOCK cycles
# NOTE: We still need to check for spawning even when stop_hook_active=true
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null) || STOP_HOOK_ACTIVE="false"
debug_log "stop_hook_active: $STOP_HOOK_ACTIVE"

# Don't exit here - we need to check if we should spawn a new session
# The STOP_HOOK_ACTIVE flag will be used later to prevent outputting another BLOCK

# Get transcript path
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path' 2>/dev/null) || TRANSCRIPT_PATH=""
debug_log "Transcript path: $TRANSCRIPT_PATH"

if [[ -z "$TRANSCRIPT_PATH" ]] || [[ "$TRANSCRIPT_PATH" == "null" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  debug_log "No valid transcript path - not a ralph session, exiting"
  exit 0
fi

# Extract loop ID from transcript; fall back to worktree-path matching if the
# transcript is empty (happens when the session was launched via
# `claude --dangerously-skip-permissions 'message'` in tmux -- the CLI
# message is stored in memory, not written to the .jsonl file).
# USED_WORKTREE_FALLBACK=true when the worktree path match is used instead of
# transcript; the "no assistant messages" handler uses this flag to BLOCK instead
# of deleting local.md and exiting (which would kill the loop).
USED_WORKTREE_FALLBACK=false
LOOP_ID=$(extract_loop_from_transcript "$TRANSCRIPT_PATH") || {
  debug_log "No RALPH LOOP CONTEXT in transcript - trying worktree fallback"
  LOOP_ID=$(extract_loop_from_worktree_state) || {
    debug_log "No RALPH LOOP CONTEXT in transcript and no matching worktree state - not a ralph session, exiting cleanly"
    exit 0
  }
  USED_WORKTREE_FALLBACK=true
}

debug_log "Found active loop: $LOOP_ID"

# Set paths - use absolute paths to handle PWD changes (Issue #3 fix)
# Try to find project root by looking for .claude directory
find_project_root() {
  local dir="$PWD"
  while [[ "$dir" != "/" ]]; do
    if [[ -d "$dir/.claude/ralph-fork/$LOOP_ID" ]]; then
      echo "$dir"
      return 0
    fi
    dir=$(dirname "$dir")
  done
  # Fallback: check if state exists in PWD
  if [[ -d ".claude/ralph-fork/$LOOP_ID" ]]; then
    echo "$PWD"
    return 0
  fi
  return 1
}

PROJECT_ROOT=$(find_project_root) || {
  debug_log "Could not find project root with ralph state for loop $LOOP_ID"
  exit 0
}
debug_log "Project root: $PROJECT_ROOT"

LOOP_DIR="$PROJECT_ROOT/.claude/ralph-fork/$LOOP_ID"
STATE_FILE="$LOOP_DIR/state.json"
LOCAL_FILE="$LOOP_DIR/local.md"

# Validate state files exist
if [[ ! -f "$LOCAL_FILE" ]]; then
  debug_log "No local file found at $LOCAL_FILE"
  exit 0
fi

if [[ ! -f "$STATE_FILE" ]]; then
  debug_log "No state file found at $STATE_FILE, cleaning up local file"
  rm -f "$LOCAL_FILE"
  exit 0
fi

# ============================================================================
# READ STATE
# ============================================================================
TOTAL_BUDGET=$(jq -r '.total_budget // 0' "$STATE_FILE" 2>/dev/null) || TOTAL_BUDGET=0
TOTAL_ITERATIONS=$(jq -r '.total_iterations // 0' "$STATE_FILE" 2>/dev/null) || TOTAL_ITERATIONS=0
CHECKLIST_PATH=$(jq -r '.checklist_file // ""' "$STATE_FILE" 2>/dev/null) || CHECKLIST_PATH=""
# Resolve relative checklist path against PROJECT_ROOT (fixes PWD bug)
if [[ -n "$CHECKLIST_PATH" ]] && [[ "$CHECKLIST_PATH" != /* ]]; then
  CHECKLIST_PATH="$PROJECT_ROOT/$CHECKLIST_PATH"
  debug_log "Resolved CHECKLIST_PATH to absolute: $CHECKLIST_PATH"
fi
ON_COMPLETION_CMD=$(jq -r '.on_completion_command // ""' "$STATE_FILE" 2>/dev/null) || ON_COMPLETION_CMD=""
PRESERVE_FINAL_SESSION=$(jq -r '.preserve_final_session // false' "$STATE_FILE" 2>/dev/null) || PRESERVE_FINAL_SESSION="false"
NO_CLEANUP=$(jq -r '.no_cleanup // false' "$STATE_FILE" 2>/dev/null) || NO_CLEANUP="false"
STOP_HOOK_REMINDERS=$(jq -r '.stop_hook_reminders // ""' "$STATE_FILE" 2>/dev/null) || STOP_HOOK_REMINDERS=""

# State machine flags
AWAITING_CHECKLIST_UPDATE=$(jq -r '.awaiting_checklist_update // false' "$STATE_FILE" 2>/dev/null) || AWAITING_CHECKLIST_UPDATE="false"
AWAITING_CONFIRMATION=$(jq -r '.awaiting_confirmation // false' "$STATE_FILE" 2>/dev/null) || AWAITING_CONFIRMATION="false"
EXECUTING_ON_COMPLETION=$(jq -r '.executing_on_completion // false' "$STATE_FILE" 2>/dev/null) || EXECUTING_ON_COMPLETION="false"
AWAITING_BACKGROUND_AGENTS=$(jq -r '.awaiting_background_agents // false' "$STATE_FILE" 2>/dev/null) || AWAITING_BACKGROUND_AGENTS="false"
BG_AGENT_BLOCK_COUNT=$(jq -r '.bg_agent_block_count // 0' "$STATE_FILE" 2>/dev/null) || BG_AGENT_BLOCK_COUNT=0

# Parse local state
FRONTMATTER=$(awk '/^---$/{i++; next} i==1' "$LOCAL_FILE") || true
LOCAL_ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//' || echo "")
MAX_PER_SESSION=$(echo "$FRONTMATTER" | grep '^max_per_session:' | sed 's/max_per_session: *//' || echo "1")
SESSION_NUMBER=$(echo "$FRONTMATTER" | grep '^session_number:' | sed 's/session_number: *//' || echo "1")
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/' || echo "")

debug_log "State: budget=$TOTAL_BUDGET, iterations=$TOTAL_ITERATIONS, session=$SESSION_NUMBER"
debug_log "Flags: awaiting_checklist_update=$AWAITING_CHECKLIST_UPDATE, awaiting_confirmation=$AWAITING_CONFIRMATION, executing_on_completion=$EXECUTING_ON_COMPLETION, awaiting_background_agents=$AWAITING_BACKGROUND_AGENTS, bg_agent_block_count=$BG_AGENT_BLOCK_COUNT"

# ============================================================================
# STALE-STATE DETECTOR (stop_hook_active=false only)
# Fires when the continuation cycle never ran (e.g., session killed mid-BLOCK).
# Clears stuck flags so the loop recovers instead of staying active=true forever.
# ============================================================================
if [[ "$STOP_HOOK_ACTIVE" == "false" ]]; then
  # Case 1: executing_on_completion stuck — on-completion ran, continuation never fired.
  # The loop is logically done; treat it as completed.
  if [[ "$EXECUTING_ON_COMPLETION" == "true" ]]; then
    debug_log "STALE-STATE: executing_on_completion=true + stop_hook_active=false — orphaned; completing loop"
    info "Ralph Loop Fork [$LOOP_ID]: Stale executing_on_completion detected — recovering orphaned loop"
    info "   NOTE: The on-completion command may or may not have run before the session was killed."
    info "   Check termination_reason='orphaned_executing_on_completion' in state.json for audit trail."
    info ""

    update_state "$STATE_FILE" ".active = false | .executing_on_completion = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"orphaned_executing_on_completion\""

    emit_signal "ralph-completed" "$(jq -nc --arg reason "orphaned_executing_on_completion" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$TOTAL_ITERATIONS" '{termination_reason: $reason, total_sessions: $sessions, total_iterations: $iterations}')"
    SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Loop complete (recovered orphaned session)")
    jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

    debug_log "STALE-STATE: Spawning detached cleanup for orphaned loop"
    run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
    debug_log "STALE-STATE: Detached cleanup spawned, exiting"
    exit 0
  fi

  # Case 2: awaiting_confirmation stuck — confirmation BLOCK was lost (session killed).
  # Clear the flag and fall through; normal flow re-detects the promise if it's still present.
  if [[ "$AWAITING_CONFIRMATION" == "true" ]]; then
    debug_log "STALE-STATE: awaiting_confirmation=true + stop_hook_active=false — clearing stale flag"
    update_state "$STATE_FILE" ".awaiting_confirmation = false"
    AWAITING_CONFIRMATION="false"
  fi

  # Case 3: awaiting_checklist_update stuck — checklist-update BLOCK was lost.
  # Clear the flag and fall through; normal flow re-evaluates the session output.
  if [[ "$AWAITING_CHECKLIST_UPDATE" == "true" ]]; then
    debug_log "STALE-STATE: awaiting_checklist_update=true + stop_hook_active=false — clearing stale flag"
    update_state "$STATE_FILE" ".awaiting_checklist_update = false"
    AWAITING_CHECKLIST_UPDATE="false"
  fi

  # Case 4: awaiting_background_agents stuck — session killed while waiting for bg agents.
  # Those agents are gone; clear the flag and fall through.
  if [[ "$AWAITING_BACKGROUND_AGENTS" == "true" ]]; then
    debug_log "STALE-STATE: awaiting_background_agents=true + stop_hook_active=false — clearing stale flag"
    update_state "$STATE_FILE" ".awaiting_background_agents = false | .bg_agent_block_count = 0"
    AWAITING_BACKGROUND_AGENTS="false"
    BG_AGENT_BLOCK_COUNT=0
  fi
fi

# ============================================================================
# HANDLE stop_hook_active=true (CONTINUATION CYCLE)
# We're in a continuation cycle - Claude responded to a BLOCK
# We should NOT output another BLOCK, but we might need to SPAWN
# ============================================================================
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  debug_log "CONTINUATION CYCLE: stop_hook_active=true"

  # If awaiting_checklist_update, Claude has updated the checklist - SPAWN new session
  if [[ "$AWAITING_CHECKLIST_UPDATE" == "true" ]]; then
    # CRITICAL: Check if checklist file still exists (may have been moved to done/)
    if [[ -n "$CHECKLIST_PATH" ]] && [[ ! -f "$CHECKLIST_PATH" ]]; then
      debug_log "CHECKLIST FILE MISSING: $CHECKLIST_PATH - stopping loop"
      info "Ralph Loop Fork [$LOOP_ID]: Checklist file moved/deleted - completing loop!"
      info "   File: $CHECKLIST_PATH"
      info "   This usually means the work is complete and checklist was moved to done/"
      info ""

      update_state "$STATE_FILE" ".active = false | .awaiting_checklist_update = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"checklist_moved\""

      emit_signal "ralph-completed" "$(jq -nc --arg reason "checklist_moved" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$TOTAL_ITERATIONS" '{termination_reason: $reason, total_sessions: $sessions, total_iterations: $iterations}')"
      SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Loop complete — checklist moved to done/")
      jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

      debug_log "Spawning detached cleanup process..."
      run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
      debug_log "Detached cleanup spawned, exiting hook"

      exit 0
    fi

    debug_log "CONTINUATION: awaiting_checklist_update=true - SPAWNING new session"
    info "Ralph Loop Fork [$LOOP_ID]: Checklist updated, spawning new session..."
    info ""

    update_state "$STATE_FILE" ".awaiting_checklist_update = false | .total_iterations = $((TOTAL_ITERATIONS + 1)) | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

    NEW_SESSION_NUMBER=$((SESSION_NUMBER + 1))
    update_state "$STATE_FILE" ".session_number = $NEW_SESSION_NUMBER"
    rm -f "$LOCAL_FILE"

    spawn_new_session "$LOOP_ID" "$NEW_SESSION_NUMBER" "$STATE_FILE" "$PLUGIN_ROOT" "$PROJECT_ROOT"
    exit 0
  fi

  # If awaiting_confirmation, Claude should have output <confirmed>YES</confirmed>
  # But we can't check that without reading transcript - let the normal flow handle it
  # For now, just exit to prevent infinite BLOCK loops
  if [[ "$AWAITING_CONFIRMATION" == "true" ]]; then
    debug_log "CONTINUATION: awaiting_confirmation=true - letting normal flow handle confirmation check"
    # Don't exit - let normal flow check for <confirmed> tag
  elif [[ "$EXECUTING_ON_COMPLETION" == "true" ]]; then
    # On-completion command was executed, now cleanup and archive
    debug_log "CONTINUATION: executing_on_completion=true - completing loop"
    info "Ralph Loop Fork [$LOOP_ID]: On-completion command executed, loop complete!"
    info "   Total sessions: $SESSION_NUMBER"
    info "   Total iterations: $TOTAL_ITERATIONS"
    info ""

    update_state "$STATE_FILE" ".active = false | .executing_on_completion = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"on_completion_executed\""

    emit_signal "ralph-completed" "$(jq -nc --arg reason "on_completion_executed" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$TOTAL_ITERATIONS" '{termination_reason: $reason, total_sessions: $sessions, total_iterations: $iterations}')"
    SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Loop complete — $SESSION_NUMBER session(s)")
    jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

    debug_log "Spawning detached cleanup process..."
    run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
    debug_log "Detached cleanup spawned, exiting hook"

    exit 0
  elif [[ "$AWAITING_BACKGROUND_AGENTS" == "true" ]]; then
    # We previously blocked waiting for background agents — re-check if they're done.
    # No cap: keep blocking until every started agent delivers its result.
    debug_log "CONTINUATION: awaiting_background_agents=true - re-checking"
    PENDING_BG_CONT=$(count_pending_background_agents "$TRANSCRIPT_PATH")
    if [[ $PENDING_BG_CONT -gt 0 ]]; then
      NEW_BG_COUNT=$((BG_AGENT_BLOCK_COUNT + 1))
      update_state "$STATE_FILE" ".bg_agent_block_count = $NEW_BG_COUNT"
      debug_log "BG AGENTS: Still $PENDING_BG_CONT pending (wait #$NEW_BG_COUNT)"
      info "Ralph Loop Fork [$LOOP_ID]: $PENDING_BG_CONT background agent(s) still running (wait #$NEW_BG_COUNT)..."
      info ""
      jq -n \
        --argjson n "$PENDING_BG_CONT" \
        --argjson attempt "$NEW_BG_COUNT" \
        --arg loopid "$LOOP_ID" \
        '{
          "decision": "block",
          "reason": ("Ralph Loop [\($loopid)]: \($n) background sub-agent(s) still running (wait #\($attempt)). Do NOT update the checklist or output the completion promise yet. Wait until ALL task-notification messages have been received, then integrate all results."),
          "systemMessage": ("Ralph [\($loopid)]: \($n) background agents still pending")
        }'
      exit 0
    else
      debug_log "BG AGENTS: All resolved in continuation cycle — resuming normal flow"
      update_state "$STATE_FILE" ".awaiting_background_agents = false | .bg_agent_block_count = 0"
      info "Ralph Loop Fork [$LOOP_ID]: All background agents completed — resuming..."
      info ""
      # Fall through to normal flow (don't exit)
    fi
  else
    if [[ "$USED_WORKTREE_FALLBACK" == "true" ]]; then
      # Worktree mode: we previously BLOCKed to get Claude's status declaration.
      # Claude's response is now in the transcript (continuation turns ARE written
      # even when the initial tmux-launched session is not). Fall through to the
      # normal flow so we can check for the completion promise, checklist changes,
      # and iteration counter — then spawn or complete as appropriate.
      debug_log "CONTINUATION: No special state (worktree fallback) - falling through to normal flow"
    else
      # Standard mode: no special state in continuation — exit cleanly.
      debug_log "CONTINUATION: No special state - exiting cleanly"
      exit 0
    fi
  fi
fi

# Validate numeric fields
if [[ ! "$LOCAL_ITERATION" =~ ^[0-9]+$ ]]; then
  debug_log "Local state corrupted (iteration: '$LOCAL_ITERATION'), stopping"
  rm -f "$LOCAL_FILE"
  exit 0
fi

if [[ ! "$SESSION_NUMBER" =~ ^[0-9]+$ ]]; then
  SESSION_NUMBER=1
fi

# ============================================================================
# STATE MACHINE: CHECK BUDGET FIRST (applies to all states)
# ============================================================================
NEW_TOTAL_ITERATIONS=$((TOTAL_ITERATIONS + 1))

if [[ $TOTAL_BUDGET -gt 0 ]] && [[ $NEW_TOTAL_ITERATIONS -gt $TOTAL_BUDGET ]]; then
  debug_log "BUDGET EXHAUSTED: $NEW_TOTAL_ITERATIONS > $TOTAL_BUDGET"
  info "Ralph Loop Fork [$LOOP_ID]: Total budget ($TOTAL_BUDGET) exhausted."
  info "   Sessions used: $SESSION_NUMBER"
  info "   Total iterations: $NEW_TOTAL_ITERATIONS"
  info ""

  update_state "$STATE_FILE" ".active = false | .budget_exhausted = true | .exhausted_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"budget_exhausted\""

  emit_signal "ralph-budget-exhausted" "$(jq -nc --argjson budget "$TOTAL_BUDGET" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$NEW_TOTAL_ITERATIONS" '{total_budget: $budget, sessions_used: $sessions, total_iterations: $iterations}')"
  SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Budget exhausted after $SESSION_NUMBER session(s)")
  jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

  debug_log "Budget exhausted - spawning detached cleanup"
  run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"

  exit 0
fi

# ============================================================================
# STATE MACHINE: CHECK executing_on_completion
# Currently unreachable-by-design (self-improving-os WP-03 review): the
# STALE-STATE Case-1 block above already disposes of stop_hook_active=false +
# executing_on_completion=true, and the continuation-cycle elif above already
# disposes of stop_hook_active=true + executing_on_completion=true, so every
# path reaching here would require both to be false — contradicting this
# block's own guard. Kept as defensive dead code; no emit_signal call here —
# if either upstream guard's invariant ever changes, add one here too.
# ============================================================================
if [[ "$EXECUTING_ON_COMPLETION" == "true" ]]; then
  debug_log "STATE: EXECUTING_ON_COMPLETION - on-completion command was sent, cleaning up"
  info "Ralph Loop Fork [$LOOP_ID]: On-completion command executed, loop complete!"
  info "   Total sessions: $SESSION_NUMBER"
  info "   Total iterations: $TOTAL_ITERATIONS"
  info ""

  update_state "$STATE_FILE" ".active = false | .executing_on_completion = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"on_completion_executed\""

  debug_log "STATE: Spawning detached cleanup..."
  run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
  debug_log "STATE: Detached cleanup spawned, exiting hook"

  exit 0
fi

# ============================================================================
# API ERROR CHECK (before proceeding with any state)
# ============================================================================
if detect_api_error "$TRANSCRIPT_PATH"; then
  info "Ralph Loop Fork [$LOOP_ID]: API error detected - NOT forking to prevent infinite loop"
  info "   Check the error message above and retry when the issue is resolved."
  exit 0
fi

# ============================================================================
# BACKGROUND AGENT DETECTION (RUNNING STATE)
# Block instead of forking until every launched background agent has delivered
# its task-notification result. No cap — waits for all agents regardless of
# how many were started.
# ============================================================================
BG_PENDING=$(count_pending_background_agents "$TRANSCRIPT_PATH")
if [[ $BG_PENDING -gt 0 ]]; then
  debug_log "RUNNING: $BG_PENDING pending background agents detected — BLOCKING"
  info "Ralph Loop Fork [$LOOP_ID]: $BG_PENDING background agent(s) still running — waiting for results..."
  info ""
  update_state "$STATE_FILE" ".awaiting_background_agents = true | .bg_agent_block_count = 1"
  jq -n \
    --argjson n "$BG_PENDING" \
    --arg loopid "$LOOP_ID" \
    '{
      "decision": "block",
      "reason": ("Ralph Loop [\($loopid)]: You have \($n) background sub-agent(s) whose results have NOT been received yet. Do NOT update the checklist or output the completion promise. Wait for all task-notification messages, then collect and integrate all results before continuing."),
      "systemMessage": ("Ralph [\($loopid)]: \($n) background agents pending — wait for completion")
    }'
  exit 0
fi

# ============================================================================
# AEOS DOOM-LOOP + REVISION-BUDGET CHECK
# Active only when .aeos-config.json exists in LOOP_DIR (W4 fail-open on read).
# Doom increment gated on STOP_HOOK_ACTIVE=false: one sample per fork, not per
# hook fire (hook fires twice per fork in the normal path).
# All jq reads fail-open: parse error → debug_log + proceed as v0.1.6.
# ============================================================================
AEOS_CONFIG_FILE="$LOOP_DIR/.aeos-config.json"
if [[ -f "$AEOS_CONFIG_FILE" ]]; then
  debug_log "AEOS: config found at $AEOS_CONFIG_FILE"

  # Read config fields (fail-open on any parse/jq error)
  AEOS_DOOM_THRESHOLD=0
  AEOS_RESPECT_REVISION=false
  AEOS_PLAN_DIR=""
  AEOS_DOOM_THRESHOLD=$(jq -r '.doom_abort_threshold // 0' "$AEOS_CONFIG_FILE" 2>/dev/null) || AEOS_DOOM_THRESHOLD=0
  AEOS_RESPECT_REVISION=$(jq -r '.respect_revision_budget // false' "$AEOS_CONFIG_FILE" 2>/dev/null) || AEOS_RESPECT_REVISION=false
  AEOS_PLAN_DIR=$(jq -r '.plan_dir // ""' "$AEOS_CONFIG_FILE" 2>/dev/null) || AEOS_PLAN_DIR=""

  # ── Doom-loop detection ──────────────────────────────────────────────────
  # Gate on STOP_HOOK_ACTIVE=false: count once per fork, not per hook fire.
  if [[ "$STOP_HOOK_ACTIVE" == "false" ]] && [[ "$AEOS_DOOM_THRESHOLD" -gt 0 ]]; then
    CURRENT_HASH=""
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      CURRENT_HASH=$(md5 -q "$CHECKLIST_PATH" 2>/dev/null || \
                    md5sum "$CHECKLIST_PATH" 2>/dev/null | awk '{print $1}') || CURRENT_HASH=""
    fi

    if [[ -n "$CURRENT_HASH" ]]; then
      LAST_HASH=$(jq -r '.last_checklist_hash // ""' "$STATE_FILE" 2>/dev/null) || LAST_HASH=""
      STUCK_COUNT=$(jq -r '.stuck_count // 0' "$STATE_FILE" 2>/dev/null) || STUCK_COUNT=0

      if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
        NEW_STUCK_COUNT=$((STUCK_COUNT + 1))
        debug_log "AEOS doom-loop: hash unchanged ($CURRENT_HASH), stuck_count=$NEW_STUCK_COUNT/$AEOS_DOOM_THRESHOLD"

        if [[ $NEW_STUCK_COUNT -ge $AEOS_DOOM_THRESHOLD ]]; then
          info "Ralph Loop Fork [$LOOP_ID]: DOOM-LOOP DETECTED — checklist unchanged for $NEW_STUCK_COUNT consecutive forks (threshold: $AEOS_DOOM_THRESHOLD)."
          info ""

          cat > "$PROJECT_ROOT/BLOCKER.md" <<BLOCKER_EOF
# BLOCKER

**Condition:** doom-loop-detected
**Detail:** Checklist hash unchanged for $NEW_STUCK_COUNT consecutive forks (threshold: $AEOS_DOOM_THRESHOLD). Loop ID: $LOOP_ID, plan_dir: ${AEOS_PLAN_DIR:-unknown}.
**Fix:** Review the checklist and the last session transcript. Identify why progress has stalled, fix the underlying issue, then remove this file and re-run the loop.
BLOCKER_EOF

          update_state "$STATE_FILE" ".active = false | .stuck_count = $NEW_STUCK_COUNT | .last_checklist_hash = \"$CURRENT_HASH\" | .termination_reason = \"doom_loop_detected\""

          emit_signal "ralph-doomed" "$(jq -nc --arg reason "doom_loop_detected" --argjson stuck "$NEW_STUCK_COUNT" --argjson threshold "$AEOS_DOOM_THRESHOLD" '{reason: $reason, stuck_count: $stuck, doom_abort_threshold: $threshold}')"
          SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Doom-loop detected — stuck for $NEW_STUCK_COUNT forks")
          jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

          debug_log "AEOS doom-loop: spawning detached cleanup"
          run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
          exit 0
        else
          update_state "$STATE_FILE" ".stuck_count = $NEW_STUCK_COUNT | .last_checklist_hash = \"$CURRENT_HASH\""
        fi
      else
        debug_log "AEOS doom-loop: hash changed (${LAST_HASH:-none} → $CURRENT_HASH), resetting stuck_count"
        update_state "$STATE_FILE" ".stuck_count = 0 | .last_checklist_hash = \"$CURRENT_HASH\""
      fi
    fi
  fi

  # ── Revision-budget check ────────────────────────────────────────────────
  if [[ "$AEOS_RESPECT_REVISION" == "true" ]] && [[ -n "$AEOS_PLAN_DIR" ]]; then
    LOOP_STATE_FILE="$PROJECT_ROOT/$AEOS_PLAN_DIR/loop-state.json"
    if [[ -f "$LOOP_STATE_FILE" ]]; then
      AEOS_REVISION_BUDGET=$(jq -r '.revision_budget // 0' "$LOOP_STATE_FILE" 2>/dev/null) || AEOS_REVISION_BUDGET=0
      AEOS_REVISION_COUNT=$(jq -r '.revision_count // 0' "$LOOP_STATE_FILE" 2>/dev/null) || AEOS_REVISION_COUNT=0

      if [[ "$AEOS_REVISION_BUDGET" -gt 0 ]] && [[ "$AEOS_REVISION_COUNT" -ge "$AEOS_REVISION_BUDGET" ]]; then
        info "Ralph Loop Fork [$LOOP_ID]: REVISION BUDGET EXHAUSTED — revision_count ($AEOS_REVISION_COUNT) >= revision_budget ($AEOS_REVISION_BUDGET)."
        info ""

        cat > "$PROJECT_ROOT/BLOCKER.md" <<BLOCKER_EOF
# BLOCKER

**Condition:** revision-budget-exhausted
**Detail:** revision_count=$AEOS_REVISION_COUNT >= revision_budget=$AEOS_REVISION_BUDGET in $AEOS_PLAN_DIR/loop-state.json. Loop ID: $LOOP_ID.
**Fix:** Review the revision history in loop-state.json, resolve the blocking issue, then bump revision_budget and remove this file before re-running the loop.
BLOCKER_EOF

        update_state "$STATE_FILE" ".active = false | .termination_reason = \"revision_budget_exhausted\""

        emit_signal "ralph-doomed" "$(jq -nc --arg reason "revision_budget_exhausted" --argjson count "$AEOS_REVISION_COUNT" --argjson budget "$AEOS_REVISION_BUDGET" '{reason: $reason, revision_count: $count, revision_budget: $budget}')"
        SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Revision budget exhausted ($AEOS_REVISION_COUNT/$AEOS_REVISION_BUDGET)")
        jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

        debug_log "AEOS revision budget: spawning detached cleanup"
        run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
        exit 0
      else
        debug_log "AEOS revision budget: $AEOS_REVISION_COUNT/$AEOS_REVISION_BUDGET"
      fi
    else
      debug_log "AEOS revision budget: loop-state.json not found at $LOOP_STATE_FILE"
    fi
  else
    debug_log "AEOS revision budget: disabled (respect_revision_budget=$AEOS_RESPECT_REVISION)"
  fi
else
  debug_log "AEOS: no config at $AEOS_CONFIG_FILE — standalone mode, no state changes"
fi

# ============================================================================
# READ LAST ASSISTANT MESSAGE
# ============================================================================
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  debug_log "No assistant messages found in transcript"

  if [[ "$USED_WORKTREE_FALLBACK" == "true" ]] && [[ "$STOP_HOOK_ACTIVE" == "false" ]]; then
    # Worktree mode, first hook call: the initial tmux session turn is never written
    # to disk. BLOCK once — the continuation turn (Claude's response to the block
    # prompt) IS written to the transcript. Do NOT delete local.md.
    debug_log "WORKTREE FALLBACK: empty transcript on first call — blocking for status declaration"
    info "Ralph Loop Fork [$LOOP_ID]: Worktree session ended without transcript — requesting status..."
    info ""

    CHECKLIST_CONTENT=""
    CHECKED_COUNT=0
    UNCHECKED_COUNT=0
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")
      ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
      UNCHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f1)
      CHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f2)
    fi

    STATUS_PROMPT="RALPH LOOP [$LOOP_ID] — STATUS DECLARATION REQUIRED

The stop hook cannot read your prior output because this session runs in a tmux worktree
where the initial conversation turn is not written to the .jsonl transcript.

CURRENT CHECKLIST STATE: ${CHECKED_COUNT} checked, ${UNCHECKED_COUNT} unchecked

$(if [[ -n "$CHECKLIST_CONTENT" ]]; then echo "=== CHECKLIST ===" && echo "$CHECKLIST_CONTENT" && echo "=== END CHECKLIST ==="; fi)

Choose exactly ONE of the following actions:

A) You completed some (but not all) work this session:
   → Update the checklist file to mark all items you completed [x]
   → Then stop. A new session will be spawned automatically to continue.

B) ALL checklist work is 100% complete:
   → Ensure every checklist item is marked [x]
   → Then output EXACTLY:
   <promise>${COMPLETION_PROMISE}</promise>
   (The XML tags are required for completion detection)

Do not describe your work — just take the correct action."

    update_state "$STATE_FILE" ".awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

    jq -n \
      --arg prompt "$STATUS_PROMPT" \
      --arg msg "Ralph [$LOOP_ID]: declare status (transcript empty in worktree mode)" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'
    exit 0

  elif [[ "$USED_WORKTREE_FALLBACK" == "true" ]] && [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    # Worktree mode, continuation call: transcript still empty even after the BLOCK.
    # Continuation turns should be written — if they are not, we cannot wait forever.
    # Spawn the next session so the loop continues rather than silently dying.
    debug_log "WORKTREE FALLBACK: transcript still empty after block — spawning next session (fallback)"
    info "Ralph Loop Fork [$LOOP_ID]: Continuation transcript empty — spawning next session..."
    info ""
    NEW_SESSION_NUMBER=$((SESSION_NUMBER + 1))
    update_state "$STATE_FILE" ".total_iterations = $((TOTAL_ITERATIONS + 1)) | .session_number = $NEW_SESSION_NUMBER | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"
    rm -f "$LOCAL_FILE"
    spawn_new_session "$LOOP_ID" "$NEW_SESSION_NUMBER" "$STATE_FILE" "$PLUGIN_ROOT" "$PROJECT_ROOT"
    exit 0

  else
    rm -f "$LOCAL_FILE"
    exit 0
  fi
fi

LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1) || LAST_LINE=""
if [[ -z "$LAST_LINE" ]]; then
  debug_log "Failed to extract last assistant message"
  rm -f "$LOCAL_FILE"
  exit 0
fi

# Priority 1: Extract text content from last assistant message
# Try line-based jq first, fallback to slurp mode if parse fails
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
  .message.content |
  if type == "array" then
    map(select(.type == "text")) |
    map(.text) |
    join("\n")
  else
    ""
  end
' 2>/dev/null) || LAST_OUTPUT=""

# If line-based parsing failed (empty due to parse error), try slurp mode on last 50 lines
if [[ -z "$LAST_OUTPUT" ]]; then
  debug_log "Line-based jq failed or empty, trying slurp mode on last 50 lines"
  LAST_OUTPUT=$(tail -50 "$TRANSCRIPT_PATH" | jq -rs '
    map(select(.message.role == "assistant")) |
    last |
    .message.content |
    if type == "array" then
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    else
      ""
    end
  ' 2>/dev/null) || LAST_OUTPUT=""
fi

# Priority 2: If no text, fallback to thinking content
# This handles cases where LLM was interrupted mid-thought (e.g., about to output promise)
if [[ -z "$LAST_OUTPUT" ]]; then
  debug_log "No text content, trying thinking fallback"

  # Try line-based first
  LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
    .message.content |
    if type == "array" then
      map(select(.type == "thinking")) |
      map(.thinking) |
      join("\n")
    else
      ""
    end
  ' 2>/dev/null) || LAST_OUTPUT=""

  # Fallback to slurp mode for thinking
  if [[ -z "$LAST_OUTPUT" ]]; then
    LAST_OUTPUT=$(tail -50 "$TRANSCRIPT_PATH" | jq -rs '
      map(select(.message.role == "assistant")) |
      last |
      .message.content |
      if type == "array" then
        map(select(.type == "thinking")) |
        map(.thinking) |
        join("\n")
      else
        ""
      end
    ' 2>/dev/null) || LAST_OUTPUT=""
  fi

  if [[ -n "$LAST_OUTPUT" ]]; then
    debug_log "Using thinking content as fallback (${#LAST_OUTPUT} chars)"
  fi
fi

# If still empty, check what content types are present
if [[ -z "$LAST_OUTPUT" ]]; then
  CONTENT_TYPES=$(echo "$LAST_LINE" | jq -r '.message.content[]?.type // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  debug_log "No text or thinking content found. Content types present: $CONTENT_TYPES"

  # If there's tool_use only, the LLM was mid-work - ask for status
  if [[ -n "$CONTENT_TYPES" ]]; then
    debug_log "Message has non-text content ($CONTENT_TYPES) - requesting status update"
    info "Ralph Loop Fork [$LOOP_ID]: Session ended without text output, requesting status..."
    info ""

    # Set flag to track this special case; clear orphan flags consistent with all other spawn sites
    update_state "$STATE_FILE" ".awaiting_checklist_update = true | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

    CHECKLIST_CONTENT=""
    CHECKED_COUNT=0
    UNCHECKED_COUNT=0
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")
      ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
      UNCHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f1)
      CHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f2)
    fi

    STATUS_PROMPT="RALPH LOOP: SESSION INTERRUPTED - STATUS REQUIRED

Your last response had no text output (only $CONTENT_TYPES).
The session is ending - please provide a status update.

CURRENT CHECKLIST STATUS: $CHECKED_COUNT checked, $UNCHECKED_COUNT unchecked

$(if [[ -n "$CHECKLIST_CONTENT" ]]; then echo "=== CHECKLIST ===" && echo "$CHECKLIST_CONTENT" && echo "=== END CHECKLIST ==="; fi)

═══════════════════════════════════════════════════════════════════════════════
CRITICAL: ALL CHECKLIST ITEMS MUST BE COMPLETED - NO EXCEPTIONS!
═══════════════════════════════════════════════════════════════════════════════

Every item in the checklist MUST be finished. No skipping, no deferring, no partial work.

REQUIRED ACTIONS:
1. Update the checklist file - mark completed items with [x]
2. Add session notes at the bottom

$(if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then echo "
IF ALL WORK IS 100% COMPLETE, output EXACTLY:
<promise>$COMPLETION_PROMISE</promise>

The XML tags are REQUIRED for completion detection!"; fi)"

    jq -n \
      --arg prompt "$STATUS_PROMPT" \
      --arg msg "Ralph [$LOOP_ID]: Session interrupted - provide status" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'
    exit 0
  fi

  # Truly empty/malformed message - exit cleanly
  debug_log "Message appears malformed or truly empty - exiting"
  rm -f "$LOCAL_FILE"
  exit 0
fi

debug_log "Parsed assistant output: ${#LAST_OUTPUT} chars"

# ============================================================================
# STATE MACHINE: CHECK awaiting_confirmation
# ============================================================================
if [[ "$AWAITING_CONFIRMATION" == "true" ]]; then
  debug_log "STATE: AWAITING_CONFIRMATION - checking for <confirmed>YES</confirmed>"

  # Parse for confirmed tag
  CONFIRMED_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<confirmed>(.*?)<\/confirmed>.*/$1/s; s/^\s+|\s+$//g' 2>/dev/null || echo "")

  if [[ -n "$CONFIRMED_TEXT" ]] && echo "$CONFIRMED_TEXT" | grep -qi "YES"; then
    debug_log "Confirmation detected: $CONFIRMED_TEXT"

    # Verify all checklist boxes are checked
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
      UNCHECKED=$(echo "$ITEM_COUNTS" | cut -d: -f1)
      CHECKED=$(echo "$ITEM_COUNTS" | cut -d: -f2)

      debug_log "Checklist check: $UNCHECKED unchecked, $CHECKED checked"

      if [[ "$UNCHECKED" -gt 0 ]]; then
        debug_log "Boxes NOT all checked - spawning new session"
        info "Ralph Loop Fork [$LOOP_ID]: Confirmation received but $UNCHECKED items still unchecked"
        info "   Spawning new session to continue work..."
        info ""

        # Clear flag and spawn
        update_state "$STATE_FILE" ".awaiting_confirmation = false | .total_iterations = $NEW_TOTAL_ITERATIONS | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

        NEW_SESSION_NUMBER=$((SESSION_NUMBER + 1))
        update_state "$STATE_FILE" ".session_number = $NEW_SESSION_NUMBER"
        rm -f "$LOCAL_FILE"

        spawn_new_session "$LOOP_ID" "$NEW_SESSION_NUMBER" "$STATE_FILE" "$PLUGIN_ROOT" "$PROJECT_ROOT"
        exit 0
      fi

      # All boxes checked - trigger on-completion
      debug_log "All boxes checked - triggering on-completion"
      info "Ralph Loop Fork [$LOOP_ID]: Confirmation verified, all $CHECKED items complete!"
      info ""

      # Best-effort move checklist to done/
      move_checklist_to_done "$CHECKLIST_PATH" || debug_log "move_checklist_to_done failed (non-fatal)"

      if [[ -n "$ON_COMPLETION_CMD" ]] && [[ "$ON_COMPLETION_CMD" != "null" ]]; then
        debug_log "Setting executing_on_completion and BLOCKing with on-completion command"

        update_state "$STATE_FILE" ".awaiting_confirmation = false | .executing_on_completion = true | .on_completion_triggered_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

        info "   Executing on-completion: $ON_COMPLETION_CMD"
        info ""

        # ONLY JSON to stdout
        jq -n \
          --arg cmd "$ON_COMPLETION_CMD" \
          --arg msg "Ralph [$LOOP_ID]: Executing on-completion command" \
          '{
            "decision": "block",
            "reason": $cmd,
            "systemMessage": $msg
          }'
        exit 0
      else
        # No on-completion command - just complete
        debug_log "No on-completion command - completing loop"
        info "   No on-completion command configured - loop complete!"
        info ""

        update_state "$STATE_FILE" ".awaiting_confirmation = false | .active = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"completed_no_on_completion\""

        emit_signal "ralph-completed" "$(jq -nc --arg reason "completed_no_on_completion" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$TOTAL_ITERATIONS" '{termination_reason: $reason, total_sessions: $sessions, total_iterations: $iterations}')"
        SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Loop complete — $SESSION_NUMBER session(s)")
        jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

        debug_log "Spawning detached cleanup (no on-completion)"
        run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"

        exit 0
      fi
    else
      # No checklist - just complete
      debug_log "No checklist to verify - completing"

      if [[ -n "$ON_COMPLETION_CMD" ]] && [[ "$ON_COMPLETION_CMD" != "null" ]]; then
        update_state "$STATE_FILE" ".awaiting_confirmation = false | .executing_on_completion = true"

        jq -n \
          --arg cmd "$ON_COMPLETION_CMD" \
          --arg msg "Ralph [$LOOP_ID]: Executing on-completion command" \
          '{
            "decision": "block",
            "reason": $cmd,
            "systemMessage": $msg
          }'
        exit 0
      else
        update_state "$STATE_FILE" ".awaiting_confirmation = false | .active = false | .completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | .termination_reason = \"completed_no_checklist\""

        emit_signal "ralph-completed" "$(jq -nc --arg reason "completed_no_checklist" --argjson sessions "$SESSION_NUMBER" --argjson iterations "$TOTAL_ITERATIONS" '{termination_reason: $reason, total_sessions: $sessions, total_iterations: $iterations}')"
        SEQ=$(build_terminal_sequence "Ralph Loop Fork [$LOOP_ID]" "Loop complete — $SESSION_NUMBER session(s)")
        jq -n --arg seq "$SEQ" '{"terminalSequence": $seq}'

        debug_log "Spawning detached cleanup (no checklist, no on-completion)"
        run_cleanup_detached "$LOOP_ID" "$STATE_FILE" "$PRESERVE_FINAL_SESSION" "$NO_CLEANUP" "$LOOP_DIR" "$PROJECT_ROOT"
        exit 0
      fi
    fi
  else
    # No confirmed tag - LLM continued working, spawn new session
    debug_log "No confirmed tag found - spawning new session"
    info "Ralph Loop Fork [$LOOP_ID]: No confirmation received, continuing work..."
    info ""

    update_state "$STATE_FILE" ".awaiting_confirmation = false | .total_iterations = $NEW_TOTAL_ITERATIONS | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

    NEW_SESSION_NUMBER=$((SESSION_NUMBER + 1))
    update_state "$STATE_FILE" ".session_number = $NEW_SESSION_NUMBER"
    rm -f "$LOCAL_FILE"

    spawn_new_session "$LOOP_ID" "$NEW_SESSION_NUMBER" "$STATE_FILE" "$PLUGIN_ROOT" "$PROJECT_ROOT"
    exit 0
  fi
fi

# ============================================================================
# STATE MACHINE: CHECK awaiting_checklist_update
# Defense-in-depth: in practice this block is unreachable because
# (a) stop_hook_active=true + awaiting_checklist_update=true is handled by the
#     continuation-cycle block above (line ~848, spawns + exits), and
# (b) stop_hook_active=false + awaiting_checklist_update=true is cleared by the
#     stale-state detector above (line ~823) before reaching here.
# Retained so any future code path that sets the flag still works correctly.
# ============================================================================
if [[ "$AWAITING_CHECKLIST_UPDATE" == "true" ]]; then
  debug_log "STATE: AWAITING_CHECKLIST_UPDATE - LLM updated checklist, spawning new session"
  info "Ralph Loop Fork [$LOOP_ID]: Checklist updated, spawning new session..."
  info ""

  update_state "$STATE_FILE" ".awaiting_checklist_update = false | .total_iterations = $NEW_TOTAL_ITERATIONS | .awaiting_background_agents = false | .bg_agent_block_count = 0 | .executing_on_completion = false"

  NEW_SESSION_NUMBER=$((SESSION_NUMBER + 1))
  update_state "$STATE_FILE" ".session_number = $NEW_SESSION_NUMBER"
  rm -f "$LOCAL_FILE"

  spawn_new_session "$LOOP_ID" "$NEW_SESSION_NUMBER" "$STATE_FILE" "$PLUGIN_ROOT" "$PROJECT_ROOT"
  exit 0
fi

# ============================================================================
# STATE MACHINE: RUNNING STATE - Check for promise
# ============================================================================
debug_log "STATE: RUNNING - checking for completion promise"

# Check for promise in output
PROMISE_DETECTED=false
if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")
  debug_log "Extracted promise text: '$PROMISE_TEXT'"
  debug_log "Expected promise: '$COMPLETION_PROMISE'"

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    PROMISE_DETECTED=true
    debug_log "Promise matched!"
  fi
fi

if [[ "$PROMISE_DETECTED" == "true" ]]; then
  # Promise detected - transition to AWAITING_CONFIRMATION
  debug_log "TRANSITION: RUNNING → AWAITING_CONFIRMATION"

  # First verify checklist boxes
  if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
    ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
    UNCHECKED=$(echo "$ITEM_COUNTS" | cut -d: -f1)
    CHECKED=$(echo "$ITEM_COUNTS" | cut -d: -f2)

    debug_log "Checklist: $UNCHECKED unchecked, $CHECKED checked"

    if [[ "$UNCHECKED" -gt 0 ]]; then
      # Boxes not all checked - reject and ask to update
      debug_log "Promise detected but $UNCHECKED unchecked items - rejecting"
      info "Ralph Loop Fork [$LOOP_ID]: Promise detected but $UNCHECKED items unchecked"
      info "   Please update the checklist before confirming completion."
      info ""

      update_state "$STATE_FILE" ".awaiting_checklist_update = true | .promise_rejected_unchecked = true"

      CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")

      REJECT_PROMPT="RALPH LOOP: COMPLETION REJECTED - UNCHECKED ITEMS

You output <promise>$COMPLETION_PROMISE</promise> but $UNCHECKED items are still unchecked.

=== CHECKLIST ($CHECKED checked, $UNCHECKED unchecked) ===
$CHECKLIST_CONTENT
=== END CHECKLIST ===

═══════════════════════════════════════════════════════════════════════════════
CRITICAL: ALL CHECKLIST ITEMS MUST BE COMPLETED - NO EXCEPTIONS!
═══════════════════════════════════════════════════════════════════════════════

Every item in the checklist MUST be finished, regardless of:
- Priority (high, medium, low - ALL must be done)
- Difficulty (easy or hard - ALL must be done)
- Time taken (quick or long - ALL must be done)

If an item is in the checklist, IT MUST BE COMPLETED. No skipping, no deferring, no \"good enough\".

REQUIRED ACTIONS:
1. Review each unchecked [ ] item
2. If genuinely complete: mark as [x]
3. If NOT complete: FINISH IT NOW, then mark as [x]
4. Only output the promise when EVERY SINGLE item is [x]$(if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then echo "

=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="; fi)"

      jq -n \
        --arg prompt "$REJECT_PROMPT" \
        --arg msg "Ralph [$LOOP_ID]: $UNCHECKED unchecked items - update checklist" \
        '{
          "decision": "block",
          "reason": $prompt,
          "systemMessage": $msg
        }'
      exit 0
    fi
  fi


  # Git dirty check: if checklist has uncommitted changes, block before confirming.
  # Only applies when git is available and the path is inside a git repo.
  if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
    if checklist_is_git_dirty "$CHECKLIST_PATH"; then
      GIT_STATUS_LINE=$(git status --porcelain -- "$CHECKLIST_PATH" 2>/dev/null || echo "(unable to get git status)")
      debug_log "Checklist has uncommitted git changes: $GIT_STATUS_LINE"
      info "Ralph Loop Fork [$LOOP_ID]: Checklist has uncommitted git changes - commit before completing"
      info ""

      update_state "$STATE_FILE" ".awaiting_checklist_update = true"

      DIRTY_PROMPT="RALPH LOOP: COMPLETION REJECTED - UNCOMMITTED CHECKLIST CHANGES

You output <promise>$COMPLETION_PROMISE</promise> and all boxes are [x], but the
checklist file has uncommitted changes in git:

  $GIT_STATUS_LINE

The stop hook requires the checklist to be committed so the [x] ticks are
preserved after the worktree is cleaned up (uncommitted changes are lost on
worktree removal, which is what caused this protection to be added).

═══════════════════════════════════════════════════════════════════════════════
REQUIRED BEFORE RE-OUTPUTTING THE PROMISE
═══════════════════════════════════════════════════════════════════════════════

1. Stage the checklist file:
     git add <path/to/checklist>

2. Commit:
     git commit -m "chore: tick checklist items — <brief description>"

3. Re-output the promise:
     <promise>$COMPLETION_PROMISE</promise>$(if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then echo "

=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="; fi)"

      jq -n \
        --arg prompt "$DIRTY_PROMPT" \
        --arg msg "Ralph [$LOOP_ID]: Checklist has uncommitted changes - commit first" \
        '{
          "decision": "block",
          "reason": $prompt,
          "systemMessage": $msg
        }'
      exit 0
    fi
  fi

  # AEOS marker gate: evidence-marker check before accepting completion promise.
  # Active only when .aeos-config.json present with non-empty required_markers (W4 fail-open).
  # Sets awaiting_checklist_update=true so the continuation cycle spawns the next session.
  if [[ -f "$AEOS_CONFIG_FILE" ]]; then
    _MG_MARKERS=$(jq -r '.required_markers // [] | map(select(length>0)) | join(" ")' "$AEOS_CONFIG_FILE" 2>/dev/null) || _MG_MARKERS=""
    _MG_PLAN_DIR=$(jq -r '.plan_dir // ""' "$AEOS_CONFIG_FILE" 2>/dev/null) || _MG_PLAN_DIR=""

    if [[ -n "$_MG_MARKERS" ]] && [[ -n "$_MG_PLAN_DIR" ]]; then
      _MG_MISSING=()
      for _marker in $_MG_MARKERS; do
        if [[ ! -f "$PROJECT_ROOT/$_MG_PLAN_DIR/.evidence/$_marker" ]]; then
          _MG_MISSING+=("$_marker")
        fi
      done

      if [[ ${#_MG_MISSING[@]} -gt 0 ]]; then
        # Increment marker_block_count gated on first hook fire per fork.
        _MG_COUNT=$(jq -r '.marker_block_count // 0' "$STATE_FILE" 2>/dev/null) || _MG_COUNT=0
        if [[ "$STOP_HOOK_ACTIVE" == "false" ]]; then
          _MG_COUNT=$((_MG_COUNT + 1))
          update_state "$STATE_FILE" ".marker_block_count = $_MG_COUNT | .awaiting_checklist_update = true"
        else
          update_state "$STATE_FILE" ".awaiting_checklist_update = true"
        fi

        _MG_MISSING_LIST=""
        for _marker in "${_MG_MISSING[@]}"; do
          _MG_MISSING_LIST="${_MG_MISSING_LIST:+${_MG_MISSING_LIST}, }${_marker}"
        done

        _MG_CMD_BLOCK=""
        for _marker in "${_MG_MISSING[@]}"; do
          case "$_marker" in
            tested)
              _MG_CMD_BLOCK="${_MG_CMD_BLOCK}  <test-command> | python3 .claude/scripts/mark.py tested --plan ${_MG_PLAN_DIR}
"
              ;;
            reviewed)
              _MG_CMD_BLOCK="${_MG_CMD_BLOCK}  python3 .claude/scripts/mark.py reviewed --plan ${_MG_PLAN_DIR} --critical 0 --warnings 0 --info 0
"
              ;;
            manual-tested)
              _MG_CMD_BLOCK="${_MG_CMD_BLOCK}  echo '<describe what you tested and observed>' | python3 .claude/scripts/mark.py manual-tested --plan ${_MG_PLAN_DIR}
"
              ;;
            *)
              _MG_CMD_BLOCK="${_MG_CMD_BLOCK}  python3 .claude/scripts/mark.py ${_marker} --plan ${_MG_PLAN_DIR}
"
              ;;
          esac
        done

        _MG_ESCALATION=""
        if [[ $_MG_COUNT -ge 3 ]]; then
          _MG_ESCALATION="

⚠️  This is marker-block #$_MG_COUNT. If evidence markers cannot be written (test
   suite unavailable, environment issue, etc.), record a revision and let the
   revision-budget mechanism terminate the loop cleanly:
     python3 .claude/scripts/loop_state.py add-revision \\
       --plan $_MG_PLAN_DIR \\
       --source verifier \\
       --categories testing \\
       --summary \"Evidence markers unavailable — cannot satisfy evidence requirements\""
        fi

        MARKER_GATE_MSG="RALPH LOOP: COMPLETION BLOCKED — EVIDENCE MARKERS MISSING

You output <promise>$COMPLETION_PROMISE</promise> but required evidence markers are absent.
  Missing: $_MG_MISSING_LIST

═══════════════════════════════════════════════════════════════════════════════
REQUIRED BEFORE RE-OUTPUTTING THE PROMISE
═══════════════════════════════════════════════════════════════════════════════

Run the mark.py command(s) for each missing marker:

${_MG_CMD_BLOCK}
Then re-output the promise:
  <promise>$COMPLETION_PROMISE</promise>${_MG_ESCALATION}"

        jq -n \
          --arg prompt "$MARKER_GATE_MSG" \
          --arg msg "Ralph [$LOOP_ID]: Evidence markers missing: $_MG_MISSING_LIST (block #$_MG_COUNT)" \
          '{
            "decision": "block",
            "reason": $prompt,
            "systemMessage": $msg
          }'
        debug_log "AEOS marker gate: BLOCK, missing=[$_MG_MISSING_LIST], block_count=$_MG_COUNT"
        exit 0
      else
        # All markers present — reset consecutive block counter.
        update_state "$STATE_FILE" ".marker_block_count = 0"
        debug_log "AEOS marker gate: all required markers present ($_MG_MARKERS)"
      fi
    else
      debug_log "AEOS marker gate: required_markers empty or plan_dir absent — skipping"
    fi
  fi

  # All boxes checked (or no checklist) - ask for confirmation
  info "Ralph Loop Fork [$LOOP_ID]: Promise detected, requesting confirmation..."
  info ""

  update_state "$STATE_FILE" ".awaiting_confirmation = true | .promise_detected_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

  CHECKLIST_CONTENT=""
  CHECKED_COUNT="all"
  if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
    CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")
    ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
    CHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f2)
  fi

  CONFIRM_PROMPT="RALPH LOOP: CONFIRMATION REQUIRED

You output <promise>$COMPLETION_PROMISE</promise> and all $CHECKED_COUNT items are marked complete.

═══════════════════════════════════════════════════════════════════════════════
CRITICAL: VERIFY EVERY ITEM IS 100% COMPLETE
═══════════════════════════════════════════════════════════════════════════════

EVERY checklist item must be FULLY FINISHED - no partial work, no \"good enough\", no shortcuts.
If even ONE item is incomplete or partially done, you MUST NOT confirm completion.

Review the checklist below with 100% confidence that EVERY item is TRULY complete:

$(if [[ -n "$CHECKLIST_CONTENT" ]]; then echo "=== CHECKLIST ===" && echo "$CHECKLIST_CONTENT" && echo "=== END CHECKLIST ==="; fi)
$(if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then echo "
=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="; fi)

═══════════════════════════════════════════════════════════════════════════════
CRITICAL: You MUST output the EXACT XML tags below. Plain 'YES' will NOT work!
═══════════════════════════════════════════════════════════════════════════════

If ALL items are 100% genuinely complete, output EXACTLY this (copy-paste it):

<confirmed>YES</confirmed>

⚠️  WRONG: YES
⚠️  WRONG: yes
⚠️  WRONG: Confirmed
✅ CORRECT: <confirmed>YES</confirmed>

The XML tags are REQUIRED for the hook to detect your confirmation!

WARNING: Do NOT confirm if you have ANY doubt."

  jq -n \
    --arg prompt "$CONFIRM_PROMPT" \
    --arg msg "Ralph [$LOOP_ID]: Confirm completion - output <confirmed>YES</confirmed>" \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'
  exit 0

else
  # No promise detected — check if we can re-feed in the same session or must fork
  if [[ $LOCAL_ITERATION -lt $MAX_PER_SESSION ]]; then
    # Still within session iteration budget — re-feed in the same session
    NEW_ITERATION=$((LOCAL_ITERATION + 1))
    debug_log "TRANSITION: RUNNING → RUNNING (re-feed, iteration $LOCAL_ITERATION → $NEW_ITERATION of $MAX_PER_SESSION)"
    info "Ralph Loop Fork [$LOOP_ID]: Iteration $LOCAL_ITERATION/$MAX_PER_SESSION — continuing in same session..."
    info ""

    # Increment iteration counter in local.md frontmatter (portable sed)
    sed -i.bak "s/^iteration: .*/iteration: $NEW_ITERATION/" "$LOCAL_FILE" && rm -f "${LOCAL_FILE}.bak"

    CHECKLIST_CONTENT=""
    CHECKED_COUNT=0
    UNCHECKED_COUNT=0
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")
      ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
      UNCHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f1)
      CHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f2)
    fi

    REMAINING=$((MAX_PER_SESSION - LOCAL_ITERATION))

    REFEED_PROMPT="RALPH LOOP: CONTINUE WORKING (Session $SESSION_NUMBER, Iteration $NEW_ITERATION/$MAX_PER_SESSION)

You have $REMAINING more iteration(s) available in this session before a fresh session is forked.

Continue working on the checklist until all items are complete.

CURRENT STATUS: $CHECKED_COUNT checked, $UNCHECKED_COUNT unchecked

$(if [[ -n "$CHECKLIST_CONTENT" ]]; then echo "=== CHECKLIST ===" && echo "$CHECKLIST_CONTENT" && echo "=== END CHECKLIST ==="; fi)
$(if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then echo "
=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="; fi)

$(if [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$COMPLETION_PROMISE" ]]; then echo "When ALL work is 100% complete, output:
<promise>$COMPLETION_PROMISE</promise>"; fi)"

    jq -n \
      --arg prompt "$REFEED_PROMPT" \
      --arg msg "Ralph [$LOOP_ID]: Continue (iteration $NEW_ITERATION/$MAX_PER_SESSION)" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'
    exit 0

  else
    # Iteration limit reached — transition to AWAITING_CHECKLIST_UPDATE (fork path)
    debug_log "TRANSITION: RUNNING → AWAITING_CHECKLIST_UPDATE (iteration $LOCAL_ITERATION/$MAX_PER_SESSION exhausted)"
    info "Ralph Loop Fork [$LOOP_ID]: Session iteration limit reached ($LOCAL_ITERATION/$MAX_PER_SESSION), requesting checklist update before forking..."
    info ""

    update_state "$STATE_FILE" ".awaiting_checklist_update = true"

    CHECKLIST_CONTENT=""
    CHECKED_COUNT=0
    UNCHECKED_COUNT=0
    if [[ -n "$CHECKLIST_PATH" ]] && [[ -f "$CHECKLIST_PATH" ]]; then
      CHECKLIST_CONTENT=$(read_checklist_content "$CHECKLIST_PATH")
      ITEM_COUNTS=$(count_checklist_items "$CHECKLIST_PATH")
      UNCHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f1)
      CHECKED_COUNT=$(echo "$ITEM_COUNTS" | cut -d: -f2)
    fi

    UPDATE_PROMPT="RALPH LOOP: SESSION ENDING - UPDATE CHECKLIST

Before this session ends, please update the checklist.

CURRENT STATUS: $CHECKED_COUNT checked, $UNCHECKED_COUNT unchecked

$(if [[ -n "$CHECKLIST_CONTENT" ]]; then echo "=== CHECKLIST ===" && echo "$CHECKLIST_CONTENT" && echo "=== END CHECKLIST ==="; fi)
$(if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then echo "
=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="; fi)

═══════════════════════════════════════════════════════════════════════════════
CRITICAL: ALL CHECKLIST ITEMS MUST BE COMPLETED - NO EXCEPTIONS!
═══════════════════════════════════════════════════════════════════════════════

Every item in the checklist MUST be finished, regardless of priority, difficulty, or time.
If an item is in the checklist, IT MUST BE COMPLETED. No skipping, no deferring, no partial work.

Continue working through ALL items until EVERY SINGLE ONE is marked [x].

REQUIRED ACTIONS:
1. Mark completed items with [x]
2. Add session notes at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Work completed
   - Problems encountered
   - Context for next session

After updating, you may exit. A fresh session will continue the work."

    jq -n \
      --arg prompt "$UPDATE_PROMPT" \
      --arg msg "Ralph [$LOOP_ID]: Update checklist ($CHECKED_COUNT/$((CHECKED_COUNT + UNCHECKED_COUNT)) complete)" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'
    exit 0
  fi
fi

debug_log "Hook completed - end of script"
