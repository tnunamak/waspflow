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
waspflow spawn --provider codex --accept-provider-default --lane parser -- "Fix the off-by-one in src/pager.ts and add a test"
waspflow wait parser --timeout 600        # block until it finishes its turn (see "trust wait" below)
waspflow peek parser --lines 60           # diagnosis/progress context; not a completion oracle
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
`--mcp auto|none|inherit` (default `auto`, MCP-minimal where supported), and
`--arg <flag>` (repeatable) to pass a flag straight to the underlying CLI. Use
`--mcp inherit` only when the task specifically needs configured MCP servers.

For task-shaped selection, `--op <id>` expands to explicit flags + a decision card
(explicit flags win over the expansion). Do NOT invent a `cheap|default|max`
ladder. Full doctrine: **docs/operating-points.md**.

```bash
waspflow ops list --task implementation      # then: --op implement.standard, review.audit, …
waspflow spawn --op implement.standard --lane fix -- "Implement …"
```

Selection defaults to warning on a bare provider default. Make that choice explicit
with `--accept-provider-default`, or select an operation with `--op`; enforce mode
(`WASPFLOW_SELECTION_GATE=enforce`) returns exit 5 (`selection_required`) with no
stdin prompt. `--auto` requires `--op`; `--ack-deprecated` applies only to `--auto`.

## Holding a worker to a deliverable (`--report`)

```bash
waspflow spawn --provider codex --accept-provider-default --lane audit --report findings.md -- "Audit auth.ts, write findings.md"
waspflow wait audit && waspflow reap audit   # reap verifies findings.md exists + is substantial
```

If the report is missing at reap, one **recovery pass** resumes the session
(write-enabled) to reconstruct it from transcript + git diff, then stamps an honest
`result`: `succeeded`/`recovered`/`failed` (also `verified`/`verify_failed` with
`--verify`). `reap` exits nonzero on failure — no false "done"; check `status
<lane>` → `.result`. Every lane auto-saves `prompt.txt`, `git-diff.txt`, and
`git-status-before/after.txt`, so "what changed?" is always answerable. (Optional
spawn flags: `--verify <cmd>`, `--prepare <cmd>`, `--isolate`.)

## Verify before destructive cleanup (`verify`)

When a lane has `--verify <cmd>` (and optionally `--prepare <cmd>`), run the
oracle before reaping so a failure remains steerable and inspectable:

```bash
waspflow wait fix
waspflow verify fix || waspflow revise fix -- "Fix the failing verification."
waspflow verify fix
waspflow reap fix
```

`verify` never touches tmux, lane status, result, session, or worktree. It exits
0 on pass and 2 on failure, and writes command/stdout/stderr/JSON receipts. The
JSON carries `failure_class` (`task`, `prepare`, `timeout`, `infra`,
`invalid_oracle`, `pre_existing`, `none`) plus
the advisory `verify_test_files_changed` heuristic. Reap consumes a checkpoint
only when its content-sensitive Git workspace fingerprint is unchanged; otherwise
it reruns the configured oracle. A changed/unknown test-surface flag is warning
only, never an approval gate.

If the checkpoint is task-class, `verify` proposes (but never starts)
`waspflow escalate fix`; `verify fix --json` exposes that command in
`suggested_argv[]`. `revise` steers the SAME arm in-session; `escalate` deliberately
switches arms and records a closing `lane_segment` receipt before a replacement window
is adopted.

Every reap also appends an outcome receipt to `$WASPFLOW_HOME/receipts.jsonl`
(arm, billing path, availability evidence, verify outcome, wall time). Declare
`--verify-strength suite|smoke` alongside `--verify` at spawn — a receipt only
counts as `stats_eligible` calibration data when strength was declared and the
lane's model/effort were explicit and attested. Costs nothing; do it by default
on serious lanes.

## Running a fleet (parallel, isolated)

```bash
waspflow spawn --provider claude --accept-provider-default --lane a --isolate -- "Refactor module A"
waspflow spawn --provider codex  --accept-provider-default --lane b --isolate -- "Refactor module B"
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
waspflow exec --provider codex --accept-provider-default -o out.md -- "Summarize the last 5 commits."
waspflow exec --provider claude --accept-provider-default -- "Which files import lib/core.sh?"   # -> stdout
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

`wait` polls the provider's session log for turn-end (Claude `end_turn`; Codex
`task_complete`; Grok `turn_ended`) — no need to poll `peek` to know an agent is
done. Exit codes: `0` idle (done), `1` timeout, `4` **stalled** — the worker produced
no output for `WASPFLOW_STALL_SECONDS` (default 45) while its turn hadn't ended.
That usually means it's waiting on a mid-run interactive prompt (a quota/model-
downgrade offer, a security check, a y/n) but can also be a hang or a very slow tool.
waspflow **surfaces** the stall fast (in seconds, not at timeout) but never auto-
answers — it hands the decision to you. On rc 4: `waspflow peek <lane>` to see exactly
what it's waiting on, then `waspflow revise <lane> -- "<answer>"` (e.g. `1`/`yes`/`no`)
to answer, then `wait` again — or raise `WASPFLOW_STALL_SECONDS` if the turn is just
slow. The trigger is the stall itself, not any specific prompt wording (robust to new
or reworded prompts).

For a live Codex lane, `revise` returns zero only after a new provider-log
`task_started` event confirms the instruction left the composer. A nonzero result
means the submission is unconfirmed (including a queued `user_message`); inspect or
attach before deciding what to do next. Its receipt is recorded in `status` as
`revise_submitted`, `revise_submission_state`, and `revise_submission_error`.

For a native background worker whose calling harness needs a completion signal,
run `waspflow wait <lane> --reap`: it blocks while polling until the provider oracle
verifies idle, then returns the final reap result. The process exit is the
notification; waspflow does not run a daemon, event subscription, or callbacks.

`waspflow park <lane>` is the non-destructive alternative for an owned,
terminal-idle resumable lane: it stops only the recorded tmux window and keeps
the transcript, state, session, worktree, and artifacts. `waspflow gc` is a
dry-run-by-default fleet selector for safely parkable lanes older than a
configured **lane age** (time since spawn, not idle duration); `--apply` parks,
never reaps. Age alone cannot establish that work is captured or safe to
destroy, so automatic age-based reaping is intentionally unsafe and absent.
For lanes created before ownership receipts, inspect first and explicitly use
`--adopt-legacy`; adoption still requires resumable + terminal-idle proof.

Reap lanes you finish (state is retained after reap, so reaping is safe); one
unreaped lane per name (reap before reusing one); `attach <lane>` drops you into the
pane (Ctrl-b d to detach) — for humans, rarely needed by an agent.

## Full command reference

`spawn · exec · ops · init · demo · list · status · peek · wait · park · gc · revise · attach ·
reap · check · doctor` — run `waspflow help` or see the README.
