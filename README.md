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
| `spawn --provider <p> --lane <n> [--model M] [--effort E] [--cwd D] [--isolate] [--report F] [--no-recovery] [--arg X]… -- <task>` | Launch an agent into a tmux window |
| `list` | All lanes + live/exited/reaped status |
| `status <lane>` | One lane's full state (JSON) |
| `peek <lane> [--lines N]` | De-escaped tail of the live pane (or transcript if exited) |
| `wait <lane> [--timeout S] [--interval S]` | Block until the agent is idle |
| `revise <lane> [--out FILE] -- <message>` | Steer the live pane, or resume the session headlessly if the window exited |
| `attach <lane>` | Attach your terminal to the pane (Ctrl-b d to detach) |
| `reap <lane> [--force] [--keep-worktree]` | Finalize the lane (verify deliverable, capture diff), kill the window, clean up |
| `check [--cwd DIR] [--config FILE] [--no-fail]` | Run the project integrity gate: git/worktrees/lanes plus optional project checks |
| `doctor` | Check deps + backends |

Spawn flags worth knowing:
- `--effort <low\|medium\|high\|xhigh\|max>` — reasoning effort. Maps to `claude --effort` and Codex `model_reasoning_effort` (Codex has no xhigh/max → clamped to high).
- `--report <path>` — a **deliverable contract** (see below). Without it, finishing the turn cleanly is success.
- `--no-recovery` — disable the one recovery pass for a missing report.

## Durable artifacts (automatic — no flags)

Every lane writes, into `$WASPFLOW_HOME/lanes/<lane>/`:
`prompt.txt`, `git-status-before.txt`, `git-status-after.txt`, `git-diff.txt` (stat + patch),
`transcript.log`, and `state.json`. The git captures answer *"what did this agent actually
change?"* with zero setup. (Git captures are skipped, not errored, when the cwd isn't a repo.)

## Deliverable contract + honest results

Pass `--report <path>` and waspflow holds the agent to producing that file:

- On `reap` (the explicit end-of-run), waspflow verifies the report exists and is substantial
  (≥ `WASPFLOW_REPORT_MIN_BYTES`, default 200 — guards against stub/panic reports).
- If it's missing, **one recovery pass** runs: the session is resumed headlessly with write
  access, asked to reconstruct the report from the transcript + git diff, and explicitly told
  to report `INCOMPLETE` rather than fabricate completion when the evidence doesn't support it.
- The lane's `result` is then one of: `succeeded` · `recovered` · `report_missing`
  (recovery disabled) · `failed`. `reap` exits **nonzero** on `failed`/`report_missing`, so a
  caller or CI can key on it. Without a `--report` contract, `result` is `succeeded` once the
  agent finished its turn.

This is the "don't silently lose a worker's output" guarantee — you always get either the
deliverable or an honest failure, never a false green.

## Project integrity gate

Live worker control is only half of orchestration. The other half is not losing
repo/process state while delegating. `waspflow check` is the generic safety gate:

- current git worktree dirty/ahead state;
- every git worktree for the repo;
- waspflow lanes associated with the project, including unreaped exited lanes
  and failed deliverable contracts;
- optional project-defined mutex, blocker, report, and command checks from
  `.waspflow/config.json` or `.waspflow.json`.

With no config, it still works as a generic git + lane inventory:

```bash
waspflow check
waspflow check --no-fail   # readable snapshot without failing the caller
```

A project can add its own local process rules without forking waspflow:

```json
{
  "lanes": { "stale_seconds": 14400 },
  "mutexes": [
    {
      "name": "live-stack",
      "file": "tmp/workstreams/current-state.md",
      "open_pattern": "^- Status: OPEN"
    }
  ],
  "blockers": { "globs": [".git/workstreams/blockers/*"] },
  "reports": { "globs": ["tmp/workstreams/*.md"], "limit": 10 },
  "commands": [
    {
      "name": "OpenSpec status",
      "command": "node scripts/openspec-status.mjs",
      "severity": "warn"
    }
  ]
}
```

This is the intended migration path for bespoke project scripts: keep the
project-specific policy in the project config, keep the implementation in
waspflow.

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
- The Codex model-proxy health check is `$WASPFLOW_CODEX_BACKEND_HEALTH_URL`
  (default empty = no check). If your Codex is configured to route through a
  local proxy, set this to that proxy's health URL so waspflow refuses to spawn a
  Codex lane while the proxy is down (a turn would otherwise hang). Leave empty
  when Codex reaches its model directly.
- All tmux windows live in a dedicated session (`$WASPFLOW_TMUX_SESSION`, default
  `waspflow`) so the user's own tmux is never disturbed.

## Environment knobs

| Var | Default | Purpose |
|---|---|---|
| `WASPFLOW_HOME` | `~/.local/state/waspflow` | Lane state + transcripts |
| `WASPFLOW_TMUX_SESSION` | `waspflow` | tmux session holding all windows |
| `WASPFLOW_CODEX_BACKEND_HEALTH_URL` | _(empty)_ | If set, preflight this URL before spawning Codex (for setups where Codex routes through a local model proxy) |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | Where Claude writes session JSONL |
| `CODEX_SESSIONS_DIR` | `~/.codex/sessions` | Where Codex writes rollout JSONL |

## Architecture

One engine, multiple faces:

- **Engine** — `lib/core.sh` (state store, tmux helpers, dispatch) + provider
  adapters `lib/providers/{claude,codex}.sh` (each: `*_spawn`, `*_is_idle`,
  `*_revise`, `*_preflight`, `*_discover_session`) + `lib/worktree.sh` +
  `lib/project.sh` (generic repo/process integrity checks).
- **CLI** — `bin/waspflow`, a thin verb router over the engine.
- **Skill** — `skill/SKILL.md`, teaches an orchestrating agent the workflow.
- **MCP** — a future adapter over the same engine (see `docs/mcp.md`).

Adding a provider = adding one `lib/providers/<name>.sh` implementing the five
contract functions. Nothing else changes.

## Status

Verified end-to-end (2026-06-15) for both providers: spawn → wait → live-revise →
wait → reap → headless-resume, with real agent output. See `docs/spike.md` for
the empirical findings and provider-specific gotchas.
