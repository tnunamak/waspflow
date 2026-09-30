# Data pack: `model-choice-policy`

**Policy**, not facts. Task-shaped **operating points** that expand to explicit
`provider` / `model` / `effort` / `mode` flags for `waspflow` (and any thin
resolver).

Separates from [`model-catalog`](../model-catalog/) so recommendations never
contaminate pricing or benchmark evidence.

## Get this pack

| | |
|---|---|
| **This version** | [data-model-choice-policy-v0.1.13](https://github.com/tnunamak/minnows/releases/tag/data-model-choice-policy-v0.1.13) — published by CI on push to main |
| **Latest** | [releases](https://github.com/tnunamak/minnows/releases?q=data-model-choice-policy&expanded=true) |
| **Facts catalog** | [model-catalog](../model-catalog/) — pin is `catalog_ref` in the policy file |

```bash
./scripts/fetch-data-pack.sh model-choice-policy
# or
TAG=data-model-choice-policy-v0.1.13
curl -fsSL -L \
  "https://github.com/tnunamak/minnows/releases/download/${TAG}/${TAG}.tar.gz" \
  | tar -xz
```

## Doctrine

1. Operating points are **task-shaped** (`implement.standard`), not `cheap|default|max`.
2. Expansion must be **explicit and logged** — no silent auto-routing.
3. **Evidence confidence** is as important as sticker cost.
4. **Quota ≠ dollars** — never merge without an explicit exchange rate.
5. Update ops only from source-backed catalog facts or local evals.
6. Raw flags always win: `--provider` / `--model` / `--effort` override `--op`.

## Use with waspflow

```bash
waspflow ops list --task implementation --constraint balanced
waspflow ops explain implement.standard
waspflow ops resolve implement.standard --json
waspflow spawn --op implement.standard --lane fix -- "…"
```

## Derive ops from data (DRAFT)

`op-requirements.json` holds the human-set slots for each op: task families,
allowed lanes and efforts, missed-failure cost, and constraints.
`scripts/recommend_ops.py` derives a recommended arm from these slots and the
catalog, or reports missing model/board coverage. It uses a 90-day price horizon
and requires independent cross-model evidence for model changes. It never edits
`operating-points.json`. See
[SCHEMA.md](SCHEMA.md#op-requirementsjson-draft--owner-review-pending).

```bash
./scripts/recommend_ops.py            # markdown table + per-op detail
./scripts/recommend_ops.py --json
uv run --with pytest --with jsonschema pytest tests/test_recommend_ops.py
```

Waspflow resolves from (first hit):

1. `$WASPFLOW_OPS_POLICY` (file path)
2. `$DATA_PACKS_HOME/model-choice-policy/operating-points.json`
3. Bundled `waspflow/data/model-choice-policy/operating-points.json`

## Operating points (10)

| Op | Provider / model / effort |
|----|---------------------------|
| `recover.report` | claude / sonnet-5-5 / low |
| `fanout.explore` | codex / gpt-6.1-sol / medium |
| `docs.lookup` | claude / sonnet-5-5 / low |
| `implement.standard` | claude / opus-5-5 / medium |
| `implement.quota-tight` | claude / sonnet-5-5 / medium |
| `implement.accuracy-first` | claude / opus-5-5 / high |
| `review.audit` | codex / gpt-6.1-sol / high |
| `advisor.deep` | claude / opus-5-5 / high |
| `ui.computer-use` | codex / gpt-6.1-sol / medium |
| `grok.explore-only` | grok / grok-4.7 / medium |

## Changelog

### v0.1.16 — 2026-09-30

- Move `review.audit` from codex/gpt-6-astra/high to **codex/gpt-6.1-sol/high**, `ui.computer-use` from codex/gpt-6-astra/medium to **codex/gpt-6.1-sol/medium**, and `fanout.explore` from claude-opus-5-5/medium to **codex/gpt-6.1-sol/medium**. No op runs GPT-6 Astra now; it stays selectable by explicit flag.
- This is a best guess with low or medium confidence, made on the owner's direction that Astra ($10/$50 per MTok) does not justify its price for routine work. Two blind reviews (Claude Opus 5.5 and a Codex reviewer, 2026-09-29) found the public evidence too thin to prove any of these moves: GPT-6.1 Sol has one launch-day Artificial Analysis snapshot and vendor claims, and no independent audit-recall, computer-use-at-medium or navigation evidence.
- Why these three: Astra costs five times Sol per token, and on the vendor charts Astra medium costs more than $2 per task over GPT-6 Sol medium, more than the draft silent-failure cost. Opus 5.5 medium on `fanout.explore` costs $2.94 per task against $0.83 for Sonnet 5.5 medium on Anthropic's own curve. The reviewers' evals (seeded-defect review, bounded patches, cheap-worker tasks, computer use) are pending; they decide whether to keep these moves.
- Unchanged: `implement.standard`, `implement.accuracy-first` and `advisor.deep` (Opus 5.5), `recover.report`, `docs.lookup` and `implement.quota-tight` (Sonnet 5.5), `grok.explore-only` (grok-4.7).
- Catalog pin: **v0.5.10**.

### v0.1.15 — 2026-09-29

- **No routing change.** Every operating point expands exactly as in v0.1.14.
- Repins to catalog v0.5.10, which adds GPT-6.1 Sol, Xiaomi MiMo-V2.6 and launch-day board rows. GPT-6.1 Sol ($2/$10 per MTok, near-Astra by OpenAI's description) is a candidate for `review.audit` and `ui.computer-use`, which run GPT-6 Astra at $10/$50. It is not routed: independent low-effort evidence is still provisional, and the change needs owner approval.
- Catalog pin: **v0.5.10**.

### v0.1.14 — 2026-09-29

- Move `recover.report` and `docs.lookup` from claude-sonnet-5/low to **claude-sonnet-5-5/low**, and `implement.quota-tight` from claude-sonnet-5/low to **claude-sonnet-5-5/medium**. Rule 1: take the newest model in the cheapest tier that clears the bar.
- Evidence (catalog v0.5.9): AA Intelligence Index v4.3.2 has Sonnet 5.5 at low at 36 for $0.41/task, against Sonnet 5 at max at 38.2 for $5.09/task. AA says its runs used a pre-release deployment.
- `implement.quota-tight` uses medium because vendor Terminal-Bench 4.0 shows Sonnet 5.5 at low at 20.0%, against 28.8% at medium. Opus 5.5 leads Sonnet 5.5 at low (38.5%) and medium (57.6%) on that board; Sonnet 5.5 passes it only at max, at a higher cost per task.
- `scripts/recommend_ops.py` returns INSUFFICIENT_EVIDENCE for 9 of 10 ops, as it does on plain `origin/main`. This change rests on the tier rule and the boards above, not on a recommender result.
- Every Opus, Astra and Grok op is unchanged.
- Catalog pin: **v0.5.9**.

### v0.1.13 — 2026-09-23

- **No routing change.** Every operating point expands exactly as in v0.1.12.
- `op-requirements.json` pins `price_as_of`, so recommender output no longer depends on the run date. `review.audit`'s different-vendor constraint is marked as an owner decision pending (`constraint_decision`).
- The recommender keeps a tied incumbent and breaks other ties by expected cost. It uses the published pass@4 to calibrate retries and re-prices promotional costs at the horizon rate. It treats independent boards without an effort label as blocking disagreements, and can take lane quota availability from clawmeter as input.
- Three independent Claude Opus 5.5 review rounds (2026-09-23) signed off on releasing this with no routing change. The only benchmark-driven question left open is `review.audit` (Gemini 3.8 Flash vs GPT-6 Astra). It needs op-level evidence, such as a seeded-defect review oracle.
- Catalog pin: **v0.5.9**.

### v0.1.12 — 2026-09-23

- Move `grok.explore-only` from grok-4.6/high to **grok-4.7/medium**. On 2026-09-23 the authenticated grok CLI offers only grok-4.7, so the grok-4.6 arm could no longer be dispatched. Rule 1 picks grok-4.7 as the only newest GA model in the lane, at the default effort (medium). An independent Claude Opus 5.5 review signed this off in both rounds.
- No other routing change. `scripts/recommend_ops.py` now ranks by expected cost per task, with evidence gates, confidence intervals, a price horizon and robustness sweeps. The review found defects that block any move it would drive: the tie-break rule, an unwired pass@k field, wall-clock price dates, and board rows with no effort recorded. They were fixed in v0.1.13.
- Catalog pin: **v0.5.7**.

### v0.1.11 — 2026-09-22

- Move `implement.standard` and `fanout.explore` from claude-sonnet-5/medium to **claude-opus-5-5/medium**. Sonnet 5 at max effort (its best) scores below Opus 5.5 at medium on every independent board, at a higher cost per task: AA Intelligence Index v4.3.2 38.2 at $5.09/task vs 51.2 at $1.34; vals.ai Terminal-Bench 4 8.1% vs 61.6% (both at max).
- Add `op-requirements.json` (DRAFT): the owner-set inputs for each op (which benchmarks count as evidence, allowed efforts, quality bar, constraints). `scripts/recommend_ops.py` derives each op's model from it and the catalog. It also names the missing evidence wherever the data cannot decide.
- Unsettled, so unchanged, with the reason in `known_gaps`:
  - `recover.report`, `docs.lookup`, `implement.quota-tight`: no independent low-effort evidence exists.
  - `review.audit`: "checker at least as strong as maker" and "different family" conflict while Opus 5.5 is the strongest maker.
  - `ui.computer-use`: no shared OSWorld harness covers Claude and GPT-6.
- Catalog pin: **v0.5.7**.

### v0.1.10 — 2026-09-22

- Move `grok.explore-only` from grok-4.5 to **grok-4.6** / high. grok-4.6 is the newest GA Grok model, the grok CLI default, and the catalog's `grok` family default. There is no same-snapshot quality comparison with grok-4.5 (AA v4.2: grok-4.6 51 at high).
- Correct the `pack.json` description, which still described v0.1.8 (catalog v0.5.4).

### v0.1.9 — 2026-09-22

- Move `advisor.deep` (sonnet-5/high) and `implement.accuracy-first` (codex gpt-6-astra/high) to **claude-opus-5-5 / high**. Evidence, all in catalog v0.5.5:
  - AA Intelligence Index v4.3.2 (grade B, one snapshot): Opus 5.5 57.6 at max, 54 at high ($1.82/task), 51.2 at medium. Fable 5.1 53.4, GPT-6 Astra 52.7, Opus 5 50.8 (all at max). Sonnet 5 is not in the top 32.
  - vals.ai Terminal-Bench 4.0 (grade C): Opus 5.5 61.6%, GPT-6 Astra 57.1%, Fable 5.1 49.5%, Opus 5 45.5%, Sonnet 5 8.1%.
  - Vendor effort curves (grade C): Terminal-Bench 4.0 at high, Opus 5.5 64.2% for $3.88/task vs GPT-6 Astra 57.9% for $7.21/task.
- `implement.accuracy-first → review.audit` now crosses model families (Claude implements, Codex audits). Before this change it was a same-arm edge that waspflow skipped.
- `evidence_confidence` stays **medium**: the independent evidence is one AA snapshot and one secondary board, with no local eval.
- The Sonnet 5 ops are unchanged. No benchmark compares Sonnet 5 with Opus 5.5 on bounded edits or reading tasks.
- Catalog pin: **v0.5.5**.

### v0.1.8 — 2026-09-09

- Move Codex ops to GA **gpt-6-astra** per owner model policy (retire gpt-5.6-sol): `review.audit` and `implement.accuracy-first` to effort **high** (never xhigh/max by default), `ui.computer-use` to effort **medium** (mechanical/implementation-shaped work). Trigger: `waspflow doctor`'s stale-edge warning on the `preferred_over` entry below, surfaced after gpt-6-astra reached GA.
- Retire the `gpt-5.6-luna over gpt-5.4-mini` `preferred_over` edge — it was authored rot-aware and the owner policy no longer prefers any 5.x model. No replacement edge added: the catalog's gpt-6 family has only `gpt-6-astra` as GA, no cheap-tier gpt-6 model yet, so there is nothing to prefer over gpt-5.6-luna without inventing evidence.
- `evidence_refs` re-pointed at existing catalog rows for gpt-6-astra (`performance/openai-gpt-6-astra-launch-2026-09`, `performance/terminal-bench-4-astra-audit-2026-09`, `pricing/openai-api-2026-07`, `pricing/codex-credits-2026-07`). `evidence_confidence` held at **medium**, not raised — the model/effort swap is owner-policy + GA-status driven, not new local evidence (the cited terminal-bench-4 audit row is itself grade C / `comparable: false`).
- Catalog pin carries forward unchanged from v0.1.7: **v0.5.4**.

### v0.1.7 — 2026-09-05

- Pin catalog **v0.5.4**. Operating-point recommendations are unchanged.

### v0.1.6 — 2026-08-02

- Pin catalog **v0.5.3** after the GPT-5.6 Codex effort-tier value-claim check.

### v0.1.5 — 2026-07-11

- Refresh `review.audit` to Codex **gpt-5.6-sol** / xhigh.

### v0.1.4 — 2026-07-09

- Pin catalog **v0.5.2**. Top-3 ops: `evidence_confidence: medium` (not high); local rows are harness smoke only.

### v0.1.4 — 2026-07-09

- Pin catalog to **`data-model-catalog-v0.5.2`** (was v0.3.0).
- Evidence refs for Sonnet ops cite digitized effort curves (`anthropic-sonnet5-digitized-2026-07`).
- Validator now enforces: unique op ids, escalate graph, `expands_to` vs capabilities, catalog:// and source:// resolvability, pack.json pin agreement.

### v0.1.0 — 2026-07-09

- Initial 10 operating points from expert recommendation (README previously said 8).
- Pins `model-catalog@data-model-catalog-v0.3.0`.
