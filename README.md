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
`/ralph-loop-fork:cancel-ralph-fork`, `/ralph-loop-fork:help-fork`, and
`/ralph-loop-fork:init-ralph-fork`.

> **Scope**: installs at user scope by default (available in all projects).
> Pass `--scope project` to scope it to a single repository.

```
# 4. Check and install dependencies
/ralph-loop-fork:init-ralph-fork
```

### Manual install

```bash
git clone https://github.com/Psykepro/ralph-loop-fork \
  ~/.claude/plugins/marketplaces/local/ralph-loop-fork
```

Restart Claude Code — plugins are discovered at startup. Then run:

```
/ralph-loop-fork:init-ralph-fork
```

---

## Dependencies

| Dependency | Required | Notes |
|---|---|---|
| `jq` | Always | JSON state management |
| `tmux` | Always | Session forking |
| `xxd` | Always | Loop ID generation |
| `git ≥ 2.5` | `--worktree` only | Worktree subcommand |
| `claude` CLI | `--worktree` only | Launched inside the worktree |
| `uuidgen` | Optional | Falls back to `/dev/urandom` |

### Quick setup

After installing the plugin, run the built-in init command to check and auto-install all dependencies:

```
/ralph-loop-fork:init-ralph-fork
```

It supports Homebrew (macOS), apt-get (Debian/Ubuntu), and pacman (Arch). Use `--check-only` to report status without installing anything.

Manual install if you prefer:

```bash
# macOS
brew install tmux jq

# Debian / Ubuntu
sudo apt install tmux jq xxd

# Arch
sudo pacman -S tmux jq vim   # xxd is part of vim on Arch
```

For checklist-progress hashing the script tries `md5sum` → `md5 -q` → `shasum` — no extra install on a standard system.

## Portability

Targets macOS, Linux, and Windows under **WSL2**. tmux does not run on native
Windows / Git Bash; install WSL2 and run from inside WSL. The init command
detects this and prints guidance.

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

## Worktree Mode

Pass `--worktree` to run the entire loop inside an isolated git worktree. The
loop's commits land on a dedicated branch (`ralph/<loop-id>` by default), and
the main branch is never touched until you choose to merge.

```bash
/ralph-loop-fork:ralph-loop-fork \
  --checklist path/to/checklist.md \
  --command "/implement" \
  --name "feat-x" \
  --completion-promise "CHECKLIST_JOB_100%_COMPLETED" \
  --on-completion "/reflect-learn" \
  --total-budget 30 \
  --worktree \
  --copy-paths "docs/specs notes/research"
```

**What happens:**

1. `git worktree add .worktrees/feat-x -b ralph/feat-x` creates the worktree on a new branch.
2. A curated set of files is copied in: `CLAUDE.md`, `.claude/skills`, `.claude/commands`, `.claude/settings*.json`, `.claude/ralph-fork/` (excluding `.archive/`), the checklist directory, every `.env*` file at the root, plus anything from `--copy-paths`.
3. The freshly-created loop state directory is moved into the worktree.
4. The initial Claude session is launched inside the worktree via tmux. All forked sessions continue running there — `fork-terminal.sh` and `stop-hook-fork.sh` need zero changes to follow along.

**Why use it:**

- The main branch stays clean — no half-finished commits, no merge conflicts during interactive work.
- The whole loop can be merged or discarded as a single unit.
- Multiple independent loops can run on the same project without stepping on each other's working tree.

**Flag reference (worktree-related):**

| Flag | Default | Purpose |
|------|---------|---------|
| `--worktree` | `false` | Enable worktree mode |
| `--no-worktree` | (default) | Explicit opt-out |
| `--worktree-base <dir>` | `.worktrees` | Parent directory for the worktree |
| `--branch <name>` | `ralph/<loop-id>` | Branch name to create |
| `--copy-paths "<a b c>"` | none | Extra files/dirs to copy in; space-separated inside a single quoted arg |

**Restrictions:**

- `--worktree` is **not** compatible with `--resume`. Resume runs from the existing worktree directly.
- The worktree itself is **not** auto-removed by `cancel-ralph-fork` — you may want to inspect or merge it first. The cancel command prints the exact cleanup commands.

### Post-completion merge workflow

