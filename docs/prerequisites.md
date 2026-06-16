# Prerequisites

Waspflow is a small shell tool around standard developer CLI programs. It does
not install system packages for you, because package-manager choices vary by
OS, but `waspflow doctor` tells you exactly what is missing.

## Required

- `tmux` — terminal multiplexer that keeps worker panes alive after your shell
  disconnects.
  Docs: https://github.com/tmux/tmux/wiki
  Install guide: https://github.com/tmux/tmux/wiki/Installing

- `jq` — JSON processor used for lane state and session-log inspection.
  Download: https://jqlang.org/download/

- `git` — used for project detection, worktree isolation, and diff capture.
  Downloads: https://git-scm.com/downloads

- `curl` — used by `doctor` and optional backend health checks.
  Project: https://curl.se/

- `uuidgen` or `/proc/sys/kernel/random/uuid` — used to mint Claude session ids.
  On most Linux/macOS systems this is already installed.

## At least one agent CLI

- OpenAI Codex CLI.
  Docs: https://developers.openai.com/codex/cli/features
  Reference: https://developers.openai.com/codex/cli/reference

- Claude Code.
  Quickstart: https://code.claude.com/docs/en/quickstart

## Verify

```bash
waspflow doctor
```

If all required tools are present and at least one agent CLI is on `PATH`, run:

```bash
waspflow demo --provider codex
waspflow demo --provider codex --run
```

Swap `codex` for `claude` if Claude Code is the agent CLI you have installed.
