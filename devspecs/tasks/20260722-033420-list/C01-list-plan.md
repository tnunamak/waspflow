# Task 20260722-033420-list C01 Plan

## Goal
list

## Description
Create a bounded implementation slice for `list`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `C00-index.md`
- `C01-list-result.md`
- `task.json`
- `public/app.mjs`
- `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md`
- `docs/design/FEDERATION_VMVERIFY_REPORT.md`
- `docs/design/FEDERATION_WAVEA_REPORT.md`
- `tests/federation-webui.test.mjs`
- `lib/federation-coordinator.mjs`
- `docs/design/FEDERATION_WAVEB_REPORT.md`

## Starting Context
### Files to Inspect First
- `public/app.mjs`

### Tests to Inspect First
- No pack-ranked files. Verify checkpoint leads below or search before editing.

### Checkpoint Leads
Verify these prior checkpoint facts before widening search. They are not files the initial pack ranked as primary.
- `docs/design/FEDERATION_WAVEA_REPORT.md` [prior-source] - Verify this prior source lead before choosing an edit target.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated read `docs/design/FEDERATION_WAVEA_REPORT.md`
- `tests/federation-webui.test.mjs` [prior-test] - Verify this prior test lead before editing.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated read test `tests/federation-webui.test.mjs`
- `lib/federation-coordinator.mjs` [prior-noise] - Treat as possible noise or reference-only context unless this task verifies it.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated called distracting `lib/federation-coordinator.mjs`
- `docs/design/FEDERATION_WAVEB_REPORT.md` [prior-source] - Verify this prior source lead before choosing an edit target.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated read `docs/design/FEDERATION_WAVEB_REPORT.md`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated edited `docs/design/FEDERATION_WAVEB_REPORT.md`
- `public/app.mjs` [prior-source] - Verify this prior source lead before choosing an edit target.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated read `public/app.mjs`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031108Z_b02_validated edited `public/app.mjs`

## Expected Change Surface
- `public/app.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Relevant tests may be missing from the initial pack.
- Pack completeness is not high; verify the working set before editing.
- Prior checkpoint recorded distracting context: Keep that family as reference-only unless this task verifies it. Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated called distracting `lib/federation-coordinator.mjs`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated called distracting `lib/federation-harnesses.mjs`.
- Initial pack includes downgraded noise candidates; avoid editing them unless verification supports it.

## Success Criteria
- [ ] Primary implementation surface is verified before edits.
- [ ] Relevant tests are found or the test-surface miss is recorded.
- [ ] Changes stay inside the bounded slice.
- [ ] A checkpoint records actual files, tests, misses, noise, and decision.

## Tasks
- [ ] Inspect the predicted primary files.
- [ ] Inspect same-package, same-stem, or receipt-related tests.
- [ ] Refine the slice if context is incomplete.
- [ ] Implement the smallest useful change.
- [ ] Run focused validation.
- [ ] Update `C01-list-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
