# Selection v1 — candidate set, truth table, forced-choice gate

Status: REWORKED through two sol review rounds. Round 1: NEEDS-REWORK, 7 P0 + 3 P1 +
1 nit — all folded; the doctrine violation in finding 4 conceded outright. Round 2:
8 FIXED / 3 PARTIAL + 3 new P0 + 1 P1 — all folded (cumulative-facts disposition model;
exit code 5 = selection_required, usage errors stay 1; shared lane-less receipt
primitive with receipt_kind discriminator; quota empty-windows guard; unset-env default
test; cause-matched retry escapes; flag-conflict matrix). Final gate: sol reviews doc +
implementation together at PR. Implements Phase 2 of
`MODEL_SELECTION_CONTROL_LOOP.md`. Escalation is Phase 3. Builds on shipped Phase 1
(`docs/design/SCHEMAS_V1.md`).
Created: 2026-07-15

## Ground truth

- **The stats frontier is EMPTY** (102/102 catalog rows `comparable: false`, sol
  re-verified live). Selection v1 is fallback-only end to end. Stats-driven dispositions
  are SPECIFIED but DORMANT; activating them is gated on the owner's admission gate AND a
  separate sol review of scalarization/adjacency — not in this build.
- **Bars are non-executable today**: the bar input is always `unratified` in v1 and can
  only ever produce warn-level effects. Ratification is machine-readable policy data (see
  schema), never code.
- **Doctrine (hardened per sol finding 4): explicit user choice always proceeds.** An
  explicit `--model` is warned on edge/bar hits but NEVER stopped and never requires
  acknowledgment. Acknowledgment gates exist only for SELECTOR-generated choices
  (`--auto` landing on a warned arm). The only hard block in the system remains Phase 1's
  scope-matched live-negative availability row.

## Candidate set (fallback-only)

```
candidates = policy_fallback_arms(all ops, or the one op given)
           ∪ {the explicitly requested arm, when --model given}
  each row an ARM (provider, model, effort, mode, billing_path, endpoint_profile) —
  not a bare model (Phase 1 Arm identity is load-bearing for quota/availability scope)
  filtered by: availability tri-state (unknown never excludes)
  annotated by: quota, billing path, evidence confidence, edge/bar dispositions
```

- **Honesty about enumeration (sol finding 7):** the table can only list what policy
  names or the caller requests. Available-but-uncatalogued models (local Qwen, brand-new
  release) do NOT appear as rows — they are never *blocked* (the standing guarantee), and
  the table ends with a footer: `other models: any --model <id> proceeds; <provider>
  enumeration: waspflow doctor --models` . The earlier claim that they "always enter the
  table" was wrong and is withdrawn.
- **Quota predicate (sol finding 5, fully specified):** an arm is hard-filtered from
  AUTO-SELECTION ONLY (never from the table, never from explicit use) when ALL of:
  (a) its `billing_path` is subscription-class (`chatgpt_subscription`,
  `subscription_env_heuristic`, `oauth_env_heuristic`);
  (b) the provider's live QuotaObservation has `state: ok` and `fetched_at` ≤ 10 min old;
  (c) the provider's `windows` array is NON-EMPTY and every window reports
  `utilization ≥ 100` (an empty array can never satisfy the filter — sol round-2:
  the envelope validator permits empty arrays, which must not vacuously pass "every");
  (d) `reset_credits_available` is 0 or null (a positive credit count defeats the filter —
  Phase 1 carries this field precisely for this);
  (e) the invocation's scope is not mismatched (a `--profile`/raw-args invocation may bill
  differently; its quota is `unknown`).
  Anything short of all five → annotate, never filter. Forecast/projection NEVER filters.
  **The selection-time QuotaObservation and the predicate verdict are persisted to lane
  state at spawn** (`selection_quota_observation`, `selection_quota_filtered`) and flow
  into Receipt v1 — the observation that shaped selection must survive, not just the
  finalize-time snapshot.

## The truth table (total by construction — sol finding 1)

