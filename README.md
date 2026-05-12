# Ralph Loop Fork Plugin

Fork-based Ralph Loop implementation that spawns NEW terminal sessions on each
iteration via tmux. Unlike standard ralph-loop which re-feeds the prompt in the
same session, this version creates fresh sessions to maximize context window
utilization.

**Supports parallel sessions**: Run multiple loops simultaneously with isolated
state.

## Installation

This is a Claude Code plugin. Install it via one of:

1. **Plugin marketplace (recommended)** — use `/plugin install` from Claude
   Code and point it at this repository.
2. **Manual install** — clone this repository and symlink it (or copy it) into
   your local Claude Code plugin directory, e.g.
   `~/.claude/plugins/marketplaces/local/ralph-loop-fork/`.

After install, start a new Claude Code session — plugins are loaded at
startup.

## Dependencies

- `tmux` — terminal multiplexer
- `jq` — JSON parsing
- `bash` 4+ — included on macOS/Linux/WSL

Install via your package manager:

```bash
# macOS (Homebrew)
brew install tmux jq

# Debian / Ubuntu
sudo apt install tmux jq

# Arch
sudo pacman -S tmux jq
```

For the checklist-progress hash the script also uses `md5sum` (Linux),
falling back to `md5 -q` (macOS) or `shasum` if neither is present — no
extra install needed on a standard system.

## Portability

The plugin targets macOS, Linux, and Windows under **WSL2**. tmux does not run
on native Windows / Git Bash; if you're on Windows install WSL2 and run the
plugin from inside WSL. The scripts detect Git Bash / MSYS2 and print a
pointer to that effect if tmux is missing.

## Commands

| Command | Description |
|---------|-------------|
| `/ralph-loop-fork:ralph-loop-fork` | Start fork-based Ralph loop |
| `/ralph-loop-fork:cancel-ralph-fork` | Cancel/list active loops |
| `/ralph-loop-fork:help-fork` | Show detailed help |

## Quick Start

```bash
# Basic usage with checklist
/ralph-loop-fork:ralph-loop-fork --checklist path/to/checklist.md

# With slash command
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --command "/implement"

# With loop name and completion promise
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --name "csrf" --completion-promise 'ALL_COMPLETE'

# Auto-generated loop ID (8-char hex)
/ralph-loop-fork:ralph-loop-fork --checklist checklist.md --total-budget 10

# Run multiple loops in parallel
# Terminal 1:
/ralph-loop-fork:ralph-loop-fork --checklist checklist-a.md --name "task-a" --completion-promise 'DONE'
# Terminal 2:
/ralph-loop-fork:ralph-loop-fork --checklist checklist-b.md --name "task-b" --completion-promise 'DONE'
```

## Arguments & Options

| Argument/Option | Default | Description |
|--------|---------|-------------|
| `--checklist <path>` | (required) | Path to checklist markdown file |
| `--command <cmd>` | null | Slash command to execute (optional) |
| `--name <id>` | auto-generated | Loop identifier for parallel sessions |
| `--total-budget <n>` | 100 | Total iterations across all sessions |
| `--max-per-session <n>` | 1 | Iterations before forking to new session |
| `--completion-promise <text>` | null | Promise phrase to signal completion |
| `--on-completion <cmd>` | null | Slash command to run after successful completion |
| `--stop-hook-reminders <text\|path>` | null | Custom reminders added to stop hook prompts (string or .md file) |
| `--preserve-final-session` | false | Keep the final session at completion |
| `--no-cleanup` | false | Don't cleanup any sessions at completion |

The plugin always launches forked sessions with
`claude --dangerously-skip-permissions`.

## Configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `RALPH_FORK_LOG_DIR` | `${TMPDIR:-/tmp}/ralph-fork-logs` | Where the stop hook writes its debug log |
| `RALPH_LOG_RETENTION_DAYS` | `90` | How long to keep daily log files |
| `RALPH_MAX_ARCHIVES` | `20` | How many completed-loop archives to keep |

## Checklist Validation

When using `--completion-promise`, the loop validates that all checklist items
are marked `[x]` before accepting completion:

- If unchecked `- [ ]` items remain, the completion is **rejected**
- A self-validation prompt is triggered to fix the discrepancy
- Only when all items are `- [x]` will the promise be accepted

This prevents false completion claims when work is not actually done.

## Parallel Session Support

Each loop is fully isolated with its own state directory:

```
.claude/ralph-fork/
├── my-feature/              # Loop: my-feature
│   ├── state.json             # Global state
│   ├── local.md               # Current session state
│   └── prompt.txt             # Prompt for forked sessions
├── api-refactor/              # Loop: api-refactor
│   ├── state.json
│   ├── local.md
│   └── prompt.txt
└── a1b2c3d4/                  # Auto-generated loop ID
    └── ...
```

### Session Naming

Sessions follow the pattern: `ralph-{LOOP_ID}-{N}`

