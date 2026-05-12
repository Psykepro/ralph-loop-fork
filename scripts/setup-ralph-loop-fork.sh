#!/bin/bash

# Ralph Loop Fork Setup Script
# Creates state files for fork-based Ralph loop
# On stop, forks to NEW terminal session instead of re-feeding prompt
#
# PARALLEL SESSION SUPPORT:
# Each loop is isolated in .claude/ralph-fork/{LOOP_ID}/ directory
# Sessions named: ralph-{LOOP_ID}-{N} managed via tmux

set -euo pipefail

# Parse arguments
CHECKLIST_FILE=""
COMMAND=""
TOTAL_BUDGET=100
MAX_PER_SESSION=1
COMPLETION_PROMISE="null"
RESUME=false
SESSION_NUMBER=1
PRESERVE_FINAL_SESSION=false
NO_CLEANUP=false
LOOP_NAME=""
ON_COMPLETION_CMD=""
STOP_HOOK_REMINDERS=""

# Parse options and positional arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      cat << 'HELP_EOF'
Ralph Loop Fork - Fork-based iterative development loop

USAGE:
  /ralph-loop-fork:ralph-loop-fork --checklist <path> [--command <cmd>] [OPTIONS]

ARGUMENTS:
  --checklist <path>         Path to checklist markdown file (REQUIRED)
  --command <cmd>            Slash command to execute (optional)

OPTIONS:
  --name <id>                Loop identifier for parallel sessions (e.g., "my-feature")
                             If not provided, generates 8-char hex ID
  --total-budget <n>         Total iterations across ALL sessions (default: 100)
  --max-per-session <n>      Max iterations per session before forking (default: 1)
  --completion-promise '<text>'  Promise phrase (USE QUOTES for multi-word)
  --preserve-final-session   Keep final session at completion (default: false)
  --no-preserve-final-session  Cleanup ALL sessions including final (default)
  --no-cleanup               Don't cleanup any sessions at completion
  --on-completion '<cmd>'    Command to execute when loop completes successfully (USE QUOTES)
  --stop-hook-reminders <text|path>  Custom reminders added to stop hook prompts
                             Can be a string or path to .md file
  --resume                   Resume from previous fork (internal use)
  --session <n>              Session number (internal use)
  -h, --help                 Show this help message

PARALLEL SESSIONS:
  Each loop is isolated in its own directory: .claude/ralph-fork/{LOOP_ID}/
  Sessions are named: ralph-{LOOP_ID}-{N} (e.g., ralph-my-feature-1)
  Managed via plain tmux sessions

  Run multiple loops in parallel:
    Terminal 1: /ralph-loop-fork:ralph-loop-fork --checklist checklist-a.md --name "task-a"
    Terminal 2: /ralph-loop-fork:ralph-loop-fork --checklist checklist-b.md --name "task-b"

EXAMPLES:
  /ralph-loop-fork:ralph-loop-fork --checklist path/to/checklist.md
  /ralph-loop-fork:ralph-loop-fork --checklist checklist.md --command "/implement"
  /ralph-loop-fork:ralph-loop-fork --checklist checklist.md --name "csrf" --completion-promise 'ALL_COMPLETE'
  /ralph-loop-fork:ralph-loop-fork --checklist checklist.md --total-budget 10
  /ralph-loop-fork:ralph-loop-fork --checklist checklist.md --completion-promise 'DONE' --on-completion '/reflect-learn'

CHECKLIST VALIDATION:
  - When using --completion-promise, the loop validates checklist completion
  - All items must be marked [x] before the promise is accepted
  - If unchecked items remain, the completion is rejected and self-validation triggered

STOPPING:
  - Reaching --total-budget stops the loop entirely
  - Detecting --completion-promise (with all items checked) stops without forking
  - Each session forks after --max-per-session iterations

MONITORING:
  # List all active loops:
  ls -la .claude/ralph-fork/

  # View specific loop state:
  cat .claude/ralph-fork/MY_LOOP_ID/state.json | jq

  # View all forked sessions:
  tmux ls | grep ralph
