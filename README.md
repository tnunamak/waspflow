# waspflow

<p align="center">
  <img src="assets/waspflow-hero.webp" alt="waspflow agent workflow control room" width="100%">
</p>

Give your main agent a live workflow for managing worker agents.

Waspflow is an agent-operable control loop for Claude Code, Codex, and Grok
workers: spawn a worker, watch its live stream, steer it with another
instruction, preserve the transcript and diff, and reap the lane deliberately.
Humans can use the same CLI directly; the deeper point is that an orchestrating
agent gets a small, durable tool surface instead of fire-and-forget subprocesses
and loose notes.

Use it when you want to:

- let a main agent delegate work without losing control of the worker;
- watch what a coding agent is doing before it finishes;
- correct a worker mid-run;
- run multiple workers in isolated git worktrees;
- require a report, transcript, and diff instead of "done, trust me";
- recover worker state after your main agent or terminal loses context.

## First Run

```bash
git clone https://github.com/tnunamak/waspflow ~/code/waspflow
~/code/waspflow/install.sh
waspflow doctor
waspflow demo --provider codex
waspflow demo --provider codex --run
```

Use `--provider claude` or `--provider grok` if that is the agent CLI you have
installed.

You need `tmux`, `jq`, `git`, `curl`, `uuidgen`, and at least one agent CLI:
`codex`, `claude`, or `grok`. If something is missing, `waspflow doctor` tells
you what to install. See [docs/prerequisites.md](docs/prerequisites.md) for links.

## The Loop

A lane is one worker and its saved state: prompt, terminal transcript, session,
working directory, git diff, optional report, and final result.

```bash
# Start a worker from any project directory.
waspflow spawn --provider codex --lane fixbug -- \
  "Find and fix the off-by-one in src/pager.ts"

# Wait until the worker finishes its current turn.
waspflow wait fixbug

# Read the tail of its pane.
waspflow peek fixbug

# Give it another instruction in the same session.
waspflow revise fixbug -- "Add a regression test too."
waspflow wait fixbug

# Close the pane and finalize the lane state.
waspflow reap fixbug
```

`reap` is cleanup, not data loss. The lane record stays under
`$WASPFLOW_HOME` so you can inspect what happened later.

## Why Not Just Run Codex Or Claude Directly?

Direct CLI sessions are great for one focused conversation. Waspflow adds a
small workflow layer when a human or orchestrating agent needs workers to be
observable, steerable, resumable, and reviewable.

| Need | Direct `codex` / `claude` | `waspflow` |
|---|---|---|
| Start a normal coding session | Yes | Yes |
| Give a main agent stable worker-agent verbs | Shell out and hope | `spawn`, `wait`, `peek`, `revise`, `reap` |
| Watch another agent while you keep working | Manual tmux setup | Built in |
| Send a correction after launch | Same terminal only | `waspflow revise <lane>` |
| Run several workers without file collisions | Manual worktrees | `--isolate` |
| Keep prompt, transcript, diff, and result together | Manual bookkeeping | Automatic lane artifacts |
| Require a written report | Prompt convention | `--report` checked on `reap` |
| Recover after your main agent loses context | Manual reconstruction | `waspflow list/status/peek` |

## Isolated Worktrees

Use `--isolate` when several workers may edit the same repo:

```bash
waspflow spawn --provider claude --lane api --isolate -- "Refactor the API client"
waspflow spawn --provider codex  --lane ui  --isolate -- "Tighten the settings page"
```

Each lane gets a git worktree on branch `waspflow/<lane>`. `reap` removes that
worktree only if it is clean. Use `--keep-worktree` to keep it, or `--force` to
discard it deliberately.

## Require a Report

Pass `--report` when the worker must leave a written result:

```bash
waspflow spawn --provider codex --lane audit --report findings.md -- \
  "Audit auth.ts and write findings.md"
waspflow wait audit
waspflow reap audit
```

On `reap`, waspflow checks that the report exists and is substantial. If it is
missing, waspflow runs one recovery pass by resuming the session and asking the
worker to reconstruct the report from the transcript and diff. If the report is
still missing, `reap` fails. You get the deliverable or a hard failure, not a
false green.

## Check the Project Before Launching More Workers

`waspflow check` summarizes the project state that matters for agent work:

- current git branch, dirty state, and upstream delta;
- other git worktrees;
- live, exited, or failed lanes for this project;
- optional project rules from `.waspflow/config.json`.

```bash
waspflow check
waspflow check --explain
waspflow check --no-fail
```

Use `--explain` when you want next steps for the risks it found.

## For Larger Repos

Waspflow works with no project config. If your repo has local rules, generate a
small config instead of writing wrapper scripts:

```bash
waspflow init --profile serious-repo
waspflow check --explain
```

Profiles are composable:

```bash
waspflow init --profile serious-repo --profile openspec
waspflow init --profile serious-repo --profile live-stack-mutex
```

The project supplies the facts: which files are blockers, which command checks
matter, which mutex file protects a live system. Waspflow supplies the common
machinery. See [docs/project-checks.md](docs/project-checks.md) for the full
config shape.

## Commands

