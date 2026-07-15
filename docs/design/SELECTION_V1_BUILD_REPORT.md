# Selection v1 build report

## Delivered

- Added `lib/selection.sh`: total cumulative disposition facts, quota predicate,
  availability observation, policy edge labels, cycle rejection, and the
  non-interactive selection menu/gate helpers.
- Added `WASPFLOW_SELECTION_GATE=off|warn|enforce` (default `warn`) and the
  `--auto`, `--ack-deprecated`, and `--accept-provider-default` surfaces to
  both `spawn` and `exec`. Exit 5 is documented as `selection_required`.
- Canonicalized policy `fallback` to internal `expands_to`, defaulted optional
  `requirements.ratified`, added v2 additive `ops resolve --json`, and loaded
  live ratified `preferred_over` edges.
- Persisted the selection-time quota envelope and verdict on spawned lane state
  and folded them into lane receipts. Lane receipts now identify
  `receipt_kind: "lane"`.
- Extracted `_receipts_append` and added one post-provider exec receipt with no
  lane identity, `receipt_kind: "exec"`, `exec_id`, `surface_exec`, invocation
  timestamps, result, and exit code.

## Disposition table

| Fact | Value in v1 |
| --- | --- |
| `included` | False only for `availability: unavailable`. |
| `warnings` | Cumulative: `availability_unknown`, `deprecated_by_edge`, and dormant `below_bar:<family>`. |
| `auto_selectable` | Requires available, own fallback, no quota filter, no bar failure, and either no deprecated edge or `--ack-deprecated`. |
| Explicit `--model` | Always proceeds after emitting applicable disposition warnings. |
| Gate | `warn` emits warnings and proceeds; `enforce` exits 5 only for a selector-generated arm that is not auto-selectable. |

## Migration inventory

| Surface | Treatment |
| --- | --- |
| README and skill examples | Added `--accept-provider-default` where the authored example intentionally retains the provider default; existing `--op` and explicit-model examples are unchanged. |
| User-facing docs | Updated first-run, SLVP, verification, synthesis, and input/red-team examples in the same way. |
| `demo --run` | Its printed spawn command now declares `--accept-provider-default`. |
| `scripts/live-soak.sh` | Added `--accept-provider-default`; it is intentionally a provider-default soak. |
| `scripts/live-smoke.sh` | Already has an explicit `--model`; unchanged. |
| `scripts/verify.sh` | Existing fixture spawns pin `WASPFLOW_SELECTION_GATE=off`; Selection v1 assertions explicitly cover the default-unset and enforce paths. |

The repository-wide invocation sweep also found historical report transcripts
and intentionally-invalid red-team examples. Explicit-model examples remain
valid; provider-default red-team commands were made explicit where executable.

## Verification transcript

```text
$ WASPFLOW_TEST_TMPDIR=$HOME/.tmp scripts/verify.sh
waspflow verify: ok
exit code: 0

$ WASPFLOW_SELECTION_GATE=enforce waspflow spawn --lane x -- "test"
selection required: choose an operating point (unranked across task families):
  … grouped operation menu …
other models: any --model <id> proceeds; <provider> enumeration: waspflow doctor --models
exit code: 5

$ waspflow ops resolve implement.standard --json | jq '.resolve_schema_version'
2
```

### Follow-up correction (2026-07-15)

Independent verification of a real exec found that the receipt builder used
`$10`, which Bash expands as `${1}0`, rather than the tenth positional
argument. The result field was therefore malformed as `<exec_id>0`. The builder
now uses `${10}` and the test pins `result == "succeeded"`, `exit_code == 0`,
and `quota_observation.reason == "not_sampled_for_exec"` exactly.

The follow-up Sol review also found quota predicate and disposition-test gaps.
The predicate now compares `window.utilization_pct`, requires reset credits to
be exactly zero or null, and treats raw provider arguments as scope-mismatched
for every provider. The test matrix now compares the complete expected
disposition object across all 108 cases and pins the quota boundaries.

The suite exercises 108 availability/bar/edge/stats/ack dispositions, quota
freshness/reset-credit/empty-window guards, fallback-only resolution, A>B>C
edge labels, cycle rejection, default warn/enforce behavior, and both receipt
shapes. `bash -n` was run over every touched shell file.

## Confidence and known gaps

High confidence in the pure policy and receipt contracts: they are deterministic
and covered hermetically in `scripts/verify.sh`. Medium confidence in live
provider hand-driving: provider CLIs were not invoked against a billed account
for this implementation run. The selection gate intentionally fails closed for
an operation whose provider enumeration is unknown, so a live `--auto` proof
requires the stubbed-provider fixture or an available provider catalog.

No stats-frontier activation, bar ratification, or escalation behavior was
introduced.
