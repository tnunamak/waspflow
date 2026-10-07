# waspflow

Waspflow runs coding-agent work in durable tmux lanes. Start a worker, inspect it, steer it, wait for a terminal turn, and deliberately reap its saved artifacts.

**Status: maintenance mode — bug fixes only.** Report bugs in [GitHub Issues](https://github.com/tnunamak/waspflow/issues).

## Quickstart

```bash
git clone https://github.com/tnunamak/waspflow /path/to/waspflow
cd /path/to/waspflow && ./install.sh
export PATH="$HOME/.local/bin:$PATH" # or the directory printed by install.sh
waspflow doctor
waspflow demo --provider codex --run
```

Replace `codex` with an installed provider, such as `claude`, `grok`, or `antigravity` (`agy`). `install.sh` creates a symlink in `$HOME/.local/bin` unless `WASPFLOW_INSTALL_BIN` is set.

## What a lane contains

A lane keeps its prompt, transcript, session details, final git capture, and state under `$WASPFLOW_HOME` (default: `~/.local/state/waspflow`). It is useful when a worker needs follow-up instructions or you need to recover its state after closing a terminal.

```bash
waspflow spawn --provider codex --accept-provider-default --lane fix -- \
  "Find and fix the failing test."
waspflow wait fix
waspflow revise fix -- "Add a regression test."
waspflow wait fix --reap
```

Use `waspflow exec` for a headless, one-shot task that does not create a lane:

```bash
waspflow exec --provider claude --accept-provider-default -- \
  "Summarize the public functions in lib/core.sh."
```

## Provider support matrix

`supported` means the adapter implements the command. `partial` means it works but has an important evidence limit.

| Provider | spawn | wait (completion detection) | revise (steer) | reap | exec |
|---|---|---|---|---|---|
| Claude | supported | supported | supported | supported | supported |
| Codex | supported | partial — rollout correlation risk | supported | supported | supported |
| Grok | supported | partial — weaker completion evidence | partial — weaker submission evidence | supported | supported |
| Antigravity (`agy`) | partial — receipt-based submission | partial — receipt-based completion | partial — headless revise only | supported | supported |
| Qwen | supported | supported | supported | supported | supported |
| DeepSeek (`dsh`) | supported | supported | partial — headless revise unsupported | supported | supported |

Claude has the strongest completion detection: Waspflow waits for terminal turn events and vetoes completion while known child or background-shell work remains active. Codex correlates rollout events with the lane’s turn; very new Codex versions can still drift from that event shape. Grok and Antigravity deliberately fail closed when submission or completion evidence is insufficient.

On first Codex use, resolve any update banner or trust prompt in the pane yourself, then run the command again. Waspflow refuses to paste into an unresolved startup menu because an Enter could select an unsafe menu item instead of submitting your task.

## Requirements

Required tools are `tmux`, `jq`, `awk`, `python3`, `git`, and `flock`, plus at least one provider CLI. `waspflow doctor` checks these before you start. See [prerequisites](docs/prerequisites.md) for installation notes.

Providers map to executables as follows: `claude`, `codex`, `grok`, `antigravity` → `agy`, `qwen`, and `deepseek` → `dsh`.

## Common commands

| Command | Purpose |
|---|---|
| `spawn --provider … --lane NAME -- TASK` | Start a durable lane. |
| `wait NAME [--reap]` | Poll until a terminal turn; optionally reap it. |
| `peek NAME` | Inspect the tmux pane for diagnosis. |
| `status NAME` / `list` | Inspect saved lane state. |
| `revise NAME -- MESSAGE` | Send a follow-up instruction. |
| `reap NAME` | Finalize a terminal lane. |
| `reconcile --json` | Read-only fleet recovery inventory. |
| `doctor` | Check dependencies and fleet warnings. |

Use `--isolate` on `spawn` when workers should get separate Git worktrees. `--report PATH` requires a non-empty report before normal reaping succeeds. See `waspflow help` for the complete option reference.

## Known limitations

- Lanes keep running if the spawning agent dies, but Waspflow cannot push completion into a new session. Use `waspflow list`, `status`, or `wait`; use `waspflow reconcile --json` and `doctor` to investigate uncertain or orphaned state.
- There is no completion callback: `wait` polls provider logs.
- Worktree isolation is **not an OS sandbox**. Lanes run provider CLIs with permissive provider modes; only run tasks you trust.
- Waspflow uses `systemd-run --user --scope` for scope tracking when available. Without it, it warns and continues with tmux-only supervision; lifecycle state can remain unknown and cleanup has less process-tree evidence.
- Set `WASPFLOW_TMUX_SOCKET=name` to make every Waspflow tmux call use `tmux -L name` instead of your default tmux server. Export it in every shell that manages those lanes; a new shell without it looks at the default server and will not see them.
- `revise` on Codex can report "not confirmed submitted" even though the message was applied. Run `waspflow peek NAME` before sending it again.
- Codex lanes use whichever `codex` the lane's login shell resolves, which can differ from the one in your current shell. If a stale copy shows an update prompt, update or remove the older install.
- `reap` refuses a live lane that the provider does not report as idle unless you pass `--force`.
- Legacy tmux windows without Waspflow ownership tags are not adopted automatically; explicit legacy adoption is required for parking.
- Provider CLIs change their TUIs and event formats. Live behavior can drift; stalled waits should be diagnosed with `waspflow peek`.
- Billing has no guarantee. Subscription versus API billing depends on the provider’s active authentication; read `waspflow doctor` before a large run.

## Security and operations

Use a dedicated tmux socket when you do not want Waspflow windows on your normal server:

```bash
export WASPFLOW_TMUX_SOCKET=waspflow
waspflow doctor
```

The default state directory holds prompts and transcripts. Treat it as sensitive local data. `WASPFLOW_HOME` changes where that state is stored.

## More documentation

- [Full reference](docs/reference.md) (selection gates, worktrees, reports, environment variables, wait internals)
- [First run](docs/first-run.md)
- [Prerequisites](docs/prerequisites.md)
- [Project checks](docs/project-checks.md)
- [MCP behavior](docs/mcp.md)

## Verify

```bash
scripts/verify.sh
```

## License

Apache-2.0. See [LICENSE](LICENSE).
