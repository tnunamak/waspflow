# Waspflow feature request: cross-provider lane transfer and transcript translation

**Date:** 2026-07-09
**Author:** Codex, at operator request
**Context:** During a cost-sensitive orchestration pass, the operator asked to stop a Claude worker and restart the same task on Codex `gpt-5.4-mini`. Today that means manually interrupting one provider and cold-starting another with a copied prompt. The prompt can preserve the task, but not the lane's accumulated state, artifacts, constraints, or provider-specific transcript context.

## The need

Waspflow should make it easy to transfer work across models and providers:

- Claude lane → Codex lane
- Codex lane → Claude lane
- same provider, cheaper or stronger model
- live lane → fresh lane seeded by a durable handoff
- exited/reaped lane → fresh lane seeded from transcript + report + diff

The user-facing shape is not "resume the same model state." Providers do not share model state, and even same-provider resume is transcript replay. The useful abstraction is: **convert a lane into a provider-neutral handoff packet, then launch or revise another provider from that packet.**

## Proposed feature

Add a small transfer/translation library plus a CLI surface around it:

```sh
waspflow transfer <lane> --to-provider codex --to-model gpt-5.4-mini --new-lane <name>
waspflow transfer <lane> --to-provider claude --to-model sonnet --new-lane <name>
waspflow transfer <lane> --same-lane --to-model gpt-5.4-mini
waspflow handoff <lane> --format neutral > handoff.md
waspflow import-handoff handoff.md --provider codex --model gpt-5.4-mini --lane <name>
```

The library should produce a provider-neutral packet with:

- original task prompt and latest user steering
- current lane state: provider, model, cwd, branch, worktree, report path, session id, status
- git evidence: branch, HEAD, dirty status, diff/stat, recent commits
- durable artifacts: report file, saved prompt, transcript tail, git-diff/status snapshots
- unresolved asks and explicit "do not do" constraints
- tool/process caveats: billing mode, sandbox, required commands, pending sessions
- confidence and verification state if present

Then provider adapters translate that neutral packet into provider-appropriate prompt text and launch mechanics.

## Important design constraints

- **Reference-only handoff.** Do not paste stale "active task" blocks as live instructions without labeling them as historical. This is the same failure mode called out in `docs/warm-worker-restart.md`.
- **Re-ground before acting.** The receiving agent must be told that its inherited view may be stale and must re-read relevant files before edits.
- **Never pretend transcript conversion is true session migration.** A Claude JSONL cannot become a Codex session with identical hidden state. The honest product is cold-start-with-handoff.
- **Preserve spend intent.** Transfer should make cost explicit: `--to-provider`, `--to-model`, optional `--effort`, and a billing warning before launch.
- **Worktree safety first.** If transferring into the same worktree, check for live processes and dirty state. If ambiguous, create an isolated lane.
- **Format should be useful outside waspflow.** A neutral `handoff.md` or JSON packet should be readable by a human and usable with any future provider adapter.

## Why this matters

- Lets the orchestrator downgrade routine harvesting/recovery work to a cheap model without retyping context.
- Lets expensive agents do hard reasoning, then hand implementation or cleanup to cheaper agents.
- Lets an interrupted provider lane continue on a different provider when one account, model, or billing path is unavailable.
- Makes provider/model swaps auditable instead of hidden in ad hoc copied prompts.

## Implementation sketch

1. Add a neutral lane packet builder:
   - `lib/transfer.sh` or equivalent
   - inputs: lane state dir, provider session log path, report path, git status/diff
   - outputs: `handoff.md` and optionally `handoff.json`

2. Add provider renderers:
   - `render_for_codex(packet)`
   - `render_for_claude(packet)`
   - keep provider-specific syntax and warnings in adapters, not in the packet builder.

3. Add launch modes:
   - `transfer --new-lane`: spawn a fresh lane with the rendered handoff.
   - `transfer --same-lane`: only if same provider/session semantics make sense; otherwise fail with an explanation.
   - `handoff`: write only, no model spend.

4. Add verification:
   - receiving agent must restate branch/HEAD and the active objective before proceeding.
   - record source lane and transfer packet path in the new lane state.

## Relationship to existing docs

This is adjacent to `docs/warm-worker-restart.md`, but not the same thing.

- Warm restart: reuse a provider session safely after drift.
- Transfer: create a fresh provider/model session from a durable, provider-neutral handoff.

The two should share the same re-grounding language and handoff packet builder.

## Priority

Medium-high. The need is already showing up in real orchestration work, especially when the operator wants low-burn swaps from Claude to Codex mini or from a high-reasoning model to a cheaper cleanup model. It is not required for single-lane work, but it would materially improve multi-agent reliability and cost control.
