#!/usr/bin/env python3
"""cooperative_launch.py — dependency-graph-driven cooperative multi-worktree launcher.

Reads a MASTER-CHECKLIST's '## Execution Order' table (ID | Checklist | Status |
blockedBy | Est.), computes which sub-checklists are "ready" (all blockedBy deps
already merged), and launches one sibling `ralph-loop-fork --worktree` instance per
ready sub-checklist from the primary checkout.

A1's live probe (sub-03, MASTER-CHECKLIST Context Handoff Log) confirmed `git worktree
add` from primary hits zero `nested-worktree-guard.py` denials. cooperative_launch.py
itself must NEVER call raw `git worktree add` -- it exclusively spawns sibling
worktrees through `setup-ralph-loop-fork.sh --worktree` (the same script backing the
`/ralph-loop-fork:ralph-loop-fork` slash command), so every spawned session goes
through that script's own Entry Gate (state-dir collision checks, model/effort
resolution, tmux session naming) instead of re-deriving worktree mechanics here.

Merge-order safety: option (b) -- parallel implementation, serial merge with rebase,
no file-disjointness pre-check this iteration. Each sibling worktree's own Exit Gate
(per `worktree-teardown.md`) is responsible for its own fetch/rebase/test/push/PR/
merge; cooperative_launch.py does not merge on a sibling's behalf. What it DOES own is
an advisory merge lock (`cooperative-state.json`'s `merge_lock` field) so two siblings
whose Exit Gates are ready to merge at the same time serialize instead of racing --
see `acquire_merge_lock`/`release_merge_lock`. This is advisory only: a sibling
session that ignores the lock can still merge (each worktree session is independent
and cooperative_launch.py cannot block its Exit Gate), so document the ordering
constraint in the sibling's own checklist/session guidance too.
"""

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

_EXEC_ORDER_HEADING_RE = re.compile(r'^##\s+Execution Order\s*$', re.MULTILINE)
_TABLE_ROW_RE = re.compile(r'^\|\s*(\d+)\s*\|(.+)\|\s*$')

DEFAULT_RALPH_SCRIPT = Path(__file__).resolve().parent / "setup-ralph-loop-fork.sh"


class CooperativeLaunchError(Exception):
    """Raised for usage/parse errors -- never caught silently by callers."""


def parse_execution_order(master_checklist_text: str) -> dict:
    """Parse the '## Execution Order' table into
    {sub_id: {"checklist": str, "status": str, "blocked_by": [int, ...]}}.

    Only rows inside the Execution Order table are parsed (scan stops at the next
    '## ' heading). The header and separator rows never match (first cell is not a
    bare integer). blockedBy cell of '-'/'--'/'—'/'' means no dependencies.
    """
    heading = _EXEC_ORDER_HEADING_RE.search(master_checklist_text)
    if not heading:
        raise CooperativeLaunchError("no '## Execution Order' heading found in MASTER-CHECKLIST")
    region = master_checklist_text[heading.end():]
    next_heading = re.search(r'^##\s+', region, re.MULTILINE)
    if next_heading:
        region = region[:next_heading.start()]

    subs = {}
    for line in region.splitlines():
        m = _TABLE_ROW_RE.match(line.strip())
        if not m:
            continue
        sub_id = int(m.group(1))
        cols = [c.strip() for c in m.group(2).split('|')]
        if len(cols) < 3:
            raise CooperativeLaunchError(f"malformed Execution Order row for id {sub_id}: {line!r}")
        checklist, status, blocked_by_raw = cols[0], cols[1], cols[2]
        digits = re.findall(r'\d+', blocked_by_raw)
        blocked_by = [int(d) for d in digits]
        subs[sub_id] = {"checklist": checklist, "status": status, "blocked_by": blocked_by}
    if not subs:
        raise CooperativeLaunchError("Execution Order table has zero parseable rows")
    return subs


def compute_ready_set(subs: dict, merged: set) -> list:
    """Sub IDs not yet merged whose every blockedBy dependency IS in `merged`.

    Deterministic ordering: ascending sub_id, matching Execution Order table order.
    """
    return sorted(
        sub_id for sub_id, info in subs.items()
        if sub_id not in merged and all(dep in merged for dep in info["blocked_by"])
    )


def load_cooperative_state(state_path: Path) -> dict:
    if not state_path.exists():
        return {"merged": [], "launched": {}, "merge_lock": None}
    with open(state_path, encoding="utf-8") as f:
        return json.load(f)