HELP_EOF
      exit 0
      ;;
    --name)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --name requires an identifier argument" >&2
        exit 1
      fi
      # Sanitize name: lowercase, replace spaces with dashes, remove special chars
      LOOP_NAME=$(echo "$2" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | sed 's/[^a-z0-9-]//g')
      if [[ -z "$LOOP_NAME" ]]; then
        echo "Error: --name resulted in empty identifier after sanitization" >&2
        exit 1
      fi
      shift 2
      ;;
    --checklist)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --checklist requires a file path" >&2
        exit 1
      fi
      if [[ ! -f "$2" ]]; then
        echo "Error: Checklist file not found: $2" >&2
        exit 1
      fi
      CHECKLIST_FILE="$2"
      shift 2
      ;;
    --command)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --command requires an argument" >&2
        exit 1
      fi
      # Strip leading/trailing quotes if present
      COMMAND="$2"
      COMMAND="${COMMAND#\"}"
      COMMAND="${COMMAND%\"}"
      COMMAND="${COMMAND#\'}"
      COMMAND="${COMMAND%\'}"
      shift 2
      ;;
    --total-budget)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --total-budget requires a number argument" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --total-budget must be a positive integer, got: $2" >&2
        exit 1
      fi
      TOTAL_BUDGET="$2"
      shift 2
      ;;
    --max-per-session)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-per-session requires a number argument" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-per-session must be a positive integer, got: $2" >&2
        exit 1
      fi
      MAX_PER_SESSION="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      # Strip leading/trailing quotes if present (user might include them accidentally)
      COMPLETION_PROMISE="$2"
      COMPLETION_PROMISE="${COMPLETION_PROMISE#\"}"  # Remove leading quote
      COMPLETION_PROMISE="${COMPLETION_PROMISE%\"}"  # Remove trailing quote
      COMPLETION_PROMISE="${COMPLETION_PROMISE#\'}"  # Remove leading single quote
      COMPLETION_PROMISE="${COMPLETION_PROMISE%\'}"  # Remove trailing single quote
      shift 2
      ;;
    --tool)
      echo "Error: --tool flag has been removed. The plugin now uses 'claude --dangerously-skip-permissions' directly." >&2
      exit 1
      ;;
    --preserve-final-session)
      PRESERVE_FINAL_SESSION=true
      shift
      ;;
    --no-preserve-final-session)
      PRESERVE_FINAL_SESSION=false
      shift
      ;;
    --no-cleanup)
      NO_CLEANUP=true
      shift
      ;;
    --on-completion)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --on-completion requires a command argument" >&2
        exit 1
      fi
      # Strip leading/trailing quotes if present
      ON_COMPLETION_CMD="$2"
      ON_COMPLETION_CMD="${ON_COMPLETION_CMD#\"}"
      ON_COMPLETION_CMD="${ON_COMPLETION_CMD%\"}"
      ON_COMPLETION_CMD="${ON_COMPLETION_CMD#\'}"
      ON_COMPLETION_CMD="${ON_COMPLETION_CMD%\'}"
      shift 2
      ;;
    --stop-hook-reminders)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --stop-hook-reminders requires a text or file path argument" >&2
        exit 1
      fi
      # Strip leading/trailing quotes if present
      STOP_HOOK_REMINDERS="$2"
      STOP_HOOK_REMINDERS="${STOP_HOOK_REMINDERS#\"}"
      STOP_HOOK_REMINDERS="${STOP_HOOK_REMINDERS%\"}"
      STOP_HOOK_REMINDERS="${STOP_HOOK_REMINDERS#\'}"
      STOP_HOOK_REMINDERS="${STOP_HOOK_REMINDERS%\'}"
      # If it's a file path, read the content
      if [[ -f "$STOP_HOOK_REMINDERS" ]]; then
        STOP_HOOK_REMINDERS=$(cat "$STOP_HOOK_REMINDERS")
        echo "Loaded stop-hook-reminders from file: $2"
      fi
      shift 2
      ;;
    --resume)
      RESUME=true
      shift
      ;;
    --session)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --session requires a number argument" >&2
        exit 1
      fi
      SESSION_NUMBER="$2"
      shift 2
      ;;
    *)
      echo "Error: Unknown argument: $1" >&2
      echo "   Positional arguments no longer supported." >&2
      echo "   Use: --checklist <path> [--command <cmd>]" >&2
      exit 1
      ;;
  esac
done

