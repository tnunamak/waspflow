---
name: waspflow-orchestrate
description: >-
  Spawn, watch, steer, and reap Claude/Codex/Grok coding-agent workers live in
  tmux from any project dir. Use when you (an agent) delegate a sub-task AND want
  live control — stream it, revise mid-run or after teardown, wait for idle,
  reap. Lanes persist on disk, so you survive your own compaction.
---

# waspflow — live cross-provider agent orchestration

You are an orchestrating agent. `waspflow` runs **worker** agents (Claude Code,
Codex, or Grok) in tmux windows you watch and steer, then reap. Lane state is on
disk: if you compact mid-task, `waspflow list` recovers everything.

Use it to delegate a sub-task while keeping the ability to **course-correct it
live**, or to run **several** workers in parallel (optionally in isolated git
worktrees), collecting results as each goes idle. Skip it for trivial work you can
do yourself, or when a single `exec` one-shot suffices.

## Preflight (once)

```bash
waspflow doctor          # deps + backends + active auth path
waspflow check --no-fail # repo/process gate: worktrees, dirty state, lanes, project checks
```

If `doctor` warns the **Codex model proxy** is down (only when
`WASPFLOW_CODEX_BACKEND_HEALTH_URL` is set), start it before spawning Codex;
Claude and Grok need no backend gate. First-time user: `waspflow demo --provider
codex [--run]`. Serious repo needing policy: `waspflow init --profile serious-repo`.

## The core loop

```bash
waspflow spawn --provider codex --lane parser -- "Fix the off-by-one in src/pager.ts and add a test"
waspflow wait parser --timeout 600        # block until it finishes its turn (see "trust wait" below)
waspflow peek parser --lines 60           # de-escaped tail of the pane; or just read the changed files
waspflow revise parser -- "Good. Now also handle the empty-input case."   # steers the LIVE session
waspflow wait parser
waspflow reap parser
```

`--lane <name>` is your handle for every later command (letters/digits/`.`/`_`/`-`,
short + unique). `status <lane>` returns full JSON (provider, session_id, cwd,
prompt, result).

## Choosing provider / model / effort

Raw flags are canonical: `--provider claude|codex|grok`, `--model <id>` (omit for
default), `--effort <none|minimal|low|medium|high|xhigh|max>` (provider-specific;
unsupported hard-fails; never silently demoted — Codex `xhigh` is real),
`--arg <flag>` (repeatable) to pass a flag straight to the underlying CLI.

For task-shaped selection, `--op <id>` expands to explicit flags + a decision card
(explicit flags win over the expansion). Do NOT invent a `cheap|default|max`
ladder. Full doctrine: **docs/operating-points.md**.

```bash
waspflow ops list --task implementation      # then: --op implement.standard, review.audit, …
waspflow spawn --op implement.standard --lane fix -- "Implement …"
```

## Holding a worker to a deliverable (`--report`)

```bash
waspflow spawn --provider codex --lane audit --report findings.md -- "Audit auth.ts, write findings.md"
waspflow wait audit && waspflow reap audit   # reap verifies findings.md exists + is substantial
```

If the report is missing at reap, one **recovery pass** resumes the session
(write-enabled) to reconstruct it from transcript + git diff, then stamps an honest
`result`: `succeeded`/`recovered`/`failed` (also `verified`/`verify_failed` with
`--verify`). `reap` exits nonzero on failure — no false "done"; check `status
<lane>` → `.result`. Every lane auto-saves `prompt.txt`, `git-diff.txt`, and
`git-status-before/after.txt`, so "what changed?" is always answerable. (Optional
spawn flags: `--verify <cmd>`, `--prepare <cmd>`, `--isolate`.)

## Running a fleet (parallel, isolated)

```bash
waspflow spawn --provider claude --lane a --isolate -- "Refactor module A"
waspflow spawn --provider codex  --lane b --isolate -- "Refactor module B"
for L in a b; do waspflow wait "$L" && waspflow peek "$L" --lines 40; done
for L in a b; do waspflow reap "$L"; done
```

`--isolate` gives each worker its own git worktree (branch `waspflow/<lane>`);
`reap` keeps a dirty worktree unless `--force`.

**Billing safety before you fan out.** If `ANTHROPIC_API_KEY` is set, headless
Claude workers bill pay-as-you-go **API** rates, not your subscription — and a
fleet multiplies that (a stray key ran up $1,800+ in two days). waspflow
hard-stops a Claude `spawn`/`exec`/`revise` when the key is set. Unset it to use
your subscription, or opt in with `WASPFLOW_ALLOW_API_BILLING=1`. Accident guard,
not a spend cap; `waspflow doctor` shows the active auth path.

## Cheap one-shot work (`exec`)

For stateless, fire-and-return work you read once (an audit, a summary, a
transform), skip lanes entirely:

```bash
waspflow exec --provider codex -o out.md -- "Summarize the last 5 commits."
waspflow exec --provider claude -- "Which files import lib/core.sh?"   # -> stdout
```

`exec` runs one headless turn, blocks, writes to `-o <file>` (or stdout), and
leaves no lane/worktree/reap. Use `spawn` when you need to steer or harvest; use
`exec` when you just need the answer.

## Recovering after YOUR OWN compaction

Lanes outlive your context:

```bash
waspflow check --no-fail   # repo/process state + project gates
waspflow list              # every lane + live/exited/reaped
waspflow status <lane>     # full JSON: provider, session_id, cwd, prompt
waspflow peek <lane>       # what it last said
```

If a window already exited, `revise` resumes the session **headlessly** and
returns the reply — capture it with `--out <file>`:

```bash
waspflow revise <lane> --out /tmp/reply.txt -- "Summarize what you changed."
```

## Trust `wait`, etiquette

`wait` reads the provider's session log for turn-end (Claude `end_turn`; Codex
`task_complete`; Grok `turn_ended`) — no need to poll `peek` to know an agent is
done. Reap lanes you finish (state is retained after reap, so reaping is safe); one
live lane per name (reap before reusing one); `attach <lane>` drops you into the
pane (Ctrl-b d to detach) — for humans, rarely needed by an agent.

## Full command reference

`spawn · exec · ops · init · demo · list · status · peek · wait · revise · attach ·
reap · check · doctor` — run `waspflow help` or see the README.
