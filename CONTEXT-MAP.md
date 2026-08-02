| path | type | LOC | summary | refs | used-by | entry | hot |
|---|---|---|---|---|---|---|---|
| hooks/ | dir | ~2280 | Stop-hook state machine (fork on stop, block on pending bg agents / promise / doom-loop) | jq, tmux, git | Claude Code Stop hook config | hooks/stop-hook-fork.sh | yes |
| scripts/ | dir | ~2000 | tmux fork/init/cancel/setup helpers + live-install sync | tmux, git | hooks/, commands/ | scripts/fork-terminal.sh | yes |
| commands/ | dir | small | Slash-command docs for ralph-loop-fork, help, init, cancel | - | Claude Code CLI | commands/ralph-loop-fork.md | no |
| tests/ | dir | - | Bats/shell test suite for hook + scripts | bats | CI / manual runs | - | no |
| _project/ | dir | - | AEOS project scaffolding carried into this plugin repo | - | - | - | no |

## Key Exports
- `hooks/stop-hook-fork.sh` — Stop hook: forks new tmux session per iteration, blocks on pending background agents / completion promise / doom-loop detection.

## Rules
- Plugin version bumps (`plugin.json`) + `scripts/sync-live-install.py` on every hook/script change — see host CLAUDE.md "AEOS-Only Rules".

## Changelog
- 2026-08-02: v0.7.1 — throttle bg-agent stop-hook re-poll rate (`RALPH_BG_POLL_INTERVAL_SECONDS`, default 15s sleep before re-emitting "still waiting" block) to cut wait-cycle spam in the transcript. See `hooks/stop-hook-fork.sh`.