# Validate required --checklist argument (unless resuming)
if [[ "$RESUME" != "true" ]] && [[ -z "$CHECKLIST_FILE" ]]; then
  echo "Error: --checklist is required" >&2
  echo "" >&2
  echo "   Example:" >&2
  echo "     /ralph-loop-fork:ralph-loop-fork --checklist path/to/checklist.md" >&2
  exit 1
fi

# Build PROMPT from checklist and command
if [[ -n "$COMMAND" ]]; then
  PROMPT="$COMMAND @$CHECKLIST_FILE"
else
  PROMPT="Read and work on the checklist: @$CHECKLIST_FILE"
fi

# Check dependencies
if ! command -v jq &> /dev/null; then
  echo "Error: jq is required but was not found." >&2
  echo "   Install it via your package manager (apt/brew/pacman/...)." >&2
  exit 1
fi

if ! command -v tmux &> /dev/null; then
  echo "Error: tmux is required but was not found." >&2
  echo "   Install it via your package manager (apt/brew/pacman/...)." >&2
  # Best-effort Windows guidance (Git Bash / MSYS2 do not ship tmux)
  if [[ -n "${MSYSTEM:-}" ]] || [[ "$(uname -s 2>/dev/null)" == MINGW* ]] || [[ "$(uname -s 2>/dev/null)" == MSYS* ]]; then
    echo "   On Windows: tmux does not run on native Windows / Git Bash. Install WSL2 and run this from inside WSL." >&2
  fi
  exit 1
fi

# Generate loop ID if not provided
if [[ -z "$LOOP_NAME" ]]; then
  LOOP_ID=$(head -c 4 /dev/urandom | xxd -p)
else
  LOOP_ID="$LOOP_NAME"
fi

# Create loop directory structure
LOOP_DIR=".claude/ralph-fork/$LOOP_ID"
mkdir -p "$LOOP_DIR"

# File paths inside loop directory
STATE_FILE="$LOOP_DIR/state.json"
LOCAL_FILE="$LOOP_DIR/local.md"
PROMPT_FILE="$LOOP_DIR/prompt.txt"

# Handle resume from forked session
if [[ "$RESUME" == "true" ]]; then
  if [[ ! -f "$STATE_FILE" ]]; then
    echo "Error: Cannot resume - no state file found at $STATE_FILE" >&2
    exit 1
  fi

  # Read state from file
  TOTAL_BUDGET=$(jq -r '.total_budget' "$STATE_FILE")
  MAX_PER_SESSION=$(jq -r '.max_per_session' "$STATE_FILE")
  COMPLETION_PROMISE=$(jq -r '.completion_promise' "$STATE_FILE")
  PROMPT=$(jq -r '.prompt' "$STATE_FILE")
  TOTAL_ITERATIONS=$(jq -r '.total_iterations' "$STATE_FILE")
  PRESERVE_FINAL_SESSION=$(jq -r '.preserve_final_session // false' "$STATE_FILE")
  NO_CLEANUP=$(jq -r '.no_cleanup // false' "$STATE_FILE")
  SESSION_TOKEN=$(jq -r '.session_token // ""' "$STATE_FILE")

  echo "Resuming Ralph Loop Fork: $LOOP_ID (Session $SESSION_NUMBER)"
  echo ""
  echo "Total iterations so far: $TOTAL_ITERATIONS"
  echo "Total budget: $TOTAL_BUDGET"
  echo "Max per session: $MAX_PER_SESSION"
  echo "Preserve final session: $PRESERVE_FINAL_SESSION"
  echo "No cleanup: $NO_CLEANUP"
  echo "Completion promise: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "$COMPLETION_PROMISE"; else echo "none"; fi)"
  echo ""

