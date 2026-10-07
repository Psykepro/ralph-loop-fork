| path | type | LOC | summary | refs | used-by | entry | hot |
|---|---|---|---|---|---|---|---|
| hooks/ | dir | ~2600 | Stop-hook state machine (fork on stop, defer silently on pending bg agents, block on promise / doom-loop); dual-backend cleanup dispatch (tmux kill-session vs herdr pane close) branches on state.json's `backend` field; doom-loop fingerprint excludes Session-N-Notes-only churn | jq, tmux, herdr, git | Claude Code Stop hook config | hooks/stop-hook-fork.sh | yes |
| scripts/ | dir | ~3400 | Setup/fork/cancel/init helpers + live-install sync, dual-backend (tmux default until 2026-08-11, now herdr default / `--backend tmux` opt-out) | tmux, herdr, jq, git | hooks/, commands/ | scripts/setup-ralph-loop-fork.sh | yes |
| commands/ | dir | small | Slash-command docs for ralph-loop-fork, help, init, cancel | - | Claude Code CLI | commands/ralph-loop-fork.md | no |
| tests/ | dir | - | Shell test suite for hook + scripts, hermetic stubs for both backends; `test-spawn-lineage.sh` covers lineage rows, SPAWN_* env, bind/sweep hooks, fingerprint exclusion | jq | CI / manual runs | - | no |
| _project/ | dir | - | AEOS project scaffolding carried into this plugin repo | - | - | - | no |

## Key Exports
- `hooks/stop-hook-fork.sh` — Stop hook: forks new session per iteration (tmux or herdr, per `backend`), blocks on pending background agents / completion promise / doom-loop detection.
- `scripts/setup-ralph-loop-fork.sh` — entry point; resolves `--backend` (default `herdr` since v0.13.0), model/effort, worktree mode.
- `scripts/fork-terminal-herdr.sh`, `scripts/lib-herdr-backend.sh` — herdr-backend spawn + shared agent-name derivation (sanitize+hash to fit herdr's `[a-z][a-z0-9_-]{0,31}` charset).
- `scripts/lib-spawn-lineage.sh`, `scripts/spawn_registry.py`, `hooks/spawn-bind-hook.py`, `hooks/spawn-sweep-hook.py` — spawn lineage (fail-open; `spawn_registry.py` must stay byte-identical to the AEOS canonical module).
- `scripts/lib-launch-profile.sh` — optional launch-profile hook for herdr launches: `launch_profile_begin` (refuses on helper failure, before any pane exists), `launch_profile_prepare_pane` (PATH shim), `launch_profile_cleanup_pane`; absent project helper = no profile/shim. Also `_lp_inherit_env`: copies `RALPH_INHERIT_ENV` (default `CLDY_SESSION AEOS_LAUNCH_PROFILE CLAUDE_CONFIG_DIR`) set vars from the parent env onto `LP_HERDR_ENV`; a non-empty helper `env` replaces them.
- `scripts/lib-session-launch.sh` — `RALPH_DISALLOWED_TOOLS_ARG` + `RALPH_PARALLEL_SUBAGENTS_TEXT`, shared by all 4 claude launch sites and 6 prompt variants.

## Rules
- Plugin version bumps (`plugin.json`) + `scripts/sync-live-install.py` on every hook/script change — see host CLAUDE.md "AEOS-Only Rules".
- Every claude launch passes `$RALPH_DISALLOWED_TOOLS_ARG` in the `=` form (the flag is variadic; the space form eats the positional prompt). Guarded by `tests/test-wait-thrash-prevention.sh`.

## Changelog
- 2026-10-07: v0.20.0 — stop hook now honors an owner BLOCKER.md beside the checklist (or at the worktree
  root): loop deactivated (`owner_blocker_present`), no new fork. Doom fingerprint excludes the checklist
  file from tree hashes so uncommitted Session-Notes writes no longer reset `stuck_count` every fork.
- 2026-10-07: v0.19.0 — forked herdr sessions inherit the parent's account env (`RALPH_INHERIT_ENV`,
  default `CLDY_SESSION AEOS_LAUNCH_PROFILE CLAUDE_CONFIG_DIR`) with no project helper needed; a non-empty
  helper `env` replaces the inherited set (no per-key merge), empty = no opinion. Names-only stderr note.
  New `tests/test-inherit-account-env.sh`.
- 2026-10-05: v0.18.0 — optional launch profile (herdr). When the project ships
  `.claude/hooks/lib/launch_profile.py`, session-1 (worktree mode) and fork launches add its `env` to the
  pane `--env` and run its `command_prefix` ahead of `claude` via a per-pane PATH shim; a failing helper
  refuses the spawn before any pane/registry row exists; shim removed at every plugin pane close.
  No helper = unchanged. New `scripts/lib-launch-profile.sh`, `tests/test-launch-profile.sh`.
- 2026-09-30: v0.17.0 — spawn lineage. Every loop session spawn records one `spawn` row (loop_id,
  iteration, prev_spawn_id, launcher parent from `state.json` `launcher_session_id`) in the spawn
  registry and exports `SPAWN_*` to the child (herdr `--env`, tmux `-e`) so a SessionStart hook
  (`hooks/spawn-bind-hook.py`, no-op when the project ships its own `spawn-bind.py`) binds the
  session. Registry module `scripts/spawn_registry.py` is a byte-identical copy of the canonical
  one (parity checked by `sync-live-install.py` via `AEOS_REPO_ROOT`). Stop hook fires a detached
  rate-limited sweep (`hooks/spawn-sweep-hook.py`) before any early exit; registry dirs are
  excluded from the doom-loop fingerprint. Kill-switch `SPAWN_REGISTRY_DISABLE=1`. New
  `tests/test-spawn-lineage.sh`. Standalone default dir: `<root>/.claude/spawn-registry/`.
