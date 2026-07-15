# Schemas v1 build report

## Built

- Provider model enumeration now emits the `source=` header protocol. Validation
  persists a v1 availability observation at spawn and blocks only a missing
  default-scope live result; cache and mismatched-scope negatives warn and pass.
- Spawn records requested Arm fields, BillingPath v1, best-effort Codex principal,
  denormalized operation families, UUID, and declared verify strength.
- Checkpoint verification now recognizes exit 126/127 as `invalid_oracle`, records
  checkpoint runs, and performs the fork-point detached-worktree baseline on a
  task failure.
- Final reap emits an append-only Receipt v1 plus the lane-local `receipt.json`.
  It includes quota attestation, receipt eligibility reasons, baseline state,
  harness hash, and old-lane fallbacks.
- Reusing a reaped lane name resets all Receipt/verification lifecycle state,
  including receipt idempotence, UUID-scoped checkpoint evidence, runtime
  attestation, baseline evidence, and availability state. The real spawn→reap→
  spawn-same-name→reap test proves two distinct receipt and lane UUIDs append.
- Added clawmeter healthy and partial-provider-error fixtures and hermetic schema
  assertions in `scripts/verify.sh`.

## Deviations and gaps

- `artifacts_emit_receipt_v1` runs after reap's existing verify promotion rather
  than inside the earlier report-finalization helper. This is intentional: receipt
  v1 requires the final verification state, and preserves the current split where
  `artifacts_finalize` handles report recovery while `artifacts_verify` owns the
  oracle outcome.
- The implementation treats any Codex `--arg` as scope-mismatched. This is the
  conservative v1 interpretation of raw passthrough: it may change the catalog,
  endpoint, or model after waspflow's bare enumeration.
- None.

## Final review dispositions

| Finding | Reproduced | Disposition | Coverage |
|---|---:|---|---|
| P1-1 stale outcome on name reuse | Yes | Reset outcome and all provenance at spawn | Real reused abandoned-name lane test |
| P1-2 append failure/fd leak | Yes (code-path audit) | Explicit lock/append checks; close dynamic fd; mark only after append | Full reap matrix |
| P1-3 legacy blank receipt | Yes (empty epoch jq semantics) | Null-safe epoch construction and non-empty JSON guard | Legacy appended-line jq test |
| P1-4 clawmeter shape drift | Yes | Validate consumed path types; drift is absent | Drifted fixture plus doctor warning |
| P1-5 baseline cleanup interruption | Yes (code-path audit) | Baseline runs in a trap-cleaned subshell | Baseline tests/full suite |
| P1-6 strength without oracle | Yes | Spawn rejects it; emission requires a real verify state | Parser/emission guard |
| nit-7 receipt mismatch | Yes | Reclassify verify-result.json too | pre_existing test |
| nit-8 OSS precedence | Yes | Track OSS separately; it wins over profile order | Billing classification path |
| nit-9 prepare invalid-oracle | Yes | Prepare remains prepare/timeout/infra | Checkpoint taxonomy tests |

## Focused verification transcript

```text
$ bash -n bin/waspflow lib/core.sh lib/billing.sh lib/artifacts.sh lib/providers/{codex,grok,claude}.sh lib/exec.sh
$ CODEX_MODELS_CACHE=<fake-cache> PATH=<no-codex> validate_model codex absent spawn default
waspflow: spawn: model 'absent' is missing from codex local_cache; cached negatives are unknown, proceeding.
state=unknown source=local_cache
$ PATH=<stub-codex-live-list> validate_model codex absent spawn default
waspflow: spawn: model 'absent' is unavailable for codex (source=live_query, observed_at=...).
waspflow:   valid models: listed
$ WASPFLOW_HOME=<tmp> ... artifacts_emit_receipt_v1 x verified
{ "schema_version": 1, "receipt_id": "…", "lane": "x",
  "quota_observation": {"schema_version":1,"state":"ok",…},
  "verify": {"verify_strength":"unknown","harness_hash":"sha256:…"} }
$ scripts/verify.sh
waspflow verify: ok
exit=0
# Includes spawned mcp-state → reap → same-name spawn → reap:
# receipts.jsonl has 2 lines with distinct receipt_id and lane_uuid.
```

## Confidence

High for the covered behavior: the complete deterministic suite exited 0 after
the checkpoint lifecycle, baseline taxonomy, invalid-oracle, provider protocol,
receipt, and existing regressions ran together. Residual risk is limited to live
provider/clawmeter schema drift, which v1 reports as an attestation state rather
than fabricating availability or quota data.
