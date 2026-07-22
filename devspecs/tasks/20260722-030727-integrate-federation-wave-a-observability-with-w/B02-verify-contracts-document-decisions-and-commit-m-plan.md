# Task 20260722-030727-integrate-federation-wave-a-observability-with-w B02 Plan

## Goal
verify contracts, document decisions, and commit merge

## Description
Create a bounded implementation slice for `integrate Federation Wave A observability with Wave B product UI`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `B00-index.md`
- `B02-verify-contracts-document-decisions-and-commit-m-result.md`
- `task.json`
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`
- `tests/federation-harness-spec.test.mjs`
- `tests/federation-harnesses.test.mjs`
- `lib/federation-harness-spec.mjs`
- `tests/federation-webui.test.mjs`
- `docs/design/FEDERATION_WAVEB_REPORT.md`
- `docs/design/FEDERATION_WAVEA_REPORT.md`

## Starting Context
### Files to Inspect First
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`

### Tests to Inspect First
- `tests/federation-harness-spec.test.mjs`
- `tests/federation-harnesses.test.mjs`
- `lib/federation-harness-spec.mjs`
- `tests/federation-webui.test.mjs`

## Expected Change Surface
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Pack completeness is not high; verify the working set before editing.
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
- [ ] Update `B02-verify-contracts-document-decisions-and-commit-m-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
