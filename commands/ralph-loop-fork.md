---
description: "Start fork-based Ralph Loop (spawns new terminal each iteration)"
argument-hint: "--checklist <path> [--command CMD] [--name ID] [--completion-promise TEXT] [--on-completion CMD] [--stop-hook-reminders TEXT|PATH] [--total-budget N] [--max-per-session N] [--preserve-final-session] [--no-cleanup] [--worktree] [--worktree-base DIR] [--branch NAME] [--copy-paths \"P1 P2\"]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop-fork.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Ralph Loop Fork Command

Execute the setup script to initialize the fork-based Ralph loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ralph-loop-fork.sh" $ARGUMENTS
SETUP_EXIT=$?

if [ $SETUP_EXIT -ne 0 ]; then
  echo ""
  echo "======================================================================="
  echo " ERROR: Ralph Loop Fork setup FAILED (exit code $SETUP_EXIT)"
  echo " Check the error message above and fix the arguments."
  echo "======================================================================="
  exit $SETUP_EXIT
fi

# Display completion promise reminder if set
if [ -d .claude/ralph-fork ]; then
  for loop_dir in .claude/ralph-fork/*/; do
    if [ -f "${loop_dir}local.md" ]; then
      LOOP_ID=$(basename "$loop_dir")
      PROMISE=$(grep '^completion_promise:' "${loop_dir}local.md" | sed 's/completion_promise: *//' | sed 's/^"\(.*\)"$/\1/')
      if [ -n "$PROMISE" ] && [ "$PROMISE" != "null" ]; then
        echo ""
        echo "======================================================================="
        echo " Ralph Loop Fork [$LOOP_ID] - Completion Promise"
        echo "======================================================================="
        echo ""
        echo " To complete this loop, output this EXACT text:"
        echo "   <promise>$PROMISE</promise>"
        echo ""
        echo " STRICT REQUIREMENTS (DO NOT VIOLATE):"
        echo "   - Use <promise> XML tags EXACTLY as shown above"
        echo "   - The statement MUST be completely and unequivocally TRUE"
        echo "   - Do NOT output false statements to exit the loop"
        echo ""
        echo " FORK BEHAVIOR:"
        echo "   When you exit without the promise, a NEW terminal session"
        echo "   will be spawned with fresh context. This continues until:"
        echo "   - You output the completion promise (success)"
        echo "   - Total budget is exhausted"
        echo "======================================================================="
      fi
    fi
  done
fi
```

## What Happens Next

You will work on the task provided. When you try to exit:

1. **If task INCOMPLETE**: A NEW terminal session is spawned via tmux
2. **If completion promise detected**: You exit normally (success!)
3. **If total budget reached**: Loop stops with summary

Unlike standard /ralph-loop which re-feeds the prompt in the SAME session until context fills up, /ralph-loop-fork:ralph-loop-fork forks a FRESH session once a session's iteration limit is reached. With --max-per-session 1 (default) every exit triggers a fork; set it higher to allow multiple re-feed iterations within one session before forking.

## Key Options

| Option | Description | Default |
|--------|-------------|---------|
| `--checklist <path>` | Path to checklist markdown file | REQUIRED |
| `--command '<cmd>'` | Command to execute on checklist (e.g., `/implement`) | none |
| `--name <id>` | Loop identifier for parallel sessions | auto-generated |
| `--completion-promise '<text>'` | Promise phrase to signal completion | none |
| `--on-completion '<cmd>'` | Command to run after successful completion | none |
| `--stop-hook-reminders '<text\|path>'` | Custom reminders added to stop hook prompts | none |
| `--total-budget <n>` | Max iterations across ALL sessions | 100 |
| `--max-per-session <n>` | Max iterations per session before forking | 1 |
| `--preserve-final-session` | Don't cleanup final session at completion (preserve report) | false |
| `--no-cleanup` | Don't cleanup any sessions at completion | false |
| `--worktree` | Run the loop in an isolated git worktree | false |
| `--worktree-base <dir>` | Parent dir for the worktree (only with `--worktree`) | `.worktrees` |
| `--branch <name>` | Branch name for the worktree (only with `--worktree`) | `ralph/<loop-id>` |
| `--copy-paths "<a b c>"` | Extra files/dirs to copy into the worktree (space-sep inside one quoted arg) | none |

## Command vs On-Completion

- `--command`: Runs WITH the checklist during each session (e.g., `/implement @checklist.md`)
- `--on-completion`: Runs AFTER the loop completes successfully (e.g., `/reflect-learn`)

## On-Completion Command

Use `--on-completion` to run a command after the loop completes successfully:

```bash
# Run /reflect-learn after all checklist items complete
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --name "my-task" \
  --completion-promise "Task complete" \
  --on-completion "/reflect-learn"
