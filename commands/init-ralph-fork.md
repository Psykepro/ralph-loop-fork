---
description: Check and install all ralph-loop-fork dependencies (jq, tmux, xxd, git ≥ 2.5, claude CLI)
argument-hint: "[--check-only]"
---

Check that all required dependencies for ralph-loop-fork are installed, and attempt to auto-install any that are missing.

```bash
"${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/scripts/init-ralph-loop-fork.sh" $ARGUMENTS
```

**What it checks:**

| Dependency | Required | Notes |
|---|---|---|
| `jq` | Always | JSON state management |
| `tmux` | Always | Session forking |
| `xxd` | Always | Loop ID generation |
| `git ≥ 2.5` | `--worktree` mode | Worktree subcommand |
| `claude` CLI | `--worktree` mode | Launched inside worktree |
| `uuidgen` | Optional | Falls back to `/dev/urandom` |

**Flags:**
- `--check-only` — report status without installing anything

**Auto-install support:** Homebrew (macOS), apt-get (Debian/Ubuntu), pacman (Arch). On other systems the script prints the manual install hint.

Run this once after installing the plugin, or any time a setup error mentions a missing dependency.
