# waspflow

Turnkey live orchestration of coding agents (Claude Code, OpenAI Codex) in tmux.

An orchestrating session — itself a Claude or Codex agent, working in **any**
project directory — uses `waspflow` to **spawn** a worker agent of either
provider into a tmux window, **watch** it stream, **steer/revise** it live or
after teardown, **wait** for it to go idle, and **reap** it. Lane state lives on
disk, so the workflow survives the orchestrator's own compaction/restart: the
windows persist and the orchestrator recovers what it spawned from
`waspflow list`.

This is *control*, not fire-and-forget: you can attach mid-run, inject a
revision, resume a session after killing its window, and reap — for agents of
either provider, behind one CLI.

## Why

Delegating to a sub-agent via a one-shot `--print` call or an MCP tool gives you
the *result* but not the *process*: you can't see it think, can't course-correct
mid-run, can't ask for one more revision before it tears down. waspflow keeps the
worker live in a tmux pane you (or your orchestrating agent) can observe and
drive, while still exposing a clean scriptable surface.

## Install

```bash
git clone <this-repo> ~/code/waspflow
~/code/waspflow/install.sh        # symlinks bin/waspflow into ~/.local/bin
waspflow doctor                   # check deps + backends
```

Requires: `tmux`, `jq`, `git`, and at least one of `claude` / `codex` on PATH.

## Quickstart

```bash
# From ANY project directory:
waspflow spawn --provider codex --lane fixbug -- "Find and fix the off-by-one in src/pager.ts"
waspflow peek  fixbug                  # de-escaped tail of the live pane
waspflow wait  fixbug                  # block until the agent goes idle
waspflow revise fixbug -- "Also add a regression test"   # steer live
waspflow wait  fixbug
waspflow reap  fixbug                  # kill the window (state retained)
```

Swap `--provider codex` for `--provider claude` — same verbs, same flow.

### Worktree isolation (parallel fleets)

```bash
waspflow spawn --provider claude --lane a --isolate -- "Refactor module A"
waspflow spawn --provider codex  --lane b --isolate -- "Refactor module B"
```

`--isolate` gives each lane its own git worktree (branch `waspflow/<lane>`) so
parallel agents can't stomp on each other's files. `reap` removes the worktree
only if it's clean (use `--force` to discard, `--keep-worktree` to keep).

## Commands

| Command | What it does |
|---|---|
| `spawn --provider <p> --lane <n> [--model M] [--cwd D] [--isolate] [--arg X]… -- <task>` | Launch an agent into a tmux window |
| `list` | All lanes + live/exited/reaped status |
| `status <lane>` | One lane's full state (JSON) |
| `peek <lane> [--lines N]` | De-escaped tail of the live pane (or transcript if exited) |
| `wait <lane> [--timeout S] [--interval S]` | Block until the agent is idle |
| `revise <lane> [--out FILE] -- <message>` | Steer the live pane, or resume the session headlessly if the window exited |
| `attach <lane>` | Attach your terminal to the pane (Ctrl-b d to detach) |
| `reap <lane> [--force] [--keep-worktree]` | Kill the window + clean up |
| `doctor` | Check deps + backends |

## How idle is detected (no screen-scraping)

waspflow never guesses from prompt glyphs. It reads each provider's own session
log:

- **Claude** — `~/.claude/projects/<slug>/<session-id>.jsonl`; idle = the last
  `assistant` event has `stop_reason: "end_turn"`. The session id is minted by
  waspflow and passed via `--session-id`, so the path is deterministic.
- **Codex** — `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`; idle =
  the last event is `task_complete`. The session is matched to a lane by the
  `cwd` recorded in the rollout's `session_meta` line (never by mtime — a
  background collector can re-touch old files).

## Revise / resume mechanics

- **Window still live** → `revise` types the message into the pane and submits,
  then verifies the turn actually started (the session log grows), retrying the
  Enter if it raced startup/hook output.
- **Window exited** → `revise` resumes the session headlessly and returns the
  reply (to `--out FILE` if given):
  - Claude: `claude --resume <session-id> --print "<msg>"`
  - Codex: `codex exec resume <session-id> "<msg>" -o <file>`

Both retain full conversation context across teardown.

## Portability

waspflow is built to move to another machine/user as a config swap, not a
rewrite:

- No hardcoded project paths; runs from any cwd.
- State lives under `$WASPFLOW_HOME` (default `~/.local/state/waspflow`).
- The Codex model backend health check is `$WASPFLOW_CODEX_BACKEND_HEALTH_URL`
  (default `http://127.0.0.1:8787/health`, the local **headroom** proxy). Set it
  empty to skip the check when Codex talks to a model directly, or point it at a
  different backend.
- All tmux windows live in a dedicated session (`$WASPFLOW_TMUX_SESSION`, default
  `waspflow`) so the user's own tmux is never disturbed.

## Environment knobs

| Var | Default | Purpose |
|---|---|---|
| `WASPFLOW_HOME` | `~/.local/state/waspflow` | Lane state + transcripts |
| `WASPFLOW_TMUX_SESSION` | `waspflow` | tmux session holding all windows |
| `WASPFLOW_CODEX_BACKEND_HEALTH_URL` | `http://127.0.0.1:8787/health` | Codex backend preflight (empty = skip) |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | Where Claude writes session JSONL |
| `CODEX_SESSIONS_DIR` | `~/.codex/sessions` | Where Codex writes rollout JSONL |

## Architecture

One engine, multiple faces:

- **Engine** — `lib/core.sh` (state store, tmux helpers, dispatch) + provider
  adapters `lib/providers/{claude,codex}.sh` (each: `*_spawn`, `*_is_idle`,
  `*_revise`, `*_preflight`, `*_discover_session`) + `lib/worktree.sh`.
- **CLI** — `bin/waspflow`, a thin verb router over the engine.
- **Skill** — `skill/SKILL.md`, teaches an orchestrating agent the workflow.
- **MCP** — a future adapter over the same engine (see `docs/mcp.md`).

Adding a provider = adding one `lib/providers/<name>.sh` implementing the five
contract functions. Nothing else changes.

## Status

Verified end-to-end (2026-06-15) for both providers: spawn → wait → live-revise →
wait → reap → headless-resume, with real agent output. See `docs/spike.md` for
the empirical findings and provider-specific gotchas.
