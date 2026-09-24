#!/bin/bash

# Shared herdr-backend helpers, sourced by fork-terminal-herdr.sh,
# hooks/stop-hook-fork.sh, and scripts/cancel-ralph-loop-fork.sh. Kept in
# ONE file (not duplicated per-consumer) specifically so the name-mapping
# function below is byte-identical everywhere it runs — a derivation
# mismatch between spawn and cleanup would target the wrong herdr agent
# name and orphan a workspace. See D3 in
# _project/specs/feature-ralph-loop-fork-herdr-backend-2026-08-09.md
# (AEOS repo) for the design rationale.

# herdr agent/workspace names: [a-z][a-z0-9_-]{0,31}, max 32 chars,
# lowercase-only, first char must be a letter. Derives a name from a
# ralph-loop-fork loop id + session number that always satisfies that
# charset/length constraint: lowercase + sanitize the raw "ralph-{ID}-{N}"
# string, truncate to 24 chars (the literal "ralph-" prefix guarantees the
# first char is a letter even for a digit-leading sanitized loop id), then
# append "-" + the first 6 hex chars of a sha1 digest of the raw string —
# 24 + 1 + 6 = 31, one under the ceiling.
herdr_derive_name() {
  local loop_id="$1"
  local session_number="$2"
  local raw="ralph-${loop_id}-${session_number}"

  local sanitized
  sanitized=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g')
  sanitized="${sanitized:0:24}"

  local digest
  if command -v sha1sum &>/dev/null; then
    digest=$(printf '%s' "$raw" | sha1sum | cut -c1-6)
  elif command -v shasum &>/dev/null; then
    digest=$(printf '%s' "$raw" | shasum -a 1 | cut -c1-6)
  else
    echo "Error: neither sha1sum nor shasum found — cannot derive herdr agent name" >&2
    return 1
  fi

  printf '%s-%s' "$sanitized" "$digest"
}

# Same derivation, applied to the loop-level prefix "ralph-{ID}-" (no
# session number) for D5's label-prefix fallback enumeration when
# spawned_sessions[] itself is unreadable. Matching the RAW unsanitized
# prefix against labels (which are always written in sanitized form via
# herdr_derive_name above) would silently match nothing.
herdr_derive_prefix() {
  local loop_id="$1"
  local raw="ralph-${loop_id}-"
  printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g' | cut -c1-24
}

# Create the pane a new loop session runs in. Inside a herdr pane
# ($HERDR_WORKSPACE_ID set and still alive) the session becomes a new TAB of
# the spawner's workspace; otherwise it gets a fresh workspace. Sets WS_ID,
# PANE_ID, HERDR_SPAWN_KIND (tab|workspace). Args: cwd label.
herdr_spawn_root_pane() {
  local cwd="$1" label="$2" json
  if [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && herdr workspace get "$HERDR_WORKSPACE_ID" >/dev/null 2>&1; then
    json=$(herdr tab create --workspace "$HERDR_WORKSPACE_ID" --cwd "$cwd" --label "$label" --env "RALPH_LOOP_ACTIVE=1" --no-focus) || {
      echo "Error: herdr tab create failed (workspace $HERDR_WORKSPACE_ID)" >&2
      return 1
    }
    WS_ID=$(jq -r '.result.tab.workspace_id' <<< "$json")
    HERDR_SPAWN_KIND=tab
  else
    json=$(herdr workspace create --cwd "$cwd" --label "$label" --env "RALPH_LOOP_ACTIVE=1" --no-focus) || {
      echo "Error: herdr workspace create failed" >&2
      return 1
    }
    WS_ID=$(jq -r '.result.workspace.workspace_id' <<< "$json")
    HERDR_SPAWN_KIND=workspace
  fi
  PANE_ID=$(jq -r '.result.root_pane.pane_id' <<< "$json")
  if [[ -z "$WS_ID" || "$WS_ID" == "null" || -z "$PANE_ID" || "$PANE_ID" == "null" ]]; then
    echo "Error: herdr $HERDR_SPAWN_KIND create did not return workspace_id/pane_id" >&2
    echo "  Response: $json" >&2
    return 1
  fi
}
