# Task 20260722-165548-implement-federation-wave-h-agent-native-transcr

## Task
Implement Federation Wave H agent-native transcripts, live tailing, uploads, network controls, task labels, collective activity, and settings honesty

## Status
packed

## Series
F

## Profile
code-change

## Created At
2026-07-22T16:55:48Z

## Original Query
Implement Federation Wave H agent-native transcripts, live tailing, uploads, network controls, task labels, collective activity, and settings honesty

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-165548-implement-federation-wave-h-agent-native-transcr`

## Resources
- `task.json`
- `F01-daemon-stream-persistence-and-apis-plan.md`
- `F01-daemon-stream-persistence-and-apis-result.md`
- `F02-web-ui-workflows-plan.md`
- `F02-web-ui-workflows-result.md`
- `F03-tests-visual-validation-report-plan.md`
- `F03-tests-visual-validation-report-result.md`

## Task Slices
- F01: daemon stream persistence and APIs. Plan: `F01-daemon-stream-persistence-and-apis-plan.md`. Result: `F01-daemon-stream-persistence-and-apis-result.md`.
- F02: web UI workflows. Plan: `F02-web-ui-workflows-plan.md`. Result: `F02-web-ui-workflows-result.md`.
- F03: tests, visual validation, report. Plan: `F03-tests-visual-validation-report-plan.md`. Result: `F03-tests-visual-validation-report-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `public`

## Likely Primary Files
- `lib/federation-daemon.mjs` - lib/federation-daemon.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, task, collective, settings; fields path, title, symbol, body; query term match in path: federation; query term match in body: collective
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, live, network, task; fields path, title, body, symbol; query term match in path: federation; query term match in body: collective
- `lib/federation-pull-internals.mjs` - lib/federation-pull-internals.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: live
- `lib/federation-submit.mjs` - lib/federation-submit.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: collective
- `public/app.mjs` - public/app.mjs (javascript)
  Evidence: query term match in body: activity; query term match in body: collective; query term match in body: federation

## Likely Tests
- `tests/federation-coordinator.test.mjs#L217` - claim an already-CLAIMED task with a live lease is rejected
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: live
- `tests/federation-harnesses.test.mjs` - tests/federation-harnesses.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: live
- `tests/federation-webui.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `tests/federation-daemon.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
None found in the initial preflight.

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `b1f47bd` 2026-07-22 - fix(federation): resolve Wave G live UI findings
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `public/app.mjs`
- `1e15edd` 2026-07-21 - fix(federation): close Wave C evidence gates
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-pull-internals.mjs`
- `78a1f04` 2026-07-21 - feat(federation): let contributors choose claimable tasks
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `public/app.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Graduation gates: what actually passes; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > Owner handoff: what's left after the autonomous fix loop; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Auth architecture (tightened 2026-07-20) > Per-harness six-column proof matrix — updated with real owner live-UAT results lines 492-521; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence lines 1157-1235; authority prior: current intent anchor because current decision context is present
- `docs/design/FEDERATION_V0_UX_REPORT.md` - Federation v0 UX report — the guided CLI layer
  Evidence: section-packed context: Federation v0 UX report — the guided CLI layer > The exact commands a non-technical contributor now runs; Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual; Federation v0 UX report — the guided CLI layer > Independent verification (reproduced, not trusted) > The default `join -> contribute` journey, live, with zero manual `trust` calls; Federation v0 UX report — the guided CLI layer > First independent review (Fable), and fixes applied (carried over from the prior revision); indexed section match: Federation v0 UX report — the guided CLI layer lines 1-23; Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual lines 88-127; Federation v0 UX report — the guided CLI layer > First independent review (Fable), and fixes applied (carried over from the prior revision) lines 199-233; authority prior: current intent anchor because current decision context is present

## Freshness Warnings
These on-disk paths match the task wording but were not present in the indexed candidate set. Treat them as stale-index risk, not proof that the initial pack is wrong.

- `docs/design/FEDERATION_WAVEF_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave
- `docs/design/FEDERATION_WAVEG_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

- On-disk paths matched the task but were not indexed [medium, freshness]
  Agent check: Inspect the warned files or refresh the index before trusting missing context.
  Evidence: `docs/design/FEDERATION_WAVEF_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave; `docs/design/FEDERATION_WAVEG_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave
- Prior checkpoint recorded a critical miss in a related area [medium, checkpoint_fact]
  Agent check: Inspect the related area before assuming the initial pack is complete.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated missed `lib/federation-daemon.mjs`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated missed `tests/federation-daemon.test.mjs`
- Prior checkpoint recorded distracting context [low, checkpoint_fact]
  Agent check: Keep that family as reference-only unless this task verifies it.
  Evidence: task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated called distracting `lib/federation-coordinator.mjs`; task 20260722-030727-integrate-federation-wave-a-observability-with-w checkpoint cp_20260722T031100Z_b01_validated called distracting `lib/federation-harnesses.mjs`

## Known Knowns
- The preflight found likely primary implementation files.
- The preflight found likely behavior/test artifacts.
- Git receipts provide historical trust evidence for packed paths.

## Known Unknowns
- Task-related on-disk paths may be missing from the indexed candidate set.
- Pack completeness is not high; verify the working set before editing.

## Confidence Summary
- Primary file confidence: high
- Test coverage confidence: high
- Docs/config coverage confidence: low
- Git receipt confidence: high
- Noise risk: medium
- Pack completeness: medium

Why:
- found 5 likely primary file(s)
- found 4 likely test file(s)
- found 3 related Git receipt(s)
- 2 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `F01-daemon-stream-persistence-and-apis-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `F01-daemon-stream-persistence-and-apis-result.md` or `ds task checkpoint`.
