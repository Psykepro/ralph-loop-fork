#!/bin/bash

# Shared launch constants and checklist status helpers for every loop session
# spawn: session 1 and forks. Sourced by setup-ralph-loop-fork.sh,
# fork-terminal-herdr.sh and the stop hook so the launch sites, prompt variants
# and checklist counters cannot drift apart.

# Iterations busy-waited on background sub-agents with ScheduleWakeup instead
# of ending the turn. The = form is required: --disallowedTools is variadic,
# so the space form swallows the positional init message that follows it.
RALPH_DISALLOWED_TOOLS_ARG="--disallowedTools=ScheduleWakeup"

# The stop hook defers silently while sub-agents are pending (v0.8.0); it
# does not hold the session open, so the model must end its own turn.
RALPH_PARALLEL_SUBAGENTS_TEXT='PARALLEL SUB-AGENTS:
- Sub-agents run in the background by default; their results arrive as task notifications on a
  later turn, not inline. Launch as many as you need, in one message for parallelism.
- After launching background sub-agents, END YOUR TURN with a short text-only reply. Each
  result re-invokes you automatically as a new turn; the loop does not advance while any
  sub-agent you launched is still pending.
- Do NOT wait by polling: no ScheduleWakeup, no repeated ListAgents calls, no ls/sleep loops
  over output folders. For a genuine timed wait on external work, run a single Bash command
  with run_in_background and end your turn.
- Do NOT declare completion or output the promise until you have received and integrated every
  sub-agent result.
- Do NOT spawn new sub-agents after outputting the promise.'

# Checklist status helpers (also sourced by the stop hook). Counts two kinds
# of items, "### Session N Notes"
# sections excluded:
#   - checkboxes: "- [ ]" open, "- [x]" done
#   - split-plan status rows: a markdown table row with a cell naming a *.md
#     file plus a status marker. 🟢/✅ (or the word completed/done) = done;
#     🔴/🟡/🟠/⬜/⏸ (or pending/in progress/blocked/todo/not started) = open.
#     Each file counts once (its first status row), so a later handoff-log row
#     mentioning the same file cannot hold the plan open forever.

# Prints content minus "### Session N Notes" sections (header through the next
# "#"/"##"/"###" heading, exclusive): ticks copied into notes are not progress.
strip_session_notes() {
  awk '
    /^### Session [0-9]+ Notes/ { skip=1; next }
    /^(# |## |### )/ { skip=0 }
    !skip { print }
  ' "$1"
}

# Prints one "<status> <file>" line per split-plan row, status = done|open,
# first row per file wins, in document order.
list_split_rows() {
  [[ -f "$1" ]] || return 1
  strip_session_notes "$1" | awk '
    /^[[:space:]]*\|/ {
      file = ""
      n = split($0, cell, "|")
      for (i = 1; i <= n; i++) {
        c = cell[i]; gsub(/^[[:space:]]+|[[:space:]]+$/, "", c); gsub(/`/, "", c)
        if (c ~ /^[^[:space:]]+\.md$/) { file = c; break }
      }
      if (file == "" || (file in seen)) next
      lc = tolower($0); st = ""
      if (index($0, "🟢") || index($0, "✅")) st = "done"
      else if (index($0, "🔴") || index($0, "🟡") || index($0, "🟠") || index($0, "⬜") || index($0, "⏸")) st = "open"
      else if (lc ~ /\| *(completed|done) *\|/) st = "done"
      else if (lc ~ /\| *(pending|in[ -]progress|blocked|todo|not started) *\|/) st = "open"
      if (st == "") next
      seen[file] = 1
      print st " " file
    }'
}

# Prints "<open>:<done>:<first open file>" for a split master; open=done=0 when
# the file has no status rows (a flat checklist).
split_plan_status() {
  local rows open done first
  rows=$(list_split_rows "$1") || { echo "0:0:"; return 1; }
  open=$(grep -c '^open ' <<<"$rows") || true
  done=$(grep -c '^done ' <<<"$rows") || true
  first=$(awk '$1 == "open" { print $2; exit }' <<<"$rows")
  echo "${open:-0}:${done:-0}:${first}"
}

# Prints "<unchecked>:<checked>" — checkboxes plus split-plan status rows.
count_checklist_items() {
  local checklist_file="$1"
  if [[ ! -f "$checklist_file" ]]; then
    echo "0:0"
    return 1
  fi
  local body unchecked checked split
  body=$(strip_session_notes "$checklist_file")
  unchecked=$(grep -c '^[[:space:]]*-[[:space:]]*\[ \]' <<<"$body") || true
  checked=$(grep -c '^[[:space:]]*-[[:space:]]*\[[xX]\]' <<<"$body") || true
  split=$(split_plan_status "$checklist_file")
  echo "$(( ${unchecked:-0} + ${split%%:*} )):$(( ${checked:-0} + $(cut -d: -f2 <<<"$split") ))"
}

# Prints the instruction block that scopes a session to one sub-checklist of a
# split plan; prints nothing for a flat checklist or a finished split plan.
split_scope_text() {
  local split open first
  split=$(split_plan_status "$1") || return 0
  open=${split%%:*}
  first=${split##*:}
  [[ "$open" -gt 0 && -n "$first" ]] || return 0
  cat <<EOF
SPLIT PLAN — ONE SUB-CHECKLIST PER SESSION ($open sub-checklist(s) still open):
- This session works ONLY on $first (the first sub-checklist whose row is not 🟢).
- Finish it: tick all its boxes, commit, mark its row "🟢 completed" in the master,
  append its handoff-log entry — then STOP and end your turn.
- The stop hook forks a fresh session for the next sub-checklist. Do NOT start the
  next sub-checklist in this session, even if the launched command says to continue.
- Output the completion promise only after the LAST open row turns 🟢; until then
  just stop.
EOF
}
