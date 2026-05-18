---
description: "Show Ralph Loop Fork command reference"
---

Print the following help reference to the user in full. Output every section exactly as written — do not summarize, shorten, or paraphrase.

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
- `--worktree` - Run the loop inside an isolated git worktree (default: `false`; see Worktree Mode below)
- `--worktree-base <dir>` - Parent dir for worktrees (default: `.worktrees`)
- `--branch <name>` - Branch name for the worktree (default: `ralph/<loop-id>`)
- `--copy-paths "<a b c>"` - Extra files/dirs to copy into the worktree (space-separated inside a single quoted arg)

**Checklist Validation:**
When using `--completion-promise`, the loop validates that all checklist items are marked `[x]` before accepting completion. If unchecked items remain, the completion is rejected and a self-validation prompt is triggered.

**How it works:**
1. Creates `.claude/ralph-fork/{LOOP_ID}/` directory with isolated state
2. You work on the task
3. When you try to exit:
   - If completion promise detected: Stop (success!)
   - If total budget exhausted: Stop
   - If current iteration < `--max-per-session`: Re-feed prompt in the **same** session (same context window, fresh block)
   - If `--max-per-session` reached: Fork to **NEW** terminal (fresh context window)
4. New session reads global state and continues

---

### /ralph-loop-fork:init-ralph-fork [--check-only]

Check and auto-install all dependencies.

```
/ralph-loop-fork:init-ralph-fork              # check + auto-install
/ralph-loop-fork:init-ralph-fork --check-only # report only, no install
```

Run this once after installing the plugin. If a subsequent `ralph-loop-fork` run fails with a missing-dependency error, run this first to fix it.

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

## Worktree Mode

Pass `--worktree` to run the entire loop inside a git worktree. The loop's commits land on a dedicated branch, leaving the main branch untouched until you choose to merge.

```bash
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --name "feat-x" \
  --completion-promise "ALL_DONE" \
  --worktree \
  --copy-paths "_project/docs docs/specs"
```

**What it does:**

1. Creates a worktree at `<worktree-base>/<loop-id>` on a new branch `ralph/<loop-id>`.
2. Copies the minimum set of files into the worktree: `CLAUDE.md`, a curated subset of `.claude/` (`skills`, `commands`, `settings*.json`), `.claude/ralph-fork/` (excluding `.archive/`), the checklist directory, all `.env*` files, plus anything passed via `--copy-paths`.
3. Moves the freshly-created loop state into the worktree.
4. Launches the initial Claude session via tmux inside the worktree. All forked sessions run there as well — no extra wiring needed.

**Flags:**

| Flag | Default | Purpose |
|------|---------|---------|
| `--worktree` | `false` | Enable worktree mode |
| `--no-worktree` | (default) | Explicit opt-out (documents intent) |
| `--worktree-base <dir>` | `.worktrees` | Parent directory for the worktree |
| `--branch <name>` | `ralph/<loop-id>` | Branch name to create |
| `--copy-paths "<a b c>"` | none | Extra files/dirs to copy in (space-separated inside one quoted arg) |

**Restrictions:**

- `--worktree` cannot be combined with `--resume` (resume already runs from the existing worktree).

**Post-completion merge workflow:**

```bash
# Review what changed on the worktree branch:
git log main..ralph/<loop-id> --oneline

# Merge (or cherry-pick) into main:
git merge ralph/<loop-id>

# Remove the worktree and delete the branch:
git worktree remove .worktrees/<loop-id>
git branch -D ralph/<loop-id>
```

`cancel-ralph-fork` prints these commands automatically when a worktree is detected.

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
    └─ Iteration < max-per-session?
        ├─ YES → Re-feed prompt (same session, increments iteration counter)
        └─ NO  → FORK to new terminal
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

Run `/ralph-loop-fork:init-ralph-fork` to check and auto-install all dependencies.

| Dependency | Required | Notes |
|---|---|---|
| `jq` | Always | JSON state |
| `tmux` | Always | Session forking |
| `xxd` | Always | Loop ID generation |
| `git ≥ 2.5` | `--worktree` only | Worktree subcommand |
| `claude` CLI | `--worktree` only | Launched inside worktree |
| `uuidgen` | Optional | Falls back to `/dev/urandom` |

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
| `tmux is required but was not found` | Run `/ralph-loop-fork:init-ralph-fork`. On Windows install WSL2. |
| `jq is required but was not found` | Run `/ralph-loop-fork:init-ralph-fork`. |
| Fork not spawning | Check tmux is running: `tmux ls` |
| Session exists error | Previous run left sessions; `tmux kill-session -t ralph-ID-N` |
| No progress detected | Ensure you're modifying the checklist file |
| State corrupted | `/ralph-loop-fork:cancel-ralph-fork LOOP_ID` and restart |
| Loop ID conflict | Use unique `--name` or let it auto-generate |
| Wrong loop triggered | Check only one `local.md` exists for active loop |

## Learn More

- Original technique: https://ghuntley.com/ralph/