| Command | What it does |
|---|---|
| `spawn --provider <claude\|codex\|grok> --lane <name> [opts] -- <task>` | Start a durable worker lane |
| `exec --provider <claude\|codex\|grok> [opts] [-o FILE] -- <task>` | Headless one-shot: run, return, leave no lane |
| `demo --provider <claude\|codex\|grok> [--run]` | Show or run a safe first demo |
| `wait <lane>` | Wait until a worker finishes its current turn |
| `peek <lane>` | Show the tail of the worker pane or transcript |
| `revise <lane> -- <message>` | Send another instruction to the same session |
| `reap <lane>` | Close the pane, verify outputs, and finalize state |
| `list` | List lanes |
| `status <lane>` | Show one lane's JSON state |
| `attach <lane>` | Attach your terminal to the worker pane |
| `check [--explain]` | Check git/worktree/lane/project state |
| `init --profile <name>` | Write `.waspflow/config.json` from reusable profiles |
| `doctor` | Check local prerequisites and agent CLIs |

Useful `spawn` options:

- `--isolate` creates a git worktree for the lane.
- `--report <path>` requires a written deliverable before `reap` succeeds.
- `--model <id>` selects a provider model.
- `--effort <low|medium|high|xhigh|max>` passes reasoning effort where supported.
- `--cwd <dir>` starts the worker in another directory.
- `--arg <flag>` passes an extra flag to the underlying agent CLI.

## Exec: Headless One-Shot Work

`spawn` creates a durable lane — a tmux window, session, optional worktree, and
state you later `reap`. That is the right shape for implementation work you steer
and harvest. For **stateless, fire-and-return** work (an analysis, an audit, a
one-shot transform) that shape is overkill: it leaves a lane and a branch to
reconcile for something you only read once.

`exec` is the cheap path. It runs one headless turn, blocks until it finishes,
writes the final message to a file (or stdout), and leaves nothing behind — no
tmux window, no worktree, no lane record, no reap.

```bash
# Analysis to a file, blocking:
waspflow exec --provider codex -o report.md -- "Summarize the auth flow in src/auth/."

# One-shot answer to stdout:
waspflow exec --provider claude -- "List the public functions in lib/core.sh."

# Same shape for Grok:
waspflow exec --provider grok -- "List the public functions in lib/core.sh."
```

Options mirror `spawn` where they apply: `--model`, `--effort`, `--cwd`, and
`-o <file>` (omit `-o` to print to stdout). Because `exec` runs the same provider
preflight as `spawn`, the billing guard below covers it too.

## Billing Safety

`waspflow doctor` reports the active auth/billing path implied by the current
environment. This is especially important for Claude fleets: if
`ANTHROPIC_API_KEY` is set, headless Claude workers bill pay-as-you-go API
rates instead of subscription/Agent-SDK credit.

For that reason, `waspflow spawn --provider claude ...` refuses to launch while
`ANTHROPIC_API_KEY` is set. Unset it to use subscription-backed Claude auth, or
override intentionally for API billing:

```bash
WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude --lane api -- \
  "Run the intended API-billed task"
```

Codex and Grok have secondary analogous checks: `OPENAI_API_KEY` / `XAI_API_KEY`
are reported by `doctor`, and spawns print a billing notice when the matching
key is set.

## What Waspflow Saves

Every lane writes to `$WASPFLOW_HOME/lanes/<lane>/`:

- `prompt.txt`
- `transcript.log`
- `state.json`
- `git-status-before.txt`
- `git-status-after.txt`
- `git-diff.txt`

Git captures are skipped, not errored, when the lane is not inside a git repo.

## How `wait` Knows a Worker Is Done

Waspflow does not scrape prompt glyphs. It reads each provider's session log:

- Claude Code: idle when the last assistant event has `stop_reason: "end_turn"`.
- Codex: idle when the latest rollout event is `task_complete`.
- Grok: idle when the last `turn_*` event in `events.jsonl` is `turn_ended`.

If the pane has exited, `revise` resumes the saved session headlessly:

- Claude: `claude --resume <session-id> --print "<message>"`
- Codex: `codex exec resume <session-id> "<message>" -o <file>`
- Grok: `grok -p "<message>" --resume <session-id> --always-approve`

## Environment

| Var | Default | Purpose |
|---|---|---|
| `WASPFLOW_HOME` | `~/.local/state/waspflow` | Lane state and transcripts |
| `WASPFLOW_TMUX_SESSION` | `waspflow` | tmux session that holds worker windows |
| `WASPFLOW_ALLOW_API_BILLING` | empty | Set to `1` to intentionally allow Claude workers while `ANTHROPIC_API_KEY` is set |
| `WASPFLOW_CODEX_BACKEND_HEALTH_URL` | empty | Optional health check URL for proxy-routed Codex setups |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | Claude session logs |
| `CODEX_SESSIONS_DIR` | `~/.codex/sessions` | Codex session logs |
| `GROK_HOME` | `~/.grok` | Grok config home (sessions under `$GROK_HOME/sessions`) |
| `GROK_SESSIONS_DIR` | `$GROK_HOME/sessions` | Grok session directories |

## Architecture

Waspflow is shell around tmux plus provider adapters:

- `bin/waspflow` routes CLI commands.
- `lib/core.sh` owns lane state, tmux helpers, and provider dispatch.
- `lib/providers/claude.sh`, `codex.sh`, and `grok.sh` adapt each CLI.
- `lib/worktree.sh` handles git worktree isolation.
- `lib/project.sh` implements `init` and `check`.
- `skill/SKILL.md` teaches an orchestrating agent how to use the CLI.

Adding another provider means adding `lib/providers/<name>.sh` with the provider
contract functions.

## Verify

```bash
scripts/verify.sh
```

The verify script checks shell syntax, config initialization, policy profiles,
mutex/blocker detection, `check --explain`, successful-reaped-lane filtering,
and demo preview output without calling a model.

## License

Apache-2.0. See [LICENSE](LICENSE).
