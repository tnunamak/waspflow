# `wait` false-idle when Claude parent is awaiting background agents

Observed 2026-07-09 on three Fable/Claude orchestration lanes.

## Symptom

`waspflow wait <lane>` returned `is IDLE` while the parent Claude session still
had two to four background `Agent` tasks running. `waspflow peek` immediately
showed the parent at `Waiting for N background agents to finish`, with the child
agents still accumulating tokens and no required report or worktree changes yet.

Affected examples:

- `fable-source-fulfillment-0709`
- `fable-pr-elevation-0709`
- `fable-owner-experience-0709`

## Why this matters

An orchestrator can interpret `wait` as fan-in completion, review an empty
worktree, or reap a lane while child agents are still producing the required
deliverable. This defeats waspflow's deliverable and cleanup guarantees.

## Expected behavior

For Claude sessions using background subagents, `wait` should remain non-idle
until both conditions hold:

1. the parent turn has ended; and
2. no child/background agents owned by that parent remain active.

If child state cannot be read reliably, return a distinct state such as
`parent_idle_children_active` rather than `IDLE`, and make `reap` fail closed
unless explicitly forced.

Add a regression fixture with a parent that launches a background agent and
waits for it before writing a required report.
