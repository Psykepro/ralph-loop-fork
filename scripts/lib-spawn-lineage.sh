#!/bin/bash

# Spawn lineage for loop sessions: one registry `spawn` row per launched
# session, child env carrying SPAWN_* so its SessionStart hook can bind.
# Sourced by setup-ralph-loop-fork.sh, fork-terminal.sh, fork-terminal-herdr.sh.
# Lineage is best-effort: every failure prints one visible line and returns 0,
# so a spawn is never broken by it. Kill-switch: SPAWN_REGISTRY_DISABLE=1.
#
# Usage (per launch):
#   spawn_lineage_begin  <project_root> <loop_id> <iteration> <state_file> <name>
#   ... create pane/session passing "${SPAWN_HERDR_ENV[@]}" / "${SPAWN_TMUX_ENV[@]}" ...
#   spawn_lineage_record [pane_id] [workspace_id]   # before the agent starts (bind race)
#   spawn_lineage_abort <reason>                    # if the launch then fails
# The loop node is synthesized at read time from `loop_id`; its parent is the
# launcher session stored in state.json as launcher_session_id.

_SL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPAWN_HERDR_ENV=()
SPAWN_TMUX_ENV=()
SPAWN_LINEAGE_ID=""

_sl_reg() { python3 "$_SL_DIR/spawn_registry.py" --root "$_SL_ROOT" "$@"; }
_sl_warn() { echo "⚠️  spawn-registry: $* (loop continues, lineage not recorded)" >&2; }

spawn_lineage_begin() {
  _SL_ROOT="$1" _SL_LOOP="$2" _SL_ITER="$3" _SL_STATE="$4" _SL_NAME="$5"
  SPAWN_HERDR_ENV=() SPAWN_TMUX_ENV=() SPAWN_LINEAGE_ID=""
  [[ "${SPAWN_REGISTRY_DISABLE:-}" == "1" ]] && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    _sl_warn "python3 not found"; return 0
  fi
  local resolved dir id
  resolved=$(_sl_reg resolve --json 2>&1) || { _sl_warn "resolve failed: $resolved"; return 0; }
  dir=$(jq -r '.dir // empty' <<< "$resolved" 2>/dev/null)
  [[ -n "$dir" ]] || { _sl_warn "resolve returned no dir: $resolved"; return 0; }
  id="sp-$( (uuidgen 2>/dev/null || head -c 16 /dev/urandom | xxd -p) | tr -d '-' | tr 'A-Z' 'a-z' | head -c 12)"
  _SL_LAUNCHER=$(jq -r '.launcher_session_id // ""' "$_SL_STATE" 2>/dev/null) || _SL_LAUNCHER=""
  _SL_PREV=$(jq -r '[.spawned_sessions[]?.spawn_id // empty | select(. != "")] | last // ""' "$_SL_STATE" 2>/dev/null) || _SL_PREV=""
  local kv=("SPAWN_REGISTRY_DIR=$dir" "SPAWN_ID=$id" "SPAWN_PARENT_NAME=ralph-loop $_SL_LOOP")
  [[ -n "$_SL_LAUNCHER" ]] && kv+=("SPAWN_PARENT_SESSION_ID=$_SL_LAUNCHER")
  local e
  for e in "${kv[@]}"; do
    SPAWN_HERDR_ENV+=(--env "$e")
    SPAWN_TMUX_ENV+=(-e "$e")
  done
  SPAWN_LINEAGE_ID="$id"
}

spawn_lineage_record() {
  [[ -n "$SPAWN_LINEAGE_ID" ]] || return 0
  local args=(spawn --spawner ralph-loop-fork --name "$_SL_NAME" --kind claude
    --parent-name "ralph-loop $_SL_LOOP" --loop-id "$_SL_LOOP" --iteration "$_SL_ITER"
    --spawn-id "$SPAWN_LINEAGE_ID")
  [[ -n "${1:-}" ]] && args+=(--pane-id "$1")
  [[ -n "${2:-}" ]] && args+=(--workspace-id "$2")
  [[ -n "$_SL_LAUNCHER" ]] && args+=(--parent-session-id "$_SL_LAUNCHER")
  [[ -n "$_SL_PREV" ]] && args+=(--prev-spawn-id "$_SL_PREV")
  _sl_reg "${args[@]}" >/dev/null || { _sl_warn "spawn row write failed"; SPAWN_LINEAGE_ID=""; return 0; }
  _SL_RECORDED=1
}

spawn_lineage_abort() {
  [[ -n "$SPAWN_LINEAGE_ID" && "${_SL_RECORDED:-}" == "1" ]] || return 0
  _sl_reg end --spawn-id "$SPAWN_LINEAGE_ID" --reason "${1:-launch_failed}" >/dev/null \
    || _sl_warn "end row write failed"
  _SL_RECORDED=""
}
