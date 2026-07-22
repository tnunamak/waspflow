# Task 20260722-020101-implement-federation-wave-a-backend-observabilit A03 Plan

## Goal
Implement daemon endpoints and coordinator timestamps

## Description
Create a bounded implementation slice for `implement Federation Wave A backend observability`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `A00-index.md`
- `A03-implement-daemon-endpoints-and-coordinator-times-result.md`
- `task.json`
- `lib/federation-docker-backend.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-coordinator.mjs`
- `tests/federation-docker-backend.test.mjs`
- `tests/federation-harness-spec.test.mjs`
- `tests/federation-runtime.test.mjs#L56`
- `tests/federation-runtime.test.mjs`

## Starting Context
### Files to Inspect First
- `lib/federation-docker-backend.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-coordinator.mjs`

### Tests to Inspect First
- `tests/federation-docker-backend.test.mjs`
- `tests/federation-harness-spec.test.mjs`
- `tests/federation-runtime.test.mjs#L56`
- `tests/federation-runtime.test.mjs`
- `lib/federation-harness-spec.mjs`

## Expected Change Surface
- `lib/federation-docker-backend.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-coordinator.mjs`

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
- [ ] Update `A03-implement-daemon-endpoints-and-coordinator-times-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