def save_cooperative_state(state_path: Path, state: dict) -> None:
    state_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = state_path.with_suffix(state_path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, sort_keys=True)
        f.write("\n")
    tmp_path.replace(state_path)


def acquire_merge_lock(state: dict, sub_id: int, now: float) -> bool:
    """Advisory only -- see module docstring. Returns True if `sub_id` now holds the
    lock (either it was free, or `sub_id` already held it), False if another sub_id
    currently holds it."""
    lock = state.get("merge_lock")
    if lock is not None and lock.get("sub_id") != sub_id:
        return False
    state["merge_lock"] = {"sub_id": sub_id, "acquired_at": now}
    return True


def release_merge_lock(state: dict, sub_id: int) -> None:
    lock = state.get("merge_lock")
    if lock is not None and lock.get("sub_id") == sub_id:
        state["merge_lock"] = None


def build_launch_argv(
    sub_id: int,
    sub_info: dict,
    checklist_dir: Path,
    coop_id: str,
    script_path: Path = None,
) -> list:
    """Build the argv for launching one ready sub-checklist as a sibling worktree
    loop via `setup-ralph-loop-fork.sh --worktree` -- never raw `git worktree add`."""
    script = str(script_path or DEFAULT_RALPH_SCRIPT)
    checklist_path = str(checklist_dir / sub_info["checklist"])
    loop_name = f"{coop_id}-sub{sub_id:02d}"
    return [
        script,
        "--checklist", checklist_path,
        "--command", "/implement",
        "--name", loop_name,
        "--worktree",
    ]


def launch_sibling(argv: list, run=subprocess.run) -> subprocess.CompletedProcess:
    """Injectable `run` for testability -- production callers use subprocess.run."""
    return run(argv, capture_output=True, text=True, check=False)


def main_with_args(argv, run=subprocess.run) -> int:
    parser = argparse.ArgumentParser(
        prog="cooperative_launch.py",
        description="Launch ready sub-checklists (per MASTER-CHECKLIST blockedBy graph) as sibling ralph-loop-fork --worktree instances.",
    )
    parser.add_argument("--master-checklist", required=True, help="Path to MASTER-CHECKLIST.md")
    parser.add_argument("--coop-id", required=True, help="Cooperative-run identifier (used to namespace state + loop names)")
    parser.add_argument("--merged", default="", help="Comma-separated sub IDs already merged (e.g. '1,2')")
    parser.add_argument("--state-dir", default=None, help="Override state dir (default: <project-root>/.claude/ralph-fork/<coop-id>)")
    parser.add_argument("--dry-run", action="store_true", help="Print launch argv without spawning")
    args = parser.parse_args(argv)

    master_path = Path(args.master_checklist)
    try:
        text = master_path.read_text(encoding="utf-8")
    except OSError as exc:
        print(f"❌ cannot read {master_path}: {exc}", file=sys.stderr)
        return 2

    try:
        subs = parse_execution_order(text)
    except CooperativeLaunchError as exc:
        print(f"❌ {exc}", file=sys.stderr)
        return 2

    merged = {int(x) for x in args.merged.split(",") if x.strip()}
    ready = compute_ready_set(subs, merged)
    if not ready:
        print("no ready sub-checklists (nothing unblocked, or all already merged)")
        return 0

    state_dir = Path(args.state_dir) if args.state_dir else Path(".claude/ralph-fork") / args.coop_id
    state_path = state_dir / "cooperative-state.json"
    state = load_cooperative_state(state_path)
    state.setdefault("merged", sorted(merged))
    state.setdefault("launched", {})

    checklist_dir = master_path.parent
    for sub_id in ready:
        argv_for_sub = build_launch_argv(sub_id, subs[sub_id], checklist_dir, args.coop_id)
        if args.dry_run:
            print(f"[dry-run] sub-{sub_id:02d}: {' '.join(argv_for_sub)}")
            continue
        result = launch_sibling(argv_for_sub, run=run)
        if result.returncode != 0:
            print(f"❌ launch failed for sub-{sub_id:02d} (exit {result.returncode}): {result.stderr.strip()}", file=sys.stderr)
            continue
        print(f"✅ launched sub-{sub_id:02d}")
        state["launched"][str(sub_id)] = {"launched_at": time.time(), "argv": argv_for_sub}

    save_cooperative_state(state_path, state)
    return 0


def main() -> None:
    sys.exit(main_with_args(sys.argv[1:]))


if __name__ == "__main__":
    main()
