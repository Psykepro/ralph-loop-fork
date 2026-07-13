#!/bin/bash

# Fork Terminal Script for Ralph Loop Fork
# Spawns a new tmux session to continue the loop
# Creates local state file BEFORE spawning to ensure hook works
#
# PARALLEL SESSION SUPPORT:
# Sessions named: ralph-{LOOP_ID}-{N}

set -euo pipefail

# Arguments
LOOP_ID="${1:?Error: Loop ID is required}"
SESSION_NUMBER="${2:-1}"
PROJECT_ROOT="${3:-$(pwd)}"

# CRITICAL: Change to PROJECT_ROOT immediately to ensure relative paths work
# This fixes the bug where hook runs from a subdirectory (e.g., after Claude cd's)
cd "$PROJECT_ROOT" || {
  echo "Error: Cannot change to PROJECT_ROOT: $PROJECT_ROOT" >&2
  exit 1
}

# Configuration - these are relative to PROJECT_ROOT (now current directory)
LOOP_DIR=".claude/ralph-fork/$LOOP_ID"
STATE_FILE="$LOOP_DIR/state.json"
LOCAL_FILE="$LOOP_DIR/local.md"
PROMPT_FILE="$LOOP_DIR/prompt.txt"
CWD="$PROJECT_ROOT"

# Check dependencies
if ! command -v tmux &> /dev/null; then
  echo "Error: tmux is required but was not found." >&2
  echo "   Install it via your package manager (apt/brew/pacman/...)." >&2
  if [[ -n "${MSYSTEM:-}" ]] || [[ "$(uname -s 2>/dev/null)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null)" == MSYS* ]]; then
    echo "   On Windows: tmux does not run on native Windows / Git Bash. Install WSL2 and run this from inside WSL." >&2
  fi
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but was not found." >&2
  echo "   Install it via your package manager (apt/brew/pacman/...)." >&2
  exit 1
fi

# Read state from file
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: State file not found: $STATE_FILE" >&2
  exit 1
fi

TOTAL_BUDGET=$(jq -r '.total_budget' "$STATE_FILE")
MAX_PER_SESSION=$(jq -r '.max_per_session' "$STATE_FILE")
COMPLETION_PROMISE=$(jq -r '.completion_promise' "$STATE_FILE")
CHECKLIST_PATH=$(jq -r '.checklist_file // ""' "$STATE_FILE")
COMMAND=$(jq -r '.command // ""' "$STATE_FILE")
STOP_HOOK_REMINDERS=$(jq -r '.stop_hook_reminders // ""' "$STATE_FILE")
MODEL=$(jq -r '.model // ""' "$STATE_FILE")
[[ "$MODEL" == "null" ]] && MODEL=""
# Effort: state files written before v0.5.0 have no effort key — fall back to
# the documented default (medium) rather than crashing or spawning unset.
# Keep the enum in sync with scripts/setup-ralph-loop-fork.sh --effort parse.
EFFORT=$(jq -r '.effort // ""' "$STATE_FILE")
[[ "$EFFORT" == "null" ]] && EFFORT=""
[[ -z "$EFFORT" ]] && EFFORT="medium"
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  *)
    echo "❌ ERROR: invalid effort '$EFFORT' in $STATE_FILE (allowed: low, medium, high, xhigh, max)" >&2
    exit 1
    ;;
esac

