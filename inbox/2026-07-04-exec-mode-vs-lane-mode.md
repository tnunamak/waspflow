# Waspflow gap: no exec-mode (headless fire-and-return) — we use the heavy lane machinery for stateless analysis too

**Date:** 2026-07-04
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** Tim shared a public Claude-Code skill for driving Codex subagents via
`codex exec` (headless, non-interactive). It's thin overall, but it surfaced one real
architectural distinction that maps onto a cost we just paid in the pdpp fan-in (see
`2026-07-03-fan-in-closeout-ledger-gap.md`). Logging the insight; the skill itself is not
worth chasing.

## The one thing worth gleaning from the skill

`codex exec --yolo --skip-git-repo-check -m gpt-5.5 -c 'model_reasoning_effort="xhigh"' -o <file> -`
with a **quoted heredoc** on stdin. That single invocation sidesteps the ENTIRE Codex-TUI
driving saga documented in this inbox (`2026-06-16`, `2026-06-17`): no PTY, no paste-chunking,
no Enter-vs-Tab submit ambiguity, no polling. The process blocks; the `-o` file appears on
completion; the parent reads it. For **fresh, fire-and-return worker tasks**, this is strictly
simpler than driving the interactive TUI through tmux.

(Quoted `<<'EOF'` matters specifically when embedding a PRIOR subagent's output into the next
prompt — it stops bash from executing code blocks in the returned text. Real footgun.)

## The architectural insight (this is the actual takeaway)

We conflate two agent modes, and use the heavy one for both:

- **exec-mode** — fire-and-return, stateless, headless, output-to-file. No worktree, no branch,
  no session, no PTY, nothing to reap. Right for token-heavy *analysis/transform* subagents:
  the audits, migrations, and forensic passes an orchestrator spawns and reads once. `codex exec`
  (and the Claude equivalent) is the correct tool; these tasks produce a report string, not git
  artifacts.
- **lane-mode** — durable, isolated worktree, live session, harvestable branch, closeout +
  fan-in. Right for long-horizon *implementation* work. This is what waspflow's spawn/wait/
  revise/reap + the new fan-in ledger are for.

The pdpp fan-in got expensive partly because **some "lanes" were really exec-mode work wearing
lane-mode clothes** — fire-and-return analyses that were spawned as full lanes and so left
durable branches/worktrees they never needed. Those then had to be reconciled and reaped like
real implementation work. exec-mode tasks should leave NOTHING to fan in.

## Proposed shape

waspflow should make the mode explicit, so the caller picks the cheap path when the work is
stateless:

```
waspflow exec  <task> [--provider codex|claude] [--effort low|xhigh] -o <file>
   # headless, blocking, output-to-file. No worktree, no lane record, no reap.
   # thin wrapper over `codex exec -o` / the Claude headless equivalent, owning the
   # heredoc/stdin/quoting so the caller never hand-builds the invocation.

waspflow spawn <lane> ...        # unchanged: durable lane, worktree, session, fan-in
```

Guidance that falls out: **default to `exec` for anything fire-and-return** (analysis, audit,
transform, a one-shot forensic question). Reserve `spawn`/lane-mode for work that needs a
worktree, session continuity, or a harvestable branch. That alone shrinks the future fan-in
surface — you can't accumulate 130 branches from work that was never a lane.

## What is NOT worth taking from the skill

Its "Golden Rule" (3k-token threshold → subagent), its parallel-`&`-then-`wait` pattern, and its
"cleanup = `rm /tmp/codex-*.txt`" are fine but unremarkable — and its fan-in model IS
`rm /tmp/*.txt` precisely because it only does the ephemeral half. It has **no session reuse, no
durable harvest, no reaping of git artifacts** — the hard parts we've already gone further on
(`adopt` note; the fan-in ledger that shipped as `feat(fanin)` #2). Different, easier tier. The
value here is the exec-vs-lane framing, not the skill.

**Not urgent.** Logged from a real observation. Complements the fan-in note: that one made
fan-in cheap; this one reduces how much there is to fan in.
