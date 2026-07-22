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

## Federation

Federation lets a trusted collective contribute spare agent capacity through a
local daemon and browser UI. The complete contributor journey is below.

**Install on Linux (first-class):**

```bash
curl -fsSL https://raw.githubusercontent.com/tnunamak/waspflow/waspflow/fedgui-e2e/bin/federation-install.sh | sh
```

The installer downloads the latest Linux `.deb` when it can install one, or a
portable bundle in `~/.local` when it cannot. It requires Node.js 20 or newer.

**Install on macOS (best effort; not tested in this Linux release pass):**

```bash
brew install tnunamak/tap/waspflow-federation
```

The formula is maintained at
[`packaging/brew/waspflow-federation.rb`](packaging/brew/waspflow-federation.rb).
It needs a published release tarball and has not been validated on macOS yet.

**First run:**

```bash
waspflow federation
```

That checks sandbox readiness, starts the loopback-only daemon, and opens the
onboarding UI. Paste the invite from your collective operator into **Join**;
then, once they approve your generated key, click **Contribute**. The doctor
keeps Docker Sandboxes (`sbx`) detect-and-guide: it tells you what is missing
without making the UI or invite flow inaccessible.

### Host a collective

You do not need a server or a domain to host a trusted collective. Install
Waspflow, then run one guided command:

```bash
waspflow federation host
```

Answer its one reachability question. **ngrok** is recommended: it gives the
signup and authtoken links, installs Waspflow’s host-only tunnel connector
only after you choose it, and prints the final public address and a paste-able
HTTPS invite. ngrok’s current free plan assigns one stable development
domain to an account; Waspflow uses that assigned address rather than asking
you to buy or configure a domain. Your members do not need ngrok accounts.

If you already operate an HTTPS reverse proxy, choose **my own HTTPS address**;
if everyone is on the same network, choose **local network only**. Scripted
hosts can skip prompts with one of:

```bash
waspflow federation host --tunnel ngrok
waspflow federation host --tunnel url:https://collective.example
waspflow federation host --tunnel lan
```

Then send the printed invite. You can print it again at any time with
`waspflow federation invite`. A packaged Linux host is kept alive by a systemd
user service; a source checkout keeps the coordinator attached to the terminal
so its lifecycle stays visible. See [Federation coordinator deployment](docs/federation-deployment.md)
for reverse-proxy details and [the host implementation report](docs/design/FEDERATION_HOST_REPORT.md)
for the current ngrok limits and the live-tunnel verification boundary.

If an invite leaks, run `waspflow federation host --rotate-token`, then send
fresh invites; existing members must re-join with the new token.

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

## Install sbx (Docker Sandboxes)

`install.sh` tries this for you automatically. If it couldn't (no Homebrew, no
passwordless sudo, unsupported OS), run one of these yourself:

```bash
# macOS
brew tap docker/tap && brew install docker/tap/sbx && sbx login

# Linux (apt-based)
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install -y docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login

# Windows
# Use the signed Federation installer. It installs prerequisites, enables
# Windows Hypervisor Platform with UAC consent, and guides any required restart.
```

Full docs: https://docs.docker.com/ai/sandboxes/get-started/

Then run the full, read-only preflight: `waspflow federation doctor`.

On Windows, the signed Federation installer owns prerequisites and restart
handling. Doctor is a backstop after installation; it directs repair through
the installer or presents an in-product unsupported-device state rather than
asking contributors to administer Windows manually.

It checks the package-backed `sbx` install, Docker CE/containerd v2, daemon,
policy, KVM access, and Docker login before Federation can claim a task. Use
`waspflow federation doctor --fix-policy` only when it offers that safe,
explicit policy initialization; all other fixes are printed for you to run.

`bin/federation-detect-sbx` remains the fast version-only detector.

This powers Federation Preview — running a job contained in a Docker sandbox
instead of on your bare host. Skip this if you're not using Federation.

## Selection gate

Selection defaults to `warn` for one release: a bare provider-default invocation
continues but prints one suggestion to add `--accept-provider-default`. Set
`WASPFLOW_SELECTION_GATE=enforce` to require `--op <id>`, an explicit `--model`,
or `--accept-provider-default`; it exits 5 (`selection_required`) without
launching anything. `--auto` selects an op fallback and requires `--op`;
`--ack-deprecated` applies only to that selector path.

