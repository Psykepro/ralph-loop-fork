#!/usr/bin/env python3
"""Pin every installed ralph-loop-fork plugin to the live repo (this checkout).

Claude Code installs marketplace plugins by COPYING them into
~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/. Those copies go
stale the moment the live repo changes, and a version bump moves the install
path so even a cache symlink breaks.

This script makes every install resolve to the live repo, for any version:
  1. Reads the live version from .claude-plugin/plugin.json (this repo).
  2. For every "ralph-loop-fork@<marketplace>" entry in
     ~/.claude/plugins/installed_plugins.json: rewrites version, installPath
     (-> cache/<marketplace>/ralph-loop-fork/<live-version>) and gitCommitSha.
  3. Replaces each cache version dir with a symlink to the live repo and
     removes stale sibling version dirs/symlinks.

Idempotent — safe to re-run any time. Run it after every version bump:
    python3 scripts/sync-live-install.py

If Claude Code's /plugin update ever rewrites installed_plugins.json or
re-copies the cache, just re-run this script.
"""

import json
import shutil
import subprocess
import sys
from pathlib import Path

PLUGIN_NAME = "ralph-loop-fork"
LIVE_REPO = Path(__file__).resolve().parent.parent
PLUGINS_DIR = Path.home() / ".claude" / "plugins"
INSTALLED_JSON = PLUGINS_DIR / "installed_plugins.json"
CACHE_DIR = PLUGINS_DIR / "cache"


def fail(msg: str) -> None:
    print(f"❌ ERROR: {msg}\n   Nothing was changed.", file=sys.stderr)
    sys.exit(1)


def live_version() -> str:
    manifest = LIVE_REPO / ".claude-plugin" / "plugin.json"
    if not manifest.is_file():
        fail(f"plugin manifest not found: {manifest}")
    version = json.loads(manifest.read_text()).get("version")
    if not version:
        fail(f"no 'version' field in {manifest}")
    return version


def live_sha() -> str:
    try:
        return subprocess.run(
            ["git", "-C", str(LIVE_REPO), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as exc:
        fail(f"git rev-parse failed in {LIVE_REPO}: {exc.stderr.strip()}")
        raise  # unreachable; keeps type-checkers happy


def ensure_symlink(version_dir: Path) -> str:
    """Make version_dir a symlink to LIVE_REPO; prune stale siblings."""
    plugin_dir = version_dir.parent
    plugin_dir.mkdir(parents=True, exist_ok=True)

    for sibling in plugin_dir.iterdir():
        if sibling != version_dir:
            shutil.rmtree(sibling, ignore_errors=True) if sibling.is_dir() and not sibling.is_symlink() else sibling.unlink(missing_ok=True)

    if version_dir.is_symlink():
        if version_dir.resolve() == LIVE_REPO:
            return "already linked"
        version_dir.unlink()
    elif version_dir.exists():
        shutil.rmtree(version_dir)
    version_dir.symlink_to(LIVE_REPO)
    return "linked"


def main() -> None:
    version = live_version()
    sha = live_sha()

    if not INSTALLED_JSON.is_file():
        fail(f"not found: {INSTALLED_JSON}")
    registry = json.loads(INSTALLED_JSON.read_text())
    plugins = registry.get("plugins", {})

    targets = {k: v for k, v in plugins.items() if k.split("@", 1)[0] == PLUGIN_NAME}
    if not targets:
        fail(f"no '{PLUGIN_NAME}@*' entries in {INSTALLED_JSON}")

    changed = False
    for key, installs in targets.items():
        marketplace = key.split("@", 1)[1]
        version_dir = CACHE_DIR / marketplace / PLUGIN_NAME / version
        link_state = ensure_symlink(version_dir)
        for install in installs:
            before = (install.get("version"), install.get("installPath"), install.get("gitCommitSha"))
            install["version"] = version
            install["installPath"] = str(version_dir)
            install["gitCommitSha"] = sha
            after = (install["version"], install["installPath"], install["gitCommitSha"])
            scope = install.get("scope", "?")
            where = install.get("projectPath", "(all projects)")
            if before != after:
                changed = True
                print(f"✅ {key} [{scope}] {where} -> v{version} ({link_state})")
            else:
                print(f"✅ {key} [{scope}] {where} already pinned to v{version} ({link_state})")

    if changed:
        INSTALLED_JSON.write_text(json.dumps(registry, indent=2) + "\n")
        print(f"✅ updated {INSTALLED_JSON}")
    else:
        print("✅ registry already up to date — no write needed")

    print(f"\n✅ All {PLUGIN_NAME} installs now resolve to: {LIVE_REPO} (v{version}, {sha[:7]})")
    print("   Reminder: bump .claude-plugin/plugin.json version on every change, then re-run this script.")


if __name__ == "__main__":
    main()