else
  # Check if loop already exists
  if [[ -f "$STATE_FILE" ]]; then
    EXISTING_ACTIVE=$(jq -r '.active' "$STATE_FILE" 2>/dev/null || echo "false")
    if [[ "$EXISTING_ACTIVE" == "true" ]]; then
      echo "Error: Loop '$LOOP_ID' already exists and is active" >&2
      echo "   To cancel it: /ralph-loop-fork:cancel-ralph-fork $LOOP_ID" >&2
      echo "   Or use a different --name" >&2
      exit 1
    fi
  fi

  # Calculate initial checklist hash for progress detection.
  # Portable: prefer md5sum (Linux/WSL), fall back to md5 -q (macOS BSD), then shasum.
  CHECKLIST_HASH=""
  if [[ -n "$CHECKLIST_FILE" ]] && [[ -f "$CHECKLIST_FILE" ]]; then
    if command -v md5sum >/dev/null 2>&1; then
      CHECKLIST_HASH=$(md5sum "$CHECKLIST_FILE" | awk '{print $1}')
    elif command -v md5 >/dev/null 2>&1; then
      CHECKLIST_HASH=$(md5 -q "$CHECKLIST_FILE")
    elif command -v shasum >/dev/null 2>&1; then
      CHECKLIST_HASH=$(shasum -a 256 "$CHECKLIST_FILE" | awk '{print $1}')
    fi
  fi

  # Generate unique session token for stop hook identification
  # This prevents false matches when other sessions read ralph-related files
  SESSION_TOKEN=$(uuidgen 2>/dev/null | tr -d '-' | head -c 16 || head -c 16 /dev/urandom | xxd -p | head -c 16)

  # Create global state file (persists across sessions)
  COMPLETION_PROMISE_JSON="null"
  if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
    COMPLETION_PROMISE_JSON="\"$COMPLETION_PROMISE\""
  fi

  COMMAND_JSON="null"
  if [[ -n "$COMMAND" ]]; then
    COMMAND_JSON=$(echo "$COMMAND" | jq -Rs .)
  fi

  ON_COMPLETION_JSON="null"
  if [[ -n "$ON_COMPLETION_CMD" ]]; then
    ON_COMPLETION_JSON=$(echo "$ON_COMPLETION_CMD" | jq -Rs .)
  fi

  STOP_HOOK_REMINDERS_JSON="null"
  if [[ -n "$STOP_HOOK_REMINDERS" ]]; then
    STOP_HOOK_REMINDERS_JSON=$(printf '%s' "$STOP_HOOK_REMINDERS" | jq -Rs .)
  fi

  # Detect current tmux session name for preserve-final-session
  ORIGINAL_SESSION=""
  if [[ -n "${TMUX:-}" ]]; then
    ORIGINAL_SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "")
  fi

  # State machine flags:
  # - awaiting_checklist_update: LLM should update checklist, then hook spawns new session
  # - awaiting_confirmation: LLM confirmed promise, hook verifies boxes then triggers on-completion
  # - executing_on_completion: On-completion slash command was sent, next hook cleans up and exits
  cat > "$STATE_FILE" <<EOF
{
  "loop_id": "$LOOP_ID",
  "active": true,
  "total_budget": $TOTAL_BUDGET,
  "max_per_session": $MAX_PER_SESSION,
  "total_iterations": 0,
  "session_number": 1,
  "session_token": "$SESSION_TOKEN",
  "completion_promise": $COMPLETION_PROMISE_JSON,
  "prompt": $(echo "$PROMPT" | jq -Rs .),
  "preserve_final_session": $PRESERVE_FINAL_SESSION,
  "no_cleanup": $NO_CLEANUP,
  "checklist_hash": "$CHECKLIST_HASH",
  "checklist_file": "$CHECKLIST_FILE",
  "command": $COMMAND_JSON,
  "on_completion_command": $ON_COMPLETION_JSON,
  "stop_hook_reminders": $STOP_HOOK_REMINDERS_JSON,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "fork_history": [],
  "awaiting_checklist_update": false,
  "awaiting_confirmation": false,
  "executing_on_completion": false,
  "spawned_sessions": [],
  "original_session_name": "$ORIGINAL_SESSION"
}
EOF

  echo "Ralph Loop Fork activated: $LOOP_ID"
  echo ""
  echo "Loop ID: $LOOP_ID"
  echo "Session: 1"
  echo "Total budget: $TOTAL_BUDGET iterations"
  echo "Max per session: $MAX_PER_SESSION"
  echo "Preserve final session: $PRESERVE_FINAL_SESSION"
  echo "No cleanup: $NO_CLEANUP"
  echo "Completion promise: $(if [[ "$COMPLETION_PROMISE" != "null" ]]; then echo "$COMPLETION_PROMISE"; else echo "none (runs until budget)"; fi)"
  echo "On-completion: $(if [[ -n "$ON_COMPLETION_CMD" ]]; then echo "$ON_COMPLETION_CMD"; else echo "none"; fi)"
  echo "Stop-hook-reminders: $(if [[ -n "$STOP_HOOK_REMINDERS" ]]; then echo "configured (${#STOP_HOOK_REMINDERS} chars)"; else echo "none"; fi)"
  echo ""
  echo "State directory: $LOOP_DIR"
  echo ""

fi

# Quote completion promise for YAML if it contains special chars or is not null
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""
else
  COMPLETION_PROMISE_YAML="null"
fi

# Build reminders section if configured
REMINDERS_SECTION=""
if [[ -n "$STOP_HOOK_REMINDERS" ]]; then
  REMINDERS_SECTION="

=== REMINDERS ===
$STOP_HOOK_REMINDERS
=== END REMINDERS ==="
fi

# Build the full prompt with RALPH LOOP CONTEXT marker (needed for stop hook detection)
# The Token is critical - it uniquely identifies this session to prevent false matches
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]]; then
  FULL_PROMPT="$PROMPT

