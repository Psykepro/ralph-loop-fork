#!/usr/bin/env python3
"""Unit tests for cooperative_launch.py -- dependency-graph parsing, ready-set
computation (AC3: no-deps, single-dep, diamond shapes), advisory merge lock, and
launch-argv construction (never raw `git worktree add`)."""

import json
from pathlib import Path

import pytest

import cooperative_launch as cl


NO_DEPS_MASTER = """# Feature: x

## Execution Order

| ID | Checklist | Status | blockedBy | Est. |
|----|-----------|--------|-----------|------|
| 1 | sub-01-x.md | pending | — | ~10k |
| 2 | sub-02-x.md | pending | — | ~10k |

## Other Section
irrelevant table row: | 99 | not-a-sub.md | x | 1 | ~1k |
"""

SINGLE_DEP_MASTER = """# Feature: y

## Execution Order

| ID | Checklist | Status | blockedBy | Est. |
|----|-----------|--------|-----------|------|
| 1 | sub-01-y.md | completed | — | ~10k |
| 2 | sub-02-y.md | pending | 1 | ~10k |
"""

DIAMOND_MASTER = """# Feature: z

## Execution Order

| ID | Checklist | Status | blockedBy | Est. |
|----|-----------|--------|-----------|------|
| 1 | sub-01-z.md | completed | — | ~10k |
| 2 | sub-02-z.md | pending | 1 | ~10k |
| 3 | sub-03-z.md | pending | 1 | ~10k |
| 4 | sub-04-z.md | pending | 2,3 | ~10k |
"""


def test_parse_no_deps_shape():
    subs = cl.parse_execution_order(NO_DEPS_MASTER)
    assert subs[1]["blocked_by"] == []
    assert subs[2]["blocked_by"] == []
    assert 99 not in subs  # row outside the Execution Order table must not be parsed


def test_parse_single_dep_shape():
    subs = cl.parse_execution_order(SINGLE_DEP_MASTER)
    assert subs[1]["blocked_by"] == []
    assert subs[2]["blocked_by"] == [1]


def test_parse_diamond_shape():
    subs = cl.parse_execution_order(DIAMOND_MASTER)
    assert subs[4]["blocked_by"] == [2, 3]


def test_parse_missing_heading_raises():
    with pytest.raises(cl.CooperativeLaunchError):
        cl.parse_execution_order("# no execution order table here\n")


def test_ready_set_no_deps():
    subs = cl.parse_execution_order(NO_DEPS_MASTER)
    assert cl.compute_ready_set(subs, merged=set()) == [1, 2]


def test_ready_set_single_dep_blocks_until_merged():
    subs = cl.parse_execution_order(SINGLE_DEP_MASTER)
    assert cl.compute_ready_set(subs, merged=set()) == [1]
    assert cl.compute_ready_set(subs, merged={1}) == [2]
    assert cl.compute_ready_set(subs, merged={1, 2}) == []


def test_ready_set_diamond_shape():
    subs = cl.parse_execution_order(DIAMOND_MASTER)
    # nothing merged yet: only the root (1) is ready
    assert cl.compute_ready_set(subs, merged=set()) == [1]
    # 1 merged: both branches (2, 3) become ready simultaneously
    assert cl.compute_ready_set(subs, merged={1}) == [2, 3]
    # only one branch merged: 4 still blocked (needs both 2 and 3)
    assert cl.compute_ready_set(subs, merged={1, 2}) == [3]
    # both branches merged: 4 becomes ready
    assert cl.compute_ready_set(subs, merged={1, 2, 3}) == [4]


def test_merge_lock_acquire_and_block():
    state = {"merge_lock": None}
    assert cl.acquire_merge_lock(state, sub_id=2, now=100.0) is True
    assert state["merge_lock"] == {"sub_id": 2, "acquired_at": 100.0}
    # a different sub cannot acquire while 2 holds it
    assert cl.acquire_merge_lock(state, sub_id=3, now=101.0) is False
    # the same sub re-acquiring is a no-op success
    assert cl.acquire_merge_lock(state, sub_id=2, now=102.0) is True


