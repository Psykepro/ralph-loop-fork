# Ralph Loop Fork

Fork-based Ralph Loop that keeps each session's context window fresh by
spawning a **new tmux session** when a session's iteration limit is reached.
Unlike the standard ralph-loop which re-feeds the prompt into the same session
until context accumulates and the model degrades, this version forks a
brand-new Claude process at the configured boundary and tracks all state in
files so work persists across sessions.

With the default `--max-per-session 1` every exit triggers a fork. Set it
higher to allow multiple re-feed iterations within one session before forking.

**Supports parallel sessions**: run multiple independent loops simultaneously,
each fully isolated.

---

## Installation

### Via Claude Code plugin system (recommended)

```bash
# 1. Add this repo as a plugin marketplace source
/plugin marketplace add Psykepro/ralph-loop-fork

# 2. Install the plugin
/plugin install ralph-loop-fork@Psykepro/ralph-loop-fork

# 3. Activate without restarting
/reload-plugins
```

The commands become available as `/ralph-loop-fork:ralph-loop-fork`,
`/ralph-loop-fork:cancel-ralph-fork`, and `/ralph-loop-fork:help-fork`.

> **Scope**: installs at user scope by default (available in all projects).
> Pass `--scope project` to scope it to a single repository.

### Manual install

```bash
git clone https://github.com/Psykepro/ralph-loop-fork \
  ~/.claude/plugins/marketplaces/local/ralph-loop-fork
```

Restart Claude Code — plugins are discovered at startup.

---

## Dependencies

- `tmux` — terminal multiplexer
- `jq` — JSON parsing
- `bash` 4+ — included on macOS/Linux/WSL

```bash
# macOS
brew install tmux jq

# Debian / Ubuntu
sudo apt install tmux jq

# Arch
sudo pacman -S tmux jq
```

For the checklist-progress hash the script uses `md5sum` (Linux), falling back
to `md5 -q` (macOS) or `shasum` — no extra install needed on a standard system.

## Portability

Targets macOS, Linux, and Windows under **WSL2**. tmux does not run on native
Windows / Git Bash; if you are on Windows install WSL2 and run from inside WSL.
The scripts detect Git Bash / MSYS2 and print a pointer to that effect if tmux
is missing.

---

## Quick Start

```bash
# Minimal — loop until budget exhausted
/ralph-loop-fork:ralph-loop-fork --checklist my-checklist.md

# With a completion signal
/ralph-loop-fork:ralph-loop-fork \
  --checklist my-checklist.md \
  --completion-promise "ALL_DONE"

# Full workflow: implement each session, reflect on everything at the end
/ralph-loop-fork:ralph-loop-fork \
  --checklist my-feature.md \
  --command "/implement" \
  --name "my-feature" \
  --completion-promise "CHECKLIST_JOB_100%_COMPLETED" \
  --on-completion "/reflect-learn" \
  --total-budget 20 \
  --max-per-session 1

# Two independent loops running in parallel
# Terminal 1:
/ralph-loop-fork:ralph-loop-fork \
  --checklist feature-a.md --name "feat-a" --completion-promise "DONE"
# Terminal 2:
/ralph-loop-fork:ralph-loop-fork \
  --checklist feature-b.md --name "feat-b" --completion-promise "DONE"
```

---

## Working with project slash commands

### `/implement` as `--command`

Pass any slash command to `--command` and it runs at the start of each session
alongside the checklist. `/implement` (or whichever implementation command your
project defines) is the natural fit: each fresh session gets the same
instruction to work through the checklist, picks up where the previous left
off, and marks items `[x]` as it goes.

```bash
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/feature-checklist.md \
  --command "/implement" \
  --name "auth-refactor" \
  --completion-promise "CHECKLIST_JOB_100%_COMPLETED" \
  --on-completion "/reflect-learn"
```

Each forked session starts with a clean context window but inherits the full
checklist state — completed items stay `[x]`, session notes accumulate below
the checklist, and the new session can orient itself instantly.

### `/reflect-learn` as `--on-completion`

`--on-completion` runs a slash command **once**, in the final session, after
the completion promise is accepted. `/reflect-learn` is the recommended choice.

Here is why it is especially powerful after a ralph-loop-fork run:

- Every session appends notes to the checklist file as it works. By the time
  the loop completes, the checklist contains a full log of findings, blockers,
  decisions, and surprises — accumulated across every forked session.
- `/reflect-learn` runs over all of that accumulated context in one pass,
  extracting durable lessons: skills to update, rules to add, patterns to
  remember for next time.
