#!/usr/bin/env python3
"""
Pre-tool-use hook: blocks Agent calls with run_in_background=true inside ralph-loop-fork sessions.

Background agents are orphaned when the session forks — their results are lost and tokens wasted.
This hook is a harness-level guard that enforces the PARALLEL SUB-AGENTS rule from the session
prompt by refusing background Agent spawns before they can start.

Only fires when RALPH_LOOP_ACTIVE env var is set (i.e., inside a forked loop session).
Hook input (JSON on stdin): session_id, tool_name, tool_input
Exit: always 0 — allow or deny is communicated via stdout JSON, never via exit code.
"""

import json
import os
import sys

DENY_RESPONSE = {
    "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "Background agents (run_in_background=true) are blocked inside ralph-loop-fork sessions. "
            "Background agents are orphaned when the session forks — results are LOST, tokens wasted. "
            "Use multiple foreground Agent calls in a single message for parallel work instead."
        ),
    }
}


def main() -> None:
    # Only enforce inside ralph-loop-fork sessions
    if not os.environ.get("RALPH_LOOP_ACTIVE"):
        sys.exit(0)

    try:
        data = json.loads(sys.stdin.read())
    except Exception:
        sys.exit(0)

    try:
        if data.get("tool_name") != "Agent":
            sys.exit(0)

        tool_input = data.get("tool_input", {})
        if tool_input.get("run_in_background") is True:
            print(json.dumps(DENY_RESPONSE))
    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