You need `tmux`, `jq`, `git`, `curl`, `uuidgen`, and at least one agent CLI:
`codex`, `claude`, or `grok`. If something is missing, `waspflow doctor` tells
you what to install. See [docs/prerequisites.md](docs/prerequisites.md) for links.

## The Loop

A lane is one worker and its saved state: prompt, terminal transcript, session,
working directory, git diff, optional report, and final result.

```bash
# Start a worker from any project directory.
waspflow spawn --provider codex --accept-provider-default --lane fixbug -- \
  "Find and fix the off-by-one in src/pager.ts"

# Wait until the worker finishes its current turn, then perform normal reap.
# The calling harness receives the final reap result directly.
waspflow wait fixbug --reap

# Use structured provider events for orchestration observation. This never reads
# full-screen terminal paint or exposes prompt/tool content.
waspflow events fixbug --lines 40 --json

# Inspect the pane only for UI/modal diagnosis (for example after a stalled wait).
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
waspflow spawn --provider claude --accept-provider-default --lane api --isolate -- "Refactor the API client"
waspflow spawn --provider codex  --accept-provider-default --lane ui  --isolate -- "Tighten the settings page"
```

Each lane gets a git worktree on branch `waspflow/<lane>`. `reap` removes that
worktree only if it is clean. Use `--keep-worktree` to keep it, or `--force` to
discard it deliberately.

## Require a Report

Pass `--report` when the worker must leave a written result:

```bash
waspflow spawn --provider codex --accept-provider-default --lane audit --report findings.md -- \
  "Audit auth.ts and write findings.md"
waspflow wait audit
waspflow reap audit
```

The report path is normalized against the worker's effective cwd and included
literally in the initial provider prompt. Ordinary `revise` messages and the
one recovery pass reassert that same exact path, so workers do not need to infer
a filename. On `reap`, waspflow checks that this exact file is substantial and,
for new lanes, was created or changed after spawn. If it is missing or unchanged,
waspflow runs one recovery pass by resuming the session and asking the worker to
write that exact path from the transcript and diff. If it is still missing,
`reap` fails. You get the deliverable or a hard failure, not a false green from
an unrelated report file.

## Verify Before Reaping

Use `--verify` to make a project oracle part of a lane, then run it while the
lane is still intact:

```bash
waspflow spawn --provider codex --accept-provider-default --lane fix --isolate \
  --prepare 'npm ci' --verify 'npm test' -- "Fix the failing test."
waspflow wait fix
waspflow verify fix                 # 0 = pass; 2 = fail; no tmux/worktree teardown
# inspect or revise the still-live lane, then run verify again
waspflow reap fix                   # reuses the checkpoint if its workspace is unchanged
```

`verify` writes `verify-command.txt`, stdout/stderr, and `verify-result.json`
under the lane directory, including `failure_class` (`task`, `prepare`,
`timeout`, `infra`, `invalid_oracle`, `pre_existing`, or `none`). A failed
checkpoint in an isolated lane also runs the oracle in a temporary detached
fork-point worktree, so an already-failing baseline is recorded as
`pre_existing`. It does not change the lane's lifecycle or
result. Reap reuses a checkpoint only when a content-sensitive Git workspace
fingerprint (HEAD, tracked changes, and untracked files) still matches; otherwise
it runs the contract again before cleanup. Non-Git workspaces are deliberately
rerun.

Each verify receipt also records the advisory `verify_test_files_changed` flag.
For new isolated lanes it compares the fork point with committed and working-tree
changes, looking for conventional `test`/`spec`/`verify` paths and paths named in
the command. It warns but never blocks, and reports `unknown` for lanes without
a trustworthy recorded fork point.