After the loop finishes (either via the completion promise or by exhausting the
budget), merge or discard the branch as a unit:

```bash
# Review what changed on the worktree branch
git log main..ralph/<loop-id> --oneline

# Merge (or cherry-pick) into main
git merge ralph/<loop-id>

# Remove the worktree and delete the branch
git worktree remove .worktrees/<loop-id>
git branch -D ralph/<loop-id>
```

`cancel-ralph-fork` prints these exact commands whenever a worktree is detected
in the loop's `state.json`.

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
| `--worktree` | false | Run the loop inside an isolated git worktree (see **Worktree Mode**) |
| `--no-worktree` | (default) | Explicit opt-out; documents intent |
| `--worktree-base <dir>` | `.worktrees` | Parent directory for the worktree (only with `--worktree`) |
| `--branch <name>` | `ralph/<loop-id>` | Branch name for the worktree (only with `--worktree`) |
| `--copy-paths "<a b c>"` | none | Extra files/dirs to copy into the worktree, space-separated inside one quoted arg |
| `--model <name>` | `sonnet` | Pin the Claude model for all spawned sessions (e.g. `sonnet`, `opus`, or a full model id) |
| `--effort <level>` | `medium` | Pin the reasoning effort for all spawned sessions (`low`\|`medium`\|`high`\|`xhigh`\|`max`) |

Forked sessions always launch with `claude --dangerously-skip-permissions --model <model> --effort <level>`.

**Iteration-1 caveat (non-worktree mode):** iteration 1 runs in the *invoking*
session — it is not a fresh `claude` spawn, so it keeps that session's own
model and effort. The `--model`/`--effort` values (including the defaults)
govern forked sessions 2+ and, in `--worktree` mode, iteration 1 as well
(worktree mode spawns even the first session via the CLI). State files written
before v0.5.0 have no `effort` field; on resume they fall back to `medium`,
while their `model` behavior is unchanged (unpinned stays unpinned).

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

