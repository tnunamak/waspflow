# Task 20260722-185507-implement-federation-wave-i-submit-lifecycle-ver G04 Plan

## Goal
Run daemon-backed browser journey, suite, screenshots, and report

## Description
Create a bounded implementation slice for `Implement Federation Wave I submit lifecycle, version compatibility, uploader, Git capability discovery, credential-only tasks, and one-time-code affordances`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `G00-index.md`
- `G04-run-daemon-backed-browser-journey-suite-screensh-result.md`
- `task.json`
- `lib/federation-submit.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-docker-backend.mjs`
- `public/app.mjs`
- `tests/federation-daemon.test.mjs#L523`

## Starting Context
### Files to Inspect First
- `lib/federation-submit.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-docker-backend.mjs`
- `public/app.mjs`

### Tests to Inspect First
- `tests/federation-daemon.test.mjs#L523`
- `tests/federation-coordinator.test.mjs#L343`
- `tests/federation-webui.test.mjs`
- `lib/federation-harness-spec.mjs`

## Expected Change Surface
- `lib/federation-submit.mjs`
- `lib/federation-coordinator.mjs`
- `lib/federation-harnesses.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-runtime.mjs`
- `lib/federation-docker-backend.mjs`
- `public/app.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Task-related on-disk paths may be missing from the indexed candidate set.
- Pack completeness is not high; verify the working set before editing.
- On-disk paths matched the task but were not indexed: Inspect the warned files or refresh the index before trusting missing context. Evidence: `docs/design/FEDERATION_GIT_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, git.
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
- [ ] Update `G04-run-daemon-backed-browser-journey-suite-screensh-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
