# Waspflow gap: no durable "advisor lane" for repeated model consults across a long task

**Date:** 2026-07-05
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** A multi-day media-server cleanup/migration. Throughout, I repeatedly consulted a
reasoning model ("Fable") as an advisor — go/no-go on a dedup plan, review of a Remux→x265
migration, readiness gates — on Tim's standing instruction "if Fable is aligned, proceed."
Tim then asked me to resume "the same Fable session I talked to before because it has context,"
and flagged: if that's not possible, it's a waspflow gap that should be documented. He's right.

## What actually happened

Every "Fable consult" this session was **stateless and one-shot**:
- Some went through the deep-research Workflow as subagents (`model: fable`) — fresh context each.
- Others were direct single-turn model calls fed a written brief.

There was **no persistent Fable session to resume.** Each round, I hand-authored a fresh brief
re-establishing the whole situation (the plan, the numbers, prior verdicts) because the advisor
had zero memory of the previous rounds. That re-briefing is real toil and it's lossy — I decide
what context to carry forward, so the advisor never sees the full arc it's supposed to reason over.

## Why this isn't covered by the existing `adopt` notes

The 2026-06-16 / 2026-06-17 notes propose `waspflow adopt` for driving a **pre-existing
interactive tmux-pane** session. That's a different mechanism. My case had no pane at all — it was
programmatic, stateless model invocations. The gap here is not "adopt an existing pane," it's:

**There is no first-class pattern for a long-lived ADVISOR LANE: spawn a reasoning agent once,
then `revise` it with each new question over hours/days, preserving its accumulated context, so
each verdict builds on the last instead of starting cold.**

Waspflow's `spawn` → `wait` → `revise` loop is *exactly* this capability — a lane keeps its
session-id and `revise` resumes it (`claude --resume <id> --print`, `codex exec resume <id>`). I
simply didn't use it that way; I reached for stateless Workflow subagents out of habit. So this is
~50% operator miss, ~50% a genuine surfacing gap:

1. **Operator miss:** for a repeated-consult advisor, I should `waspflow spawn --lane fable-advisor`
   once and `revise` it each round — the context persists for free. I didn't, and paid the
   re-brief tax every time.
2. **Surfacing gap:** nothing in README/docs/skill names the "advisor lane" use case. The docs frame
   lanes as *workers that do a task and get reaped*. The equally-common shape — a **standing advisor
   you consult repeatedly and never reap until the campaign ends** — isn't described, so an
   orchestrator doesn't think to use `spawn`/`revise` for it. A worker lane and an advisor lane have
   different lifecycles (advisor: no deliverable, no `--report`, long-lived, detach-not-reap).

## Proposed (low-cost)

- **Doc/skill:** add an "advisor lane" recipe to `skill/SKILL.md` + README: `spawn` a reasoning
  model once, `revise` per consult to preserve context, `detach` (not `reap`) at campaign end.
  Note it pairs with `--model` to pick the advisor tier (e.g. a high-reasoning model) distinct from
  worker lanes.
- **Optional ergonomics:** a lane "kind" (`worker` vs `advisor`) so `check`/`list` don't nag an
  advisor lane about a missing report or an unreaped long-lived lane. Advisor lanes are *supposed*
  to sit open across the whole task.
- **Cross-provider caveat:** resume fidelity depends on the provider keeping full session context on
  `--resume`/`exec resume`. Worth a doc line: advisor lanes are only as good as the provider's
  session persistence; verify the model actually sees prior turns (a quick "what did you conclude
  last round?" probe) before trusting continuity.

## Why it matters

The "consult a smart advisor repeatedly over a long, risky operation" pattern is common and
high-value (it's Tim's whole "if Fable is aligned, proceed" workflow). Done statelessly it's lossy
and toilsome; done as a waspflow advisor lane it's a single durable session the orchestrator steers.
The machinery already exists — it just isn't named as a use case, so it doesn't get used.

**Priority:** medium. Logged from a real run. The immediate fix is operator behavior (use an
advisor lane next time); the durable fix is documenting the pattern so the next orchestrator reaches
for it.