# Cancel only stuck loops (session killed mid-BLOCK, continuation never fired)
/ralph-loop-fork:cancel-ralph-fork --all-stuck
```

> **Cancel vs. complete**: `cancel-ralph-fork` removes the state directory
> *without* archiving it and kills all associated tmux sessions. Normally
> completed loops are moved to `.claude/ralph-fork/.archive/` automatically.

> **Stuck loops**: If a tmux session is killed while Claude is responding to a BLOCK (e.g., updating the checklist), the continuation cycle never fires and the loop stays `active=true` permanently. The stop hook auto-recovers these on the next session start. For bulk manual cleanup, use `--all-stuck`.

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

## AEOS integration (optional)

ralph-loop-fork has optional integration with [AEOS (Agentic Engineering OS)](https://github.com/Psykepro/agentic-coding-ready-now) that activates automatically when `.claude/scripts/ralph_aeos_config.py` is present in the project root.

### How it activates

At loop launch (`setup-ralph-loop-fork.sh`), if `ralph_aeos_config.py` exists, it is called with the checklist path and loop directory. It writes `.aeos-config.json` to the loop state directory. If the script fails or is absent, the loop proceeds normally with no AEOS gates — **fail-open by design** (W4 guarantee: standalone behavior is always preserved).

### .aeos-config.json fields

| Field | Type | Meaning |
|-------|------|---------|
| `doom_abort_threshold` | int | Consecutive no-progress forks before the doom breaker engages (default: 3) |
| `respect_revision_budget` | bool | Whether to enforce `revision_budget` from `loop-state.json` |
| `required_markers` | list[str] | Evidence marker names that must exist before the completion promise is accepted |
| `plan_dir` | str | Path to the evidence directory (`.evidence/`) relative to AEOS project root |
| `progress_paths` | list[str] | (v0.5.1) Extra git roots whose HEAD counts as progress — for work that lands outside the project root (e.g. a plugin repo). Absolute paths. |
| `progress_exclude` | list[str] | (v0.5.1) Extra repo-relative paths excluded from the working-tree progress hash (for always-mutating files). Entries must be space-free. |

### AEOS-controlled termination modes

**Doom-loop detection** (v0.5.1 — progress fingerprint): a fork counts as "no progress" only when the **composite progress fingerprint** is unchanged: checklist content + project `HEAD` + working-tree state (excluding always-mutating paths: `_project/metrics`, `_project/signals`, `.claude/ralph-fork`, `BLOCKER.md`, plus `progress_exclude`) + `HEAD` of every declared `progress_paths` root. Commits, uncommitted edits, and declared external-repo work all reset the stuck counter — only genuine spinning accrues strikes. (Pre-0.5.1 the detector hashed only the checklist file, which false-positived on loops whose work landed before the checklist tick.)

The breaker is **two-stage**: at `doom_abort_threshold` strikes the stopping session gets one blocking last-chance warning (and a `ralph-stuck-warning` signal is emitted) — one turn to land observable progress. If the fingerprint still hasn't moved at the next sample, the loop terminates and writes `BLOCKER.md` with `termination_reason: doom_loop_detected`. From the first strike onward, forked sessions also get a `⚠️ NO-PROGRESS WARNING` banner telling them to land close-out (commit + ticks + handoff) before new work.

Debug a stuck loop's fingerprint by hand: `hooks/stop-hook-fork.sh --fingerprint <checklist> <project_root> <aeos_config>`.

**Revision-budget exhaustion**: If `respect_revision_budget` is true and `loop-state.json:revision_count >= revision_budget`, the loop terminates with `termination_reason: revision_budget_exhausted`. The budget is set at loop launch via `--total-budget`.

**Required-markers gate**: Before accepting a completion promise from the agent, the stop hook checks that all `required_markers` exist in the plan's `.evidence/` directory. If any are missing, the session is re-forked with instructions to write the missing markers (via `python .claude/scripts/mark.py`). The agent cannot exit the loop without all required evidence.

### Non-AEOS projects

None of these behaviors activate without `.aeos-config.json`. If you install ralph-loop-fork in a project that does not use AEOS, you will never see doom-loop termination, revision-budget exhaustion, or the marker gate. The `BLOCKER.md` file only appears in AEOS-managed loops.

### Signals (optional, AEOS integration)

On every loop termination — completion (with or without `--on-completion`, checklist moved away, or an orphaned-session recovery), doom-loop detection, revision-budget exhaustion, or total-budget exhaustion — the stop hook does two things, independent of each other and of everything above:

1. **Appends one row** to `$PROJECT_ROOT/_project/signals/events.jsonl` with `kind` `ralph-completed`, `ralph-doomed`, or `ralph-budget-exhausted` (schema: [AEOS's `signals-protocol` rule](https://github.com/Psykepro/agentic-coding-ready-now)). Only runs if `_project/signals/` already exists — **no-op, no error** in any project that doesn't have it (same fail-open sentinel pattern as the AEOS config above).
2. **Emits a `terminalSequence` desktop notification** (OSC 777) in the hook's JSON output — works in any terminal that supports it, independent of the AEOS signal bus.

Neither behavior requires `.aeos-config.json` — the signals-dir check and the notification are both unconditional, so even a standalone install gets the desktop notification on completion/doom/budget-exhaustion.

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
| `tmux is required but was not found` | Run `/ralph-loop-fork:init-ralph-fork`. On Windows: install WSL2 and run from inside WSL. |
| `jq is required but was not found` | Run `/ralph-loop-fork:init-ralph-fork`. |
| Fork not spawning | Verify tmux: `tmux -V` |
| Session already exists error | Remove stale session: `tmux kill-session -t ralph-LOOP_ID-N` |
| State corrupted | Cancel and restart: `/ralph-loop-fork:cancel-ralph-fork LOOP_ID` |
| Loop stuck `active=true` (session killed mid-BLOCK) | Run `/ralph-loop-fork:cancel-ralph-fork --all-stuck` to bulk-cancel, or just start a new session — the stop hook auto-recovers on the next run |
| Loop ID conflict | Use a unique `--name` or omit it for auto-generated ID |
| Wrong loop triggered | Check only one `local.md` exists: `ls .claude/ralph-fork/*/local.md` |

---

## Running tests

```bash
bash tests/test-state-tracking.sh
bash tests/test-stop-hook-states.sh
bash tests/test-aeos-attach.sh   # AEOS integration + signals emission
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
│   ├── setup-worktree.sh            # Worktree creation + file population
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
