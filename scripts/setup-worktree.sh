#!/bin/bash

# Ralph Loop Fork — Worktree Setup
#
# Creates a git worktree on a new branch and populates it with the minimum
# files needed to run the loop in isolation: CLAUDE.md, a curated subset of
# .claude/, the checklist directory, .env* files, and any user-supplied
# extra paths.
#
# Usage:
#   setup-worktree.sh LOOP_ID WORKTREE_PATH BRANCH CHECKLIST_DIR [COPY_PATHS...]
#
# Arguments:
#   LOOP_ID         loop identifier (used to skip its stale state in the dest)
#   WORKTREE_PATH   path to create the worktree at (relative or absolute)
#   BRANCH          branch name to create with `git worktree add -b`
#   CHECKLIST_DIR   directory containing the checklist file (copied wholesale)
#   COPY_PATHS...   extra files/dirs to copy verbatim into matching paths
#
# Output (stdout):
#   The absolute path of the created worktree (single line).
#
# Exit codes:
#   0 success; non-zero on any failure (caller should abort).

set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: setup-worktree.sh LOOP_ID WORKTREE_PATH BRANCH CHECKLIST_DIR [COPY_PATHS...]" >&2
  exit 1
fi

LOOP_ID="$1"
WORKTREE_PATH="$2"
BRANCH="$3"
CHECKLIST_DIR="$4"
shift 4
# Remaining args are extra copy paths (may be zero).

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required but was not found." >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Error: setup-worktree.sh must run inside a git repository." >&2
  exit 1
fi

# Create parent dir for the worktree (e.g. .worktrees/).
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create the worktree on a new branch. Surfaces git's own error messages
# (branch exists, path exists, etc.) without swallowing them.
git worktree add "$WORKTREE_PATH" -b "$BRANCH" >&2

# Resolve absolute path now that the dir exists.
WORKTREE_ABS="$(cd "$WORKTREE_PATH" && pwd)"

# If the source repo tracks .claude/ralph-fork/.archive/ in git (common when
# completed loops are committed), `git worktree add` will have brought it
# along. The archive is irrelevant in a fresh worktree and its nested .claude
# trees would confuse forked sessions — remove it proactively.
if [[ -d "$WORKTREE_ABS/.claude/ralph-fork/.archive" ]]; then
  rm -rf "$WORKTREE_ABS/.claude/ralph-fork/.archive"
fi

# --- File population ---------------------------------------------------------

# CLAUDE.md (skip silently if absent).
if [[ -f "CLAUDE.md" ]]; then
  cp "CLAUDE.md" "$WORKTREE_ABS/" >&2
fi

# Selective .claude/ copy. Avoids copying .claude/.archive or other dirs
# that may contain nested .claude trees from previous worktree runs.
if [[ -d ".claude" ]]; then
  mkdir -p "$WORKTREE_ABS/.claude"
  for item in skills commands settings.json settings.local.json; do
    if [[ -e ".claude/$item" ]]; then
      cp -R ".claude/$item" "$WORKTREE_ABS/.claude/" >&2
    fi
  done
fi

# Copy .claude/ralph-fork/ EXCLUDING .archive/ (avoids dragging archived
# loops with nested .claude trees into the worktree). Strip the trailing
# slash from the glob expansion — BSD cp treats `src/` as "copy contents",
# which would flatten every loop into the same destination dir.
if [[ -d ".claude/ralph-fork" ]]; then
  mkdir -p "$WORKTREE_ABS/.claude/ralph-fork"
  for entry in .claude/ralph-fork/*/; do
    [[ -d "$entry" ]] || continue
    name="$(basename "$entry")"
    if [[ "$name" == ".archive" ]]; then
      continue
    fi
    cp -R "${entry%/}" "$WORKTREE_ABS/.claude/ralph-fork/" >&2
  done
fi

# Remove stale state for THIS loop if it was carried over — the caller will
# move the freshly-created state dir into place next, and `cp -r` over an
# existing dir would nest it (`<dst>/<id>/<id>/...`).
if [[ -d "$WORKTREE_ABS/.claude/ralph-fork/$LOOP_ID" ]]; then
  rm -rf "$WORKTREE_ABS/.claude/ralph-fork/$LOOP_ID"
fi

# Checklist directory (copy whole dir so sibling files referenced by the
# checklist — e.g. spec docs — come along).
# Skip when CHECKLIST_DIR is "." (root-level checklist): copying `./.` would
# pull the whole working tree, including .git/, into the worktree and
# clobber its gitdir pointer. Users with root-level checklists rely on
# `git worktree add` to bring tracked files along, or use --copy-paths.
if [[ -n "$CHECKLIST_DIR" ]] && [[ "$CHECKLIST_DIR" != "." ]] && [[ -d "$CHECKLIST_DIR" ]]; then
  mkdir -p "$WORKTREE_ABS/$CHECKLIST_DIR"
  cp -R "$CHECKLIST_DIR/." "$WORKTREE_ABS/$CHECKLIST_DIR/" >&2
fi

# .env files at repo root (any name starting with .env). One glob, no overlap.
shopt -s nullglob
for envfile in .env*; do
  if [[ -f "$envfile" ]]; then
    cp "$envfile" "$WORKTREE_ABS/" >&2
  fi
done
shopt -u nullglob

# Extra user-supplied copy paths. Each is copied into the matching relative
# path under the worktree. Files and dirs are handled differently because
# `cp -R src dst` nests on macOS when dst already exists (which happens when
# the path is a tracked file/dir — git worktree add brought it in already).
for src in "$@"; do
  [[ -z "$src" ]] && continue
  if [[ ! -e "$src" ]]; then
    echo "Warning: --copy-paths entry not found, skipping: $src" >&2
    continue
  fi
  dest="$WORKTREE_ABS/$src"
  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    # Copy contents of src into dest. Works whether dest existed or not.
    cp -R "$src/." "$dest/" >&2
  else
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest" >&2
  fi
done

# Print the absolute path for the caller to capture.
echo "$WORKTREE_ABS"