- Because the loop explicitly separates *doing* (each session) from *learning*
  (the final pass), the reflection is richer than what any single session could
  produce — it sees the whole journey.

```bash
# The loop does the work; reflect-learn distils what was learned
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --command "/implement" \
  --name "my-task" \
  --completion-promise "CHECKLIST_JOB_100%_COMPLETED" \
  --on-completion "/reflect-learn" \
  --total-budget 30
```

---

## Arguments & Options

| Option | Default | Description |
|--------|---------|-------------|
| `--checklist <path>` | **required** | Path to checklist markdown file |
| `--command <cmd>` | null | Slash command run at the start of each session |
| `--name <id>` | auto 8-char hex | Loop identifier; used for tmux session names and state directory |
| `--total-budget <n>` | 100 | Hard cap on total iterations across all sessions |
| `--max-per-session <n>` | 1 | Iterations before forking a new session |
| `--completion-promise <text>` | null | Phrase Claude must output in `<promise>` tags to end the loop |
| `--on-completion <cmd>` | null | Slash command run once after successful completion |
| `--stop-hook-reminders <text\|path>` | null | Extra text injected into every stop-hook prompt; string or `.md` file |
| `--preserve-final-session` | false | Keep the final tmux session alive after completion |
| `--no-cleanup` | false | Never kill any spawned sessions |

Forked sessions always launch with `claude --dangerously-skip-permissions`.

---

## Configuration

| Env var | Default | Purpose |
|---------|---------|---------|
| `RALPH_FORK_LOG_DIR` | `${TMPDIR:-/tmp}/ralph-fork-logs` | Where the stop hook writes its debug log |
| `RALPH_LOG_RETENTION_DAYS` | `90` | How long to keep daily log files |
| `RALPH_MAX_ARCHIVES` | `20` | How many completed-loop archives to retain |

---

## How It Works

```
Session 1              Session 2              Session 3
┌─────────────┐        ┌─────────────┐        ┌─────────────┐
│ 1. Read task│        │ 1. Read task│        │ 1. Read task│
│ 2. Work...  │  FORK  │ 2. Work...  │  FORK  │ 2. Work...  │
│ 3. Exit     │ ─────► │ 3. Exit     │ ─────► │ 3. Done!    │
└─────────────┘        └─────────────┘        └─────────────┘
  Fresh context          Fresh context         <promise>DONE
                                               then /reflect-learn
```

### Stop hook state machine

Every time a session tries to exit, the stop hook fires and decides what to do:

1. **Token check** — confirms this event belongs to the active session (see below); stale events are silently dropped.
2. **Promise check** — if `<promise>...</promise>` is present and all checklist items are `[x]`, move toward completion.
3. **Budget check** — if `total_budget` is exhausted, exit cleanly.
4. **Session limit** — if this session hasn't reached `max-per-session`, re-feed the prompt in the same session.
5. **Fork** — otherwise, spawn a new tmux session and rotate the token.

### Session tokens and hook isolation

This is the mechanism that makes parallel loops and long multi-session runs
safe.

When a session starts, a unique 16-char token is embedded in its prompt:

```
RALPH LOOP CONTEXT (Loop: auth-refactor, Session 3, Token: 4a7f2b9e1c3d8e6f):
```

The stop hook reads this token from the session transcript and compares it
against the token stored in `state.json`. If they don't match — meaning this
event came from a session that has already been superseded by a fork — the hook
silently ignores it. No phantom fork, no duplicate state update.

When a new session is forked, the token is **rotated**: the old session's token
is immediately invalidated in `state.json`, so even if it somehow fires the
hook again it cannot interfere.

This means:
- Parallel loops with different `--name` values never cross-trigger each other's hooks.
- A slow or crashed session that recovers late cannot cause a double-fork.
- You can `tmux attach` to any session for inspection without disrupting the loop.

### tmux session management

Sessions are named `ralph-{LOOP_ID}-{N}`:

```bash
# Watch all active ralph sessions
tmux ls | grep ralph

# Attach to a specific session for inspection (read-only is fine)
tmux attach -t ralph-auth-refactor-2

# The loop manages cleanup automatically on completion
# For manual intervention:
tmux kill-session -t ralph-auth-refactor-1
```

State for each loop lives in `.claude/ralph-fork/{LOOP_ID}/`:

```
.claude/ralph-fork/
├── auth-refactor/
│   ├── state.json    # budget, session count, token, fork history
│   ├── local.md      # per-session prompt + frontmatter
│   └── prompt.txt    # raw prompt written for forked sessions to read
└── .archive/
    └── auth-refactor-20260513T142300/   # completed loops archived here
```

