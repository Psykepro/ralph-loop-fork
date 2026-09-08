#!/bin/bash

# Ralph Loop Fork — Worktree Setup
#
# Creates a git worktree on a new branch and populates it with the files
# needed to run the loop in isolation: CLAUDE.md, the full .claude/ dir, the
# full _project/ dir, the checklist directory, .env* files, and any
# user-supplied extra paths.
#
# Usage:
#   setup-worktree.sh LOOP_ID WORKTREE_PATH BRANCH BASE_REF CHECKLIST_DIR [COPY_PATHS...]
#
# Arguments:
#   LOOP_ID         loop identifier (used to skip its stale state in the dest)
#   WORKTREE_PATH   path to create the worktree at (relative or absolute)
#   BRANCH          branch name to create with `git worktree add -b`
#   BASE_REF        REQUIRED ref the new branch forks from (commit-ish: branch,
#                   tag, SHA). Passed straight to `git worktree add PATH -b
#                   BRANCH BASE_REF` — no default, no fallback to the invoking
#                   cwd's HEAD. Callers MUST resolve this explicitly; ambient
#                   cwd state must never decide a sibling worktree's parent.
#   CHECKLIST_DIR   directory containing the checklist file (copied wholesale)
#   COPY_PATHS...   extra files/dirs to copy verbatim into matching paths
#
# Output (stdout):
#   The absolute path of the created worktree (single line).
#
# Exit codes:
#   0 success; non-zero on any failure (caller should abort).

set -euo pipefail

