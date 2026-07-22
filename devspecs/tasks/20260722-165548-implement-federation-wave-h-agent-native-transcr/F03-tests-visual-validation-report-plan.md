# Task 20260722-165548-implement-federation-wave-h-agent-native-transcr F03 Plan

## Goal
tests, visual validation, report

## Description
Create a bounded implementation slice for `Implement Federation Wave H agent-native transcripts, live tailing, uploads, network controls, task labels, collective activity, and settings honesty`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `F00-index.md`
- `F03-tests-visual-validation-report-result.md`
- `task.json`
- `lib/federation-daemon.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`
- `public/app.mjs`
- `tests/federation-coordinator.test.mjs#L217`
- `tests/federation-harnesses.test.mjs`
- `tests/federation-webui.test.mjs`

## Starting Context
### Files to Inspect First
- `lib/federation-daemon.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`
- `public/app.mjs`

### Tests to Inspect First
- `tests/federation-coordinator.test.mjs#L217`
- `tests/federation-harnesses.test.mjs`
- `tests/federation-webui.test.mjs`
- `tests/federation-daemon.test.mjs`

## Expected Change Surface
- `lib/federation-daemon.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-pull-internals.mjs`
- `lib/federation-submit.mjs`
- `public/app.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Task-related on-disk paths may be missing from the indexed candidate set.
- Pack completeness is not high; verify the working set before editing.
- On-disk paths matched the task but were not indexed: Inspect the warned files or refresh the index before trusting missing context. Evidence: `docs/design/FEDERATION_WAVEF_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave; `docs/design/FEDERATION_WAVEG_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave.
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
- [ ] Update `F03-tests-visual-validation-report-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