---

## Checklist Validation

When `--completion-promise` is set, the hook enforces completion
programmatically — it does not rely on trust:

- Claude outputs `<promise>ALL_DONE</promise>`
- Hook counts unchecked `- [ ]` items in the checklist
- If any remain → **rejected**, Claude is shown the checklist and must finish
- When all items are `[x]` → hook asks for explicit confirmation
- Claude outputs `<confirmed>YES</confirmed>`
- Hook verifies boxes one more time before accepting

This prevents false completion claims when work is not actually done.

---

## Managing Loops

```bash
# List active loops (shows iterations/budget per loop)
/ralph-loop-fork:cancel-ralph-fork --list

# Cancel a specific loop — kills its tmux sessions + removes state
/ralph-loop-fork:cancel-ralph-fork auth-refactor

# Cancel all loops (archives are preserved)
/ralph-loop-fork:cancel-ralph-fork --all
```

> **Cancel vs. complete**: `cancel-ralph-fork` removes the state directory
> *without* archiving it and kills all associated tmux sessions. Normally
> completed loops are moved to `.claude/ralph-fork/.archive/` automatically.

---

## Monitoring

```bash
# List all loops
ls -la .claude/ralph-fork/

# Inspect loop state
cat .claude/ralph-fork/auth-refactor/state.json | jq

# View current session prompt
head -20 .claude/ralph-fork/auth-refactor/local.md

# Watch all ralph tmux sessions
tmux ls | grep ralph

# Attach to a running session
tmux attach -t ralph-auth-refactor-2

# View debug log
tail -f "${RALPH_FORK_LOG_DIR:-/tmp/ralph-fork-logs}/ralph-fork-$(date +%Y-%m-%d).log"
```

---

## Comparison with standard ralph-loop

| Feature | `/ralph-loop` | `/ralph-loop-fork` |
|---------|--------------|-------------------|
| Context handling | Accumulates every iteration | Fresh context each fork |
| Session count | 1 | Multiple (one per fork) |
| Best for | Short tasks | Long, complex, multi-session tasks |
| Visibility | Single terminal | Named tmux sessions |
| State persistence | Single local file | Isolated per loop in `.claude/ralph-fork/` |
| Parallel loops | No | Yes — via `--name` |
| Hook isolation | N/A | Session tokens prevent cross-session triggers |
| Post-completion hook | No | Yes — `--on-completion` |

---

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Commands not recognized after install | Run `/reload-plugins` — no restart needed |
| `tmux is required but was not found` | Install via your package manager. On Windows: install WSL2 and run from inside WSL. |
| `jq is required but was not found` | Install via your package manager (`apt install jq`, `brew install jq`, etc.) |
| Fork not spawning | Verify tmux: `tmux -V` |
| Session already exists error | Remove stale session: `tmux kill-session -t ralph-LOOP_ID-N` |
| State corrupted | Cancel and restart: `/ralph-loop-fork:cancel-ralph-fork LOOP_ID` |
| Loop ID conflict | Use a unique `--name` or omit it for auto-generated ID |
| Wrong loop triggered | Check only one `local.md` exists: `ls .claude/ralph-fork/*/local.md` |

---

## Running tests

```bash
bash tests/test-state-tracking.sh
bash tests/test-stop-hook-states.sh
```

---

## File Structure

```
ralph-loop-fork/
├── .claude-plugin/
│   └── plugin.json                  # Plugin manifest
├── hooks/
│   ├── hooks.json                   # Hook registration (Stop event)
│   └── stop-hook-fork.sh            # Stop hook — state machine, fork logic
├── scripts/
│   ├── setup-ralph-loop-fork.sh     # Initialisation script
│   ├── fork-terminal.sh             # tmux fork spawner
│   └── cancel-ralph-loop-fork.sh    # Cancel / list script
├── commands/
│   ├── ralph-loop-fork.md           # Main command
│   ├── cancel-ralph-fork.md         # Cancel command
│   └── help-fork.md                 # Help command
├── tests/
│   ├── test-state-tracking.sh
│   └── test-stop-hook-states.sh
├── CONTRIBUTING.md
├── LICENSE                          # MIT
└── README.md
```

---

## Credits

- Original Ralph Wiggum technique by [Geoffrey Huntley](https://ghuntley.com/ralph/)

## License

MIT — see [LICENSE](LICENSE).
