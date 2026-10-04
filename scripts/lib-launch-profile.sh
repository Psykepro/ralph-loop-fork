#!/bin/bash

# Optional launch-profile hook for herdr launches (sourced by fork-terminal-herdr.sh,
# setup-ralph-loop-fork.sh, cancel-ralph-loop-fork.sh and the stop hook).
#
# A project MAY ship `.claude/hooks/lib/launch_profile.py`: a helper whose `plan <dir>` prints
#   {"profile": ..., "env": {K: V}, "command_prefix": [...]}
# so a spawned session gets the same account markers and wrapper command a human launch alias would add.
# Absent helper => every function below is a no-op and launches behave exactly as before.
# Helper present but failing (e.g. unusable rule) => launch_profile_begin returns 1: refuse to spawn,
# never fall back to a default account.
#
# Usage (per launch):
#   launch_profile_begin <cwd> [project_root] || exit 1     # BEFORE any pane/registry side effect
#   ... herdr create ... ${LP_HERDR_ENV[@]+"${LP_HERDR_ENV[@]}"} ...
#   launch_profile_prepare_pane <cwd> <pane_id> || { close pane; exit 1; }   # BEFORE `agent start`
#   launch_profile_cleanup_pane <pane_id>     # after every `herdr pane close` (best-effort)

LP_HELPER=""
LP_HERDR_ENV=()
LP_ACTIVE=""

_lp_find_helper() {
  local d
  for d in "$@"; do
    [[ -n "$d" && -f "$d/.claude/hooks/lib/launch_profile.py" ]] && { printf '%s' "$d/.claude/hooks/lib/launch_profile.py"; return 0; }
  done
  return 1
}

launch_profile_begin() {
  local cwd="$1" root="${2:-}" plan err
  LP_HELPER="" LP_HERDR_ENV=() LP_ACTIVE=""
  LP_HELPER=$(_lp_find_helper "$cwd" "$root") || return 0
  err=$(mktemp "${TMPDIR:-/tmp}/lp-err.XXXXXX") || return 1
  if ! plan=$(python3 "$LP_HELPER" plan "$cwd" 2>"$err"); then
    echo "Error: launch profile refused the spawn:" >&2
    cat "$err" >&2
    rm -f "$err"
    return 1
  fi
  rm -f "$err"
  local kv
  while IFS= read -r kv; do
    [[ -n "$kv" ]] && LP_HERDR_ENV+=(--env "$kv")
  done < <(jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"' <<< "$plan")
  if [[ "$(jq -r '(.command_prefix // []) | length' <<< "$plan")" -gt 0 ]]; then
    LP_ACTIVE=1
  fi
  return 0
}

launch_profile_prepare_pane() {
  local cwd="$1" pane_id="$2" shim_dir
  [[ -n "$LP_ACTIVE" ]] || return 0
  shim_dir=$(python3 "$LP_HELPER" shim "$cwd" "$pane_id") && [[ -n "$shim_dir" ]] || {
    echo "Error: launch-profile shim could not be written for pane $pane_id" >&2
    return 1
  }
  herdr pane run "$pane_id" "export PATH=$shim_dir:\$PATH" >/dev/null || {
    echo "Error: launch-profile PATH export failed in pane $pane_id" >&2
    python3 "$LP_HELPER" shim-cleanup "$pane_id" >/dev/null 2>&1 || true
    return 1
  }
}

launch_profile_cleanup_pane() {
  local pane_id="$1" helper="$LP_HELPER"
  [[ -n "$pane_id" && "$pane_id" != "null" ]] || return 0
  [[ -n "$helper" ]] || helper=$(_lp_find_helper "${CLAUDE_PROJECT_DIR:-}" "${PROJECT_ROOT:-}" "$PWD") || return 0
  python3 "$helper" shim-cleanup "$pane_id" >/dev/null 2>&1 || true
}
