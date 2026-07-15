# Model Selection as a Control Loop — v2 design

Status: design proposal — REVISED after sol review #3 (2026-07-15): direction confirmed,
**rejected as an implementation spec**; implementation gated on the "Review #3 outcome"
section below, which WINS over the body wherever they conflict. Supersedes
`MODEL_CHOICE_ROUTING.md` (v1).
Created: 2026-07-15
Authored by: Claude (Fable), synthesizing five research threads + two sol (gpt-5.6-sol)
adversarial reviews + owner decisions from the 2026-07-14/15 sessions.
Grounded in:
- corpus: `ai/research/model-routing/stats-based-selection-is-sound-only-within-tagged-comparable-groups-plus-domination-and-quota-filters.md`
- corpus: `ai/research/model-routing/escalation-triggers-on-verify-failure-not-verify-success-and-walks-the-model-effort-frontier.md`
- corpus: `ai/research/agentic-context-design/agent-model-choice-is-cost-performance-at-effort-not-quota-or-sticker-price-alone.md`
- corpus: `ai/research/agentic-context-design/auditing-the-orchestrator-not-just-the-change.md`
- sol review #1 (v1 doc): tri-state availability gate; reject family-inference currency; (A) resolver stance
- sol review #2 (reconciliation): forced-choice gate confirmed; deprecation migration; `--accept-provider-default`
- owner decisions: policy-as-requirements (ratified); selector lives in waspflow lib; blind-by-stats
  bounded version; quota is the cost axis for subscription-backed arms only; frontier-walking
  escalation (owner-corrected from my "effort-first")

## Review #3 outcome (gpt-5.6-sol, xhigh, 2026-07-15) — READ FIRST; wins over the body

Author-verified against live data/code before folding (3/3 spot-checks exact). The P0s:

1. **The frontier is EMPTY today, not thin.** All 102 `comparability_group` rows in pinned
   catalog v0.5.2 are `comparable: false`; **zero** `comparable: true` rows exist
   (author-verified by grep). Requirements-based resolution works for **zero** families —
   the body's "a minority of families today" is wrong. Also: a Pareto frontier is a partial
   order — "next arm up" needs a task-scoped scalarization + adjacency + tie-break rule that
   the body never defines; and the named-arm fallback's `escalate_to` is a *branching graph*
   (multiple targets), not a ladder. Gate: separate `stats_frontier` (where eligible data
   exists) from an explicit `fallback_ladder` (ordered, per point); do not claim one
   structure until both have executable ordering semantics. **Until a first
   `comparable: true` arm-group exists, Phase 2 ships fallback-only selection — no
   pretend frontier.**
2. **The domination/bars/`preferred_over` triad needs a truth table.** The body never
   defines precedence or coverage: models governed by none of the three; edge-target
   unavailable/dominated/bar-failing; edge-vs-bar conflicts; uncatalogued arms' rank
   position. Bars are non-executable against the actual policy data (evidence confidence
   `medium`/`missing`, contaminated smoke evidence). Gate: a truth table over
   {stats-eligibility × bar × edge × availability} → {include, auto-select, warn,
   require-ack, fallback, escalate}.
3. **Arm identity regressed from v1's own gate.** `(provider, model, effort)` cannot
   distinguish subscription vs API billing, endpoint/profile, or mode — v1's
   invocation-scoped availability contract (still standing) must define the arm. Also
   contradictory: "availability is the gate" vs "explicit `--model` always proceeds" —
   resolved per sol: live-proven `unavailable` fails even explicit use (with evidence);
   `unknown` is never auto-selected but explicit use proceeds and is receipted; cached
   negatives can only ever produce `unknown`, never a block.
4. **`verify_failed` currently fires inside destructive reap** — window killed, worktree
   removed — so the correction loop has nothing to act on; and verify does NOT necessarily
   run isolated (`--isolate` is optional; verify runs in lane cwd; committed test edits
   evade the plain-diff artifact). Gate: split verification from reap — a non-destructive
   checkpoint-verify that preserves lane/arm/session/worktree on failure, an
   agent-inaccessible verify baseline, and a failure taxonomy (task / pre-existing /
   prepare / infra / timeout / invalid-oracle). **This, not clawmeter, is the heart of
   Phase 1.**
5. **Forced choice can't rank without a task.** A bare spawn has no task family/constraint,
   so a "bar status" table is unrankable — the gate must first ask for task+constraint
   (never infer from the prompt: that reintroduces the router). `exec` is stateless with no
   receipts and needs its own design.