Use `--verify-strength suite` or `--verify-strength smoke` to declare the
oracle class in the append-only receipt; waspflow never guesses it from the
command. Receipts live at `$WASPFLOW_HOME/receipts.jsonl` and are emitted when a
lane is reaped.

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
| `wait <lane> [--reap]` | Poll the provider log until a worker finishes; `--reap` then returns the final reap result |
| `events <lane> [--lines N] [--json]` | Safe, normalized provider-event tail for Codex, Claude, or Grok |
| `inspect [<lane>] --json` | Read-only lane facts and explainable cleanup classifications |
| `peek <lane> [--events]` | Pane/transcript capture for UI diagnosis; `--events` is the structured tail |
| `revise <lane> -- <message>` | Send another instruction to the same session; nonzero means live submission was not confirmed |
| `escalate <lane> [--to …] [--handoff]` | Switch arms after a failed checkpoint; `revise` instead steers the same arm |
| `accept-runtime <lane> --reason <text>` | Explicitly accept the current observed Codex model/effort mismatch |
| `verify <lane> [--json]` | Run the configured prepare/verify contract without teardown (0 pass, 2 fail); failed task checkpoints propose `escalate` |
| `reap <lane>` | Close the pane, verify outputs, and finalize state |
| `park <lane>` | Close only a verified-idle owned tmux window; preserve the resumable lane |
| `gc [--lane-age S] [--apply]` | Dry-run fleet selection for safely parkable old lanes; `--apply` parks them |
| `close <lane> --status <harvested\|superseded\|abandoned>` | Record a lane's fan-in outcome (with provenance) |
| `captured <lane> --in <ref>` | Is the lane's work already present in `<ref>`? (by content, not ancestry) |
| `ops list\|explain\|resolve <id>` | Resolve a task-shaped operating point to explicit flags |
| `list` | List lanes |
| `status <lane>` | Show one lane's JSON state |
| `attach <lane>` | Attach your terminal to the worker pane |
| `check [--explain]` | Check git/worktree/lane/project state |
| `init --profile <name>` | Write `.waspflow/config.json` from reusable profiles |
| `doctor` | Check local prerequisites and agent CLIs |

Useful `spawn` options:

- `--isolate` creates a git worktree for the lane.
- `--report <path>` requires a written deliverable before `reap` succeeds.
- `--verify <cmd>` configures an oracle; use `verify <lane>` before destructive reap.
- `--prepare <cmd>` runs setup before that oracle; `--verify-timeout <seconds>` bounds both commands.
- `--verify-strength <suite|smoke>` declares receipt comparability; it is never inferred.
- `--model <id>` selects a provider model.
- `--effort <none|minimal|low|medium|high|xhigh|max>` passes reasoning effort **exactly** where supported (never silent demotion; Codex accepts `xhigh`).
- `--mcp <auto|none|inherit>` controls worker MCP exposure. `auto` is the default and is MCP-minimal where the provider supports it; use `inherit` only when the task needs the current provider configuration.
- `--op <id>` expands a task-shaped operating point (`waspflow ops list`); explicit flags win over expansion.
- `--cwd <dir>` starts the worker in another directory.
- `--arg <flag>` passes an extra flag to the underlying agent CLI.

MCP policy by provider: Claude and Codex resolve `auto` to `none`; Grok
currently resolves `auto` to `inherit` with a warning because its CLI has no
verified empty-MCP launch boundary. Explicit Grok `--mcp none` fails before
launch. Under Claude/Codex isolation, pass-through MCP config (and Codex config
profiles) is rejected; choose `inherit` explicitly when a task needs it.

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
waspflow exec --provider codex --accept-provider-default -o report.md -- "Summarize the auth flow in src/auth/."

# One-shot answer to stdout:
waspflow exec --provider claude --accept-provider-default -- "List the public functions in lib/core.sh."