Inputs are per-arm, each with a closed domain — totality is by construction (three
independent fact functions, each total over its inputs), and a seeded-fixture test
enumerates the full cross-product (3 availability × 3 bar × 3 edge × 2 stats = 54
combinations) asserting all three facts for every one:

- `availability ∈ {available, unknown, unavailable}` — `not_applicable` (no `--model`)
  never reaches the table: there is no arm to rank; the gate path handles it (sol: the
  4th state now has a defined home).
- `bar ∈ {clears, fails, unratified}` (v1 runtime: always `unratified`)
- `edge ∈ {preferred, deprecated_by_edge, none}` — computed from `preferred_over` edges
  AFTER cycle/chain resolution (below); a node in a chain gets ONE label: deprecated if
  ANY live edge points at it, else preferred if it points at another candidate.
- `stats ∈ {eligible, none}` (v1 runtime: always `none`)

**Dispositions are cumulative facts, not one exclusive rule** (sol round-2 P0: an
exclusive first-match scheme let `--ack-deprecated` launder a bar failure). Each arm gets
three independently-computed facts:

- `included`: false ONLY when `availability == unavailable` (evidence shown). Everything
  else is included.
- `warnings[]`: ACCUMULATE — `availability_unknown` (when unknown),
  `deprecated_by_edge` (when edged), `below_bar:<family>` (dormant, when bar fails).
  Every applicable warning is emitted; none suppresses another.
- `auto_selectable`: true only when ALL hold — `availability == available`; not quota-
  filtered; `edge != deprecated_by_edge` OR the caller passed `--ack-deprecated`;
  `bar != fails` (an ack NEVER overrides a bar — the two are independent facts);
  and (v1) the arm is the given op's own fallback. Dormant refinement: when
  `bar == clears AND stats == eligible`, ranking within auto-selectable arms uses stats.

The 54-combination cross-product test asserts all three facts per combination — and
additionally sweeps ack state (108 assertions total), pinning sol's laundering case:
`{available, bar=fails, edge=deprecated_by_edge}` + `--auto --ack-deprecated` stays
NOT auto-selectable with BOTH warnings present. Ungoverned arms (no edge, unratified
bar, no stats): included, no warnings, auto-selectable iff the op's own fallback —
never "ungoverned → exclude".

### `preferred_over` edge schema (sol finding 3 — it must exist to be computable)

New OPTIONAL top-level policy array (absent today ⇒ `edge == none` for every arm, which
is exactly v1 runtime — the column is computable from day one because absence is a
defined value):

```json
"preferred_over": [
  { "prefer": {"provider":"codex","model":"gpt-5.6-luna"},
    "over":   {"provider":"codex","model":"gpt-5.4-mini"},
    "reason": "owner 2026-07-10: never 5.4",
    "ratified": true }
]
```

Loader validation: edges with `ratified: false` are ignored with a warning; cycles
rejected at load (error names the cycle); an edge whose `prefer` side is itself
deprecated by another edge still deprecates its `over` target (labels per node, above).
Ratification state is a JSON FIELD, not a comment (sol: `// UNRATIFIED` was invalid
JSON) — same pattern for `requirements.ratified` below.

## The forced-choice gate — two stages, no interactivity (sol findings 2, 9)

