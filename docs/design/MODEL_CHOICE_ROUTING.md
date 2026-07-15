# Model Choice & Orchestrator Routing — availability, catalog, policy, and who decides

Status: SUPERSEDED by `MODEL_SELECTION_CONTROL_LOOP.md` (v2, 2026-07-15) — retained for provenance
Created: 2026-07-14
Grounded in:
- research: `ai/research/agentic-context-design/agent-model-choice-is-cost-performance-at-effort-not-quota-or-sticker-price-alone.md` (2026-07-09)
- research: `ai/research/agentic-context-design/auditing-the-orchestrator-not-just-the-change.md` (2026-06-30)
- the minnows `model-catalog` pack (`~/code/minnows/data/model-catalog/`: `models.json`, `pricing/*`, `performance/*`)
- the shipped `ops` doctrine (`docs/operating-points.md`, `lib/ops.sh`, `data/model-choice-policy/operating-points.json`)

## Adversarial review outcome (gpt-5.6-sol, 2026-07-14) — READ FIRST

This design was authored by Claude and adversarially reviewed by a different model
(gpt-5.6-sol, high effort, given the full chat via `convo` + all source files). The reviewer
found **fact-level defects, not just opinion-level ones**, all independently re-verified against
the live files. The material corrections, folded below:

1. **Routing decision reversed → (A) pure resolver, NOT bounded-(B).** A decision card is a
   *receipt, not consent*; a bare spawn acquiring a model it didn't request is auto-routing even
   if carded — which the shipped doctrine forbids. Decisive implementation fact: the policy is a
   **sparse ID-keyed list, not a `(task_family, constraint) → point` function** (two points exist
   for `(implementation, balanced)`), and `ops.sh` resolves by exact `--op` id only — so (B) is
   *not even resolvable* without inventing a router. And the incident was upstream of `ops`, so
   changing bare-spawn semantics would not have prevented it. If ergonomic routing is wanted,
   add an **explicitly invoked** surface (`spawn --task X --constraint Y` / `--auto-op`); never
   change bare `spawn --provider` semantics.
