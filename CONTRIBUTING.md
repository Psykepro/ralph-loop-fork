# Contributing to ralph-loop-fork

Thanks for your interest in improving this plugin. The notes below should be
enough to get you started.

## Running the tests

The repo has bash-based tests under `tests/`. Run them directly:

```bash
bash tests/test-state-tracking.sh
bash tests/test-stop-hook-states.sh
```

Both tests are self-contained and create their fixtures in temporary
directories. They require `bash`, `jq`, and `tmux`.

## Reporting bugs

Open an issue with:

- What you ran (full command line).
- What you expected.
- What you got, including any output from `/tmp/ralph-fork-logs/` (or the
  directory you set via `RALPH_FORK_LOG_DIR`).
- Your platform (`uname -a`, `bash --version`, `tmux -V`, `jq --version`).

## Pull requests

A good PR:

- Has a clear description of the problem it solves.
- Touches the smallest set of files that solves it.
- Includes a test (or a clear explanation of why one isn't practical).
- Passes `bash -n` on every shell script it modifies.
- Keeps the plugin portable: scripts should run on macOS, Linux, and WSL2.
  Avoid GNU-only or BSD-only flags. When you must branch, detect the tool
  (e.g. `command -v md5sum` vs `md5 -q`).

## Conventions

- Shell scripts use `#!/bin/bash` and `set -uo pipefail` (or `-euo pipefail`
  where appropriate).
- Informational output goes to stderr; only JSON for hook responses goes to
  stdout.
- Debug logs go to `${RALPH_FORK_LOG_DIR:-/tmp/ralph-fork-logs}`.
