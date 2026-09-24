#!/bin/bash

# herdr-backend Fork Terminal Script for Ralph Loop Fork
# Sibling to fork-terminal.sh (the tmux backend) -- same job, herdr's
# socket-API CLI instead of tmux. See D2 in
# _project/specs/feature-ralph-loop-fork-herdr-backend-2026-08-09.md
# (AEOS repo) for the full design rationale and the live evidence behind
# each herdr call shape below.
#
# PARALLEL SESSION SUPPORT:
# Herdr agent names: ralph-{LOOP_ID}-{N}, sanitized+hashed via
# lib-herdr-backend.sh's herdr_derive_name() to fit herdr's
# [a-z][a-z0-9_-]{0,31} charset.

set -euo pipefail

# Arguments
LOOP_ID="${1:?Error: Loop ID is required}"
SESSION_NUMBER="${2:-1}"
PROJECT_ROOT="${3:-$(pwd)}"

cd "$PROJECT_ROOT" || {
  echo "Error: Cannot change to PROJECT_ROOT: $PROJECT_ROOT" >&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib-herdr-backend.sh
source "$SCRIPT_DIR/lib-herdr-backend.sh"

LOOP_DIR=".claude/ralph-fork/$LOOP_ID"
STATE_FILE="$LOOP_DIR/state.json"
LOCAL_FILE="$LOOP_DIR/local.md"
PROMPT_FILE="$LOOP_DIR/prompt.txt"
CWD="$PROJECT_ROOT"

if ! command -v herdr &> /dev/null; then
  echo "Error: herdr is required for --backend herdr but was not found." >&2
  echo "   Install it and ensure 'herdr server' is running." >&2
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but was not found." >&2
  exit 1
fi

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
# Built-in defaults — MUST match scripts/setup-ralph-loop-fork.sh's
# DEFAULT_MODEL/DEFAULT_EFFORT (pinned by tests/test-model-resolution.sh),
# same fallback pattern fork-terminal.sh uses.
DEFAULT_MODEL="sonnet"
DEFAULT_EFFORT="medium"

MODEL=$(jq -r '.model // ""' "$STATE_FILE")
[[ "$MODEL" == "null" ]] && MODEL=""
if [[ -z "$MODEL" ]]; then
  echo "⚠️  no model in $STATE_FILE — falling back to default: $DEFAULT_MODEL" >&2
  MODEL="$DEFAULT_MODEL"
fi

EFFORT=$(jq -r '.effort // ""' "$STATE_FILE")
[[ "$EFFORT" == "null" ]] && EFFORT=""
if [[ -z "$EFFORT" ]]; then
  echo "⚠️  no effort in $STATE_FILE — falling back to default: $DEFAULT_EFFORT" >&2
  EFFORT="$DEFAULT_EFFORT"
fi
case "$EFFORT" in
  low|medium|high|xhigh|max) ;;
  *)
    echo "❌ ERROR: invalid effort '$EFFORT' in $STATE_FILE (allowed: low, medium, high, xhigh, max)" >&2
    exit 1
    ;;
esac

if [[ -z "$MODEL" ]] || [[ -z "$EFFORT" ]]; then
  echo "❌ ERROR: refusing to spawn — model/effort resolved empty (model='$MODEL' effort='$EFFORT')" >&2
  exit 1
fi

STUCK_COUNT=$(jq -r '.stuck_count // 0' "$STATE_FILE" 2>/dev/null) || STUCK_COUNT=0
DOOM_THRESHOLD=$(jq -r '.doom_abort_threshold // 0' "$LOOP_DIR/.aeos-config.json" 2>/dev/null) || DOOM_THRESHOLD=0
STUCK_BANNER=""
if [[ "$DOOM_THRESHOLD" =~ ^[0-9]+$ ]] && [[ "$STUCK_COUNT" =~ ^[0-9]+$ ]] \
   && [[ "$DOOM_THRESHOLD" -gt 0 ]] && [[ "$STUCK_COUNT" -ge 1 ]]; then
  STUCK_BANNER="⚠️ NO-PROGRESS WARNING ($STUCK_COUNT of $DOOM_THRESHOLD strikes): the last $STUCK_COUNT session(s) ended with NO observable progress — no commit, no working-tree change, no checklist tick. At $DOOM_THRESHOLD strikes the loop TERMINATES.
FIRST ACTION THIS SESSION: land the close-out for any already-finished work — commit it, mark completed checklist items [x], append the handoff-log entry — BEFORE starting new work. If work landed outside this repo, tick + handoff NOW so progress becomes visible.

"
fi

