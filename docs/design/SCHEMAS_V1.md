# Versioned schemas v1 — Arm, AvailabilityObservation, BillingPath, QuotaObservation, Receipt

Status: REWORKED through two sol review rounds (2026-07-15). Round 1 (NEEDS-REWORK):
9 findings, all folded — load-bearing ones author-verified against code/CLI first.
Round 2: 5 FIXED / 4 PARTIAL / 4 new — all folded (surface_changed covers
revise-on-exited; codex billing precedence incl. OPENAI_API_KEY; baseline comparability
rule + rc-126/127 invalid_oracle; receipts append protocol; WASPFLOW_HOME; query_scope
domain; verify-state vs result vocabularies; single-operator auth-principal assumption
stated). Final gate: sol reviews doc + implementation together at PR.
Implements Phase 1b + 1d of `MODEL_SELECTION_CONTROL_LOOP.md`.
Created: 2026-07-15
Scope discipline: additive over existing lane state / receipts. No existing field renamed
or repurposed. Every schema carries `schema_version`; consumers ignore unknown fields.

## The honesty mechanism everything hangs on: `stats_eligible`

sol #4 finding 1 (P0): requested `(provider, model, effort)` does not pin the invocation —
provider defaults resolve differently over time, raw `--arg` passthrough can override
model/profile/endpoint after the recorded fields, a TUI lane can be recovered headlessly
mid-life, claude/grok cannot attest runtime settings, and the auth principal is an axis.

v1 does NOT try to close every axis. Instead: **receipts are always emitted, but a receipt
is flywheel/stats-eligible only when the axes were stable and attested.**

```json
"stats_eligible": false,
"ineligibility_reasons": ["raw_provider_args", "surface_changed", "attestation_missing"]
```

Reason vocabulary (v1): `raw_provider_args` (any `--arg` passthrough present),
`surface_changed` (ANY headless resume on a TUI lane — report recovery AND
`revise`-on-exited, `bin/waspflow:1068`, both trip it), `model_default` /
`effort_default` (empty ⇒ provider-resolved, unattested), `attestation_missing`
(`runtime_settings_state != observed`), `attestation_error`, `billing_path_unknown`,
`availability_scope_mismatched`, `verify_strength_unknown`. Empty array ⇔
`stats_eligible: true`. The flywheel consumes eligible receipts only; ineligible ones
still serve debugging and audit. This is cheaper and more honest than pretending to
resolve axes we cannot attest (claude/grok observed_model is `null`, recorded as such).

Stated assumption (not a reason code): waspflow is a single-operator tool; `auth_principal`
is recorded (or `null`) but principal changes do NOT affect eligibility in v1. Pooling
receipts across principals is a telemetry-era concern; local receipts share one operator.

## 1. Arm v1

```json
{
  "schema_version": 1,
  "provider": "codex",                    // claude | codex | grok
  "surface": "tui",                       // tui | headless — AT SPAWN; changes land in
                                          // ineligibility_reasons, not silent mutation
  "model": "gpt-5.6-terra",               // as passed; "" = provider default (verbatim)
  "effort": "high",                       // as passed; "" = provider default (verbatim)
  "mode": "standard",                     // op expands_to.mode / service_tier, else "standard"
  "billing_path": { … BillingPath v1 … },
  "endpoint_profile": "default",          // codex: --profile <name> | "oss" | "default"
  "raw_provider_args": false,             // true ⇒ the above may be overridden downstream
  "auth_principal": null                  // best-effort, cheap introspection only:
                                          // codex: `codex login status` account line if present;
                                          // claude/grok: null (no cheap surface) — never guessed
}
```

Requested vs attested: this is the REQUESTED arm. Attestation reuses the existing
runtime-settings receipt machinery; Receipt v1 carries both plus `stats_eligible`.

## 2. AvailabilityObservation v1 — tri-state, evidence-carrying, scope-honest