P1 corrections folded: the flywheel dataset **does not exist yet** (author-verified:
1,779 lanes → 56 with verify → 34 outcomes → **0** with a task-family label; receipts today
lack task_family/duration/cost-basis/verify-class fields — receipt v1 schema is a
prerequisite, and ~96 obs per arm×family×verify-class cell for ±10pp means distillation is
far off; assignment confounding applies to the LOCAL flywheel too, not just pooled
telemetry). "Detecting the wrong model is solved" overstates — verify failure proves
*not-done*, not *model-wrong*. Stall rc-4 is an interactive-prompt/hang signal, **not** an
escalation trigger — dropped. Grok cache behavior is inferred, not confirmed — "uniform"
hedged. Stakes-from-`--isolate` only covers file edits — DB writes/sends/external calls are
independent irreversibility risks; stakes derivation narrowed accordingly. Migration must
also cover: `ops resolve --json` output-contract versioning, Codex reap's drift-detection
(a deliberate escalation switch must not trip the runtime-drift alarm), and park/resume
re-asserting the ORIGINAL arm (escalation must atomically update the lane's current arm or
`park`→`revise` silently reverts it). Corpus gate added: measure the actual escalation rate
against `d < 1 − c_cheap/c_strong` before relying on weak-first economics.

Sound per sol (unchanged): arms as model×effort with no fixed effort-first; the
availability/catalog/policy separation; forced choice + `--auto` + provider-default escape;
the verify-failure/green-success asymmetry; structured-state handoff; quota/dollar
non-fungibility.

## The reframe everything rests on

**Predicting the right model is unsolved; detecting the wrong one is solved — for coding.**
The 2026 routing literature shows every deployable router plateauing far below the oracle
(sophisticated routers within ~1pp of trivial kNN) because per-task correctness prediction is
the bottleneck. Coding uniquely has an objective post-hoc signal: tests. Therefore waspflow
does not build a router. It builds a **control loop**: a self-cleaning candidate set, a
human-owned bar, an objective escalation trigger it already ships (`--verify`), and receipts
that make every task a calibration datum. Selection gets better with use because waspflow —
unlike every router in the literature — owns the verification gate.

## One data structure, two uses: the frontier of arms

The unit of choice is an **arm**: a `(provider, model, effort)` triple. Arms live on a
cost-performance frontier computed from tagged-comparable stats. That one structure serves:
1. **Spawn-time selection** — pick the cheapest arm clearing the task's bar.
2. **Escalation** — on trigger, move to the next non-dominated arm up the frontier.

Effort-vs-model ordering is a *frontier fact, not a rule* (owner correction, corpus-verified):
a better model at low effort can dominate a worse one at max (Sonnet-5-high ≈ Opus-4.8);
effort is non-monotonic on small models; and every switch — model OR effort — costs one
full-context cache miss uniformly across all three harnesses, so there is no cache argument
for effort-first. Hard rule that survives: repeated verify-failures at a model's top arm =
capability saturation → jump models (Snell TTC band).

## The candidate set is computed, not authored

```
candidates = live_availability(auth-scoped, tri-state)
           ∩ capability_filters(context, tools, …)
           ∩ non_dominated(within one tagged comparability_group)
           ∩ quota_headroom(clawmeter, subscription-backed arms only)
```