if [[ $# -lt 5 ]]; then
  echo "Usage: setup-worktree.sh LOOP_ID WORKTREE_PATH BRANCH BASE_REF CHECKLIST_DIR [COPY_PATHS...]" >&2
  exit 1
fi

LOOP_ID="$1"
WORKTREE_PATH="$2"
BRANCH="$3"
BASE_REF="$4"
CHECKLIST_DIR="$5"
shift 5
# Remaining args are extra copy paths (may be zero).

# Fail loudly rather than silently defaulting — this script is the plugin's
# last line of defense if a caller somehow skips the CLI-layer requirement.
if [[ -z "$BASE_REF" ]]; then
  echo "Error: BASE_REF is required and was empty." >&2
  echo "  setup-worktree.sh never defaults to the invoking cwd's HEAD — pass an explicit ref." >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Error: git is required but was not found." >&2
  exit 1
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  echo "Error: setup-worktree.sh must run inside a git repository." >&2
  exit 1
fi

if ! git rev-parse --verify --quiet "${BASE_REF}^{commit}" >/dev/null 2>&1; then
  echo "Error: BASE_REF does not resolve to a commit: $BASE_REF" >&2
  exit 1
fi

# Create parent dir for the worktree (e.g. .worktrees/).
mkdir -p "$(dirname "$WORKTREE_PATH")"

# Create the worktree on a new branch, forked from BASE_REF (never the
# invoking cwd's ambient HEAD). Surfaces git's own error messages (branch
# exists, path exists, etc.) without swallowing them.
git worktree add "$WORKTREE_PATH" -b "$BRANCH" "$BASE_REF" >&2

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

# .claude/ untracked-file overlay. `git worktree add` above already checked
# out the clean, committed .claude/ tree from BASE_REF — that's the correct,
# safe baseline (2026-08-31: a raw `cp -R ".claude/." dst` here used to also
# drag along OTHER sessions' uncommitted, in-flight edits to already-tracked
# files — e.g. a mid-edit hook script — into every new worktree, which then
# surfaced as spurious diffs/merge conflicts when that worktree's branch was
# later merged back. Copy every genuinely NEW, not-yet-committed file
# (git's own untracked-file list, deliberately WITHOUT --exclude-standard —
# a machine-global gitignore commonly excludes `.claude/settings.local.json`,
# and that file must still travel with the worktree since it's real local
# config, not someone else's WIP) so a locally-added-but-uncommitted
# skill/hook/local-setting still makes it in, without also carrying unrelated
# dirty edits to existing TRACKED files (those are what actually caused the
# leak — an untracked file was never anyone's silently-abandoned mid-edit,
# it has no prior committed state to diverge from). A prior curated-allowlist
# approach here had gone stale in the other direction (missed `hooks/`,
# breaking every PreToolUse hook in a worktree) — this fixes both failure
# modes at once, since `git ls-files --others` is git's own live-derived
# list, never a hand-maintained one that can go stale.
if [[ -d ".claude" ]]; then
  mkdir -p "$WORKTREE_ABS/.claude"
  git ls-files --others -- .claude | while IFS= read -r f; do
    # 2026-08-31: `git ls-files --others` is a snapshot; on a shared checkout
    # with other concurrent sessions actively creating/deleting untracked
    # files (e.g. a skill-creator run mid-write under .claude/skills/), a
    # listed file can vanish before this loop reaches it. A missing SOURCE
    # here is an expected concurrent-session race, not a setup failure —
    # skip and warn rather than letting one vanished file abort the whole
    # worktree creation (which then rolls back and silently discards every
    # other file this loop already copied).
    if [[ ! -e "$f" ]]; then
      echo "⚠️  skipping .claude overlay file (vanished before copy, likely a concurrent session): $f" >&2
      continue
    fi
    mkdir -p "$WORKTREE_ABS/$(dirname "$f")"
    cp "$f" "$WORKTREE_ABS/$f"
  done
  rm -rf "$WORKTREE_ABS/.claude/ralph-fork"
fi

# _project/ untracked-file overlay — same fix, same reasoning as .claude/
# above. Always applied, not gated behind --copy-paths — a worktree without
# it can't resolve _project/rules/ references from CLAUDE.md or run
# rule-gated hooks.
if [[ -d "_project" ]]; then
  mkdir -p "$WORKTREE_ABS/_project"
  git ls-files --others -- _project | while IFS= read -r f; do
    # Same concurrent-session race tolerance as the .claude/ overlay above.
    if [[ ! -e "$f" ]]; then
      echo "⚠️  skipping _project overlay file (vanished before copy, likely a concurrent session): $f" >&2
      continue
    fi
    mkdir -p "$WORKTREE_ABS/$(dirname "$f")"
    cp "$f" "$WORKTREE_ABS/$f"
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

# Checklist directory — untracked-file overlay, same fix/reasoning as
# .claude/ and _project/ above: `git worktree add` already brought the
# clean committed tree, so only genuinely new (untracked) files need a
# manual copy; a tracked-but-locally-modified file is left at its clean
# committed version rather than inheriting a dirty edit from elsewhere.
# Skip when CHECKLIST_DIR is "." (root-level checklist): copying `./.` would
# pull the whole working tree, including .git/, into the worktree and
# clobber its gitdir pointer. Users with root-level checklists rely on
# `git worktree add` to bring tracked files along, or use --copy-paths.
if [[ -n "$CHECKLIST_DIR" ]] && [[ "$CHECKLIST_DIR" != "." ]] && [[ -d "$CHECKLIST_DIR" ]]; then
  mkdir -p "$WORKTREE_ABS/$CHECKLIST_DIR"
  git ls-files --others -- "$CHECKLIST_DIR" | while IFS= read -r f; do
    mkdir -p "$WORKTREE_ABS/$(dirname "$f")"
    cp "$f" "$WORKTREE_ABS/$f"
  done
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
# path under the worktree — untracked files only, same fix/reasoning as
# .claude/_project/CHECKLIST_DIR above (a tracked file already arrived via
# `git worktree add`'s clean BASE_REF checkout; only genuinely new content
# needs a manual copy here). A single explicitly-named file is copied
# unconditionally only when it isn't tracked at all (the common case for
# --copy-paths targets like .secret/.env, which are gitignored by design).
for src in "$@"; do
  [[ -z "$src" ]] && continue
  if [[ ! -e "$src" ]]; then
    echo "⚠️  Warning (non-fatal): --copy-paths entry not found, skipping: $src" >&2
    continue
  fi
  dest="$WORKTREE_ABS/$src"
  if [[ -d "$src" ]]; then
    mkdir -p "$dest"
    git ls-files --others -- "$src" | while IFS= read -r f; do
      mkdir -p "$WORKTREE_ABS/$(dirname "$f")"
      cp "$f" "$WORKTREE_ABS/$f"
    done
  else
    if [[ -z "$(git ls-files -- "$src")" ]]; then
      mkdir -p "$(dirname "$dest")"
      cp "$src" "$dest" >&2
    fi
  fi
done

# Print the absolute path for the caller to capture.
echo "$WORKTREE_ABS"
