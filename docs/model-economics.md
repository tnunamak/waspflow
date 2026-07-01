# Model economics — cost/task × pass-rate per effort (the data behind model selection)

**Why this exists.** Choosing an agent model is a *marginal-return* decision, not a "which is best" one.
Vendor blurbs say "fastest" / "more efficient"; those don't let you decide. The **(cost-per-task, pass-rate%)
per effort level** does: you can see that a jump from `high`→`xhigh` may cost 2× for +3 points, so you only pay
for it when those 3 points are load-bearing (e.g. an adversarial judge on a risky change). This file is the
digitized source data + the derived heuristic. Update it when vendors publish new curves.

Source: Anthropic "Introducing Claude Sonnet 5" (2026-06-30) cost-performance charts (BrowseComp agentic search;
OSWorld-Verified computer use) + OpenAI GPT-5.5 evals (2026-04-23) + published API pricing (2026-06-30 snapshot).
Chart points are **digitized by eye** from the log-scale plots — treat as ±10% approximate, good enough for
tier decisions, not for billing.

## API token pricing (per 1M tokens, standard tier, 2026-06-30)

| Model | Input | Output | Notes |
|---|---|---|---|
| Opus 4.8 (`claude-opus-4-8`) | $5 | $25 | most capable; effort defaults `high` |
| Sonnet 5 (`claude-sonnet-5`) | $3 ($2 intro→Aug31) | $15 ($10 intro) | ≈Opus 4.8 at high effort, cheaper; effort defaults `high` |
| Haiku 4.5 (`claude-haiku-4-5`) | $1 | $5 | fastest, near-frontier |
| GPT-5.5 (`gpt-5.5`) | $5 | $30 | strongest agentic coder; more token-efficient than 5.4; 400K–1M ctx |
| GPT-5.4 (`gpt-5.4`) | $2.50 | $15 | prior GA |

## Cost-per-task × pass-rate by effort — BrowseComp (agentic search ≈ recon/judge reasoning proxy)

| model | effort | $/task | pass% | marginal %/$ vs prev effort |
|---|---|---|---|---|
| Sonnet 5 | low | ~1.5 | 60.0 | (base) |
| Sonnet 5 | med | ~3.5 | 71.5 | **5.75 — great value** |
| Sonnet 5 | high | ~7 | 79.5 | 2.29 — good |
| Sonnet 5 | xhigh | ~15 | 82.5 | **0.38 — poor** (only if pass is load-bearing) |
| Sonnet 5 | max | ~21 | 84.8 | **0.38 — poor** |
| Opus 4.8 | low | ~7 | 77.5 | (base) |
| Opus 4.8 | med | ~13 | 79.0 | 0.25 — poor (Opus med is bad value) |
| Opus 4.8 | high | ~15 | 82.0 | 1.50 — good |
| Opus 4.8 | xhigh | ~20 | 84.2 | 0.44 — poor |
| Opus 4.8 | max | ~25 | 84.3 | 0.02 — negligible |

## Cost-per-task × pass-rate by effort — OSWorld-Verified (computer use)

| model | effort | $/task | pass% | note |
|---|---|---|---|---|
| Sonnet 5 | low→max | 0.22→0.68 | 76.7→81.3 | effort scaling CHEAP here (all good marginal); Opus dominates on pass% |
| Opus 4.8 | low→max | 0.30→1.15 | 78.4→83.4 | best pass% at every tier, 1.4–1.7× the cost; effort cheap except max |
| Sonnet 4.6 | low→max | 0.30→0.52 | 71.5→78.4 | superseded by Sonnet 5 (strictly better) |

## Coding (SWE-bench class — the metric engineers trust)
Vendor coding numbers are less comparable (different SWE-bench variants), but for context:
- **GPT-5.5**: SWE-Bench Pro (public) 58.6%, Terminal-Bench 2.0 82.7% (SoTA), Expert-SWE 73.1%. "Strongest agentic
  coder; more token-efficient than 5.4." Claude Opus 4.7 scored 64.3% on that same SWE-Bench Pro public set
  (memorization caveat noted by the labs). No published Sonnet-5 SWE-bench-Verified-vs-effort curve yet — the
  Sonnet 5 announcement states its coding is "close to Opus 4.8."

## The heuristic (what to actually DO)

**Reasoning-heavy roles (recon, judge, planner) — use the BrowseComp curve:**
- **Default = Sonnet 5 @ high** (79.5% @ ~$7): it *beats* Opus 4.8 @ low at equal cost and ~matches Opus 4.8 @ high
  for less. Best value point on the curve (med→high still >2 %/$; high→xhigh collapses to 0.38 %/$).
- **Escalate to Sonnet 5 xhigh/max, or Opus 4.8 high, ONLY when the extra ~3–5 points is load-bearing** — i.e. a
  final adversarial judge on a RED/high-risk change, or a tie-break. Don't pay the xhigh premium on routine cuts.
- **Opus 4.8 @ med is a trap** (0.25 %/$) — if you're on Opus, use high, not med.
- Sonnet 5 max (84.8%) ≥ Opus 4.8 max (84.3%) and cheaper — for the absolute ceiling, Sonnet 5 max, not Opus max.

**Maker (produce a change): Sonnet 5 @ high** is the value default; the checker just has to out-rank it (below).

**Checker ≠ maker (the gate's hard rule):** the checker must be ≥ maker capability AND a **different lineage**
(gpt vs opus vs sonnet). So a Sonnet-5 maker pairs with an Opus-4.8 or GPT-5.5 checker; an Opus maker pairs with a
GPT-5.5 checker. The rank table in `lib/loop.sh` (`_loop_classify_model`) enforces this; this file explains the WHY
and the cost tradeoff behind each tier choice.

**Computer-use / browser roles:** Opus 4.8 leads on pass% at every effort and its effort scaling is cheap — use
Opus for browser-automation quality; drop to Sonnet 5 low only when cost dominates and ~77% is acceptable.