- **Availability is the gate; the catalog is enrichment, never a gate** (v1 principle,
  survives review). Tri-state per sol: `available | unavailable | unknown`; a stale-cache
  miss is `unknown → allow explicit choice`, never a false block. An available-but-
  uncatalogued model (user's local Qwen, brand-new release) is always usable — un-enriched,
  warned, never blocked.
- **Domination retires old BIG models automatically** (~96% of models are off the
  intelligence-price frontier; Opus 4.7 fell off the day 4.8 shipped). This kills the
  stale-model class structurally — no hand-maintained deny-list.
- **Domination does NOT retire old SMALL models** — `gpt-5.4-mini` is *cheaper* than luna and
  may sit on the frontier's low end. What excludes it is the **task bar** (its performance
  tier fails the bar) or, where comparable stats don't exist, an owner-authored
  `preferred_over` edge (sol review #1's mechanism — complementary to domination, not
  replaced by it; each covers the regime the other can't).
- **Cost is billing-path-conditional** (owner decision): subscription-backed arms are costed
  in **quota** (clawmeter live windows — hard-filter exhausted arms; guard the
  just-reset-window flood); API-backed arms in **$/MTok**. Never merged without the explicit
  **shadow-price knob**: spend dollars to preserve quota only when burn-rate projects
  cap-before-reset; otherwise quota is use-it-or-lose-it (≈$0 marginal). The knob is
  owner-set policy, not a derived optimum.
- Comparability discipline: rank only within one `comparability_group` (minnows already
  tags this); harness effects move scores 10–20+ points, so cross-group ranking is
  garbage-in. Vendor self-reports never drive ranking.

## Policy becomes requirements, not model names (ratified)

`operating-points.json` migrates from `expands_to.model: claude-sonnet-5` (the rot vector —
exactly how the gpt-5.5 pin went stale) to **requirements**: per task family, a performance
axis + bar tier + cost stance + stakes class. The resolver picks the cheapest candidate arm
clearing the bar. Honest transition: requirements-based resolution only works where
task-scoped comparable stats exist — **zero families under pinned catalog v0.5.2** (all 102
tagged performance rows are `comparable: false`; author-verified). Fallback-only until the
first `comparable: true` arm-group is admitted. So points carry BOTH
forms: `requirements` (used when evidence supports) and a named-arm `fallback` (used
otherwise, marked with `evidence_confidence` as today). Families graduate as evidence
accumulates (see flywheel).

**Stakes is derived, not asked**: an isolated worktree IS the reversibility mechanism —
default stakes = reversible for `--isolate` lanes; elevated when a lane is non-isolated or
touches live-stack-mutex-guarded paths (signals waspflow already has).

### The five human-owned slots (irreducible; no stats table can produce them)
1. Task→axis mapping (which benchmark proxies "code review" — needs a private eval eventually)
2. The bar per task family ("adequate" vs "audit-grade")
3. Comparability/trust tagging of stat sources (exists in minnows; stewarded)
4. The quota↔dollar shadow-price knob
5. The new-model admission gate (nothing in industry automates this)
Slots 1, 2, 4 ship with **placeholder defaults marked UNRATIFIED** until the owner sets them.

## The correction loop

- **Triggers**: `verify_failed` (rank-1 signal) and stall (rc 4, already detected). NOT
  verbalized confidence (least reliable signal), NOT an LLM judge per-turn.
- **Action**: walk to the next non-dominated arm; execute via mid-session switch
  (`/model`, `/effort` keystrokes — the only on-the-fly path for Codex; Grok has ACP) at the
  task boundary a verify failure naturally is, accepting the one cache-miss turn — OR
  fresh-lane handoff carrying **structured state** (waspflow's existing artifacts: prompt,
  git-diff, report — the warm-restart re-grounding). Reset rather than hand off when the
  trajectory is poisoned by repeated failures (AgentSwing).
- **Cascade honesty**: weak-first-escalate only pays while escalation rate
  `d < 1 − c_cheap/c_strong`. Where the task family predicts high difficulty (the prior
  exists — that's what `task_family` is for), route to the strong arm up front; don't pay
  for a doomed cheap attempt.
- **Granularity honesty**: turn/verify-boundary, not step-level (R2V's 0.6%-of-steps result
  is not reachable through a TUI). Deliberate distance from the research frontier, justified
  by harness constraints.

## Green verify is not a stop signal (new hardening requirement)

28–76% of passing solutions can game tests. `verified` today is a clean terminal state —
that's unsafe, and it also pollutes the flywheel's labels. Hardening (upstream of everything):
verify runs in the isolated worktree (already true), test files read-only where possible,
and a cheap independent check on green (did the lane touch test files? does behavior match
the report?) before `verified` is trusted or recorded as a label.

## The interaction contract (sol-converged; unchanged)

Never silent. Bare spawn/exec with no model and no op: **stop and present the ranked
candidate table** (arms, cost in the applicable currency, bar status, evidence confidence)
— the agent chooses; `--auto` explicitly opts into accepting the top arm;
`--accept-provider-default` is the sovereignty escape. Explicit `--model` always proceeds
(warn-or-require-ack on `preferred_over` hits). Migration per sol: a deprecation phase with
loud warnings + exact replacement commands before the hard gate; `spawn`, `exec`, `demo`,
docs, skill, fixtures updated together.

## The flywheel (the durable advantage)

Every lane already emits `(task_family, arm, verify_state, duration, cost basis)` — exactly
the labeled outcome data whose absence is the routing field's bottleneck. Loop: hand-authored
priors → receipts accumulate → periodic **human-ratified** distillation sharpens bars and
graduates families to requirements-based resolution. Maker≠judge holds: verify is a
deterministic external signal, and policy updates pass through the owner, so the orchestrator
never grades its own routing. Label quality depends on the green-verify hardening above.

### Future work (design-doc sections, not build items)
- **Optional good-faith telemetry**: the receipt minus content
  (`{task_family, provider, model, effort, verify_state, verify_command_class, duration,
  escalation_path, cost_basis}`) is inherently anonymizable and would be the first
  task-scoped coding-agent outcome commons. Schema must class verify strength
  (smoke/suite/none) or outcomes aren't comparable across users; data is observational
  (models get non-random task assignment) — stratify by family; the rigorous fix is an
  opt-in exploration percentage, someday. Local flywheel first; pooling is the network
  effect later.
- **Log-mining bootstrap**: Claude/Codex/Grok session logs (convo already parses all three)
  yield weak labels (inferred outcomes: tests-passed-near-end, commits) — usable to
  bootstrap priors, never to set bars. Receipts remain gold.

## What we are explicitly NOT building
No learned router (plateau; calibration doesn't pay for a small pool). No difficulty
classifier (the NVIDIA classifier is a curation tool; even NVIDIA doesn't route with it).
No silent auto-routing (doctrine, twice sol-confirmed). No cross-comparability-group
ranking. No per-step micro-routing. No hand-maintained model deny-lists (domination + bars
+ sparse `preferred_over` edges replace them).

## Phases (re-gated per review #3; each phase sol-reviewed before code)

0. **Corpus capture** — DONE (2 entries in `ai/research/model-routing/`, reconciled).
1. **Foundations** (the real heart, per sol):
   a. **Split verification from reap** — non-destructive checkpoint-verify preserving
      lane/arm/session/worktree on failure; agent-inaccessible verify baseline (catches
      committed test edits); failure taxonomy (task / pre-existing / prepare / infra /
      timeout / invalid-oracle).
   b. **Ratify versioned schemas**: `Arm` (invocation-scoped: surface, endpoint/profile,
      billing path, model, effort, mode), `AvailabilityObservation` (tri-state + evidence
      source + freshness), `BillingPath`, `QuotaObservation`, **receipt v1** (runtime arm
      attestation, task family, verify-strength class + harness hash, baseline state,
      timestamps, cost currency, escalation path).
   c. Tri-state matrix enforced in code: cached negatives → `unknown`, never a block
      (fixes today's stale-cache hard-reject); live-proven `unavailable` fails even
      explicit use, with evidence.
   d. `clawmeter --json` contract established (attestation only — the hard filter waits
      for Phase 2's candidate set).
   e. Provider contract-test matrix restored from v1: Codex ChatGPT/API/access-token/
      profile/custom-catalog/`--oss`; Claude non-enumerability; Grok logged-out +
      stale-cache; live-query failure; park/resume-after-escalation; verify-failure-
      preserves-lane.
2. **Selection**: candidate-set computation (**fallback-only until the first
   `comparable: true` arm-group exists** — no pretend frontier); the triad truth table;
   forced-choice gate that first elicits task+constraint, then ranks
   (+ `--auto`/`--accept-provider-default`); separate `exec` design (stateless → needs its
   own receipt story); requirements+fallback policy schema with `ops resolve --json`
   compat versioning; deprecation-phase migration (66 bare-spawn call sites audited by sol,
   incl. `demo --run`, docs, skill, fixtures).
3. **Correction**: escalation on the new checkpoint-verify failure (NOT stall rc-4),
   walking `stats_frontier` where it exists / `fallback_ladder` otherwise; escalation
   atomically updates the lane's current arm (park/resume must not revert it) and must not
   trip Codex drift detection; structured-state handoff and poisoned-lane reset;
   escalation-rate measurement gate (`d < 1 − c_cheap/c_strong`) before weak-first is
   defaulted anywhere.
4. **Flywheel**: only after receipt v1 has accumulated real cells (~96 obs per
   arm×family×verify-class for ±10pp — measure, don't assume); distillation reports where
   the ratifier audits raw-label validity and the statistical comparison, not a summary;
   families graduate to requirements-based; telemetry/log-mining revisited after the local
   loop proves out.

## Open items (owner)
- Ratify slots 1/2/4 defaults when Phase 2 lands (placeholders marked UNRATIFIED).
- Admission-gate process for brand-new models (trust Artificial Analysis vs local eval run).
- clawmeter `--json` contract (owner owns clawmeter).
