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

- `flock` — required to serialize spawn/revise/park/reap transitions so a
  newly-started turn cannot race cleanup. It ships with util-linux on Linux;
  on macOS install a compatible `flock` command before using waspflow.

- `curl` — used by `doctor` and optional backend health checks.
  Project: https://curl.se/

- `uuidgen` or `/proc/sys/kernel/random/uuid` — used to mint Claude/Grok session
  ids. On most Linux/macOS systems this is already installed.

## At least one agent CLI

- OpenAI Codex CLI.
  Docs: https://developers.openai.com/codex/cli/features
  Reference: https://developers.openai.com/codex/cli/reference

- Claude Code.
  Quickstart: https://code.claude.com/docs/en/quickstart

- Grok Build CLI (`grok`).
  Installs to `~/.grok/bin/grok` by default; ensure that directory is on `PATH`.

## Verify

```bash
waspflow doctor
```

If all required tools are present and at least one agent CLI is on `PATH`, run:

```bash
waspflow demo --provider codex
waspflow demo --provider codex --run
```

Swap `codex` for `claude` or `grok` if that is the agent CLI you have installed.