if [[ -n "$CHECKLIST_PATH" ]] && [[ "$CHECKLIST_PATH" != "null" ]] && [[ "$CHECKLIST_PATH" != /* ]]; then
  CHECKLIST_PATH="$PROJECT_ROOT/$CHECKLIST_PATH"
fi

NEW_SESSION_ID=$(uuidgen 2>/dev/null | tr -d '-' | head -c 16 || head -c 16 /dev/urandom | xxd -p | head -c 16)
jq ".session_id = \"$NEW_SESSION_ID\" | del(.session_token)" "$STATE_FILE" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"
SESSION_ID="$NEW_SESSION_ID"
echo "Generated new session token: $SESSION_ID (old sessions will be invalidated)"

if [[ -n "$COMMAND" ]] && [[ "$COMMAND" != "null" ]]; then
  PROMPT="$COMMAND @$CHECKLIST_PATH"
else
  PROMPT="Continue working on the checklist: @$CHECKLIST_PATH"
fi

AGENT_NAME=$(herdr_derive_name "$LOOP_ID" "$SESSION_NUMBER")

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
session_id: $SESSION_ID
iteration: 1
max_per_session: $MAX_PER_SESSION
completion_promise: $COMPLETION_PROMISE_YAML
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$PROMPT
EOF

echo "Created local state file for loop [$LOOP_ID] session $SESSION_NUMBER"

REMINDERS_SECTION=""
if [[ -n "$STOP_HOOK_REMINDERS" ]] && [[ "$STOP_HOOK_REMINDERS" != "null" ]]; then
  REMINDERS_SECTION="

=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="
fi

if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  FULL_PROMPT="$STUCK_BANNER$PROMPT

---
RALPH LOOP CONTEXT (Loop: $LOOP_ID, Session $SESSION_NUMBER, Token: $SESSION_ID):
- This is a continuation session. Work through the checklist until complete.
- When ALL work is COMPLETE, output: <promise>$COMPLETION_PROMISE</promise>
- Only output the promise when the statement is completely TRUE.
- Do NOT lie to exit the loop.

PARALLEL SUB-AGENTS:
- Sub-agents run in the background by default; their results arrive as task notifications on a
  later turn, not inline. Launch as many as you need, in one message for parallelism.
- The loop's stop hook holds the session open (BLOCK-and-wait) until every launched sub-agent has
  delivered its result — do NOT declare completion or output the promise until you have received
  and integrated every result.
- Do NOT spawn new sub-agents after outputting the promise.

BEFORE EXITING (MANDATORY):
1. Update the checklist file - mark completed items with [x].
   Close-out is part of the work, not an epilogue: tick items and append the
   handoff entry in the SAME step as the commit that finishes them — a session
   boundary between 'work committed' and 'checklist ticked' reads as NO progress.
2. Add a session notes section at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Key findings and decisions made
   - Problems encountered and solutions
   - Important context for future sessions
   - Learnings worth preserving for /reflect-learn
3. These notes will be used by /reflect-learn at the end to update skills$REMINDERS_SECTION"
else
  FULL_PROMPT="$STUCK_BANNER$PROMPT

---
RALPH LOOP CONTEXT (Loop: $LOOP_ID, Session $SESSION_NUMBER, Token: $SESSION_ID):
- This is a continuation session. Work through the checklist until complete.

PARALLEL SUB-AGENTS:
- Sub-agents run in the background by default; their results arrive as task notifications on a
  later turn, not inline. Launch as many as you need, in one message for parallelism.
- The loop's stop hook holds the session open (BLOCK-and-wait) until every launched sub-agent has
  delivered its result — do NOT declare completion or output the promise until you have received
  and integrated every result.
- Do NOT spawn new sub-agents after outputting the promise.

BEFORE EXITING (MANDATORY):
1. Update the checklist file - mark completed items with [x].
   Close-out is part of the work, not an epilogue: tick items and append the
   handoff entry in the SAME step as the commit that finishes them — a session
   boundary between 'work committed' and 'checklist ticked' reads as NO progress.
2. Add a session notes section at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Key findings and decisions made
   - Problems encountered and solutions
   - Important context for future sessions$REMINDERS_SECTION"
fi

printf '%s' "$FULL_PROMPT" > "$PROMPT_FILE"

if [[ ! -d "$CWD" ]]; then
  echo "Error: Working directory no longer exists: $CWD" >&2
  echo "  Loop: $LOOP_ID, expected at: $CWD" >&2
  exit 1
fi

echo "Forking to new herdr agent: $AGENT_NAME"

# ============================================================================
# SPAWN via herdr socket-API
# ============================================================================
herdr_spawn_root_pane "$CWD" "$AGENT_NAME" || exit 1

# Env sanitation: the running herdr daemon's own environment may carry
# CLAUDECODE=1 (and friends), inherited by the pane's shell. Launching
# `claude` with CLAUDECODE already set produces "cannot be launched inside
# another Claude Code session," silently killing the fork — live-verified
# this session (AEOS spec's Showstopper Gate table). Unset before agent
# start; RALPH_LOOP_ACTIVE (set via --env above) survives this unset.
herdr pane run "$PANE_ID" 'unset CLAUDECODE CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDE_CODE_SSE_PORT ANTHROPIC_MODEL CLAUDE_CODE_EFFORT_LEVEL' \
  || echo "⚠️  env sanitation pane run failed (non-fatal, continuing)" >&2

# agent_pane_busy retry: a pane's shell isn't always ready the instant
# workspace create returns (live-reproduced, herdr-fork-terminal/SKILL.md's
# "Fresh-pane race" gotcha; same 0/0.5/1/2s backoff herdr_fork.py's
# spawn_agent() already uses for this exact race).
AGENT_START_OK=false
for delay in 0 0.5 1 2; do
  if [[ "$delay" != "0" ]]; then
    sleep "$delay"
  fi
  if herdr agent start "$AGENT_NAME" --kind claude --pane "$PANE_ID" -- --dangerously-skip-permissions --model "$MODEL" --effort "$EFFORT" 2>/tmp/herdr-agent-start-err.$$; then
    AGENT_START_OK=true
    break
  fi
done

if [[ "$AGENT_START_OK" != "true" ]]; then
  echo "Error: herdr agent start failed after retries" >&2
  [[ -f "/tmp/herdr-agent-start-err.$$" ]] && cat "/tmp/herdr-agent-start-err.$$" >&2
  rm -f "/tmp/herdr-agent-start-err.$$"
  herdr pane close "$PANE_ID" 2>/dev/null || true
  exit 1
fi
rm -f "/tmp/herdr-agent-start-err.$$"

# Prompt delivery: bare `agent prompt` (no --wait flag exists on herdr's
# CLI other than --wait itself, which we deliberately omit — fire-and-
# forget is the default), immediately followed by a literal Enter keypress.
# The Enter is NOT optional: $FULL_PROMPT is always multi-line, and a
# multi-line `agent prompt` triggers bracketed-paste mode which swallows
# the submit keypress (live-reproduced, herdr-fork-terminal/SKILL.md).
herdr agent prompt "$AGENT_NAME" "$FULL_PROMPT" || {
  echo "⚠️  herdr agent prompt reported failure — session may not have received its task" >&2
}
herdr agent send-keys "$AGENT_NAME" Enter || {
  echo "⚠️  herdr agent send-keys Enter failed — prompt may be un-submitted" >&2
}

# Log the fork event and record the new session's identifiers.
FORK_TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq ".fork_history += [{\"session\": $SESSION_NUMBER, \"timestamp\": \"$FORK_TIMESTAMP\", \"agent_name\": \"$AGENT_NAME\"}] | .spawned_sessions += [{\"name\": \"$AGENT_NAME\", \"agent_name\": \"$AGENT_NAME\", \"workspace_id\": \"$WS_ID\", \"pane_id\": \"$PANE_ID\", \"session_number\": $SESSION_NUMBER, \"spawned_at\": \"$FORK_TIMESTAMP\"}]" "$STATE_FILE" > "${STATE_FILE}.tmp"
mv "${STATE_FILE}.tmp" "$STATE_FILE"

echo "Herdr agent $AGENT_NAME started ($HERDR_SPAWN_KIND in workspace $WS_ID, pane $PANE_ID)"

# ============================================================================
# CLEANUP OLD SESSIONS — herdr equivalent of fork-terminal.sh's tmux
# cleanup block. Detached, best-effort, never blocks this script's own
# exit. Logged (not /dev/null) so a failed reap is recoverable — unlike
# the tmux path's equivalent block, which does discard output.
# ============================================================================
OLD_PANES=$(jq -r '.spawned_sessions[]?.pane_id // empty' "$STATE_FILE" 2>/dev/null)
CURRENT_PANE="$PANE_ID"

if [[ -n "$OLD_PANES" ]]; then
  KILL_LIST=""
  for old_pane in $OLD_PANES; do
    if [[ "$old_pane" != "$CURRENT_PANE" ]]; then
      KILL_LIST="$KILL_LIST $old_pane"
    fi
  done

  if [[ -n "$KILL_LIST" ]]; then
    echo "Scheduling cleanup of old herdr panes:$KILL_LIST"
    RALPH_LOG_DIR="${RALPH_FORK_LOG_DIR:-${TMPDIR:-/tmp}/ralph-fork-logs}"
    mkdir -p "$RALPH_LOG_DIR" 2>/dev/null || true
    ( nohup bash -c "
      sleep 5
      for p in $KILL_LIST; do
        herdr pane close \"\$p\" 2>&1 || echo \"[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] herdr pane close \$p FAILED\"
      done
    " </dev/null >>"$RALPH_LOG_DIR/herdr-cleanup.log" 2>&1 & )
  fi
fi

echo ""
echo "List agents: herdr agent list"
echo "Read output: herdr agent read $AGENT_NAME"

exit 0
