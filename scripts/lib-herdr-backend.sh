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
