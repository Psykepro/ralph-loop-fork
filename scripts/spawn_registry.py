#!/usr/bin/env python3
"""Spawn registry — canonical parent->child lineage log for spawned Claude sessions.

Stdlib-only, Python 3.9-compatible. Owns main-checkout resolution (pure file reads),
the append-only JSONL writer, the incremental reader, `build_tree` and `sweep`.

Consumers import it behind a guard so a broken import fails open, loudly:

    try:
        import spawn_registry
    except Exception as exc:  # also catches a 3.9 SyntaxError/TypeError
        print(f"spawn-registry: import failed, lineage skipped: {exc}", file=sys.stderr)
        spawn_registry = None

CLI: python3 spawn_registry.py {spawn|bind|end|tree|resolve|sweep|status}
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, Iterator, List, Optional, Tuple

try:
    import fcntl
except ImportError:  # non-POSIX: rotation runs unlocked
    fcntl = None  # type: ignore[assignment]

SCHEMA_V = 1
MAX_ROW_BYTES = 512  # PIPE_BUF, per signals-protocol
LIVE_NAME = "spawns.jsonl"
RETENTION_DAYS = 90
FAILURES_CAP_BYTES = 256 * 1024
METRICS_CAP_BYTES = 256 * 1024
DEFAULT_MAX_SEGMENT_BYTES = 4 * 1024 * 1024
SWEEP_INTERVAL_S = 24 * 3600
SWEEP_LOCK_TIMEOUT_S = 30
DEFAULT_FOLDER = "spawn-registry"
BIND_SOURCES = ("startup", "resume", "compact", "clear", "fork")
ALIVE_STATES = ("running", "idle", "needs-you")
_PROTECTED = {"v", "type", "trunc", "spawn_id", "ts"}


class RegistryConfigError(Exception):
    """Invalid override / malformed settings / no repo — always loud, never falls through."""


# ------------------------------------------------------------------ main-checkout resolution
def _find_git_top(start: Path) -> Tuple[Path, Path]:
    """Nearest ancestor holding `.git` -> (top, path-to-.git)."""
    cur = Path(start).resolve()
    for cand in [cur, *cur.parents]:
        g = cand / ".git"
        if g.exists():
            return cand, g
    raise RegistryConfigError(f"no git repository at or above {start}")


def _resolve_gitdir(dot_git: Path) -> Tuple[Path, Optional[Path]]:
    """`.git` dir or file -> (gitdir, commondir-or-None) by file reads only."""
    if dot_git.is_dir():
        return dot_git.resolve(), None
    text = dot_git.read_text(encoding="utf-8", errors="replace").strip()
    if not text.startswith("gitdir:"):
        raise RegistryConfigError(f"unrecognised .git file: {dot_git}")
    gitdir = (dot_git.parent / text[len("gitdir:"):].strip()).resolve()
    cd = gitdir / "commondir"
    if cd.is_file():
        return gitdir, (gitdir / cd.read_text(encoding="utf-8").strip()).resolve()
    return gitdir, None


def git_common_dir(start: Any) -> Path:
    """Equals `git rev-parse --git-common-dir` (resolved), with no subprocess."""
    _, dot_git = _find_git_top(Path(start))
    gitdir, common = _resolve_gitdir(dot_git)
    return common or gitdir


def main_checkout(start: Any) -> Path:
    """Main-checkout root for `start`; a nested repo/submodule is its own root."""
    top, dot_git = _find_git_top(Path(start))
    if dot_git.is_dir():
        return top
    _, common = _resolve_gitdir(dot_git)
    if common is not None and common.name == ".git":
        return common.parent
    return top


def _anchor_root(explicit: Any = None, env: Optional[Dict[str, str]] = None) -> Path:
    env = os.environ if env is None else env
    if explicit:
        return main_checkout(explicit)
    if env.get("CLAUDE_PROJECT_DIR"):
        return main_checkout(env["CLAUDE_PROJECT_DIR"])
    here = Path(__file__).resolve()
    if len(here.parents) > 3 and here.parents[2].name == ".claude":
        return main_checkout(here.parents[3])
    print("spawn-registry: ⚠️ no project anchor; falling back to cwd", file=sys.stderr)
    return main_checkout(Path.cwd())


# ------------------------------------------------------------------ settings + dir resolution
class Resolved:
    def __init__(self, path: Path, source: str, root: Optional[Path]):
        self.path, self.source, self.root = path, source, root

    def as_dict(self) -> Dict[str, Any]:
        return {"dir": str(self.path), "source": self.source, "root": str(self.root) if self.root else None}


def _read_settings(root: Path) -> Dict[str, Any]:
    for rel in ("_project/project-settings.json", ".claude/ralph-fork/config.json"):
        p = root / rel
        if p.is_file():
            try:
                data = json.loads(p.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                raise RegistryConfigError(f"malformed settings {p}: {exc}") from exc
            if not isinstance(data, dict):
                raise RegistryConfigError(f"malformed settings {p}: top level is not an object")
            return data
    return {}


def _lineage_cfg(settings: Dict[str, Any]) -> Dict[str, Any]:
    cfg = (settings.get("rule_config") or {}).get("spawn-lineage") or {}
    if not isinstance(cfg, dict):
        raise RegistryConfigError("rule_config.spawn-lineage must be an object")
    return cfg


def _ensure_writable(path: Path, *, parents: bool) -> None:
    try:
        path.mkdir(parents=parents, exist_ok=True)
    except OSError as exc:
        raise RegistryConfigError(f"cannot create registry dir {path}: {exc}") from exc
    if not os.access(path, os.W_OK):
        raise RegistryConfigError(f"registry dir not writable: {path}")


def resolve_registry_dir(root: Any = None, env: Optional[Dict[str, str]] = None) -> Resolved:
    """env SPAWN_REGISTRY_DIR -> settings rule_config.spawn-lineage -> default. Invalid = loud."""
    env = os.environ if env is None else env
    override = env.get("SPAWN_REGISTRY_DIR")
    if override:
        p = Path(override)
        if not p.is_absolute():
            raise RegistryConfigError(f"SPAWN_REGISTRY_DIR must be absolute: {override!r}")
        _ensure_writable(p, parents=False)
        return Resolved(p, "env", None)
    rootp = _anchor_root(root, env)
    cfg = _lineage_cfg(_read_settings(rootp))
    parent_dir, folder = cfg.get("parent_dir"), cfg.get("folder_name")
    for key, val in (("parent_dir", parent_dir), ("folder_name", folder)):
        if val is not None and (not isinstance(val, str) or not val):
            raise RegistryConfigError(f"rule_config.spawn-lineage.{key} must be a non-empty string")
    if folder is not None and (os.sep in folder or folder in (".", "..")):
        raise RegistryConfigError(f"rule_config.spawn-lineage.folder_name must be a plain name: {folder!r}")
    if parent_dir is not None:
        base = Path(parent_dir) if os.path.isabs(parent_dir) else rootp / parent_dir
        if not base.is_dir():
            raise RegistryConfigError(f"rule_config.spawn-lineage.parent_dir does not exist: {base}")
        path = base / (folder or DEFAULT_FOLDER)
        _ensure_writable(path, parents=False)
        return Resolved(path, "settings", rootp)
    base = rootp / ("_project/aeos/runtime" if (rootp / "_project").is_dir() else ".claude")
    path = base / (folder or DEFAULT_FOLDER)
    _ensure_writable(path, parents=True)
    return Resolved(path, "default", rootp)


def is_disabled(root: Any = None, env: Optional[Dict[str, str]] = None) -> bool:
    """Single kill-switch: env SPAWN_REGISTRY_DISABLE=1 or `rules.spawn-lineage=false`.

    Settings are read only when a root is given or CLAUDE_PROJECT_DIR is set (cheap hot path)."""
    env = os.environ if env is None else env
    if env.get("SPAWN_REGISTRY_DISABLE") == "1":
        return True
    anchor = root or env.get("CLAUDE_PROJECT_DIR")
    if not anchor:
        return False
    return (_read_settings(main_checkout(anchor)).get("rules") or {}).get("spawn-lineage") is False


# ------------------------------------------------------------------ rows
def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _clean(d: Optional[Dict[str, Any]], keep_none: bool = False) -> Dict[str, Any]:
    return {k: v for k, v in (d or {}).items() if keep_none or v is not None}


def new_spawn_id() -> str:
    return "sp-" + uuid.uuid4().hex[:12]


def spawn_row(spawner: str, parent: Optional[Dict[str, Any]] = None, child: Optional[Dict[str, Any]] = None,
              loop: Optional[Dict[str, Any]] = None, spawn_id: Optional[str] = None) -> Dict[str, Any]:
    row: Dict[str, Any] = {"v": SCHEMA_V, "type": "spawn", "spawn_id": spawn_id or new_spawn_id(),
                           "ts": _now(), "spawner": spawner}
    if _clean(parent):
        row["parent"] = _clean(parent)
    row["child"] = _clean(child)
    if loop:
        row["loop"] = _clean(loop, keep_none=True)
    return row


def bind_row(spawn_id: str, session_id: str, source: str) -> Dict[str, Any]:
    if source not in BIND_SOURCES:
        raise ValueError(f"bind source must be one of {'|'.join(BIND_SOURCES)}, got {source!r}")
    return {"v": SCHEMA_V, "type": "bind", "spawn_id": spawn_id, "ts": _now(),
            "session_id": session_id, "source": source}


def end_row(spawn_id: str, session_id: Optional[str] = None, reason: Optional[str] = None) -> Dict[str, Any]:
    return {"v": SCHEMA_V, "type": "end", "spawn_id": spawn_id, "ts": _now(),
            **_clean({"session_id": session_id, "reason": reason})}


def _dumps(row: Dict[str, Any]) -> bytes:
    return (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _longest_leaf(obj: Any, path: Tuple = ()) -> Optional[Tuple[Tuple, str]]:
    best: Optional[Tuple[Tuple, str]] = None
    items = obj.items() if isinstance(obj, dict) else []
    for k, v in items:
        if not path and k in _PROTECTED:
            continue
        cand = _longest_leaf(v, path + (k,)) if isinstance(v, dict) else ((path + (k,), v) if isinstance(v, str) else None)
        if cand and (best is None or len(cand[1]) > len(best[1])):
            best = cand
    return best


def encode_row(row: Dict[str, Any]) -> bytes:
    """One JSON line <= MAX_ROW_BYTES (UTF-8, incl. newline); shrinks long fields, sets `trunc`."""
    line = _dumps(row)
    if len(line) <= MAX_ROW_BYTES:
        return line
    row = copy.deepcopy(row)
    row["trunc"] = True
    while True:
        line = _dumps(row)
        if len(line) <= MAX_ROW_BYTES:
            return line
        leaf = _longest_leaf(row)
        if leaf is None or not leaf[1]:
            raise ValueError("row cannot be shortened to 512 bytes")
        path, val = leaf
        node = row
        for k in path[:-1]:
            node = node[k]
        node[path[-1]] = val[: len(val) // 2]


# ------------------------------------------------------------------ append + failure surface
def append_line(reg_dir: Any, line: bytes) -> bool:
    """One `write()` in append mode, opened per row so a rotation rename never reorders a writer."""
    fd = os.open(str(Path(reg_dir) / LIVE_NAME), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        n = os.write(fd, line)
    finally:
        os.close(fd)
    if n != len(line):
        if n:  # terminate the partial line so the next row doesn't concatenate onto it
            with contextlib.suppress(OSError):
                fd = os.open(str(Path(reg_dir) / LIVE_NAME), os.O_WRONLY | os.O_APPEND)
                try:
                    os.write(fd, b"\n")
                finally:
                    os.close(fd)
        raise OSError(f"short write {n}/{len(line)}")
    return True


def _capped_append(path: Path, text: str, cap: int) -> None:
    with contextlib.suppress(OSError):
        if path.stat().st_size >= cap:
            # non-blocking lock + re-stat: a concurrent writer that lost the race must not replace .1 with a fresh log
            with _rotate_lock(path.parent, 0) as got:
                if got and path.stat().st_size >= cap:
                    os.replace(str(path), str(path) + ".1")
    with open(path, "a", encoding="utf-8") as f:
        f.write(text)


def log_failure(reg_dir: Any, msg: str, cap_bytes: int = FAILURES_CAP_BYTES) -> None:
    try:
        _capped_append(Path(reg_dir) / "failures.log", f"{_now()} {msg}\n", cap_bytes)
    except OSError as exc:
        print(f"spawn-registry: ❌ could not write failures.log: {exc}", file=sys.stderr)


def record_metric(reg_dir: Any, metric: str, value: float = 1.0) -> None:
    try:
        _capped_append(Path(reg_dir) / "metrics.jsonl",
                       json.dumps({"ts": _now(), "metric": metric, "value": value}) + "\n", METRICS_CAP_BYTES)
    except OSError as exc:
        print(f"spawn-registry: ⚠️ metric {metric} not recorded: {exc}", file=sys.stderr)


def write_event(reg_dir: Any, row: Dict[str, Any], env: Optional[Dict[str, str]] = None,
                root: Any = None) -> bool:
    """Fail-open append. Disabled -> True (no-op). Failure -> stderr + failures.log + metric, False."""
    try:
        if is_disabled(root=root, env=env):
            return True
    except RegistryConfigError as exc:
        print(f"spawn-registry: ❌ {exc}", file=sys.stderr)
        log_failure(reg_dir, f"config: {exc}")
        record_metric(reg_dir, "write_failure")
        return False
    try:
        return append_line(reg_dir, encode_row(row))
    except (OSError, ValueError) as exc:
        print(f"spawn-registry: ❌ write failed ({row.get('type')} {row.get('spawn_id')}): {exc}", file=sys.stderr)
        log_failure(reg_dir, f"write failed type={row.get('type')} spawn_id={row.get('spawn_id')}: {exc}")
        record_metric(reg_dir, "write_failure")
        return False


def bind_from_env(payload: Dict[str, Any], env: Optional[Dict[str, str]] = None) -> bool:
    """[HOT] SessionStart bind: one append, no subprocess. No SPAWN_ID -> no-op (False)."""
    env = os.environ if env is None else env
    spawn_id = env.get("SPAWN_ID")
    if not spawn_id:
        return False
    t0 = time.perf_counter()
    try:
        reg = Path(env["SPAWN_REGISTRY_DIR"]) if env.get("SPAWN_REGISTRY_DIR") else resolve_registry_dir(env=env).path
        row = bind_row(spawn_id, str(payload.get("session_id", "")), str(payload.get("source") or "startup"))
    except (RegistryConfigError, ValueError, KeyError) as exc:
        print(f"spawn-registry: ❌ bind skipped: {exc}", file=sys.stderr)
        return False
    ok = write_event(reg, row, env=env)
    if ok:
        record_metric(reg, "bind_ms", round((time.perf_counter() - t0) * 1000, 3))
    return ok


# ------------------------------------------------------------------ reader
def _segments(reg_dir: Path) -> List[Path]:
    return sorted(reg_dir.glob("spawns-*.jsonl"), key=lambda p: p.name)


class Reader:
    """Incremental tail fold. Cursor is keyed by inode, so a rotation rename is invisible and
    late writes into an already-rotated segment are still picked up. `refolded` is set when a
    truncation forced a full re-read (the returned events are then the complete set)."""

    def __init__(self, reg_dir: Any):
        self.dir = Path(reg_dir)
        self.skipped = 0
        self.refolded = False
        self._offsets: Dict[int, int] = {}

    def _files(self) -> List[Path]:
        files = _segments(self.dir)
        live = self.dir / LIVE_NAME
        if live.exists():
            files.append(live)
        return files

    def poll(self) -> List[Dict[str, Any]]:
        self.refolded = False
        out: List[Dict[str, Any]] = []
        files = []
        for p in self._files():
            try:
                files.append((p, p.stat()))
            except OSError:
                continue
        if any(st.st_size < self._offsets.get(st.st_ino, 0) for _, st in files):
            self._offsets.clear()
            self.skipped = 0
            self.refolded = True
        for p, st in files:
            off = self._offsets.get(st.st_ino, 0)
            if st.st_size <= off:
                continue
            try:
                with open(p, "rb") as f:
                    f.seek(off)
                    chunk = f.read()
            except OSError:
                continue
            end = chunk.rfind(b"\n")
            if end < 0:
                continue
            self._offsets[st.st_ino] = off + end + 1
            for raw in chunk[: end + 1].splitlines():
                try:
                    obj = json.loads(raw)
                except ValueError:
                    self.skipped += 1
                    continue
                if isinstance(obj, dict) and obj.get("type") in ("spawn", "bind", "end"):
                    out.append(obj)
                else:
                    self.skipped += 1
        return out


def read_all(reg_dir: Any) -> Tuple[List[Dict[str, Any]], int]:
    rd = Reader(reg_dir)
    return rd.poll(), rd.skipped


# ------------------------------------------------------------------ build_tree
Liveness = Optional[Callable[[str], Optional[str]]]


def _opt(v: Any, typ: Any) -> bool:
    return v is None or isinstance(v, typ)


def _well_formed(e: Any) -> bool:
    """Field-shape check for the events build_tree reads; unknown `type`s pass (ignored by the fold)."""
    if not isinstance(e, dict) or not isinstance(e.get("spawn_id"), str):
        return False
    t = e.get("type")
    if t == "spawn":
        child, parent, loop = e.get("child"), e.get("parent"), e.get("loop")
        if not (_opt(child, dict) and _opt(parent, dict) and _opt(loop, dict)):
            return False
        return (all(_opt((child or {}).get(k), str) for k in ("name", "pane_id", "workspace_id", "kind"))
                and all(_opt((parent or {}).get(k), str) for k in ("session_id", "name"))
                and all(_opt((loop or {}).get(k), str) for k in ("loop_id", "prev_spawn_id"))
                and _opt((loop or {}).get("iteration"), int) and _opt(e.get("spawner"), str) and _opt(e.get("ts"), str))
    if t == "bind":
        return isinstance(e.get("session_id"), str) and _opt(e.get("source"), str)
    return True


def build_tree(events: List[Dict[str, Any]], liveness: Liveness) -> Dict[str, Any]:
    """Pure fold of registry events into a flat `nodes` map + `roots` (ids); children are id lists.

    `liveness(session_id)` returns running|idle|needs-you for a live session, None for a gone one.
    `liveness=None` -> bound sessions read `idle` with `liveness: "unknown"` (never guessed dead)."""
    spawns: Dict[str, Dict[str, Any]] = {}
    malformed = 0
    for e in events:
        if not _well_formed(e):
            malformed += 1
            continue
        sid = e.get("spawn_id")
        t = e.get("type")
        if t == "spawn" and sid and sid not in spawns:
            child, loop = e.get("child") or {}, e.get("loop") or {}
            spawns[sid] = {"id": sid, "kind": "spawn", "name": child.get("name") or sid, "spawner": e.get("spawner"),
                           "ts": e.get("ts"), "pane_id": child.get("pane_id"), "workspace_id": child.get("workspace_id"),
                           "child_kind": child.get("kind"), "parent": e.get("parent") or {},
                           "loop_id": loop.get("loop_id"), "iteration": loop.get("iteration"),
                           "prev_spawn_id": loop.get("prev_spawn_id"), "session_ids": [], "session_id": None,
                           "ended": False, "children": []}
        elif sid in spawns and t == "bind" and e.get("session_id"):
            n = spawns[sid]
            # WHY: the pane env leaks SPAWN_ID to descendant `claude` runs, whose startup binds are not this
            # spawn's lineage; only the first startup binds (resume/clear/compact/fork rebinds still apply).
            if e.get("source") == "startup" and n["session_ids"] and e["session_id"] not in n["session_ids"]:
                continue
            if e["session_id"] not in n["session_ids"]:
                n["session_ids"].append(e["session_id"])
            n["session_id"] = e["session_id"]
        elif sid in spawns and t == "end":
            spawns[sid]["ended"] = True

    by_session = {s: n["id"] for n in spawns.values() for s in n["session_ids"]}
    nodes: Dict[str, Dict[str, Any]] = {}

    def alive_state(session_id: str) -> Tuple[str, str]:
        if liveness is None:
            return "idle", "unknown"
        st = liveness(session_id)
        return (st, "known") if st else ("dead", "known")

    for n in spawns.values():
        if n["ended"]:
            n["state"], n["liveness"] = "done", "registry"
        elif not n["session_ids"]:
            n["state"], n["liveness"] = "unbound", "registry"
        else:
            n["state"], n["liveness"] = alive_state(n["session_id"])
        nodes[n["id"]] = n

    def parent_of(parent: Dict[str, Any], self_id: str) -> Optional[str]:
        psid, pname = parent.get("session_id"), parent.get("name")
        if psid:
            owner = by_session.get(psid)
            if owner and owner != self_id:
                return owner
            xid = "external:session:" + psid
            if xid not in nodes:
                state, live = alive_state(psid)
                nodes[xid] = {"id": xid, "kind": "external", "name": pname or psid[:8], "state": state,
                              "liveness": live, "children": [], "parent_id": None, "session_id": psid}
            return xid
        if pname:
            xid = "external:name:" + pname
            if xid not in nodes:
                nodes[xid] = {"id": xid, "kind": "external", "name": pname, "state": "unbound",
                              "liveness": "registry", "children": [], "parent_id": None}
            return xid
        return None

    loop_first_parent: Dict[str, Dict[str, Any]] = {}
    for n in list(spawns.values()):
        lid = n["loop_id"]
        if lid:
            lnode_id = "loop:" + lid
            if lnode_id not in nodes:
                nodes[lnode_id] = {"id": lnode_id, "kind": "loop", "name": "loop " + lid, "loop_id": lid,
                                   "children": [], "state": "unbound", "liveness": "derived", "parent_id": None}
                loop_first_parent[lnode_id] = n["parent"]
            n["parent_id"] = lnode_id
        else:
            n["parent_id"] = parent_of(n["parent"], n["id"])
    for lnode_id, parent in loop_first_parent.items():
        nodes[lnode_id]["parent_id"] = parent_of(parent, lnode_id)

    for nid in list(nodes):  # break cycles: a node whose ancestor chain returns to itself becomes a root
        seen, cur = {nid}, nodes[nid].get("parent_id")
        while cur:
            if cur == nid:
                nodes[nid]["parent_id"] = None
                break
            if cur in seen:  # chain enters a cycle that excludes this node; the cycle's own members break it
                break
            seen.add(cur)
            cur = nodes[cur].get("parent_id")

    for n in nodes.values():
        pid = n.get("parent_id")
        if pid:
            nodes[pid]["children"].append(n["id"])

    for n in spawns.values():  # orphan: still alive, parent gone
        pid = n.get("parent_id")
        parent = nodes.get(pid) if pid else None
        if n["state"] in ALIVE_STATES and parent and parent["kind"] in ("spawn", "external") \
                and parent["state"] in ("dead", "done"):
            n["state"] = "orphan"

    for n in nodes.values():  # loop node state from its iterations
        if n["kind"] != "loop":
            continue
        kids = [nodes[c]["state"] for c in n["children"]]
        alive = [s for s in kids if s in ALIVE_STATES or s == "orphan"]
        n["state"] = "needs-you" if "needs-you" in kids else ("running" if alive else (kids[-1] if kids else "unbound"))

    counts: Dict[str, int] = {}
    for n in spawns.values():
        counts[n["state"]] = counts.get(n["state"], 0) + 1
    roots = [n["id"] for n in nodes.values() if not n.get("parent_id")]
    return {"roots": roots, "nodes": nodes, "counts": counts, "malformed_events": malformed}


def render_tree(tree: Dict[str, Any]) -> str:
    lines: List[str] = []

    def walk(nid: str, depth: int) -> None:
        n = tree["nodes"][nid]
        extra = f"  ({n['spawner']}, {n['id']})" if n["kind"] == "spawn" else ""
        lines.append(f"{'  ' * depth}{n['state']:<9} {n['name']}{extra}")
        for c in n["children"]:
            walk(c, depth + 1)

    for r in tree["roots"]:
        walk(r, 0)
    return "\n".join(lines) if lines else "(no spawns recorded)"


# ------------------------------------------------------------------ sweep
@contextlib.contextmanager
def _rotate_lock(reg_dir: Path, timeout: float) -> Iterator[bool]:
    if fcntl is None:
        yield True
        return
    fd = os.open(str(reg_dir / ".rotate.lock"), os.O_RDWR | os.O_CREAT, 0o644)
    got = False
    deadline = time.time() + timeout
    try:
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                got = True
                break
            except OSError:
                if time.time() >= deadline:
                    break
                time.sleep(0.01)
        yield got
    finally:
        if got:
            fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


_MICRO = timedelta(microseconds=1)


def _segment_name(reg_dir: Path) -> str:
    now = datetime.now(timezone.utc)
    stamp = now.strftime("%Y%m%dT%H%M%S%fZ")
    prior = _segments(reg_dir)
    if prior:
        last = prior[-1].name.split("-")[1]
        if last >= stamp:  # keep names strictly increasing even if the clock steps back
            stamp = (datetime.strptime(last, "%Y%m%dT%H%M%S%fZ") + _MICRO).strftime("%Y%m%dT%H%M%S%fZ")
    return f"spawns-{stamp}-{os.getpid()}-{uuid.uuid4().hex[:8]}.jsonl"


def sweep(reg_dir: Any, max_segment_bytes: Optional[int] = None, ttl_days: int = RETENTION_DAYS,
          lock_timeout: float = SWEEP_LOCK_TIMEOUT_S) -> Dict[str, Any]:
    """Rotate the live file when big and expire old segments, under `.rotate.lock` (registry files only)."""
    d = Path(reg_dir)
    if max_segment_bytes is None:
        max_segment_bytes = int(os.environ.get("SPAWN_REGISTRY_MAX_SEGMENT_BYTES") or DEFAULT_MAX_SEGMENT_BYTES)
    result: Dict[str, Any] = {"rotated": False, "segment": None, "expired": [], "locked": True}
    with _rotate_lock(d, lock_timeout) as got:
        if not got:
            result["locked"] = False
            return result
        live = d / LIVE_NAME
        try:
            size = live.stat().st_size  # re-stat after acquiring the lock
        except OSError:
            size = 0
        if size > 0 and size >= max_segment_bytes:
            name = _segment_name(d)
            os.rename(str(live), str(d / name))
            result["rotated"], result["segment"] = True, name
        cutoff = time.time() - ttl_days * 86400
        for seg in _segments(d):
            with contextlib.suppress(OSError):
                if seg.stat().st_mtime < cutoff:
                    seg.unlink()
                    result["expired"].append(seg.name)
    with contextlib.suppress(OSError):
        (d / ".last-sweep").touch()
    return result


def maybe_detached_sweep(reg_dir: Any) -> bool:
    """[ASYNC] rate-limited (24 h) detached sweep; the `.last-sweep` touch is the claim."""
    d = Path(reg_dir)
    stamp = d / ".last-sweep"
    try:
        if time.time() - stamp.stat().st_mtime < SWEEP_INTERVAL_S:
            return False
    except OSError:
        pass
    try:
        stamp.touch()
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "sweep", "--quiet"],
            env={**os.environ, "SPAWN_REGISTRY_DIR": str(d)},
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True, close_fds=True,
        )
    except OSError as exc:
        with contextlib.suppress(OSError):
            stamp.unlink()  # release the claim so the next call can retry
        print(f"spawn-registry: ⚠️ detached sweep not started: {exc}", file=sys.stderr)
        return False
    return True


# ------------------------------------------------------------------ status
def _pct(vals: List[float], p: float) -> Optional[float]:
    if not vals:
        return None
    s = sorted(vals)
    return s[min(len(s) - 1, int(round(p * (len(s) - 1))))]


def collect_status(reg_dir: Any) -> Dict[str, Any]:
    d = Path(reg_dir)
    events, skipped = read_all(d)
    t0 = time.perf_counter()
    tree = build_tree(events, None)
    tree_ms = (time.perf_counter() - t0) * 1000
    m: Dict[str, List[float]] = {}
    with contextlib.suppress(OSError):
        for raw in (d / "metrics.jsonl").read_text(encoding="utf-8").splitlines():
            with contextlib.suppress(ValueError, KeyError):
                r = json.loads(raw)
                m.setdefault(r["metric"], []).append(float(r["value"]))
    fails = len(m.get("write_failure", []))
    writes = fails + len(m.get("bind_ms", [])) + len(m.get("spawn_cli_ms", []))
    spawn_n = sum(tree["counts"].values())
    live = d / LIVE_NAME
    return {
        "dir": str(d), "segments": len(_segments(d)),
        "live_bytes": live.stat().st_size if live.exists() else 0,
        "rows": len(events), "skipped_rows": skipped + tree["malformed_events"], "spawns": spawn_n, "counts": tree["counts"],
        "unbound_ratio": round(tree["counts"].get("unbound", 0) / spawn_n, 3) if spawn_n else 0.0,
        "write_failure_rate": round(fails / writes, 4) if writes else 0.0,
        "bind_ms_p95": _pct(m.get("bind_ms", []), 0.95),
        "spawn_cli_ms_p95": _pct(m.get("spawn_cli_ms", []), 0.95),
        "tree_build_ms": round(tree_ms, 3),
        "failures_log_bytes": (d / "failures.log").stat().st_size if (d / "failures.log").exists() else 0,
    }


# ------------------------------------------------------------------ CLI
def _fail(msg: str, code: int = 1) -> int:
    print(f"❌ spawn-registry: {msg}", file=sys.stderr)
    return code


def _sweep_failed(reg_dir: Path, msg: str) -> int:
    """Loud failure + drop the `.last-sweep` claim so the next spawn retries instead of waiting 24 h."""
    log_failure(reg_dir, msg)
    record_metric(reg_dir, "sweep_failure")
    with contextlib.suppress(OSError):
        (reg_dir / ".last-sweep").unlink()
    return _fail(msg)


def _cmd_write(args: argparse.Namespace, build: Callable[[], Dict[str, Any]], emit: Optional[str] = None) -> int:
    t0 = time.perf_counter()
    try:
        resolved = resolve_registry_dir(root=args.root)
        row = build()
        if is_disabled(root=resolved.root):
            print("spawn-registry: disabled (rules.spawn-lineage=false or SPAWN_REGISTRY_DISABLE=1); nothing written",
                  file=sys.stderr)
            return 0
    except RegistryConfigError as exc:
        return _fail(str(exc), 2)
    except ValueError as exc:
        return _fail(str(exc), 2)
    if not write_event(resolved.path, row, root=resolved.root):
        return _fail(f"write failed; see {resolved.path / 'failures.log'}")
    if row["type"] == "spawn":
        record_metric(resolved.path, "spawn_cli_ms", round((time.perf_counter() - t0) * 1000, 3))
        maybe_detached_sweep(resolved.path)
        print(row["spawn_id"])
    return 0


def _liveness_from_file(path: Optional[str]) -> Liveness:
    if not path:
        return None
    mapping = json.loads(Path(path).read_text(encoding="utf-8"))
    return lambda sid: mapping.get(sid)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="spawn_registry.py", description=__doc__.splitlines()[0])
    ap.add_argument("--root", help="project root anchor (default: $CLAUDE_PROJECT_DIR, then this file's checkout)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("spawn")
    sp.add_argument("--spawner", required=True)
    sp.add_argument("--name", required=True)
    sp.add_argument("--kind", default="claude")
    sp.add_argument("--pane-id")
    sp.add_argument("--workspace-id")
    sp.add_argument("--parent-session-id")
    sp.add_argument("--parent-name")
    sp.add_argument("--loop-id")
    sp.add_argument("--iteration", type=int)
    sp.add_argument("--prev-spawn-id")
    sp.add_argument("--spawn-id")
    bp = sub.add_parser("bind")
    bp.add_argument("--spawn-id", required=True)
    bp.add_argument("--session-id", required=True)
    bp.add_argument("--source", default="startup")
    ep = sub.add_parser("end")
    ep.add_argument("--spawn-id", required=True)
    ep.add_argument("--session-id")
    ep.add_argument("--reason")
    tp = sub.add_parser("tree")
    tp.add_argument("--json", action="store_true")
    tp.add_argument("--liveness-file", help='JSON {"<session_id>": "running|idle|needs-you"}; absent = gone')
    rp = sub.add_parser("resolve")
    rp.add_argument("--json", action="store_true")
    swp = sub.add_parser("sweep")
    swp.add_argument("--quiet", action="store_true")
    stp = sub.add_parser("status")
    stp.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    if args.cmd == "spawn":
        env = os.environ
        psid = args.parent_session_id
        if not psid and not args.parent_name:
            psid = env.get("CLAUDE_CODE_SESSION_ID")
        loop = ({"loop_id": args.loop_id, "iteration": args.iteration, "prev_spawn_id": args.prev_spawn_id}
                if args.loop_id else None)
        return _cmd_write(args, lambda: spawn_row(
            args.spawner, {"session_id": psid, "name": args.parent_name},
            {"name": args.name, "kind": args.kind, "pane_id": args.pane_id, "workspace_id": args.workspace_id},
            loop, args.spawn_id))
    if args.cmd == "bind":
        return _cmd_write(args, lambda: bind_row(args.spawn_id, args.session_id, args.source))
    if args.cmd == "end":
        return _cmd_write(args, lambda: end_row(args.spawn_id, args.session_id, args.reason))

    try:
        resolved = resolve_registry_dir(root=args.root)
    except RegistryConfigError as exc:
        return _fail(str(exc), 2)
    if args.cmd == "resolve":
        print(json.dumps(resolved.as_dict()) if args.json else f"{resolved.path}  (source: {resolved.source})")
        return 0
    if args.cmd == "sweep":
        try:
            res = sweep(resolved.path)
        except OSError as exc:
            return _sweep_failed(resolved.path, f"sweep failed: {exc}")
        if not res["locked"]:
            return _sweep_failed(resolved.path, "sweep skipped: could not acquire .rotate.lock within timeout")
        if not args.quiet:
            print(json.dumps(res))
        return 0
    if args.cmd == "status":
        st = collect_status(resolved.path)
        st["source"] = resolved.source
        print(json.dumps(st, indent=2) if args.json else
              "\n".join(f"{k}: {v}" for k, v in st.items()))
        return 0
    if args.cmd == "tree":
        try:
            live = _liveness_from_file(args.liveness_file)
        except (OSError, ValueError) as exc:
            return _fail(f"bad --liveness-file: {exc}", 2)
        events, skipped = read_all(resolved.path)
        tree = build_tree(events, live)
        tree["skipped_rows"] = skipped + tree["malformed_events"]
        print(json.dumps(tree) if args.json else render_tree(tree))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