```

The on-completion command runs AFTER:
1. The completion promise is detected
2. You confirm with `<confirmed>YES</confirmed>`
3. All checklist items are marked complete

## Stop Hook Reminders

Use `--stop-hook-reminders` to add custom reminders that appear in every stop hook prompt. This is useful for enforcing rules or reminding about constraints across all sessions.

```bash
# Pass reminders as a string
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --name "my-task" \
  --completion-promise "Task complete" \
  --stop-hook-reminders "IMPORTANT: Always run tests before marking items complete. Use skill X for validation."

# Or pass a path to a .md file
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --name "my-task" \
  --completion-promise "Task complete" \
  --stop-hook-reminders "path/to/reminders.md"
```

The reminders appear in:
- Initial session prompt
- Forked session prompts
- All stop hook BLOCK prompts (checklist update, promise rejection, confirmation)

## Parallel Sessions

Use `--name` to run multiple loops in parallel with isolated state:

```bash
# Terminal 1
/ralph-loop-fork:ralph-loop-fork --checklist checklist-a.md --name "task-a" --completion-promise 'DONE'

# Terminal 2
/ralph-loop-fork:ralph-loop-fork --checklist checklist-b.md --name "task-b" --completion-promise 'DONE'
```

Each loop gets its own directory: `.claude/ralph-fork/{LOOP_ID}/`

Sessions are named `ralph-{LOOP_ID}-{N}` and managed via tmux.

## Worktree Mode

`--worktree` runs the entire loop inside a git worktree, so the loop's commits land on a dedicated branch and the main branch is never touched until you choose to merge.

```bash
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --name "feat-x" \
  --worktree \
  --copy-paths "_project/docs docs/specs"
```

Behaviour:

- Creates worktree at `<worktree-base>/<loop-id>` on branch `ralph/<loop-id>` (override either with `--worktree-base` and `--branch`).
- Copies CLAUDE.md, a curated subset of `.claude/` (skills, commands, settings), the checklist directory, all `.env*` files, and any `--copy-paths` entries.
- Launches the initial Claude session via tmux pointing at the worktree. All forked sessions continue inside the worktree without further intervention.
- `cancel-ralph-fork` detects the worktree and prints `git merge / git worktree remove / git branch -D` commands — the worktree itself is left in place so you can inspect or merge first.

`--worktree` is **not** compatible with `--resume` (resume runs from the existing worktree directly).

## How to Complete the Task

Work on the task step by step. Mark checklist items as you complete them.

**CRITICAL RULE**: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop.

When the task is genuinely complete, output:
```
<promise>YOUR_COMPLETION_PROMISE</promise>
```

The hook will then ask you to confirm. You MUST output:
```
<confirmed>YES</confirmed>
```

This will:
1. Verify all checklist items are marked `[x]`
2. Execute the `--on-completion` command (if set)
3. Archive the loop state
4. Clean up spawned sessions

## Checklist Tasks

If the prompt references a checklist file (e.g., `@path/to/checklist.md`):

1. Read the checklist file
2. Work on uncompleted items (`- [ ]`)
3. Mark items complete (`- [x]`) as you finish them
4. The loop detects checklist progress via file hash
5. When all items are complete, output the completion promise

## Important Notes

- Your work persists in files and git history across sessions
- Each new session starts with fresh context but sees previous work
- Progress is tracked in `.claude/ralph-fork/{LOOP_ID}/state.json`
- Use `tmux ls` to view all running sessions
- Use `tmux ls | grep {LOOP_ID}` to see sessions for specific loop
- The loop continues until completion promise OR budget exhaustion
- Cancel with: `/ralph-loop-fork:cancel-ralph-fork {LOOP_ID}`
