#!/usr/bin/env python3
"""SessionStart hook: bind this session to its spawn lineage row.

If env SPAWN_ID is set, appends one `bind` row via spawn_registry.bind_from_env;
otherwise a no-op. No stdout. Fail-open: any error is one stderr line, exit 0.
No-op when the project already ships its own bind hook
(<project>/.claude/hooks/session-start/spawn-bind.py) so a bind is written once.
Python 3.9 compatible.
"""

import json
import os
import sys
from pathlib import Path

_SENTINEL = Path(".claude/hooks/session-start/spawn-bind.py")


def main() -> int:
    if not os.environ.get("SPAWN_ID"):
        return 0
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    try:
        project = os.environ.get("CLAUDE_PROJECT_DIR") or payload.get("cwd") or os.getcwd()
        if (Path(project) / _SENTINEL).is_file():
            return 0
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
        import spawn_registry
        spawn_registry.bind_from_env(payload, os.environ)
    except Exception as exc:  # noqa: BLE001 — incl. 3.9 SyntaxError/TypeError in the module
        print(f"spawn-bind: ❌ bind skipped: {exc!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