def test_merge_lock_release_frees_it_for_others():
    state = {"merge_lock": {"sub_id": 2, "acquired_at": 100.0}}
    cl.release_merge_lock(state, sub_id=2)
    assert state["merge_lock"] is None
    assert cl.acquire_merge_lock(state, sub_id=3, now=200.0) is True


def test_release_by_non_holder_is_noop():
    state = {"merge_lock": {"sub_id": 2, "acquired_at": 100.0}}
    cl.release_merge_lock(state, sub_id=3)
    assert state["merge_lock"] == {"sub_id": 2, "acquired_at": 100.0}


def test_build_launch_argv_uses_worktree_flag_never_raw_git():
    subs = cl.parse_execution_order(SINGLE_DEP_MASTER)
    argv = cl.build_launch_argv(2, subs[2], Path("/tmp/plan-dir"), "coop-x", script_path=Path("/fake/setup-ralph-loop-fork.sh"))
    assert argv[0] == "/fake/setup-ralph-loop-fork.sh"
    assert "--worktree" in argv
    assert "git" not in argv
    assert "worktree" not in [a for a in argv if a not in ("--worktree",)]  # no raw "worktree" subcommand token
    assert "--checklist" in argv
    assert str(Path("/tmp/plan-dir") / "sub-02-y.md") in argv
    assert "coop-x-sub02" in argv


def test_launch_sibling_injects_run_callable():
    calls = []

    def fake_run(argv, capture_output, text, check):
        calls.append(argv)

        class Result:
            returncode = 0
            stdout = ""
            stderr = ""

        return Result()

    result = cl.launch_sibling(["echo", "hi"], run=fake_run)
    assert result.returncode == 0
    assert calls == [["echo", "hi"]]


def test_cooperative_state_round_trip(tmp_path):
    state_path = tmp_path / "cooperative-state.json"
    assert cl.load_cooperative_state(state_path) == {"merged": [], "launched": {}, "merge_lock": None}

    state = {"merged": [1], "launched": {"2": {"launched_at": 1.0}}, "merge_lock": None}
    cl.save_cooperative_state(state_path, state)
    assert json.loads(state_path.read_text()) == state
    assert cl.load_cooperative_state(state_path) == state


def test_main_dry_run_launches_nothing(tmp_path, capsys):
    master = tmp_path / "MASTER-CHECKLIST.md"
    master.write_text(SINGLE_DEP_MASTER)

    def fail_if_called(*a, **k):
        raise AssertionError("run() must not be called in --dry-run mode")

    rc = cl.main_with_args(
        [
            "--master-checklist", str(master),
            "--coop-id", "test-coop",
            "--state-dir", str(tmp_path / "state"),
            "--dry-run",
        ],
        run=fail_if_called,
    )
    assert rc == 0
    out = capsys.readouterr().out
    assert "[dry-run] sub-01" in out


def test_main_launches_ready_set_and_persists_state(tmp_path):
    master = tmp_path / "MASTER-CHECKLIST.md"
    master.write_text(SINGLE_DEP_MASTER)
    state_dir = tmp_path / "state"

    calls = []

    def fake_run(argv, capture_output, text, check):
        calls.append(argv)

        class Result:
            returncode = 0
            stdout = ""
            stderr = ""

        return Result()

    rc = cl.main_with_args(
        [
            "--master-checklist", str(master),
            "--coop-id", "test-coop",
            "--state-dir", str(state_dir),
        ],
        run=fake_run,
    )
    assert rc == 0
    assert len(calls) == 1  # only sub-1 is ready (sub-2 blockedBy 1)

    state = cl.load_cooperative_state(state_dir / "cooperative-state.json")
    assert "1" in state["launched"]


def test_main_no_ready_subs_returns_zero(tmp_path, capsys):
    master = tmp_path / "MASTER-CHECKLIST.md"
    master.write_text(SINGLE_DEP_MASTER)

    rc = cl.main_with_args(
        [
            "--master-checklist", str(master),
            "--coop-id", "test-coop",
            "--merged", "1,2",
            "--state-dir", str(tmp_path / "state"),
        ],
        run=lambda *a, **k: (_ for _ in ()).throw(AssertionError("must not launch")),
    )
    assert rc == 0
    assert "no ready sub-checklists" in capsys.readouterr().out
