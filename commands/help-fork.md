---
description: "Explain Ralph Loop Fork plugin and available commands"
---

# Ralph Loop Fork Plugin Help

Please explain the following to the user:

## What is Ralph Loop Fork?

Ralph Loop Fork extends the original Ralph Wiggum technique with **terminal forking**. Instead of re-feeding the prompt in the same session (which accumulates context), it spawns a NEW terminal session on each iteration.

**Benefits:**
- Fresh context window each iteration (no context accumulation)
- Better for long-running, complex tasks
- State persists across sessions via files
- Parallel execution visibility via tmux
- **Run multiple loops simultaneously** with isolated state

**Core concept:**
```bash
# Original Ralph Loop:
while :; do
  cat PROMPT.md | claude-code --continue  # Same session
done

# Ralph Loop Fork:
while :; do
  spawn_new_terminal "cat PROMPT.md | claude-code"  # Fresh session
done
```

## Available Commands

### /ralph-loop-fork:ralph-loop-fork --checklist <path> [OPTIONS]

Start a fork-based Ralph loop.

**Usage:**
```
/ralph-loop-fork:ralph-loop-fork --checklist path/to/checklist.md
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --name "csrf" --completion-promise "ALL_COMPLETE"
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --completion-promise "DONE" --on-completion "/reflect-learn"
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --total-budget 10 --max-per-session 1
```

**Arguments:**
- `--checklist <path>` - Path to checklist markdown file (REQUIRED)
- `--command <cmd>` - Slash command to execute (optional)

**Options:**
- `--name <id>` - Loop identifier for parallel sessions (auto-generates if not provided)
- `--total-budget <n>` - Total iterations across ALL sessions (default: 100)
- `--max-per-session <n>` - Iterations before forking (default: 1)
- `--completion-promise <text>` - Promise phrase to signal completion
- `--on-completion <cmd>` - Command to execute when loop completes successfully
- `--stop-hook-reminders <text|path>` - Custom reminders added to stop hook prompts
- `--preserve-final-session` - Keep the final session at completion (default: false)
- `--no-cleanup` - Don't cleanup any sessions at completion (default: false)

**Checklist Validation:**
When using `--completion-promise`, the loop validates that all checklist items are marked `[x]` before accepting completion. If unchecked items remain, the completion is rejected and a self-validation prompt is triggered.

**How it works:**
1. Creates `.claude/ralph-fork/{LOOP_ID}/` directory with isolated state
2. You work on the task
3. When you try to exit:
   - If `--max-per-session` reached: Fork to NEW terminal
   - If completion promise detected: Stop (success!)
   - If total budget exhausted: Stop
4. New session reads global state and continues

---

### /ralph-loop-fork:cancel-ralph-fork [LOOP_ID | --list | --all]

Manage active Ralph Loop Fork sessions.

**Usage:**
```
/ralph-loop-fork:cancel-ralph-fork --list        # List all active loops
/ralph-loop-fork:cancel-ralph-fork my-feature  # Cancel specific loop
/ralph-loop-fork:cancel-ralph-fork --all         # Cancel all loops
```

**What it does:**
- `--list`: Shows all active loops with their status
- `LOOP_ID`: Removes state files and tmux sessions for that loop
- `--all`: Removes all loops and all ralph-* tmux sessions

---

## Parallel Sessions

Run multiple loops simultaneously with isolated state:

```bash
# Terminal 1:
/ralph-loop-fork:ralph-loop-fork --checklist checklist-a.md --name "task-a" --completion-promise 'DONE'

# Terminal 2:
/ralph-loop-fork:ralph-loop-fork --checklist checklist-b.md --name "task-b" --completion-promise 'DONE'
```

Each loop is fully isolated:
```
.claude/ralph-fork/
├── task-a/
│   ├── state.json
│   ├── local.md
│   └── prompt.txt
└── task-b/
    ├── state.json
    ├── local.md
    └── prompt.txt
```

Sessions are named `ralph-{LOOP_ID}-{N}` and managed via tmux.

---

## Key Concepts

### State Files

| File | Scope | Contents |
|------|-------|----------|
| `.claude/ralph-fork/{ID}/state.json` | Global (persists across sessions) | Budget, total iterations, prompt, checklist hash |
| `.claude/ralph-fork/{ID}/local.md` | Session (recreated each fork) | Current iteration, session number, prompt |
| `.claude/ralph-fork/{ID}/prompt.txt` | Session | Full prompt for forked session |

### Session Naming

Sessions follow pattern: `ralph-{LOOP_ID}-{N}`

Examples:
- `ralph-my-feature-1` → First session of "my-feature" loop
- `ralph-my-feature-2` → Second session (after fork)
- `ralph-a1b2c3d4-1` → Auto-generated ID

### Completion Flow

To complete a loop, output the promise and confirm:

**Step 1:** Output your completion promise
```
<promise>TASK COMPLETE</promise>
```

