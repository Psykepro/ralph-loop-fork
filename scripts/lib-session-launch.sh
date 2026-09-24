#!/bin/bash

# Shared launch constants for every loop session spawn: session 1 and forks,
# tmux and herdr. Sourced by setup-ralph-loop-fork.sh, fork-terminal.sh and
# fork-terminal-herdr.sh so the four launch sites and six prompt variants
# cannot drift apart.

# Iterations busy-waited on background sub-agents with ScheduleWakeup instead
# of ending the turn. The = form is required: --disallowedTools is variadic,
# so the space form swallows the positional init message that follows it.
RALPH_DISALLOWED_TOOLS_ARG="--disallowedTools=ScheduleWakeup"

# The stop hook defers silently while sub-agents are pending (v0.8.0); it
# does not hold the session open, so the model must end its own turn.
RALPH_PARALLEL_SUBAGENTS_TEXT='PARALLEL SUB-AGENTS:
- Sub-agents run in the background by default; their results arrive as task notifications on a
  later turn, not inline. Launch as many as you need, in one message for parallelism.
- After launching background sub-agents, END YOUR TURN with a short text-only reply. Each
  result re-invokes you automatically as a new turn; the loop does not advance while any
  sub-agent you launched is still pending.
- Do NOT wait by polling: no ScheduleWakeup, no repeated ListAgents calls, no ls/sleep loops
  over output folders. For a genuine timed wait on external work, run a single Bash command
  with run_in_background and end your turn.
- Do NOT declare completion or output the promise until you have received and integrated every
  sub-agent result.
- Do NOT spawn new sub-agents after outputting the promise.'