- 2026-09-24: v0.16.0 — stop wait-thrash. Iterations busy-waited on background sub-agents
  (ScheduleWakeup / ListAgents / `ls` polling) instead of ending the turn, burning ~42-55% of
  an affected session's tokens; the prompt wrongly said the stop hook "holds the session open
  (BLOCK-and-wait)" although it has deferred silently since v0.8.0. All 4 launch sites now pass
  `--disallowedTools=ScheduleWakeup`, and the 6 prompt variants share one rewritten block
  telling the model to end its turn (new `scripts/lib-session-launch.sh`). Verified on CLI
  2.1.281: the flag removes the deferred tool (ToolSearch returns no match) in headless and
  herdr-interactive sessions. New `tests/test-wait-thrash-prevention.sh`, plus assertions in
  the herdr and tmux fork tests.
- 2026-08-11: v0.13.0 — `--backend` default flipped from `tmux` to `herdr`; `tmux` is now the
  explicit opt-in (`--backend tmux`). herdr binary + server-reachability checked at startup
  (retried 0/0.5/1s — a bare `VAR=$(cmd) || true` fix was needed here: an unguarded failing
  command substitution under `set -euo pipefail` silently kills the script, caught by a
  hermetic test flaking ~100% once introduced). tmux dependency check is now conditional on
  `--backend tmux` (previously unconditional, blocking herdr-only users with no tmux
  installed). New `tests/test-backend-default.sh` (6 assertions: default selection, explicit
  opt-out, both missing-binary/unreachable-server error paths, tmux-not-required regression
  guard). Non-worktree test fixtures pinned to `--backend tmux` explicitly so they stay
  hermetic against the new default. See `scripts/setup-ralph-loop-fork.sh`, `README.md`,
  `commands/ralph-loop-fork.md`.
- 2026-08-11: v0.12.0 — doom-loop fingerprint fix: mandatory per-session Notes-only
  commits/checklist edits no longer reset `stuck_count` (`strip_session_notes`,
  `find_last_non_checklist_commit` in `hooks/stop-hook-fork.sh`). Also documents the
  always-on default `--stop-hook-reminders` (code shipped earlier in 4713bad, never written
  up), and fixes `run_cleanup_detached()` — the code path that actually runs on loop
  completion, not `cleanup_ralph_sessions()` which has zero callers — which was still 100%
  hardcoded to `tmux kill-session`, silently leaking every herdr-backend loop's pane
  (`tests/test-detached-cleanup-herdr.sh`). See `hooks/stop-hook-fork.sh`.
- 2026-08-06: v0.11.3 — `extract_loop_from_worktree_state` (the WORKTREE FALLBACK) now requires `RALPH_LOOP_ACTIVE=1` before trusting a cwd==worktree_path match. Cause: an ordinary session that `cd`s into an active loop's worktree (e.g. to inspect it) satisfied the cwd predicate honestly and got misidentified as that loop's own spawned session — the Stop hook then mutated the loop's state (`awaiting_checklist_update`, `session_number`) and, on the next Stop event, really spawned a new tmux iteration for a loop nobody asked to continue. `fork-terminal.sh`'s `FORK_CMD` already unconditionally exports `RALPH_LOOP_ACTIVE=1` into every session it spawns (and unsets it nowhere else) — cwd inspection can't set env vars, so this is an exact identity check, not a location heuristic. See `hooks/stop-hook-fork.sh`.
- 2026-08-05: v0.9.0 — `--worktree` mode now REQUIRES `--base-ref <ref>` (no default, never the invoking cwd's ambient HEAD). Closes an ambient-branch-state bug: sibling worktrees (e.g. `cooperative_launch.py`) previously forked from whatever HEAD the invoking cwd happened to have at spawn time instead of an intended parent branch. `scripts/setup-worktree.sh` gains a new positional `BASE_REF` arg (after `BRANCH`, before `CHECKLIST_DIR`) and fails loudly if empty or unresolvable; `scripts/setup-ralph-loop-fork.sh` validates `--base-ref` is present whenever `--worktree` is passed and threads it through. Docs (`README.md`, `commands/help-fork.md`, `commands/ralph-loop-fork.md`) and `tests/test-worktree-setup.sh` (+8 new assertions) updated to match. See `scripts/setup-worktree.sh`, `scripts/setup-ralph-loop-fork.sh`.
- 2026-08-02: v0.8.0 — replaced bg-agent block-and-poll with defer-don't-block: pending background agents now exit the Stop hook silently (no `decision:block`), letting the queued `task-notification` resume the session naturally instead of forcing an instant re-stop cycle. Removes the v0.7.1 poll-interval sleep (now moot). Unverified risk accepted: the block existed to close an AC2 finish-vs-integrate race; no reproduction was re-run before switching. Test suite updated to assert silent defer instead of block; all 171 tests pass. See `hooks/stop-hook-fork.sh`, `tests/test-background-agent-detection.sh`.
- 2026-08-02: v0.7.1 — throttle bg-agent stop-hook re-poll rate (`RALPH_BG_POLL_INTERVAL_SECONDS`, default 15s sleep before re-emitting "still waiting" block) to cut wait-cycle spam in the transcript. Superseded by v0.8.0. See `hooks/stop-hook-fork.sh`.