**Step 2:** When prompted, confirm with XML tags
```
<confirmed>YES</confirmed>
```

**What happens:**
1. Hook detects promise → verifies all checklist items are `[x]`
2. Hook asks for confirmation → you output `<confirmed>YES</confirmed>`
3. On-completion command runs (if set with `--on-completion`)
4. Loop archives and cleans up

### On-Completion Command

Run a command after successful completion:

```bash
/ralph-loop-fork:ralph-loop-fork \
  --checklist checklist.md \
  --completion-promise "Done" \
  --on-completion "/reflect-learn"
```

The `--on-completion` command runs AFTER confirmation and checklist validation.

### Forking Behavior

```
Stop Event
    │
    ├─ Completion promise found?
    │   ├─ All checklist items [x]?
    │   │   ├─ YES → Ask for <confirmed>YES</confirmed>
    │   │   │        └─ Confirmed? → Run on-completion → EXIT (success)
    │   │   └─ NO  → Reject, spawn new session
    │   └─ NO → Continue checking...
    │
    ├─ Total budget exhausted?
    │   └─ YES → EXIT (budget limit)
    │
    └─ Max iterations reached?
        └─ YES → FORK to new terminal
```

## Comparison: ralph-loop vs ralph-loop-fork

| Feature | /ralph-loop | /ralph-loop-fork:ralph-loop-fork |
|---------|-------------|------------------|
| Context accumulation | Yes (grows each iteration) | No (fresh each fork) |
| Session count | 1 | Multiple (via tmux) |
| Best for | Short tasks | Long, complex tasks |
| Visibility | Single terminal | tmux sessions |
| State persistence | Local file only | Global + local files |
| Parallel support | No | Yes (via --name) |

## Monitoring

```bash
# List all loops:
ls -la .claude/ralph-fork/

# View specific loop state:
cat .claude/ralph-fork/my-feature/state.json | jq

# View session state:
head -10 .claude/ralph-fork/my-feature/local.md

# List all forked sessions:
tmux ls | grep ralph

# List sessions for specific loop:
tmux ls | grep my-feature

# Attach to a session:
tmux attach -t ralph-my-feature-1
```

## Example Workflow

### Long Checklist Task with On-Completion

```
/ralph-loop-fork:ralph-loop-fork \
  --checklist @checklist.md \
  --name "feature-impl" \
  --completion-promise "ALL_ITEMS_COMPLETE" \
  --on-completion "/reflect-learn" \
  --total-budget 50 \
  --max-per-session 1
```

Each iteration:
1. Read checklist
2. Work on uncompleted items
3. Mark items complete
4. Exit → Fork to new session
5. Repeat until all items done
6. Output `<promise>ALL_ITEMS_COMPLETE</promise>`
7. Confirm with `<confirmed>YES</confirmed>`
8. `/reflect-learn` runs automatically

### Parallel Training Sessions

```bash
# Terminal 1
/ralph-loop-fork:ralph-loop-fork --name "csrf-training" @skill-csrf.md --completion-promise "TRAINED"

# Terminal 2
/ralph-loop-fork:ralph-loop-fork --name "xss-training" @skill-xss.md --completion-promise "TRAINED"

# Monitor both
tmux ls | grep ralph
```

## Dependencies

- `tmux`: Terminal multiplexer (install via `apt install tmux`, `brew install tmux`, `pacman -S tmux`, ...)
- `jq`: JSON parsing (install via `apt install jq`, `brew install jq`, `pacman -S jq`, ...)
- `md5sum` or `md5`: Checksum (Linux ships `md5sum`; macOS ships `md5 -q`; either works)

On Windows: tmux does not run on native Windows / Git Bash. Install WSL2 and
run this plugin from inside WSL.

## Configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `RALPH_FORK_LOG_DIR` | `${TMPDIR:-/tmp}/ralph-fork-logs` | Where the stop hook writes its debug log |
| `RALPH_LOG_RETENTION_DAYS` | `90` | How long to keep daily log files |
| `RALPH_MAX_ARCHIVES` | `20` | How many completed-loop archives to keep |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `tmux is required but was not found` | Install via your package manager (`apt install tmux`, `brew install tmux`, ...). On Windows install WSL2. |
| `jq is required but was not found` | Install via your package manager (`apt install jq`, `brew install jq`, ...). |
| Fork not spawning | Check tmux is running: `tmux ls` |
| Session exists error | Previous run left sessions; `tmux kill-session -t ralph-ID-N` |
| No progress detected | Ensure you're modifying the checklist file |
| State corrupted | `/ralph-loop-fork:cancel-ralph-fork LOOP_ID` and restart |
| Loop ID conflict | Use unique `--name` or let it auto-generate |
| Wrong loop triggered | Check only one `local.md` exists for active loop |

## Learn More

- Original technique: https://ghuntley.com/ralph/
