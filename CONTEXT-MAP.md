| path | type | LOC | summary | refs | used-by | entry | hot |
|---|---|---|---|---|---|---|---|
| hooks/ | dir | ~2260 | Stop-hook state machine (fork on stop, defer silently on pending bg agents, block on promise / doom-loop) | jq, tmux, git | Claude Code Stop hook config | hooks/stop-hook-fork.sh | yes |
| scripts/ | dir | ~2000 | tmux fork/init/cancel/setup helpers + live-install sync | tmux, git | hooks/, commands/ | scripts/fork-terminal.sh | yes |
| commands/ | dir | small | Slash-command docs for ralph-loop-fork, help, init, cancel | - | Claude Code CLI | commands/ralph-loop-fork.md | no |
| tests/ | dir | - | Bats/shell test suite for hook + scripts | bats | CI / manual runs | - | no |
| _project/ | dir | - | AEOS project scaffolding carried into this plugin repo | - | - | - | no |

## Key Exports
- `hooks/stop-hook-fork.sh` — Stop hook: forks new tmux session per iteration, blocks on pending background agents / completion promise / doom-loop detection.

## Rules
- Plugin version bumps (`plugin.json`) + `scripts/sync-live-install.py` on every hook/script change — see host CLAUDE.md "AEOS-Only Rules".

## Changelog
- 2026-08-05: v0.9.0 — `--worktree` mode now REQUIRES `--base-ref <ref>` (no default, never the invoking cwd's ambient HEAD). Closes an ambient-branch-state bug: sibling worktrees (e.g. `cooperative_launch.py`) previously forked from whatever HEAD the invoking cwd happened to have at spawn time instead of an intended parent branch. `scripts/setup-worktree.sh` gains a new positional `BASE_REF` arg (after `BRANCH`, before `CHECKLIST_DIR`) and fails loudly if empty or unresolvable; `scripts/setup-ralph-loop-fork.sh` validates `--base-ref` is present whenever `--worktree` is passed and threads it through. Docs (`README.md`, `commands/help-fork.md`, `commands/ralph-loop-fork.md`) and `tests/test-worktree-setup.sh` (+8 new assertions) updated to match. See `scripts/setup-worktree.sh`, `scripts/setup-ralph-loop-fork.sh`.
- 2026-08-02: v0.8.0 — replaced bg-agent block-and-poll with defer-don't-block: pending background agents now exit the Stop hook silently (no `decision:block`), letting the queued `task-notification` resume the session naturally instead of forcing an instant re-stop cycle. Removes the v0.7.1 poll-interval sleep (now moot). Unverified risk accepted: the block existed to close an AC2 finish-vs-integrate race; no reproduction was re-run before switching. Test suite updated to assert silent defer instead of block; all 171 tests pass. See `hooks/stop-hook-fork.sh`, `tests/test-background-agent-detection.sh`.
- 2026-08-02: v0.7.1 — throttle bg-agent stop-hook re-poll rate (`RALPH_BG_POLL_INTERVAL_SECONDS`, default 15s sleep before re-emitting "still waiting" block) to cut wait-cycle spam in the transcript. Superseded by v0.8.0. See `hooks/stop-hook-fork.sh`.