Examples:
- `ralph-my-feature-1` → First session of "my-feature" loop
- `ralph-my-feature-2` → Second session (after fork)
- `ralph-a1b2c3d4-1` → Auto-generated ID

Sessions are managed via tmux and identifiable by their `ralph-{LOOP_ID}-{N}` naming.

## How It Works

```
Session 1              Session 2              Session 3
┌─────────────┐        ┌─────────────┐        ┌─────────────┐
│ 1. Read task│        │ 1. Read task│        │ 1. Read task│
│ 2. Work...  │   ──►  │ 2. Work...  │   ──►  │ 2. Work...  │
│ 3. Exit     │  FORK  │ 3. Exit     │  FORK  │ 3. Done!    │
└─────────────┘        └─────────────┘        └─────────────┘
  Fresh context          Fresh context          <promise>DONE
```

### Hook Behavior

**Stop Hook:**
1. Discovers active loop from `.claude/ralph-fork/*/local.md`
2. Check for completion promise → **Exit (success)**
3. Check total budget → **Exit (limit reached)**
4. Check session iterations < max → **Re-feed prompt (same session)**
5. Otherwise → **Fork to new terminal**

## Managing Loops

### List Active Loops

```bash
/ralph-loop-fork:cancel-ralph-fork --list
```

Shows each active loop with `active`, `sessions`, and `iterations/budget`.

### Cancel Specific Loop

```bash
/ralph-loop-fork:cancel-ralph-fork my-feature
```

Kills every tmux session belonging to the loop (spawned sessions plus the
original launcher) and removes its state directory at
`.claude/ralph-fork/<LOOP_ID>/`.

### Cancel All Loops

```bash
/ralph-loop-fork:cancel-ralph-fork --all
```

Same as above for every loop. The `.claude/ralph-fork/.archive/` directory is
preserved.

## Monitoring

```bash
# List all loops
ls -la .claude/ralph-fork/

# View specific loop state
cat .claude/ralph-fork/my-feature/state.json | jq

# View current session
head -10 .claude/ralph-fork/my-feature/local.md

# List all ralph tmux sessions
tmux ls | grep ralph

# List sessions for specific loop
tmux ls | grep my-feature

# Attach to a session
tmux attach -t ralph-my-feature-1
```

## Completion

To complete the loop, output the exact promise phrase:

```
<promise>YOUR_COMPLETION_PROMISE</promise>
```

The hook then asks for an explicit confirmation:

```
<confirmed>YES</confirmed>
```

Only after both, with every checklist item marked `[x]`, does the loop accept
completion.

**CRITICAL**: Only output the promise when the statement is completely and
unequivocally TRUE.

## Comparison with Standard Ralph Loop

| Feature | `/ralph-loop` | `/ralph-loop-fork:ralph-loop-fork` |
|---------|--------------|-------------------|
| Context handling | Accumulates each iteration | Fresh each fork |
| Session count | 1 | Multiple |
| Best for | Short tasks | Long, complex tasks |
| Visibility | Single terminal | tmux sessions |
| State | Single local file | Isolated per loop |
| Parallel support | No | Yes (via --name) |

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Commands not recognized | Restart Claude Code (plugins cached at startup) |
| `tmux is required but was not found` | Install via your package manager (`apt install tmux`, `brew install tmux`, etc.). On Windows install WSL2. |
| `jq is required but was not found` | Install via your package manager (`apt install jq`, `brew install jq`, etc.). |
| Fork not spawning | Verify tmux installed: `tmux -V` |
| Session exists error | Remove old sessions: `tmux kill-session -t ralph-LOOP_ID-N` |
| State corrupted | Cancel and restart: `/ralph-loop-fork:cancel-ralph-fork LOOP_ID` |
| Loop ID conflict | Use unique `--name` or let it auto-generate |
| Wrong loop triggered | Check `.claude/ralph-fork/*/local.md` exists only for active loop |

## Running tests

```bash
bash tests/test-state-tracking.sh
bash tests/test-stop-hook-states.sh
```

## File Structure

```
ralph-loop-fork/
├── .claude-plugin/
│   └── plugin.json              # Plugin manifest
├── hooks/
│   ├── hooks.json               # Hook registration (Stop)
│   └── stop-hook-fork.sh        # Stop hook (main fork logic)
├── scripts/
│   ├── setup-ralph-loop-fork.sh # Setup script
│   ├── fork-terminal.sh         # Fork execution
│   └── cancel-ralph-loop-fork.sh # Cancel/list script
├── commands/
│   ├── ralph-loop-fork.md       # Main command
│   ├── cancel-ralph-fork.md     # Cancel command
│   └── help-fork.md             # Help command
├── tests/
│   ├── test-state-tracking.sh
│   └── test-stop-hook-states.sh
├── CONTRIBUTING.md
├── LICENSE                      # MIT
└── README.md                    # This file
```

## Credits

- Original Ralph Wiggum technique by [Geoffrey Huntley](https://ghuntley.com/ralph/)

## License

MIT — see [LICENSE](LICENSE).
