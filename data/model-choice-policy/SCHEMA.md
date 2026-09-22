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