**waspflow never prompts on stdin.** All callers are treated as non-TTY agents: every
gate outcome is a deterministic exit code + a complete retry command. No confirm
prompts, no EOF ambiguity, nothing to recover via wait/revise (which require a lane that
doesn't exist yet — sol verified).

Stage semantics (fixing the "elicits first, then ranks" contradiction — the pre-choice
listing is a MENU grouped by task family, explicitly unranked; ranking exists only
WITHIN an op once the task is known):

Exit-code contract (sol round-2 P0 — existing meanings must not be reused: `1` is
argument/usage error, `2` is completed-with-failed-contract, `3` is spawn's
launched-but-submission-unconfirmed, `4` is stall): **`5` = `selection_required`** —
nothing was launched; choose an arm and re-run. Invalid flag combinations die with `1`
like every other usage error.

- **Stage 1 — no `--op`, no `--model`** (gate in `enforce` mode): exit 5, print the op
  MENU (one line per op: id, task/constraint, fallback arm, quota annotation) + the
  footer + the three escapes. Nothing is ranked across task families — there is no task
  yet, so no bar/edge context to rank with (review-#3 P0 #5 preserved).
- **Stage 2 — `--op` given**: candidates = that op's fallback arm + any explicit
  overrides, dispositions per truth table. Without `--auto`: if the op's fallback is
  cleanly auto-selectable (rule 6, its own fallback, not filtered) it is USED — this is
  today's behavior, unchanged. If it is warned/filtered (deprecated edge, quota
  predicate, unknown availability), exit 5 with the disposition and escapes MATCHED TO
  THE CAUSE (sol round-2 P1): deprecated edge → `--auto --ack-deprecated`; quota-filtered
  or unknown availability → `--model <id>` (explicit proceeds) or
  `--accept-provider-default` — never a suggested retry that would fail identically.
- **`--auto`**: requires `--op` (exit 1, usage error, otherwise). Takes the op
  fallback if auto-selectable; else exit 5 as above. Flag conflicts all die with 1:
  `--auto --model`, `--auto --accept-provider-default`, `--model
  --accept-provider-default` are each contradictions (one selector, one arm source). `--auto` is the SELECTOR path —
  distinct from dormant stats auto-select (rule 5), which is a future ranking refinement
  of the same path, not a separate flag.
- **All-unknown candidate set** (e.g. no enumeration source at all): nothing is
  auto-selectable → `--auto` exits 5 listing the unknowns; explicit `--model` and
  `--accept-provider-default` both proceed (doctrine).
- **`--accept-provider-default`**: proceeds with no model arg; receipt gains
  `model_default` (+ `effort_default` when effort unset — sol nit, both pinned in tests).
- **Explicit `--provider` conflicting with the op's fallback provider** (sol finding 8's
  cross-provider trap, verified against `ops_apply_to_spawn` explicit-flags-win): if the
  caller gives `--op X --provider Y` where Y ≠ X's fallback provider and no `--model`,
  die with exit 1 ("op implement.standard resolves codex/gpt-5.6-terra; --provider claude
  contradicts it — give --model too, or drop one") — never import a model id across
  providers.

## Migration (sol finding 8 — behavior-preserving)

`WASPFLOW_SELECTION_GATE=off|warn|enforce`, default **`warn`** for one release:
- `warn`: bare spawns behave exactly as today plus ONE stderr line whose suggested
  replacement is **`--accept-provider-default`** (the behavior-preserving translation —
  never an invented `--op`, which would change the arm). Choosing a real op is human/agent
  judgment, prompted by the line but not encoded in it.
- `off`: today's behavior, no warning (escape hatch during soak).
- `enforce`: the gate above. Default flips only by owner decision after soak.
Call sites: every doc/README/skill example gains `--op` or an explicit arm (these SET the
example, so choosing ops there is correct — they're authored, not translated);
`demo --run` and `scripts/live-soak.sh`'s intentional provider-default Grok spawn use
`--accept-provider-default` explicitly. Test fixtures: existing spawn tests pin
`WASPFLOW_SELECTION_GATE=off` (behavior-pinning), and NEW tests cover `warn` (line
present, spawn proceeds), `enforce` (each stage/exit code), AND the UNSET-variable case
asserting the default is `warn` (sol round-2: mode-pinned tests alone cannot detect an
accidental default flip; only an unset-env test can).

## Policy schema: requirements + fallback (sol finding 6 — canonicalization)

- Loader canonicalizes at read time: a row may carry `expands_to` (old name) or
  `fallback` (new name) — **same shape, one canonical internal form (`expands_to`)**.
  Both present and identical → fine; both present and DIFFERENT → load error naming the
  op (never a silent pick). Downstream code (`ops_apply_to_spawn`, resolve) continues to
  read the canonical field only — a fallback-only row therefore resolves fully.
- `requirements` block optional, carries `"ratified": false` by default
  (machine-readable); the resolver ignores `requirements` entirely while the frontier is
  empty. Placeholder values (`performance_axis`, `bar_tier`) ship unratified and
  non-load-bearing.
- `ops resolve --json`: emits **both** `resolve_schema_version: 2` AND the unchanged v1
  fields including canonical `expands_to` — v2 is strictly additive (new keys:
  `requirements`, `selection` disposition block). No negotiation needed because v1
  consumers read v1 fields that remain present and identical; the version key exists so a
  FUTURE breaking change has an anchor. This guarantee (v2 always emits canonical
  `expands_to`) is the compat contract, stated explicitly per sol.

## exec — receipt via a shared lane-less primitive (sol findings 10 + round-2 P0)

exec gains the same gate (`off|warn|enforce` + `--op`/`--auto`/`--accept-provider-default`)
and emits a durable receipt. Implementation shape per sol round 2 — the shipped
`artifacts_emit_receipt_v1` is lane-coupled (reads lane state, writes the lane-dir copy,
stamps `receipt_emitted`) and CANNOT serve exec, and mutating the shipped identity fields
to null is not additive. Instead:

- **Extract the append primitive**: `_receipts_append <json>` — the validate-non-empty +
  flock + single-printf + fd-close block from Phase 1, shared verbatim by both builders.
- **Keep the lane builder unchanged** (same output, now calling the primitive).
- **New exec builder**: emits `schema_version: 1` rows with additive discriminator
  `receipt_kind: "exec"` (lane rows gain `receipt_kind: "lane"` — additive; consumers
  that predate the key see unchanged lane rows), `exec_id` (uuid, the invocation
  identity), `lane`/`lane_uuid` ABSENT (not null — absence is the additive form),
  arm + billing + availability as computed at invocation, `stats_eligible: false` with
  reason `surface_exec`, verify block `{state: "skipped"}`, timestamps
  `{invoked_epoch, completed_epoch, wall_seconds}`, result `succeeded|failed` + exit
  code. Idempotence: the builder runs once in exec's single code path after the provider
  returns (no retry loop exists in exec; if one is added, `exec_id` dedups downstream).
- No lane-dir copy (there is no lane dir); `receipts.jsonl` is the only destination.

The billing guard is untouched (exec already runs provider preflight — sol verified
`lib/exec.sh:56`). Rationale unchanged: Phase 1's eligibility mechanism exists precisely
so weaker-attestation rows can be durable without polluting stats.

## What this build does NOT include

Escalation (Phase 3). Stats-frontier activation (dormant rules 4–5 + deferred sol gate).
Bar/requirements ratification (owner, via policy data). Behavior changes for explicit
`--model` callers beyond warnings. Any learned component. Interactive prompts of any kind.

## Testing (extends scripts/verify.sh)

54-combination cross-product through a seeded policy fixture (every combination reaches
exactly one disposition; the conflict cases sol constructed are named assertions);
edge-chain labeling (A>B>C: B deprecated) and cycle rejection at load; quota predicate
five-condition matrix incl. the reset-credits false-block and stale-fetched_at false-pass
cases, plus persistence of the selection-time observation into lane state and receipt;
gate stages × modes × exit codes (0/1/5 pinned; 5 documented as selection_required), incl. cross-provider `--op`/`--provider`
conflict; dual-shape loader (old, new, both-same, both-different→error);
`ops resolve --json` v2 additive assertion (v1 fields byte-identical); exec receipt line
(receipt_kind exec, exec_id present, lane keys absent, surface_exec reason) + lane rows
carry receipt_kind lane; `model_default`+`effort_default` both present
for provider-default spawns; existing spawn tests pinned `off` + new `warn`/`enforce`
coverage.

## Ratification (owner)

- `requirements` placeholders and any future `preferred_over` edges: `ratified: true` is
  the owner's act, in policy data.
- The `warn` → `enforce` default flip after soak.
- Admission gate for the first `comparable: true` arm-group (separate process).
