# Waspflow SLVP Ideal

Status: current product target
Created: 2026-06-15

SLVP means Stripe, Linear, Vercel, and Plaid as the quality bar. It is not a
quality acronym. For waspflow, the bar is: the tool should feel simple for a
single developer, but still carry enough durable machinery for serious
multi-agent work without every project inventing its own orchestration system.

## Thesis

Waspflow encapsulates reusable agent-orchestration machinery. Projects declare
local policy.

Reusable machinery belongs in waspflow:

- spawn, stream, wait, revise, resume, and reap worker agents;
- provider adapters behind one lane model;
- isolated git worktrees;
- durable lane artifacts: prompt, transcript, state, status, diff, and report;
- report contracts and honest recovery;
- compaction recovery through on-disk state;
- project integrity checks for git, worktrees, lanes, mutexes, blockers,
  reports, and project commands;
- guided first-run and project initialization.

Project policy stays outside waspflow:

- which checks are mandatory for this repo;
- which files mark a live operational mutex;
- which report paths matter;
- whether OpenSpec, CI, deploy, or owner-review gates apply;
- who has authority to merge, deploy, or discard work.

The ideal split is small config, not bespoke scripts.

## User Tiers

### First-time individual user

The user should be able to clone, install, and complete a no-edit demo without
learning workstream theory:

```bash
waspflow doctor
waspflow demo --provider codex
waspflow demo --provider codex --run
```

If that path fails, the failure should name the missing dependency or backend
and the next concrete action.

### Developer delegating real work

The user should learn one loop:

```bash
waspflow spawn --provider codex --accept-provider-default --lane fix -- "Fix the bug and add a test"
waspflow wait fix
waspflow peek fix
waspflow revise fix -- "Tighten the edge case"
waspflow reap fix
```

The lane is the durable unit of work. The user should never wonder where the
prompt, transcript, diff, or result went.

### Serious project owner

The owner should initialize local policy declaratively:

```bash
waspflow init --profile serious-repo
waspflow check --explain
```

More demanding repos compose profiles:

```bash
waspflow init --profile serious-repo --profile openspec --profile live-stack-mutex
```

The tool explains risks in operational language. It should not require a
project-specific playbook to understand dirty worktrees, unreaped lanes, failed
reports, blocker files, or open mutexes.

### Flagship dogfood project

PDPP should be an example of the serious-project tier, not a fork of waspflow.
PDPP can keep a short governance doc, but orchestration mechanics should remain
in waspflow. If PDPP needs a new generic primitive, the default answer is to
improve waspflow, then delete the local workaround.

## Prior Art Signals

The target is aligned with current leading-agent products:

- Amp treats subagents as useful for independent work, parallel work, and
  preserving the main context window.
- GitHub Copilot cloud agent makes background sessions reviewable through logs
  and pull-request-style iteration rather than unobservable one-shot tasks.
- Codex CLI/cloud separates local terminal work from cloud/background tasks but
  keeps task application explicit.
- Claude Code skills and hooks demonstrate that reusable behavior and guardrails
  should be packaged, not re-explained in every project.
- Agent orchestration literature distinguishes code-driven orchestration from
  model-driven orchestration; waspflow intentionally mixes them. The durable
  control plane is code-driven, while the worker intelligence remains model-
  driven.

## Non-Goals

- Waspflow is not a project manager.
- Waspflow is not an autonomous merge/deploy system by default.
- Waspflow is not a replacement for repo-specific standards, specs, or CI.
- Waspflow should not encode PDPP-specific paths, OpenSpec assumptions, or live
  personal-data policy into its default behavior.

## Product Invariants

- A first run should be understandable in under five minutes.
- A serious project should not need local orchestration scripts.
- A lane result should never be falsely green when a required report is missing.
- Reaping is cleanup, not data loss; lane artifacts remain inspectable.
- Provider-specific behavior belongs in adapters and must degrade honestly.
- Project-specific policy should be visible in `.waspflow/config.json`.
- Human review remains explicit unless a project deliberately configures
  otherwise.

## Current Gaps

- Distribution is still clone-plus-install, not a polished package channel.
- `init` covers core profiles but not an interactive wizard.
- `check --explain` is useful but intentionally generic; future versions should
  attach advice to the exact failing checks.
- There is no browser or TUI dashboard for lanes.
- Antigravity (`agy`) is supported for headless durable lanes; model discovery
  is `agy models`, with OAuth/quota billing and conservative MCP defaults.

These are productization gaps, not architecture blockers.
