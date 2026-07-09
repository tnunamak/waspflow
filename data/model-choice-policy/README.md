# Data pack: `model-choice-policy`

**Policy**, not facts. Task-shaped **operating points** that expand to explicit
`provider` / `model` / `effort` / `mode` flags for `waspflow` (and any thin
resolver).

Separates from [`model-catalog`](../model-catalog/) so recommendations never
contaminate pricing or benchmark evidence.

## Get this pack

| | |
|---|---|
| **This version** | Tag **`data-model-choice-policy-v0.1.0`** |
| **Latest** | [releases](https://github.com/tnunamak/minnows/releases?q=data-model-choice-policy&expanded=true) |
| **Facts catalog** | [model-catalog](../model-catalog/) (pin the `catalog_ref` in the policy file) |

```bash
./scripts/fetch-data-pack.sh model-choice-policy
# or
TAG=data-model-choice-policy-v0.1.0
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

## Changelog

### v0.1.0 — 2026-07-09

- Initial 8 operating points from expert recommendation.
- Pins `model-catalog@data-model-catalog-v0.3.0`.
