---
name: waspflow-orchestrate
description: >-
  Spawn, watch, steer, and reap Claude/Codex coding agents live in tmux from any
  project directory. Use when you (an agent) need to delegate work to a worker
  agent of either provider AND retain live control — observe it stream, inject a
  revision mid-run or after teardown, wait for idle, and clean up — rather than a
  one-shot fire-and-forget call. Survives your own compaction (lanes persist on disk).
---

# waspflow — live cross-provider agent orchestration

You are an orchestrating agent. `waspflow` lets you run **worker** agents
(Claude Code or OpenAI Codex) in tmux windows you can watch and steer, then reap.
Lane state is on disk, so if you compact mid-task you recover everything with
`waspflow list`.

## When to use this

- You want to delegate a sub-task to an agent **and** keep the ability to course-
  correct it live (not just take a single result).
- You want to run **several** workers in parallel (optionally isolated in their
  own git worktrees) and collect results as each goes idle.
- You're resuming after a compaction and need to find/continue agents you spawned.

Do **not** use it for trivial work you can just do yourself, or when a single
`--print`/one-shot call is genuinely enough.

## Preflight (once)

```bash
waspflow doctor
```

Green = ready. If it warns the **Codex backend** is down and you intend to spawn
Codex, that backend must be up first (on this machine: `headroom proxy`). Claude
needs no backend gate. If `waspflow` isn't on PATH, run the repo's `install.sh`.

## The core loop

```bash
# 1. Spawn a worker. Pick provider + a short lane name. Task goes after `--`.
waspflow spawn --provider codex --lane parser -- "Fix the off-by-one in src/pager.ts and add a test"

# 2. Watch it (optional — wait usually suffices).
waspflow peek parser            # de-escaped tail of the live pane

# 3. Block until it finishes its turn.
waspflow wait parser --timeout 600

# 4. Inspect the result (peek the pane, or read the files it changed).
waspflow peek parser --lines 60

# 5. Revise if needed — this is the whole point. Steers the LIVE session.
waspflow revise parser -- "Good. Now also handle the empty-input case."
waspflow wait parser

# 6. Reap when done.
waspflow reap parser
```

## Choosing provider / model / lane

- `--provider claude` or `--provider codex`.
- `--model <id>` to override (e.g. a specific Claude or gpt model). Omit to use
  the provider's default.
- `--lane <name>` is your handle for every later command — keep it short and
  unique (letters/digits/`.`/`_`/`-`).
- `--arg <x>` (repeatable) passes an extra flag straight to the underlying agent
  CLI when you need provider-specific behavior.

## Running a fleet (parallel, isolated)

```bash
waspflow spawn --provider claude --lane a --isolate -- "Refactor module A"
waspflow spawn --provider codex  --lane b --isolate -- "Refactor module B"
# poll each:
for L in a b; do waspflow wait "$L" && waspflow peek "$L" --lines 40; done
for L in a b; do waspflow reap "$L"; done
```

`--isolate` puts each agent in its own git worktree (branch `waspflow/<lane>`) so
they don't collide. `reap` keeps a dirty worktree unless you pass `--force`.

## Recovering after YOUR OWN compaction

The lanes outlive your context. To pick back up:

```bash
waspflow list                   # every lane + live/exited/reaped
waspflow status <lane>          # full JSON: provider, session_id, cwd, prompt
waspflow peek <lane>            # what it's doing / last said
```

If a window already exited, `revise` resumes the session **headlessly** and
returns the reply — use `--out <file>` to capture it:

```bash
waspflow revise <lane> --out /tmp/reply.txt -- "Summarize what you changed."
```

## Idle is detected from the agent's own logs (trust `wait`)

You don't need to read panes to know when an agent is done — `wait` reads the
provider's session log (Claude `stop_reason: end_turn`; Codex `task_complete`).
Prefer `wait` over polling `peek`.

## Etiquette

- Reap lanes you're done with; state is retained after reap for inspection, so
  reaping is safe.
- One live lane per name. Reap before reusing a lane name.
- `attach <lane>` drops your terminal into the pane (Ctrl-b d to detach) — handy
  for a human, rarely needed by an agent.

## Full command reference

`spawn · list · status · peek · wait · revise · attach · reap · doctor` — run
`waspflow help` or see the repo README.
