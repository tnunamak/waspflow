# Prerequisites

Waspflow is a shell tool. It does not install system packages because package managers differ across Linux and macOS. Run `waspflow doctor` after installation to see the exact missing dependencies.

## Required tools

- `tmux` — keeps lane panes alive after the launching shell disconnects.
- `jq` — reads JSON lane state and provider events.
- `awk`, `python3`, and `git` — used by the CLI and artifact capture.
- `timeout` — bounds cleanup and transcript inspection.
- `perl` — strips terminal control sequences from saved transcripts.
- `flock` — serializes lane state transitions. It is supplied by util-linux on most Linux systems; macOS needs a compatible `flock` command.
- `uuidgen`, or Linux `/proc/sys/kernel/random/uuid` — creates supported provider session IDs.

## One provider CLI

Install at least one of these and make it available on `PATH`:

| Waspflow provider | Executable |
|---|---|
| Claude | `claude` |
| Codex | `codex` |
| Grok | `grok` |
| Antigravity | `agy` |
| Qwen | `qwen` |
| DeepSeek | `dsh` |

After `./install.sh`, add `$HOME/.local/bin` to `PATH` unless the installer printed a different directory. For example:

```bash
export PATH="$HOME/.local/bin:$PATH"
waspflow doctor
```

The installer uses `WASPFLOW_INSTALL_BIN` when set, so use that printed directory instead of assuming the default.

## First Codex launch

Codex may show an update or trust prompt before its composer is ready. Resolve it in the tmux pane, then rerun the Waspflow command. Waspflow refuses to inject a task into that unresolved menu because it could activate its selected action.

## Verify

```bash
waspflow doctor
waspflow demo --provider codex
waspflow demo --provider codex --run
```

Replace `codex` with any installed provider. Antigravity uses `agy`.
