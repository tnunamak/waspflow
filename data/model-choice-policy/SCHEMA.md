# model-choice-policy schema (v1)

Policy documents only. Every `expands_to` is a launch recipe, not a quality claim.

## `operating-points.json`

| Field | Role |
|-------|------|
| `id` | Stable op id (`task.constraint` style) |
| `task_family` | implement, review, recover, fanout, advisor, ui, docs |
| `constraint_family` | balanced, quota-tight, dollar-tight, latency-sensitive, accuracy-first |
| `expands_to` | `provider`, `model`, `effort`, `mode` / `service_tier` |
| `frontier_assumption` | Qualitative cost/quota/strength/evidence — **not** computed scores |
| `evidence_refs` | Strings pointing at catalog files or source ids |
| `use_when` / `avoid_when` | Human + agent guidance |
| `escalate_to` / `deescalate_to` | Other op ids |
| `known_gaps` | Explicit missing evidence |
| `override_policy` | Always `explicit_flags_win` in v1 |

Root also carries:

- `catalog_ref` — pinned model-catalog tag
- `policy_version` — pack semver
- `doctrine` — short non-goals

## `op-requirements.json` (DRAFT — owner review pending)

Human-set slots that let `scripts/recommend_ops.py` derive each op's arm
mechanically from the pinned catalog. The recommender only reads this file and
the catalog. It never edits `operating-points.json`. JSON Schema:
[`schemas/op-requirements-v1.schema.json`](schemas/op-requirements-v1.schema.json).
The script checks cross-file references at load time: op ids, metric ids,
provider restrictions, and constraint cycles.

| Field | Role |
|-------|------|
| `op` | An `operating-points.json` id. One entry per op. |
| `status` | `DRAFT` until the owner reviews the entry, then `REVIEWED`. |
| `evidence_metrics` | `metrics.json` ids whose scores measure this task. Rows are compared only inside one `comparability_group`. |
| `allowed_providers` | Lane CLIs (`claude`, `codex`, `grok`). Default `claude`, `codex`. `defaults.provider_restrictions` limits `grok` to `grok.explore-only`. |
| `allowed_efforts` | Effort ceiling. Default `low`/`medium`/`high`. `xhigh`/`max`/`ultra` are rejected unless the entry sets `effort_override_reason` (rule 1: never xhigh/max by default). |
| `bar` | `{type: frontier_best}` · `{type: within_points_of_best, points: N}` · `{type: at_least_op, op: <maker op>}`. Points are percentage points when every value in the group is a 0–1 fraction; otherwise they are in the metric's own unit. The best score is taken over candidate arms only. |
| `constraints` | `different_vendor_from:<op>` (models.json `provider`) or `different_model_family_from:<op>` (models.json `family`, which is scoped to tier or generation: `claude-opus` ≠ `claude-sonnet`). |
| `cost_basis` | `usd_per_task`. Only row-level `cost.unit == usd_per_task` values are used. List prices are never converted into per-task cost. |
| `min_evidence_grade` | Rows below this grade are dropped. Default `C`, so grade-D digitized charts and harness smoke do not count. |
| `rationale` | One line. The full reasoning is in the table below. |

`defaults.source_weights` is the trust weighting of stat sources, which is a human-set slot.
Independent boards (`third_party_board`, `third_party_eval`, `local_eval`) weigh 2. The
`other` type (secondary board reads), `vendor_table`, and `digitized_chart` weigh 1.
`vendor_cross_vendor_factor` (0.5) multiplies the weight of a vendor chart that ranks
a rival vendor's models.

### How the recommender decides

1. **Candidate arms.** An arm is a (model, effort) pair. The model must be `ga` and
   have a `tier`, its vendor must map to an allowed lane, and it must be the newest
   GA model in its (vendor, tier). "Newest" is read from the numeric version in the
   id, because the catalog has no release-date field. The effort must be allowed
   and valid on the lane's CLI surface (`claude_code`, `codex_cli`, `grok_cli`). If
   that surface is missing, the `api` surface is used and the output flags it.
   Constraint-excluded vendors and families are removed here.