---
RALPH LOOP CONTEXT (Loop: $LOOP_ID, Session $SESSION_NUMBER, Token: $SESSION_TOKEN):
- This is session 1. Work through the checklist until complete.
- When ALL work is COMPLETE, output: <promise>$COMPLETION_PROMISE</promise>
- Only output the promise when the statement is completely TRUE.
- Do NOT lie to exit the loop.

BEFORE EXITING (MANDATORY):

CRITICAL RULES FOR CHECKLIST UPDATES:
- NEVER remove existing checklist items
- NEVER replace items with different items
- Only mark items [x] when completed
- Leave uncompleted items as [ ]
- Add session notes BELOW existing content, don't modify structure

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
- This is session 1. Work through the checklist until complete.

BEFORE EXITING (MANDATORY):

CRITICAL RULES FOR CHECKLIST UPDATES:
- NEVER remove existing checklist items
- NEVER replace items with different items
- Only mark items [x] when completed
- Leave uncompleted items as [ ]
- Add session notes BELOW existing content, don't modify structure

1. Update the checklist file - mark completed items with [x]
2. Add a session notes section at the bottom:
   ### Session $SESSION_NUMBER Notes
   - Key findings and decisions made
   - Problems encountered and solutions
   - Important context for future sessions$REMINDERS_SECTION"
fi

# Create local session state file (markdown with YAML frontmatter)
cat > "$LOCAL_FILE" <<EOF
---
loop_id: $LOOP_ID
active: true
session_number: $SESSION_NUMBER
session_token: $SESSION_TOKEN
iteration: 1
max_per_session: $MAX_PER_SESSION
completion_promise: $COMPLETION_PROMISE_YAML
preserve_final_session: $PRESERVE_FINAL_SESSION
no_cleanup: $NO_CLEANUP
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

$FULL_PROMPT
EOF

cat <<EOF

The stop hook is now active. When you try to exit:
- If task INCOMPLETE: Fork to NEW terminal session
- If completion promise detected: Exit normally (success)
- If total budget reached: Exit with message

Unlike standard ralph-loop, each iteration gets a FRESH context window.
Your previous work persists in files and git history.

WARNING: This loop cannot be stopped manually!
    To stop: output <promise>$COMPLETION_PROMISE</promise> (when TRUE)
    Or wait for budget ($TOTAL_BUDGET iterations) to exhaust.
    Or cancel: /ralph-loop-fork:cancel-ralph-fork $LOOP_ID

EOF

# Output the initial prompt with RALPH LOOP CONTEXT
echo ""
echo "$FULL_PROMPT"

# ═══════════════════════════════════════════════════════════════════════════
# SLASH COMMAND / SKILL DETECTION
# ═══════════════════════════════════════════════════════════════════════════
SLASH_COMMAND=""
if [[ "$PROMPT" =~ ^/?(/[a-zA-Z][a-zA-Z0-9_-]*) ]]; then
  SLASH_COMMAND="${BASH_REMATCH[1]}"