# Same shape for Grok:
waspflow exec --provider grok --accept-provider-default -- "List the public functions in lib/core.sh."
```

Options mirror `spawn` where they apply: `--model`, `--effort`, `--mcp`, `--cwd`, and
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
WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude --accept-provider-default --lane api -- \
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

For Codex, a headless resume reasserts the lane's requested model and passed
reasoning effort. Waspflow then records the structured runtime settings actually
observed for the exact correlated session; launch intent is never overwritten.

## Codex Runtime Settings Receipt

`model_requested`/`model_passed` and `effort_requested`/`effort_passed` are
immutable launch-intent receipts (legacy `model`/`effort` remain unchanged).
Codex lanes additionally expose `runtime_model`,
`runtime_effort`, source, timestamp, and requested-match status from typed rollout
events only (`turn_context` and `thread_settings_applied`). `status` and `list
--json` refresh this receipt without reading TUI text, prompts, or transcripts.

An explicit requested model/effort mismatch blocks normal reap with
`result: runtime_drift` while retaining the lane and its work. After reviewing
the evidence, an operator may explicitly accept that exact observed timestamp:

```bash
waspflow accept-runtime my-lane --reason "provider safety fallback accepted"
waspflow reap my-lane
```

A later observed settings timestamp requires a new acceptance; Waspflow never
silently changes the requested model or effort.

## Provider-log Completion Polling

For a native, backgrounded worker, use `waspflow wait <lane> --reap`. The
calling harness blocks while `wait` polls the provider session log at its
configured interval, and receives the normal final reap result only after the
provider terminal oracle confirms the lane is idle. There is no waspflow daemon,
event subscription, callback endpoint, or claimed asynchronous notification
delivery: process completion is the notification mechanism. Use `peek` after a
nonzero `wait` result (especially rc 4 stalled) to diagnose the exception; it is
not the completion oracle.

## Parking and Conservative Fleet GC

`park <lane>` stops only the tmux window recorded as belonging to a currently
live lane. It refuses active, corrupt, reaped, unresumable, or unowned lanes;
the transcript, lane state, provider session, worktree, and artifacts remain in
place, and `revise` can resume the provider session later.

Lanes created before ownership receipts were introduced remain safe-by-default:
parking refuses them. After checking the dry-run candidate, use
`park <lane> --adopt-legacy` or `gc ... --adopt-legacy --apply` to explicitly
bind the existing named window to its lane record before cleanup. Adoption still
requires a resumable provider session and a terminal-idle oracle result.

`gc` is dry-run by default. It selects live, owned lanes whose provider terminal
oracle is idle and whose **lane age** (time since spawn), not idle duration,
meets `--lane-age` (or `WASPFLOW_GC_LANE_AGE_SECONDS`, default 86400). Pass
`--apply` to park the selected windows, optionally bounded by `--project DIR`.
It never auto-reaps and never removes worktrees or artifacts. Age alone cannot
prove that a lane's changes were inspected, captured, or safe to destroy, so
age-based cleanup parks rather than reaps.

`list --json` exposes the durable global lane index to callers. It supports
`--project DIR`, `--lifecycle-state live,exited,parked,reaped`, and `--limit N`
while continuing to show corrupt records rather than silently dropping them.
The bulk JSON is a metadata projection and deliberately excludes prompts,
commands, and resolved provider argv/env; use `status <lane>` for one full record.

## Environment

| Var | Default | Purpose |
|---|---|---|
| `WASPFLOW_HOME` | `~/.local/state/waspflow` | Lane state and transcripts |
| `WASPFLOW_TMUX_SESSION` | `waspflow` | tmux session that holds worker windows |
| `WASPFLOW_LANE_PAGER` | `cat` | Pager command for provider children in new lanes; overrides inherited `PAGER` and `GIT_PAGER` for those children only |
| `WASPFLOW_ALLOW_API_BILLING` | empty | Set to `1` to intentionally allow Claude workers while `ANTHROPIC_API_KEY` is set |
| `WASPFLOW_CODEX_BACKEND_HEALTH_URL` | empty | Optional health check URL for proxy-routed Codex setups |
| `CLAUDE_PROJECTS_DIR` | `~/.claude/projects` | Claude session logs |
| `CODEX_SESSIONS_DIR` | `~/.codex/sessions` | Codex session logs |
| `GROK_HOME` | `~/.grok` | Grok config home (sessions under `$GROK_HOME/sessions`) |
| `GROK_SESSIONS_DIR` | `$GROK_HOME/sessions` | Grok session directories |

Lane provider children default both `PAGER` and `GIT_PAGER` to `cat`. This
prevents commands such as `git log` from parking an unattended lane in an
interactive pager inherited from the tmux server. It does not change the
operator shell or tmux server, and the pane remains a real PTY for `attach`.

Override precedence is explicit: `WASPFLOW_LANE_PAGER` wins, then the default
is `cat`; inherited `PAGER` and `GIT_PAGER` never control a lane. Set
`WASPFLOW_LANE_PAGER=less` only when an operator intentionally accepts that an
unattended lane may wait in a pager. The override applies to provider children
and headless lane recovery commands, not to the operator's shell.

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

## Releases (CI)

Pushes to `main` with conventional commits (`feat:`, `fix:`, `BREAKING CHANGE`) trigger
[semantic-release](https://github.com/semantic-release/semantic-release): GitHub Releases + notes.

- Workflow: `.github/workflows/release.yml` (after `scripts/verify.sh`)
- Local install still tracks your clone: `git pull && ./install.sh` (also wired in `dotfiles/setup.sh`).
