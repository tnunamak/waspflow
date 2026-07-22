# Task 20260722-154338-federation-wave-g-eliminate-web-ui-render-churn

## Task
Federation Wave G: eliminate web UI render churn, harden identity sign-in/probe state, persist task execution logs

## Status
packed

## Series
E

## Profile
code-change

## Created At
2026-07-22T15:43:38Z

## Original Query
Federation Wave G: eliminate web UI render churn, harden identity sign-in/probe state, persist task execution logs

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-154338-federation-wave-g-eliminate-web-ui-render-churn`

## Resources
- `task.json`
- `E01-trace-state-apis-and-tests-establish-a-minimal-b-plan.md`
- `E01-trace-state-apis-and-tests-establish-a-minimal-b-result.md`
- `E02-implement-ui-identity-task-log-changes-with-regr-plan.md`
- `E02-implement-ui-identity-task-log-changes-with-regr-result.md`
- `E03-run-full-verification-real-flow-cancel-ui-screen-plan.md`
- `E03-run-full-verification-real-flow-cancel-ui-screen-result.md`

## Task Slices
- E01: Trace state, APIs, and tests; establish a minimal behavior plan. Plan: `E01-trace-state-apis-and-tests-establish-a-minimal-b-plan.md`. Result: `E01-trace-state-apis-and-tests-establish-a-minimal-b-result.md`.
- E02: Implement UI identity/task/log changes with regression tests. Plan: `E02-implement-ui-identity-task-log-changes-with-regr-plan.md`. Result: `E02-implement-ui-identity-task-log-changes-with-regr-result.md`.
- E03: Run full verification, real-flow cancel, UI screenshot checks, and write Wave G report. Plan: `E03-run-full-verification-real-flow-cancel-ui-screen-plan.md`. Result: `E03-run-full-verification-real-flow-cancel-ui-screen-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `docs`
- `public`

## Likely Primary Files
- `lib/federation-daemon.mjs` - lib/federation-daemon.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, identity, state, task; fields path, title, symbol, body; query term match in path: federation; query term match in body: execution
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, identity, state; fields path, title, body, symbol; query term match in path: federation; query term match in body: identity
- `lib/federation-pull-internals.mjs` - lib/federation-pull-internals.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, identity, task, execution; fields path, title, symbol, body; query term match in path: federation; query term match in body: execution
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: execution
- `lib/federation-submit.mjs` - lib/federation-submit.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: sign
- `public/app.mjs` - public/app.mjs (javascript)
  Evidence: query term match in body: execution; query term match in body: federation; query term match in body: identity

## Likely Tests
- `tests/federation-envelope.test.mjs#L42` - result execution_metadata is optional, signed when present, and structurally excludes identities
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: execution
- `tests/waspflow-federation-cli.test.mjs` - tests/waspflow-federation-cli.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: eliminate
- `tests/federation-daemon.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `tests/federation-webui.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Autonomous fix loop: entrypoints, headless execution, and real containment results; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence lines 1157-1235; authority prior: current intent anchor because current decision context is present
- `docs/design/FEDERATION_V0_UX_REPORT.md` - Federation v0 UX report — the guided CLI layer
  Evidence: section-packed context: Federation v0 UX report — the guided CLI layer; Federation v0 UX report — the guided CLI layer > The exact commands a non-technical contributor now runs; Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual; indexed section match: Federation v0 UX report — the guided CLI layer lines 1-23; Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual lines 88-127; authority prior: current intent anchor because current decision context is present

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `1e15edd` 2026-07-21 - fix(federation): close Wave C evidence gates
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`
- `305e039` 2026-07-21 - feat(federation): add Wave A observability receipts
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`
- `5be5d06` 2026-07-20 - feat(federation): guided CLI + GET /roster auto-fetch (owner decision)
  Matched paths: `docs/design/FEDERATION_V0_UAT_REPORT.md`, `docs/design/FEDERATION_V0_UX_REPORT.md`, `lib/federation-coordinator.mjs`

## Noise Risks
None found in the initial preflight.

## Freshness Warnings
These on-disk paths match the task wording but were not present in the indexed candidate set. Treat them as stale-index risk, not proof that the initial pack is wrong.

- `docs/design/FEDERATION_WAVEF_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave, sign

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

- On-disk paths matched the task but were not indexed [medium, freshness]
  Agent check: Inspect the warned files or refresh the index before trusting missing context.
  Evidence: `docs/design/FEDERATION_WAVEF_REPORT.md` - on-disk path matched task terms but was not in the indexed candidate set: federation, wave, sign
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

## Confidence Summary
- Primary file confidence: high
- Test coverage confidence: high
- Docs/config coverage confidence: high
- Git receipt confidence: high
- Noise risk: low
- Pack completeness: high

Why:
- found 6 likely primary file(s)
- found 4 likely test file(s)
- found 3 related Git receipt(s)

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `E01-trace-state-apis-and-tests-establish-a-minimal-b-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `E01-trace-state-apis-and-tests-establish-a-minimal-b-result.md` or `ds task checkpoint`.