2. **Per comparability group.** Rows need a concrete effort; the most recent
   `observed_at` wins for duplicates. `lower_better` scores are negated.
   `context_dependent` metrics and mixed-unit groups are skipped. A group needs at
   least two candidate arms to compare, except with an `at_least_op` bar, where the
   maker's score is the reference. The script marks priced arms dominated on
   (score, cost), computes the bar, and marks eligibility.
3. **Choice per group.** The cheapest eligible, undominated, priced arm wins. Ties
   go to the lower API list price (the cheaper tier), then the newer model.
4. **Aggregate.** An arm is RECOMMENDED only when all of these hold:
   - it wins more than half the weight of the decisive groups that contain it
     (a win is being the choice, or being eligible and no more expensive than the
     choice);
   - it also wins more than half the weight of the cross-model groups among them
     (a chart of one model's efforts picks an effort, not a model);
   - it fails no bar where present;
   - no other arm passes the same tests on disjoint evidence.

   Otherwise the op is INSUFFICIENT_EVIDENCE, and the output lists the exact
   (model, metric) scores or costs that would decide it. Confidence is `high` with
   ≥2 winning independent groups that compare ≥2 models and no losses, `medium`
   with one such group, and `low` otherwise.
5. **Constraints** resolve against the maker op's recommended arm. If the maker op
   is not RECOMMENDED, they resolve against its current `expands_to`, and the output
   says so. Ops are evaluated in dependency order; cycles are rejected.

### DRAFT entries and why

| Op | Evidence | Efforts | Bar | Why |
|----|----------|---------|-----|-----|
| `recover.report` | factual-error-rate (lower better), AA Intelligence Index v4.3.2 | low, medium | within 10 | Summaries must not invent facts. General capability is a weak second signal. Errors are cheap to fix, so the bar is wide. |
| `fanout.explore` | BrowseComp, Terminal-Bench 4.0, AA v4.3.2 | low, medium | within 10 | Scouts search and navigate; many run at once, so cost dominates. |
| `docs.lookup` | BrowseComp, factual-error-rate, HLE with tools | low, medium | within 10 | Find and cite: retrieval, factual accuracy, and tool-assisted QA. |
| `implement.standard` | TB 4.0, TB 2.1, FrontierCode main, DeepSWE (vendor + Datacurve), SWE-Bench Pro, CursorBench 4.0, AA Coding Agent Index | low, medium | within 5 | Default coding with a verify step. Rule 1: medium is the default ceiling. A verify step catches some misses, so 5 points. |
| `implement.quota-tight` | same as implement.standard | low, medium | within 10 | Small patches under quota pressure. `usd_per_task` is only a proxy for quota burn (doctrine 4: quota ≠ dollars). |
| `implement.accuracy-first` | same as implement.standard | low, medium, high | within 2 | Rework is costly, so high effort is allowed (rule 1: hard agentic work) and the bar is tight. |
| `review.audit` | TB 4.0, TB 2.1, FrontierCode main, DeepSWE, SWE-Bench Pro, CursorBench 4.0, AA v4.3.2 | low, medium, high | at least `implement.standard` | Rule 1: judged review allows high. Checker ≥ maker on shared evidence, and a different vendor from both implementers (vendor, not `family`, because `family` would let Sonnet check Opus). |
| `advisor.deep` | AA v4.3.2, HLE with tools, GDPval-AA v2.1, ARC-AGI-2 | low, medium, high | within 2 | No benchmark measures design advice. These use broad reasoning and knowledge work as proxies. Judged work, so high is allowed and the bar is tight. |
| `ui.computer-use` | OSWorld 2.0 (+ partial, strict), OSWorld-Verified, AutomationBench | low, medium | within 5 | Computer use is mechanical, so medium is the ceiling (as in v0.1.8). |
| `grok.explore-only` | AA v4.2, TB 2.1 | low, medium, high | within 10 | Visible exploration point only. It cannot resolve today: xAI rows have no `tier`, and grok-4.6 has no `grok_cli` surface. |
