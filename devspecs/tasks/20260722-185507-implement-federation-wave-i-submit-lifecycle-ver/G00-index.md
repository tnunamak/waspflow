# Task 20260722-185507-implement-federation-wave-i-submit-lifecycle-ver

## Task
Implement Federation Wave I submit lifecycle, version compatibility, uploader, Git capability discovery, credential-only tasks, and one-time-code affordances

## Status
packed

## Series
G

## Profile
code-change

## Created At
2026-07-22T18:55:07Z

## Original Query
Implement Federation Wave I submit lifecycle, version compatibility, uploader, Git capability discovery, credential-only tasks, and one-time-code affordances

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-185507-implement-federation-wave-i-submit-lifecycle-ver`

## Resources
- `task.json`
- `G01-map-current-wire-and-ui-contracts-establish-regr-plan.md`
- `G01-map-current-wire-and-ui-contracts-establish-regr-result.md`
- `G02-implement-coordinator-and-daemon-protocol-change-plan.md`
- `G02-implement-coordinator-and-daemon-protocol-change-result.md`
- `G03-implement-requests-and-credential-ui-flows-plan.md`
- `G03-implement-requests-and-credential-ui-flows-result.md`
- `G04-run-daemon-backed-browser-journey-suite-screensh-plan.md`
- `G04-run-daemon-backed-browser-journey-suite-screensh-result.md`

## Task Slices
- G01: Map current wire and UI contracts; establish regression tests. Plan: `G01-map-current-wire-and-ui-contracts-establish-regr-plan.md`. Result: `G01-map-current-wire-and-ui-contracts-establish-regr-result.md`.
- G02: Implement coordinator and daemon protocol changes. Plan: `G02-implement-coordinator-and-daemon-protocol-change-plan.md`. Result: `G02-implement-coordinator-and-daemon-protocol-change-result.md`.
- G03: Implement Requests and credential UI flows. Plan: `G03-implement-requests-and-credential-ui-flows-plan.md`. Result: `G03-implement-requests-and-credential-ui-flows-result.md`.
- G04: Run daemon-backed browser journey, suite, screenshots, and report. Plan: `G04-run-daemon-backed-browser-journey-suite-screensh-plan.md`. Result: `G04-run-daemon-backed-browser-journey-suite-screensh-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `public`

## Likely Primary Files
- `lib/federation-submit.mjs` - lib/federation-submit.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, submit, tasks; fields path, title, body, symbol; query term match in path: federation; query term match in path: submit
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, submit, discovery, tasks; fields path, title, body, symbol; query term match in path: federation; query term match in body: code
- `lib/federation-harnesses.mjs` - lib/federation-harnesses.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, lifecycle, version, discovery; fields path, title, body; query term match in path: federation; query term match in body: code
- `lib/federation-daemon.mjs` - lib/federation-daemon.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, submit, version, tasks; fields path, title, symbol, body; query term match in path: federation; query term match in body: code
- `lib/federation-runtime.mjs` - lib/federation-runtime.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in path: time
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: capability
- `public/app.mjs` - public/app.mjs (javascript)
  Evidence: query term match in body: code; query term match in body: federation; query term match in body: lifecycle

## Likely Tests
- `tests/federation-daemon.test.mjs#L523` - POST /submit supervises the guided submit verb and GET /submit/status proxies its JSON lifecycle
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: lifecycle
- `tests/federation-coordinator.test.mjs#L343` - submit requires bearer token
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: submit
- `tests/federation-webui.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `lib/federation-harness-spec.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
None found in the initial preflight.

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `1f33e16` 2026-07-22 - feat(federation): support Git repository task sources
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`
- `0b4d4bd` 2026-07-22 - feat(federation): add live agent transcripts
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`
- `1e15edd` 2026-07-21 - fix(federation): close Wave C evidence gates
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Graduation gates: what actually passes; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > User guide: guided CLI (2026-07-21 UX pass, updated same day — GET /roster auto-fetch — see FEDERATION_V0_UX_REPORT.md) > Advanced: raw, flag-driven bins (unchanged, still fully supported); Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Graduation gates: what actually passes lines 645-668; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence lines 1157-1235; authority prior: current intent anchor because current decision context is present

## Freshness Warnings
These on-disk paths match the task wording but were not present in the indexed candidate set. Treat them as stale-index risk, not proof that the initial pack is wrong.

- `docs/design/FEDERATION_GIT_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, git

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

- On-disk paths matched the task but were not indexed [medium, freshness]
  Agent check: Inspect the warned files or refresh the index before trusting missing context.
  Evidence: `docs/design/FEDERATION_GIT_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, git
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
- found 7 likely primary file(s)
- found 4 likely test file(s)
- found 3 related Git receipt(s)
- 1 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `G01-map-current-wire-and-ui-contracts-establish-regr-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `G01-map-current-wire-and-ui-contracts-establish-regr-result.md` or `ds task checkpoint`.