elif [[ "$PROMPT" =~ [[:space:]](/[a-zA-Z][a-zA-Z0-9_-]*) ]]; then
  SLASH_COMMAND="${BASH_REMATCH[1]}"
fi

if [[ -n "$SLASH_COMMAND" ]]; then
  echo ""
  echo "======================================================================="
  echo " SLASH COMMAND DETECTED: $SLASH_COMMAND"
  echo "======================================================================="
  echo ""
  echo " MANDATORY: Use the Skill tool to invoke '$SLASH_COMMAND' FIRST!"
  echo ""
  echo " Example:"
  echo "   Skill tool with skill: \"${SLASH_COMMAND#/}\""
  echo ""
  echo " Then follow ALL instructions in the expanded command."
  echo "======================================================================="
fi

# ═══════════════════════════════════════════════════════════════════════════
# SKILLS DETECTION FROM CHECKLIST FILE
# ═══════════════════════════════════════════════════════════════════════════
# This is a project-convention helper: if the checklist has a "Skills" section
# AND the project has a .claude/skills/ directory, print a "load these skills"
# reminder. Silently skipped for projects that don't follow this convention.
if [[ -n "$CHECKLIST_FILE" ]] && [[ -f "$CHECKLIST_FILE" ]] && [[ -d ".claude/skills" ]]; then
  SKILLS_SECTION=$(grep -A20 -E "^##? Skills( Required)?|^Skills Required" "$CHECKLIST_FILE" 2>/dev/null | head -20 || echo "")

  if [[ -n "$SKILLS_SECTION" ]]; then
    SKILLS=$(echo "$SKILLS_SECTION" | grep -E "^[[:space:]]*-" | sed 's/^[[:space:]]*-[[:space:]]*//' | head -10)

    if [[ -n "$SKILLS" ]]; then
      echo ""
      echo "======================================================================="
      echo " REQUIRED SKILLS DETECTED (LOAD BEFORE STARTING)"
      echo "======================================================================="
      echo "$SKILLS" | while read -r skill; do
        skill_clean=$(echo "$skill" | sed 's/[[:space:]]*$//' | tr -d '\r')
        if [[ -n "$skill_clean" ]]; then
          echo "   Read: .claude/skills/${skill_clean}.md"
        fi
      done
      echo ""
      echo " MANDATORY: Read each skill file BEFORE starting implementation!"
      echo "======================================================================="
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# COMPLETION PROMISE REQUIREMENTS
# ═══════════════════════════════════════════════════════════════════════════
if [[ "$COMPLETION_PROMISE" != "null" ]]; then
  echo ""
  echo "======================================================================="
  echo " COMPLETION PROMISE (OUTPUT THIS WHEN TASK IS 100% COMPLETE)"
  echo "======================================================================="
  echo ""
  echo "   <promise>$COMPLETION_PROMISE</promise>"
  echo ""
  echo " STRICT REQUIREMENTS:"
  echo "   - Use <promise> XML tags EXACTLY as shown above"
  echo "   - Statement MUST be completely and unequivocally TRUE"
  echo "   - Do NOT output false statements to exit the loop"
  echo "   - Output ONLY when ALL acceptance criteria are met"
  echo ""
  echo " WITHOUT THIS TAG: Session will fork to new terminal automatically!"
  echo "======================================================================="
fi

# ═══════════════════════════════════════════════════════════════════════════
# SESSION NOTES REQUIREMENT
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "======================================================================="
echo " SESSION NOTES (UPDATE CHECKLIST BEFORE EXITING)"
echo "======================================================================="
echo ""
echo " CRITICAL RULES FOR CHECKLIST UPDATES:"
echo "   - NEVER remove existing checklist items"
echo "   - NEVER replace items with different items"
echo "   - Only mark items [x] when completed"
echo "   - Leave uncompleted items as [ ]"
echo "   - Add session notes BELOW existing content, don't modify structure"
echo ""
echo " 1. Mark completed items with [x] in the checklist file"
echo ""
echo " 2. Add session notes at the bottom:"
echo "    ### Session $SESSION_NUMBER Notes"
echo "    - Key findings and decisions made"
echo "    - Problems encountered and solutions"
echo "    - Important context for future sessions"
echo "    - Learnings worth preserving"
echo ""
echo " These notes are used by /reflect-learn at completion."
echo "======================================================================="