# Resolve CHECKLIST_PATH to absolute so forked sessions launched from any CWD can expand @
if [[ -n "$CHECKLIST_PATH" ]] && [[ "$CHECKLIST_PATH" != "null" ]] && [[ "$CHECKLIST_PATH" != /* ]]; then
  CHECKLIST_PATH="$PROJECT_ROOT/$CHECKLIST_PATH"
fi

# CRITICAL: Generate NEW session token for this forked session
# This invalidates the old session's token, preventing it from triggering hooks
# after spawning. Without this, old sessions continue running and spawn duplicates.
NEW_SESSION_TOKEN=$(uuidgen 2>/dev/null | tr -d '-' | head -c 16 || head -c 16 /dev/urandom | xxd -p | head -c 16)

# Update state.json with new token BEFORE spawning
jq ".session_token = \"$NEW_SESSION_TOKEN\"" "$STATE_FILE" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

SESSION_TOKEN="$NEW_SESSION_TOKEN"
echo "Generated new session token: $SESSION_TOKEN (old sessions will be invalidated)"

# Build prompt from checklist and command
if [[ -n "$COMMAND" ]] && [[ "$COMMAND" != "null" ]]; then
  PROMPT="$COMMAND @$CHECKLIST_PATH"
else
  PROMPT="Continue working on the checklist: @$CHECKLIST_PATH"
fi

# Session naming: ralph-{LOOP_ID}-{SESSION_NUMBER}
SESSION_NAME="ralph-$LOOP_ID-$SESSION_NUMBER"

# Check if session already exists
if tmux has-session -t "=$SESSION_NAME" 2>/dev/null; then
  # Session exists - increment and try again
  echo "Warning: Session $SESSION_NAME exists, incrementing..." >&2
  SESSION_NUMBER=$((SESSION_NUMBER + 1))
  SESSION_NAME="ralph-$LOOP_ID-$SESSION_NUMBER"

  # Update state file with new session number
  jq ".session_number = $SESSION_NUMBER" "$STATE_FILE" > "${STATE_FILE}.tmp"
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
fi


# Create local state file BEFORE spawning (critical for hook to work)
# Quote completion promise for YAML if it contains special chars or is not null
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

cat > "$LOCAL_FILE" <<EOF
---
loop_id: $LOOP_ID
active: true
session_number: $SESSION_NUMBER
session_token: $SESSION_TOKEN
iteration: 1
max_per_session: $MAX_PER_SESSION
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

echo "Created local state file for loop [$LOOP_ID] session $SESSION_NUMBER"

# Build reminders section if configured
REMINDERS_SECTION=""
if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then
  REMINDERS_SECTION="

=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="
fi

# Build the prompt with completion instructions
# Include ralph loop context so the new session knows how to complete
# Token is critical for preventing false matches from other sessions reading ralph files
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  FULL_PROMPT="$PROMPT

---
RALPH LOOP CONTEXT (Loop: $LOOP_ID, Session $SESSION_NUMBER, Token: $SESSION_TOKEN):
- This is a continuation session. Work through the checklist until complete.
- When ALL work is COMPLETE, output: <promise>$COMPLETION_PROMISE</promise>
- Only output the promise when the statement is completely TRUE.
- Do NOT lie to exit the loop.

PARALLEL SUB-AGENTS (CRITICAL RULE):
- NEVER use Agent with run_in_background=true inside this session.
  Background agents are orphaned when the session forks — results are LOST, tokens wasted.
- Parallel research still works: send multiple Agent calls WITHOUT run_in_background in ONE
  message. The harness runs them concurrently and waits for ALL to finish before continuing.
  You get full parallelism without losing results across session boundaries.
- Do NOT end your turn until every sub-agent result has been received and integrated.

BEFORE EXITING (MANDATORY):
1. Update the checklist file - mark completed items with [x]
2. Add a session notes section at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Key findings and decisions made
   - Problems encountered and solutions
   - Important context for future sessions
   - Learnings worth preserving for /reflect-learn
3. These notes will be used by /reflect-learn at the end to update skills$REMINDERS_SECTION"
else
  FULL_PROMPT="$PROMPT

---
RALPH LOOP CONTEXT (Loop: $LOOP_ID, Session $SESSION_NUMBER, Token: $SESSION_TOKEN):
- This is a continuation session. Work through the checklist until complete.

PARALLEL SUB-AGENTS (CRITICAL RULE):
- NEVER use Agent with run_in_background=true inside this session.
  Background agents are orphaned when the session forks — results are LOST, tokens wasted.
- Parallel research still works: send multiple Agent calls WITHOUT run_in_background in ONE
  message. The harness runs them concurrently and waits for ALL to finish before continuing.
  You get full parallelism without losing results across session boundaries.
- Do NOT end your turn until every sub-agent result has been received and integrated.

BEFORE EXITING (MANDATORY):
1. Update the checklist file - mark completed items with [x]
2. Add a session notes section at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Key findings and decisions made
   - Problems encountered and solutions
   - Important context for future sessions$REMINDERS_SECTION"
fi

# Save prompt to file for interactive mode (avoids shell escaping issues)
printf '%s' "$FULL_PROMPT" > "$PROMPT_FILE"

# Build command for interactive mode
# Claude reads prompt from file, session remains fully interactive
# Use absolute path so it works regardless of CWD when tmux session starts
PROMPT_FILE_ABS="$PROJECT_ROOT/.claude/ralph-fork/$LOOP_ID/prompt.txt"
INIT_MSG="Read and execute the task in $PROMPT_FILE_ABS"
# CRITICAL: Unset TMUX to allow spawning from inside an existing tmux session (avoids nesting error).
# CRITICAL: Unset CLAUDECODE to prevent "cannot be launched inside another Claude Code session" error.
# tmux sessions inherit env vars from the parent process, and CLAUDECODE causes Claude to
# refuse to start, silently killing the forked session (discovered 2026-02-14).
# Optional model pinning: persisted in state.json by setup --model (charset
# validated there since the value is interpolated into this shell command).
MODEL_FLAG=""
if [[ -n "$MODEL" ]]; then
  MODEL_FLAG=" --model $MODEL"
fi
EFFORT_FLAG=""
if [[ -n "$EFFORT" ]]; then
  EFFORT_FLAG=" --effort $EFFORT"
fi
FORK_CMD="unset TMUX CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SSE_PORT && export RALPH_LOOP_ACTIVE=1 && claude --dangerously-skip-permissions$MODEL_FLAG$EFFORT_FLAG '$INIT_MSG'"

# Validate CWD exists before spawning — catches deleted temp dirs (e.g., mktemp -d in tests)
if [[ ! -d "$CWD" ]]; then
  echo "Error: Working directory no longer exists: $CWD" >&2
  echo "  Loop: $LOOP_ID, expected at: $CWD" >&2
  exit 1
fi

echo "Forking to new session: $SESSION_NAME"

# Spawn detached tmux session
# Must unset TMUX in the env to avoid "sessions should be nested with care" when spawning from inside tmux
TMUX= tmux new-session -d -s "$SESSION_NAME" -c "$CWD" -e "RALPH_LOOP_ACTIVE=1" "$FORK_CMD" 2>&1 || {
  echo "Error: Failed to create tmux session $SESSION_NAME" >&2
  exit 1
}

# Log the fork event and store session name in spawned_sessions for cleanup
FORK_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq ".fork_history += [{\"session\": $SESSION_NUMBER, \"timestamp\": \"$FORK_TIMESTAMP\", \"session_name\": \"$SESSION_NAME\"}] | .spawned_sessions += [{\"name\": \"$SESSION_NAME\", \"spawned_at\": \"$FORK_TIMESTAMP\"}]" "$STATE_FILE" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

echo "Session $SESSION_NAME started"

# Auto-accept "Trust this folder" prompt for new directories (e.g., worktrees).
# Claude Code shows this prompt when launched in an untrusted directory.
# Sending Enter accepts the default (option 1: "Yes, I trust this folder").
# If no prompt appears (already trusted), Enter is harmless (empty input during startup).
(sleep 4 && tmux send-keys -t "=$SESSION_NAME" Enter 2>/dev/null) &

# ============================================================================
# CLEANUP OLD SESSIONS (BUG-008 fix)
# ============================================================================
# In interactive mode, after the stop hook spawns a new session and exits 0,
# the old Claude process returns to its REPL prompt and sits there forever.
# We must actively kill old sessions to prevent orphan accumulation.
#
# Uses nohup + background to survive parent process exit.
# 5-second delay lets the hook finish and return control before killing.
# NEVER kills the original_session_name (user's main session).
OLD_SESSIONS=$(jq -r '.spawned_sessions[]?.name // empty' "$STATE_FILE" 2>/dev/null)
ORIGINAL_SESSION=$(jq -r '.original_session_name // empty' "$STATE_FILE" 2>/dev/null)

if [[ -n "$OLD_SESSIONS" ]]; then
  # Build list of sessions to kill (exclude the just-spawned session and original)
  KILL_LIST=""
  for old_sess in $OLD_SESSIONS; do
    if [[ "$old_sess" != "$SESSION_NAME" ]] && [[ "$old_sess" != "$ORIGINAL_SESSION" ]]; then
      KILL_LIST="$KILL_LIST $old_sess"
    fi
  done

  if [[ -n "$KILL_LIST" ]]; then
    echo "Scheduling cleanup of old sessions:$KILL_LIST"
    ( nohup bash -c "
      sleep 5
      for s in $KILL_LIST; do
        tmux kill-session -t \"=\$s\" 2>/dev/null || true
      done
    " </dev/null >/dev/null 2>&1 & )
  fi
fi

echo ""
echo "List sessions: tmux ls | grep ralph"
echo "Attach to session: tmux attach -t $SESSION_NAME"

exit 0