```json
{
  "schema_version": 1,
  "provider": "codex",
  "model": "gpt-5.6-terra",
  "state": "available",            // available | unavailable | unknown | not_applicable
  "evidence_source": "live_query", // live_query | local_cache | non_enumerable | none
  "query_scope": "default",        // default | mismatched | not_applicable —
                                   // mismatched when the invocation carries --profile /
                                   // --oss / -c config / raw provider args the enumeration
                                   // didn't reflect (codex enumerates the DEFAULT catalog
                                   // only: lib/providers/codex.sh runs bare
                                   // `codex debug models`); not_applicable for the
                                   // non_enumerable / none / no-model rows
  "observed_at": "2026-07-15T20:11:04Z",
  "detail": ""
}
```

**Decision matrix (Phase 1c enforces in `validate_model`):**

| evidence_source | query_scope | model listed? | state          | action                              |
|-----------------|-------------|---------------|----------------|-------------------------------------|
| live_query      | default     | yes           | available      | proceed                             |
| live_query      | default     | no            | unavailable    | **block, even explicit `--model`** — print evidence (live query, time, valid set) |
| live_query      | mismatched  | no            | unknown        | warn + proceed (the enumeration cannot speak for this invocation — sol #4 finding 2) |
| local_cache     | any         | yes           | available      | proceed (cache-positive trusted; a since-removed model fails loudly at the provider) |
| local_cache     | any         | no            | unknown        | **warn + proceed** — cached negative is never a block (fixes today's stale-cache hard-die in `lib/core.sh validate_model`) |
| non_enumerable  | —           | —             | unknown        | proceed silently (claude)           |
| none            | —           | —             | unknown        | proceed silently                    |
| (no `--model`)  | —           | —             | not_applicable | proceed (provider default; nothing to validate) |

- **Provider protocol** (sol #4 finding 3 — command substitution runs the function in a
  subshell, so a global set inside is lost): `${provider}_valid_models` output becomes
  line-1 header `source=live_query|local_cache|non_enumerable|none`, remaining lines the
  model list. Header survives command substitution; callers `head -1`/`tail -n +2`.
  All three providers + `validate_model` change together (one PR).
- Observation stamped on lane state (`model_validation_state/_source/_scope/_at`), flows
  into Receipt v1. `exec` is stateless — v1 prints the same warnings but records nothing;
  exec receipts are Phase 2's separate design (per review #3 P0 #5).
- TTLs/probe budgets for selection-time caching: Phase 2.

## 3. BillingPath v1

sol #4 finding 4 (P0, verified): `codex debug auth` does not exist; `codex login status`
prints e.g. "Logged in using ChatGPT" (text, cheap). Claude has more paths than two.
Enums widened; every value carries its evidence; `_env_heuristic` values never masquerade
as attestation.

```json
{ "schema_version": 1, "path": "chatgpt_subscription", "evidence": "codex_login_status_text", "detail": "Logged in using ChatGPT" }
```

| provider | path values | evidence rule |
|----------|------------|---------------|
| claude | `api_key` \| `auth_token` \| `bedrock` \| `vertex` \| `custom_base_url` \| `subscription_env_heuristic` \| `unknown` | `ANTHROPIC_API_KEY` → api_key; `ANTHROPIC_AUTH_TOKEN` → auth_token; `CLAUDE_CODE_USE_BEDROCK/VERTEX` → bedrock/vertex; `ANTHROPIC_BASE_URL` → custom_base_url; none of these set → `subscription_env_heuristic` (absence of overrides does NOT prove subscription — named accordingly) |
| codex | `chatgpt_subscription` \| `api_key` \| `api_key_env` \| `access_token_env` \| `oss_local` \| `scoped_unknown` \| `unknown` | Precedence, first match wins: (1) `--oss` → oss_local; (2) `--profile`/`-c`/raw args → `scoped_unknown` (login status can't speak for a non-default profile/endpoint); (3) `codex login status` text → chatgpt_subscription or api_key (attested, cheap); (4) `CODEX_ACCESS_TOKEN` set → access_token_env; (5) `OPENAI_API_KEY` set → api_key_env (the signal `lib/billing.sh:15` already warns on); (6) unknown |
| grok | `api_key_env` \| `oauth_env_heuristic` \| `unknown` | `XAI_API_KEY` → api_key_env; else oauth_env_heuristic |

`cost_currency` derivation: `chatgpt_subscription | subscription_env_heuristic |
oauth_env_heuristic → quota`; `api_key | auth_token | access_token_env | api_key_env →
usd`; `bedrock | vertex | custom_base_url | oss_local | scoped_unknown | unknown →
unknown`. Heuristic paths keep their derived currency (the evidence field preserves the
uncertainty); only `unknown`-currency receipts get the `billing_path_unknown`
ineligibility reason. Quota/dollar never merged.

## 4. QuotaObservation v1 — the clawmeter contract (Phase 1d)

Attestation only in Phase 1. sol #4 finding 8 (verified live): v0.27.6 can exit 0 with
valid JSON while one provider carries `usage.error`, `windows: null`, no forecast — so a
per-provider **envelope** is the unit, not bare fields:

```json
{
  "schema_version": 1,
  "state": "ok",              // ok | provider_error | stale | absent
  "reason": "",               // e.g. usage.error text, "clawmeter not on PATH", parse error
  "stale": false,             // .providers.<p>.usage.stale when present
  "source": "clawmeter@0.27.6",
  "observation": {            // null unless state == ok or stale
    "provider_key": "openai", // waspflow maps codex→openai, claude→claude
    "windows": [ { "name": "7d", "utilization_pct": 68, "resets_at": "…", "projected_pct": 494 } ],
    "reset_credits_available": 5,
    "fetched_at": "…"
  }
}
```

Contract paths consumed (pinned v0.27.6): `.providers.<p>.usage.{fetched_at, stale,
error}`, `.providers.<p>.usage.windows[].{name, display_name, utilization, resets_at}`,
`.providers.<p>.forecast.windows.<w>.projected_pct`,
`.providers.openai.usage.reset_credits.{available_count, fetched_at}`.

Failure semantics: never a spawn gate, never a fabricated zero. Contract tests run
against **committed fixtures** — one healthy shape AND one partial/error shape
(`usage.error` + `windows:null` + missing forecast); `doctor` runs the same jq assertions
against the live binary.

**Owner ask (Tim, owns clawmeter):** top-level `schema_version` in `--json`, bumped on
breaking changes. Until then: pin on `clawmeter --version` + shape-check; drift ⇒
`state: absent` + loud doctor warning.

## 5. Receipt v1

**Identity & durability** (sol #4 finding 7, verified — lane names are reusable after
reap, `bin/waspflow:252`): receipts are **append-only JSONL** in
`$WASPFLOW_HOME/receipts.jsonl` (survives lane-name reuse and lane cleanup; the
flywheel reads one file), plus a convenience copy `receipt.json` in the lane dir. Each
receipt: `receipt_id` (uuid), `lane_uuid` (new: uuid stamped at spawn), `waspflow_version`
(git describe at build/install; "dev" fallback). The reap-time finalize row keeps
`receipt_kind: "lane"`, preserving exactly one `lane` row per lane life. For an
escalated lane, that final row carries `segment: {index:<last>, closed_by:"reap"}`;
a never-escalated legacy lane keeps `segment: null`. An escalation-closing row uses
`receipt_kind: "lane_segment"` and
`segment: {index, closed_by:"escalation", transition:<uuid>}`; checkpoint verify runs
are recorded in `verify_runs[]` within that closing row. Consumers that include
segments key them by `(lane_uuid, segment.index)`; the lane directory's
`receipt.json` is always the latest row.

Append protocol: single `printf '%s\n'` of the complete line under `flock` on
`$WASPFLOW_LOCKS_DIR/receipts.lock` (the existing lock-dir pattern). Duplicate
protection is structural: `artifacts_finalize` is already idempotent (a set `result`
short-circuits), so the append runs at most once per lane life; `receipt_id` makes any
residual duplicate detectable downstream.

```json
{
  "schema_version": 1,
  "receipt_id": "…uuid…", "lane": "verify-split", "lane_uuid": "…uuid…",
  "waspflow_version": "…", "segment": null,
  "op": "code-review.default",          // "" for bare spawns (gap closes with Phase 2 forced choice)
  "task_family": "code-review",         // denormalized from policy AT SPAWN (policy files rotate)
  "constraint_family": "quality-first",
  "policy_version": "…", "catalog_ref": "…",
  "arm_requested": { … Arm v1 … },
  "arm_attestation": {
    "runtime_settings_state": "observed",   // observed | unknown | error
    "observed_model": "gpt-5.6-terra",      // codex: rollout; claude: session log
                                            // (model only); grok: session summary
                                            // (model + effort). Gap closed 2026-07-15;
                                            // claude observed_effort remains null.
    "observed_effort": "high"
  },
  "stats_eligible": true, "ineligibility_reasons": [],
  "availability": { … AvailabilityObservation v1 … },
  "quota_observation": { … QuotaObservation v1 envelope … },
  "verify": {
    "state": "passed",                      // existing verify-run vocabulary:
                                            // passed | failed | timeout | skipped
                                            // (lane RESULT keeps verified/verify_failed/… —
                                            // two vocabularies, not conflated)
    "failure_class": "none",                // EXTENDED vocabulary, see below
    "verify_strength": "declared:suite",    // declared:<suite|smoke> via --verify-strength; else
                                            // "unknown" — NEVER inferred from command text
    "harness_hash": "sha256:…",             // over prepare_command + "\n" + verify_command
    "test_files_changed": "false",          // existing tri-state heuristic, existing name —
                                            // NOT renamed to "integrity" (sol: that overclaims)
    "fork_point": "<sha or ''>",
    "baseline_oracle": { "ran": true, "state": "passed", "reason": "" },
    "verify_runs": [ { "kind": "checkpoint", "at": 1789, "state": "failed", "failure_class": "task" } ]
  },
  "timestamps": { "spawn_epoch": 1789000000, "finalize_epoch": 1789000342, "wall_seconds": 342 },
                                            // wall time INCLUDING idle/operator delay —
                                            // named honestly; execution latency needs
                                            // event-level data that doesn't exist yet
  "cost_observation": {
    "currency": "quota",                    // usd | quota | unknown (from billing_path)
    "amount": null,                         // no per-invocation metering exists in v1 —
    "attribution": "none",                  // never fabricated; window-delta is future work
    "evidence": "billing_path"
  },
  "result": "verified", "outcome": "harvested",
  "escalation_path": []                     // reserved; Phase 3 appends {from_arm, to_arm, trigger, at}
}
```

### Failure-class vocabulary completes review #3's taxonomy (sol #4 finding 5)

PR #7 shipped `none | task | prepare | timeout | infra`. Review #3 required
`pre_existing` and `invalid_oracle` (underscore literals throughout — one spelling) and
an agent-inaccessible baseline. This build closes that:

- **`invalid_oracle`**: the verify command itself exits 127 (command not found) or 126
  (not executable) — the only reliable signals for an arbitrary `bash -c` string; no
  attempt to parse "the executable" out of the command text. Split out of `infra` (which
  keeps cwd-missing; note today's code already maps exit 127 → infra,
  `lib/artifacts.sh:380` — that mapping moves to invalid_oracle).
- **`pre_existing`**: on a `task`-class CHECKPOINT failure where `fork_point` exists, run
  prepare+verify in an **ephemeral detached worktree at the fork point** (created at
  classification time — the agent never had access to it, which is what makes the baseline
  agent-inaccessible; deleted after). Comparability rule (sol round-2 finding 4): the
  reclassification to `pre_existing` requires the baseline run to reach a comparable
  TASK-class failure — the baseline verify command actually ran and failed. A baseline
  prepare failure, timeout, or infra error ⇒ `baseline_oracle.state: "inconclusive"` and
  the class stays `task`. Baseline passes ⇒ class stays `task`,
  `baseline_oracle.state: passed`. No fork point / non-isolated lane ⇒
  `baseline_oracle: {ran: false, state: "skipped", reason: "no_fork_point"}` — recorded,
  not guessed. Cost: one extra verify run, only on failure, only when classifiable.
- Legacy receipts/lanes with the five-class vocabulary remain valid v1 receipts
  (`baseline_oracle.ran: false`).

## What this doc does NOT decide

Selection (Phase 2), escalation mechanics (Phase 3), flywheel aggregation (Phase 4),
telemetry, exec receipts (Phase 2's separate design). The only spawn-blocking change
anywhere here is the scope-matched live-negative row — a strictly SMALLER block set than
today (cached negatives currently hard-die; they become warn-and-proceed).

## Ratification

- sol re-review of this rework before code (gate).
- Owner (Tim): clawmeter `schema_version` ask; `--verify-strength` flag naming if opinionated.
