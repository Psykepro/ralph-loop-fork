---
description: "Cancel active Ralph Loop Fork (by name, --list, --all, or --all-stuck)"
argument-hint: "[LOOP_ID | --list | --all | --all-stuck]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph-loop-fork.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Ralph Fork

Execute the cancel script:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/cancel-ralph-loop-fork.sh" $ARGUMENTS
```

## Usage

```
/ralph-loop-fork:cancel-ralph-fork --list        # List all active loops (read-only)
/ralph-loop-fork:cancel-ralph-fork LOOP_ID       # Cancel a specific loop
/ralph-loop-fork:cancel-ralph-fork --all         # Cancel all loops
/ralph-loop-fork:cancel-ralph-fork --all-stuck   # Cancel only stuck loops
```

## What it does

- `--list`: Shows every active loop with `active`, `sessions`, and `iterations/budget`. Does not touch anything.
- `LOOP_ID`: Closes every herdr pane belonging to the loop, then removes its state directory at `.claude/ralph-fork/<LOOP_ID>/`.
- `--all`: Same as above for every loop. The `.claude/ralph-fork/.archive/` directory is preserved.
- `--all-stuck` / `--stuck`: Targets only loops where `active=true` AND (`executing_on_completion=true` OR `awaiting_confirmation=true`). These are loops whose continuation cycle never fired — typically because the herdr pane was closed mid-BLOCK. Writes `termination_reason=user_cancelled_stuck` before removing state. Requires `jq`.

## Session discovery

The cancel script uses `state.json` as the source of truth:

1. `.spawned_sessions[].pane_id` — every herdr pane forked by the loop.

If `state.json` is missing or corrupt (or `jq` is not installed), it falls back to the loop's herdr workspace/tab labels.

It is safe to run even if `herdr` is not running, if some sessions are already dead, or if the loop is in a partially-corrupted state — the script warns to stderr and continues.
