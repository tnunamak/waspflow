# Task 20260722-190800-complete-federation-linux-package-self-service-f H01 Plan

## Goal
make .deb staging reproducible and build with nfpm fallback

## Description
Create a bounded implementation slice for `complete Federation Linux package self-service flow`. This plan is grounded by the task index preflight, but it is not authoritative; confirm predicted files and tests before making edits.

## Resources
- `H00-index.md`
- `H01-make-deb-staging-reproducible-and-build-with-nfp-result.md`
- `task.json`
- `lib/federation-docker-backend.mjs`
- `lib/federation-auth-flow.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `tray/cmd/waspflow-federation-tray/main.go`
- `lib/federation-submit.mjs`
- `lib/federation-harness-spec.mjs`
- `tests/federation-auth-flow.test.mjs`

## Starting Context
### Files to Inspect First
- `lib/federation-docker-backend.mjs`
- `lib/federation-auth-flow.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `tray/cmd/waspflow-federation-tray/main.go`
- `lib/federation-submit.mjs`
- `lib/federation-harness-spec.mjs`

### Tests to Inspect First
- `tests/federation-auth-flow.test.mjs`
- `tests/federation-daemon.test.mjs#L582`
- `tests/federation-harnesses.test.mjs#L73`
- `tests/waspflow-federation-cli.test.mjs`

## Expected Change Surface
- `lib/federation-docker-backend.mjs`
- `lib/federation-auth-flow.mjs`
- `lib/federation-daemon.mjs`
- `lib/federation-harnesses.mjs`
- `tray/cmd/waspflow-federation-tray/main.go`
- `lib/federation-submit.mjs`
- `lib/federation-harness-spec.mjs`

## Out-of-Scope Areas
- Replanning the whole thread unless evidence says this slice should split or be superseded.
- Broad pack-ranking changes unless they are necessary for this task.
- Treating the generated context as complete without verification.

## Risks
- Task-related on-disk paths may be missing from the indexed candidate set.
- Pack completeness is not high; verify the working set before editing.
- On-disk paths matched the task but were not indexed: Inspect the warned files or refresh the index before trusting missing context. Evidence: `packaging/windows/winget/tnunamak.WaspflowFederation.installer.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow; `packaging/windows/winget/tnunamak.WaspflowFederation.locale.en-US.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow.
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
- [ ] Update `H01-make-deb-staging-reproducible-and-build-with-nfp-result.md` or run `ds task checkpoint`.

## Decision Gates
- Promote: the workspace was useful enough and misses are actionable.
- Improve: useful start, but incomplete/noisy enough to require template or retrieval changes.
- Rework: task workspace feels like planning overhead or fails to capture useful evidence.
- Rollback: workspace creates false confidence or worsens agent performance.
- Block: external input or a missing prerequisite prevents useful progress.