2. **The "same family" currency signal is broken on the real data (verified).** minnows families
   are `gpt-5.4` / `gpt-5.5` / `gpt-5.6` — *different* families — so the guard cannot detect the
   motivating `gpt-5.4-mini → gpt-5.6` transition at all; and `luna/terra/sol` share
   `family: gpt-5.6` but are **cost tiers, not chronological succession** ("newer" among them is
   invented). Replace family-inference with **owner-authored, scoped `preferred_over` edges**
   (`from → to`, surface, task families, rationale, reviewed_at). `gpt-5.4-mini` is *not*
   objectively superseded (OpenAI still lists it; it's cheaper than luna) — Tim's prohibition is
   a valid **owner policy**, not a catalog fact.
3. **Availability is the wrong data type.** It is not a set of IDs; it is invocation-scoped
   `(adapter, auth principal, billing path, provider/endpoint, profile/config, cwd/trust, model,
   effort, mode)` and **tri-state: `available | unavailable | unknown`**. A stale-cache miss must
   be `unknown` (→ allow explicit model), never a false `unavailable` (→ block). Today
   `validate_model` refuses on cache-absence (`core.sh:90`) — that is NOT fail-open, contradicting
   this doc's own stated principle. This is the **#1 pre-implementation gate**: define & prove a
   tri-state, invocation-scoped provider contract first.
4. **Factual errors corrected inline:** `escalate` is *not* null — the field is `escalate_to` and
   9/10 points carry paths (my `jq` queried the wrong key; the claimed "escalate gap" is
   nonexistent). minnows is *not* all `status: ga` — it has `preview`/`promo`/
   `third_party_board_only`. `ops` does *not* "resolve within the available set" — it never reads
   availability. `review.audit`→`sol` cites GPT-5.5-only evidence (its "medium" confidence is
   unsupported). Provider (`codex`, a harness) ≠ catalog provider (`openai`, a surface) — joining
   on model id alone loses billing/capability distinctions.
5. **Kept (reviewer concurred):** the availability/catalog/policy *decomposition* is sound;
   quota≠dollars non-fungibility; decision cards + durable receipts; never reject an uncatalogued
   model; and "judged adequacy cannot be certified — a challenger refutes, never blesses."

**The pre-implementation gate (reviewer's, adopted):** before building routing OR currency
warnings — (1) an invocation-scoped tri-state provider contract; (2) cached-negative-evidence
never blocks an explicit model; (3) explicit `preferred_over` edges, no `family`/lexical
inference; (4) contract tests for Codex ChatGPT/API/access-token/profile/custom-catalog/`--oss`,
Claude's non-enumerable case, Grok logged-out + stale-cache, and live-query failure; (5) bare
spawn semantics unchanged.

*The body below is the original proposal, retained for provenance; where it conflicts with the
five points above, the corrections above win.*

## The motivating incident (state it plainly)

An agent working in pdpp ran on `gpt-5.4-mini` — a superseded model — when `gpt-5.6-luna`
(the current cheap Codex tier) was available. The waste was real. But the root cause was
**not** waspflow: it was a stale project-local Codex worker profile
(`pdpp/.codex/agents/gpt55-low-worker.toml`, `model = "gpt-5.5"`, since removed). Waspflow's
`ops` resolver never produces a stale model — it resolves Codex to `gpt-5.6-sol`. The lesson
that survives: **model choice leaks to stale values wherever a hand-authored pin lives
upstream of a currency-aware resolver, and nothing downstream catches it.** This doc is about
making the *right* choice the path of least resistance, and catching the wrong one — without
ever blocking a model the user legitimately has.

## The core error to avoid: conflating three different things

The tempting-but-wrong model is "the catalog is the source of truth for models." It is not,
and cannot be. There are **three distinct sources**, and every prior mistake this session came
from collapsing them:

| # | Question | Authoritative source | Nature |
|---|---|---|---|
| 1 | **What can this user actually invoke, right now?** | the live provider, scoped to the **active auth** (`codex debug models`; the claude model set; a local model server) | *availability* — only the environment knows it |
| 2 | **What does a model cost, and how well does it perform at each effort?** | the **minnows catalog** (`pricing/*`, `performance/*`) | *facts about models* — says nothing about whether you can run them |
| 3 | **Which model should a given task-shape prefer?** | the **policy** (`operating-points.json`), a mapping over (1)∩(2) | *preference + currency judgment* |

The decisive design rule follows directly:

> **Availability is the gate. The catalog is enrichment, never a gate. The policy resolves
> within the available set.**

Three corollaries, each answering a real failure mode seen this session:

- **A model that is available but NOT in the catalog must still be usable.** (The user may have
  `gpt-5.6-terra`, a local Qwen, or a brand-new release the catalog hasn't ingested.) Waspflow
  **fails OPEN** on uncatalogued-but-available models — allow, don't enrich, warn "no
  cost/perf data." This matches the existing `claude_valid_models() { return 1; }` fail-open
  comment in `lib/providers/claude.sh`. Blocking the user's own models would be *worse* than
  the stale-model problem.
- **A model that is in the catalog but NOT available must never be routed to.** (Auth-scoped:
  `gpt-5.3-codex` is rejected on a ChatGPT account; a model may be region/plan-gated.) The
  policy resolves only within the live-available set; a policy point that resolves to an
  unavailable model is a *policy error surfaced at resolve time*, not a spawn-time crash.
- **"Currency" is relative, not a catalog flag.** minnows marks *every* model `status: "ga"`
  (verified: `gpt-5.5`, `gpt-5.4`, and `gpt-5.6-luna` are all `ga`). So the catalog cannot tell
  you `gpt-5.5` is superseded. Currency is a *policy* judgment over the available set: "is
  there a newer/preferred model **in the same family** that is **also available**?" Only the
  policy (which owns family-tier preference) plus live availability can answer this.

## What the catalog gives us (enrichment, grounded)

The minnows catalog is genuinely rich and correctly separated (facts, not policy):

- `models.json` — id, `status`, `family` (e.g. `claude-sonnet`, `claude-opus`). Family is the
  key we need for currency ("newest available in this family").
- `pricing/` — `anthropic-api`, `openai-api`, `codex-credits`, `xai-api`, `google-api`. The
  **cost axis**, correctly split into API $/MTok vs Codex credits (the research entry's
  non-fungibility point: quota ≠ dollars).
- `performance/` — BrowseComp, SWE-bench, Terminal-bench, ARC, Artificial-Analysis,
  `anthropic-effort-quality`, `local-evals`. The **quality×effort axis** — the exact
  cost–performance-at-effort framing from the Anthropic Sonnet 5 post.

Enrichment means: when a decision card is printed for an *available* model that is *also* in
the catalog, attach its cost + the relevant effort-quality evidence. When it's available but
uncatalogued, print the card with `evidence: none` and proceed. **The catalog decorates a
choice; it never makes or blocks one.**

## What the policy owns (and the gap that caused the incident)

The `operating-points.json` policy maps `(task_family, constraint_family) → {provider, model,
effort}` with a decision card. Verified current families: `implementation, review, recover,
fanout, advisor, ui, docs` × `balanced, accuracy-first, dollar-tight, quota-tight,
latency-sensitive`.

**The concrete gap (data-confirmed):** Codex appears in the policy *only* at `gpt-5.6-sol` for
`accuracy-first` tasks. There is **no cheap-Codex operating point** — nothing resolves to
`gpt-5.6-luna`. So an orchestrator that wants a cheap Codex worker has **no `--op` to reach
for**, and reaches for a raw `--model` instead — which is exactly the path where a stale pin
(or a stale project config) slips in. **Adding the missing low-cost operating points is the
single most direct structural fix for the motivating incident:** make the right cheap Codex
choice a named, resolvable operating point so nobody hand-pins.

Also confirmed: `escalate` is `null` on every point. The doctrine ("escalate model *or* effort
only on failed verify/revise") is documented but not yet *encoded as data* — the policy should
carry an explicit `escalate` path per point so the escalation is a resolvable step, not folklore.

## The responsibility split (the load-bearing decision)

This is the heart of your question — "how does one orchestrator choose or influence an
appropriate subagent without ending up too-expensive or too-dumb?" The prior-art entry on
auditing the orchestrator answers the *governance* half unambiguously: **an orchestrator that
executes, sequences, AND self-grades its choices is an un-gated self-grade, and a
better-instructed orchestrator does not fix it** (Adversarial Goodhart; a self-authored,
self-run, self-routable check merely relocates the gaming). Trust comes only from moving the
check outside the orchestrator, in descending strength: (1) deterministic, (2) different-model
challenge, (3) human at a fixed cadence.

Applied to *model choice* specifically, the split is:

| Layer | Owns | Must NOT own |
|---|---|---|
| **Live provider** | availability (auth-scoped) | preference, cost judgment |
| **Catalog (minnows)** | cost + performance facts | availability, preference |
| **Policy (operating-points)** | task→operating-point mapping; family-tier preference; currency; escalate path | availability (reads it, doesn't define it) |
| **waspflow resolver (`ops`)** | resolve policy within available set; **print a decision card**; validate; warn on stale/uncatalogued | *deciding for* the orchestrator silently |
| **Orchestrator** | pick the **task family** + constraint; may override with explicit `--model/--effort` (always wins) | grading its own choice as correct |
| **Pre-spawn challenge** (new) | deterministically flag a choice that violates the policy/currency rules **before tokens are spent** | certifying the choice is *good* (it only refutes clear violations) |

### THE DECISION FOR YOU (flagged, with a defensible default)

*How much routing authority should waspflow take?* Two coherent positions:

- **(A) Pure resolver (the shipped doctrine).** `ops` resolves only when explicitly given
  `--op`; a bare `spawn --provider codex` inherits the provider's own default. Waspflow never
  auto-routes. Pro: no hidden authority, matches `docs/operating-points.md` ("no silent
  auto-routing"). Con: a bare spawn is *only as good as the provider default* — which is where
  stale pins live. It does not prevent the incident; it just refuses to cause it.

- **(B) Resolver with a safety floor.** A bare spawn with no `--op`/`--model` **still resolves
  a default operating point for the task family** (or, if no family is given, a conservative
  balanced default) and prints the card — the orchestrator can always override. Plus a
  **currency guard**: if a resolved-or-explicit model is *superseded-and-a-current-one-is-
  available*, warn loudly (never block). Pro: makes the right choice the default, directly
  prevents the incident. Con: takes routing authority the current doctrine deliberately
  withholds.

**Defensible default I will design around, pending your ratification: a bounded (B).** Not
silent auto-routing — an *explicit, carded, overridable* default plus a *warn-never-block*
currency guard. Rationale: (A) is philosophically clean but leaves the exact hole that burned
you (the default is where staleness hides); (B)-bounded keeps the orchestrator sovereign
(explicit flags always win; every resolution prints its reasoning) while removing the
foot-gun. The one hard line either way: **never block a model the user actually has** — the
guard is preference/warning, never refusal, because availability (not the catalog) is truth.

This is the decision I most want your ratification on before implementation, because it sets
how much waspflow decides vs. leaves to the caller.

## The pre-spawn challenge (maker≠judge on the choice, made cheap)

The auditing-the-orchestrator entry says the model/lane choice must be **challenged before the
work, not rationalized after**, by something outside the orchestrator's control, and that the
*strongest* such check is **deterministic** (ungameable by construction), not a
different-model opinion. For model choice this is unusually tractable, because most of "is this
choice sane?" *is* deterministic:

Deterministic pre-spawn checks (no model needed, cannot be gamed):
1. Resolved/explicit model ∈ live-available set for the active auth? (else refuse-with-list)
2. Is it superseded — a newer model in the same `family` also available? (warn, never block)
3. Does the constraint match the bill? (subscription worker costed in quota; API worker in
   dollars — never merge without an explicit exchange rate; the research entry's hard rule)
4. Is effort pass-through honored (no silent demote; Codex `xhigh` is real)?

Only the irreducibly-judged residue — "is `sol`+`xhigh` genuinely warranted for *this* task,
or is a cheaper point adequate?" — is a candidate for a different-model challenger, and per the
prior art that challenger **refutes, never certifies**, and must be outside the orchestrator's
routing control. For v1 this residue can stay with the human (the decision card gives them
what they need); a different-model sequencing-challenger is a v2 escalation, not day one.

## What this is explicitly NOT

- **Not silent auto-routing.** Every resolution prints a decision card with its reasoning;
  explicit `--model/--effort` always win. (Even (B) is carded and overridable.)
- **Not a `cheap|default|max` ladder.** Task family + constraint, per the shipped doctrine —
  not a global quality knob.
- **Not blocking uncatalogued/local models.** Availability is truth; the catalog only enriches.
- **Not cross-ranking vendors from launch blogs.** Same-vendor-relative guidance unless an
  independent fixed harness is cited (the research entry's rule; minnows keeps sources).
- **Not a live cost meter.** clawmeter (quota) and tokensmash (dollars) own spend; this design
  only *chooses* and *records the basis*, it does not measure the invoice.

## Proposed shape (for review, not commitment)

1. **Availability provider-fn** per adapter: `<provider>_available_models` — query live
   (`codex debug models`), auth-scoped, cache as *fallback only* with a freshness stamp
   (today's `models_cache.json` is >24h stale and is the validation source — that's the bug to
   fix: refresh-then-fallback, not fallback-first).
2. **Currency guard** in the resolve/validate path: family-relative supersession warning
   (needs `family` from minnows + the available set). Warn, never block.
3. **Fill the policy gap:** add low-cost operating points (a cheap-Codex point → `gpt-5.6-luna`;
   the missing task×constraint cells) and encode `escalate` paths as data.
4. **Make the catalog dependency load-bearing:** validate the policy's `expands_to.model`
   values against the pinned catalog at build/test time, so the policy can't silently drift
   from the `catalog_ref` it cites.
5. **(pending ratification) bounded-(B) default resolution** + carded output on bare spawn.

## Open questions

1. **The (A) vs (B) routing-authority decision above — yours to set.**
2. Where does the availability query's auth-scope come from — does `doctor` already resolve the
   active Codex auth mode (ChatGPT vs API key) reliably enough to scope the model set?
3. Is a stale-`models_cache.json` refresh waspflow's job, or should it defer to `codex debug
   models` every spawn (latency vs. correctness)?
4. Should the policy pack *consume* minnows performance data to *derive* operating points, or
   stay hand-authored-but-validated-against it? (Derive = less drift, more complexity; the
   research entry warns evals go stale monthly — argues for validated-hand-authored + a
   freshness gate over full derivation.)
