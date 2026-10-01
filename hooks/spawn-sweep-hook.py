#!/usr/bin/env python3
"""Stop hook helper: rate-limited detached registry sweep [ASYNC].

Runs before every early exit of stop-hook-fork.sh. Acts only in a project that
uses ralph-loop-fork (has `.claude/ralph-fork/`); resolving the registry path may
create its dir there, so unrelated repos are untouched. Silent no-op otherwise; fail-open.
Python 3.9 compatible.
"""

import json
import os
import sys
from pathlib import Path


def main() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    try:
        project = Path(os.environ.get("CLAUDE_PROJECT_DIR") or (payload or {}).get("cwd") or os.getcwd())
        if not (project / ".claude" / "ralph-fork").is_dir():
            return 0
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
        import spawn_registry
        if spawn_registry.is_disabled(root=project):
            return 0
        reg = spawn_registry.resolve_registry_dir(root=project).path
        spawn_registry.maybe_detached_sweep(reg)
    except Exception as exc:  # noqa: BLE001
        print(f"spawn-sweep: ⚠️ sweep skipped: {exc!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
