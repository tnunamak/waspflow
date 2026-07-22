# Task 20260722-033259-fix-federation-wave-c-evidence-gate-across-daemo C03 Plan

## Goal
Implement UI state, polling, and rendering fixes

## Description
Create a bounded implementation slice for `Fix Federation Wave C evidence gate across daemon, UI, isolation, and live verification`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `C00-index.md`
- `C03-implement-ui-state-polling-and-rendering-fixes-result.md`
- `task.json`
- `lib/federation-docker-backend.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`
- `tests/federation-daemon.test.mjs`
- `tests/federation-coordinator.test.mjs#L217`

## Starting Context
### Files to Inspect First
- `lib/federation-docker-backend.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`

### Tests to Inspect First
- `tests/federation-daemon.test.mjs`
- `tests/federation-coordinator.test.mjs#L217`
- `tests/federation-docker-backend.test.mjs#L32`

## Expected Change Surface
- `lib/federation-docker-backend.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Pack completeness is not high; verify the working set before editing.
- Prior checkpoint recorded a critical miss in a related area: Inspect the related area before assuming the initial pack is complete. Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated missed `lib/federation-daemon.mjs`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated missed `tests/federation-daemon.test.mjs`.
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
- [ ] Update `C03-implement-ui-state-polling-and-rendering-fixes-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
