# Data pack: `model-choice-policy`

**Policy**, not facts. Task-shaped **operating points** that expand to explicit
`provider` / `model` / `effort` / `mode` flags for `waspflow` (and any thin
resolver).

Separates from [`model-catalog`](../model-catalog/) so recommendations never
contaminate pricing or benchmark evidence.

## Get this pack

| | |
|---|---|
| **This version** | Tag **`data-model-choice-policy-v0.1.3`** |
| **Latest** | [releases](https://github.com/tnunamak/minnows/releases?q=data-model-choice-policy&expanded=true) |
| **Facts catalog** | [model-catalog](../model-catalog/) — pin is `catalog_ref` in the policy file |

```bash
./scripts/fetch-data-pack.sh model-choice-policy
# or
TAG=data-model-choice-policy-v0.1.3
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

Waspflow resolves from (first hit):

1. `$WASPFLOW_OPS_POLICY` (file path)
2. `$DATA_PACKS_HOME/model-choice-policy/operating-points.json`
3. Bundled `waspflow/data/model-choice-policy/operating-points.json`

## Operating points (10)

| Op | Provider / model / effort |
|----|---------------------------|
| `recover.report` | claude / sonnet-5 / low |
| `fanout.explore` | claude / sonnet-5 / medium |
| `docs.lookup` | claude / sonnet-5 / low |
| `implement.standard` | claude / sonnet-5 / medium |
| `implement.quota-tight` | claude / sonnet-5 / low |
| `implement.accuracy-first` | codex / gpt-5.6-sol / xhigh |
| `review.audit` | codex / gpt-5.5 / xhigh |
| `advisor.deep` | claude / sonnet-5 / high |
| `ui.computer-use` | codex / gpt-5.6-sol / high |
| `grok.explore-only` | grok / grok-4.5 / high |

## Changelog

### v0.1.3 — 2026-07-09

- Pin catalog to **`data-model-catalog-v0.5.1`** (was v0.3.0).
- Evidence refs for Sonnet ops cite digitized effort curves (`anthropic-sonnet5-digitized-2026-07`).
- Validator now enforces: unique op ids, escalate graph, `expands_to` vs capabilities, catalog:// and source:// resolvability, pack.json pin agreement.

### v0.1.0 — 2026-07-09

- Initial 10 operating points from expert recommendation (README previously said 8).
- Pins `model-catalog@data-model-catalog-v0.3.0`.
