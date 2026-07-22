# Task 20260722-033259-fix-federation-wave-c-evidence-gate-across-daemo

## Task
Fix Federation Wave C evidence gate across daemon, UI, isolation, and live verification

## Status
packed

## Series
C

## Profile
code-change

## Created At
2026-07-22T03:32:59Z

## Original Query
Fix Federation Wave C evidence gate across daemon, UI, isolation, and live verification

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-033259-fix-federation-wave-c-evidence-gate-across-daemo`

## Resources
- `task.json`
- `C01-map-http-ui-test-contracts-and-prove-defects-plan.md`
- `C01-map-http-ui-test-contracts-and-prove-defects-result.md`
- `C02-implement-daemon-api-caching-error-and-test-isol-plan.md`
- `C02-implement-daemon-api-caching-error-and-test-isol-result.md`
- `C03-implement-ui-state-polling-and-rendering-fixes-plan.md`
- `C03-implement-ui-state-polling-and-rendering-fixes-result.md`
- `C04-run-live-e2e-browser-journey-suite-report-and-co-plan.md`
- `C04-run-live-e2e-browser-journey-suite-report-and-co-result.md`

## Task Slices
- C01: Map HTTP/UI/test contracts and prove defects. Plan: `C01-map-http-ui-test-contracts-and-prove-defects-plan.md`. Result: `C01-map-http-ui-test-contracts-and-prove-defects-result.md`.
- C02: Implement daemon API, caching, error and test isolation fixes. Plan: `C02-implement-daemon-api-caching-error-and-test-isol-plan.md`. Result: `C02-implement-daemon-api-caching-error-and-test-isol-result.md`.
- C03: Implement UI state, polling, and rendering fixes. Plan: `C03-implement-ui-state-polling-and-rendering-fixes-plan.md`. Result: `C03-implement-ui-state-polling-and-rendering-fixes-result.md`.
- C04: Run live E2E, browser journey, suite, report, and commit. Plan: `C04-run-live-e2e-browser-journey-suite-report-and-co-plan.md`. Result: `C04-run-live-e2e-browser-journey-suite-report-and-co-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `docs`

## Likely Primary Files
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, gate, daemon, live; fields path, title, body, symbol; query term match in path: federation; query term match in body: daemon
- `lib/federation-daemon.mjs` - lib/federation-daemon.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, daemon; fields path, title, symbol, body; query term match in path: daemon; query term match in path: federation
- `lib/federation-harnesses.mjs` - lib/federation-harnesses.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, evidence, isolation, live; fields path, title, body; query term match in path: federation; query term match in body: evidence
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, gate, live, verification; fields path, title, body; query term match in path: federation; query term match in body: across
- `lib/federation-pull-internals.mjs` - lib/federation-pull-internals.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: evidence
- `lib/federation-submit.mjs` - lib/federation-submit.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: fix

## Likely Tests
- `tests/federation-daemon.test.mjs` - tests/federation-daemon.test.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, daemon; fields path, title, test_name, body; query term match in path: daemon; query term match in path: federation
- `tests/federation-coordinator.test.mjs#L217` - claim an already-CLAIMED task with a live lease is rejected
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: live
- `tests/federation-docker-backend.test.mjs#L32` - sanitizedEnv strips SSH agent and DOCKER_HOST exactly
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation

## Likely Docs / Plans / Config
- `docs/design/FEDERATION_WAVEB_REPORT.md` - Federation Wave B — Product UI Report
  Evidence: section-packed context: Federation Wave B — Product UI Report > Delivered; Federation Wave B — Product UI Report > Verification; Federation Wave B — Product UI Report > Wave A integration decisions; indexed section match: Federation Wave B — Product UI Report > Data contracts and compatibility lines 23-33; Federation Wave B — Product UI Report > Verification lines 34-40; anchor-first ranking: score 24.000; matches federation, wave, daemon, live; fields path, title, heading, body

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `305e039` 2026-07-21 - feat(federation): add Wave A observability receipts
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`
- `4afda53` 2026-07-21 - feat(federation): Wave B product IA — Contribute/Requests/Activity/Settings/Help (lane output)
  Matched paths: `docs/design/FEDERATION_WAVEB_REPORT.md`, `lib/federation-daemon.mjs`, `tests/federation-daemon.test.mjs`
- `04f55f8` 2026-07-21 - feat(federation): complete Wave 2 onboarding and sbx setup
  Matched paths: `lib/federation-daemon.mjs`, `lib/federation-docker-backend.mjs`, `tests/federation-daemon.test.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Autonomous fix loop: entrypoints, headless execution, and real containment results > Real containment results from graduation gates B, C, E, F, G, run against a live sandbox; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence lines 1157-1235; authority prior: current intent anchor because current decision context is present
- `docs/design/FEDERATION_V0_UX_REPORT.md` - Federation v0 UX report — the guided CLI layer
  Evidence: section-packed context: Federation v0 UX report — the guided CLI layer; Federation v0 UX report — the guided CLI layer > What was built (cumulative across both revisions); Federation v0 UX report — the guided CLI layer > First independent review (Fable), and fixes applied (carried over from the prior revision); indexed section match: Federation v0 UX report — the guided CLI layer > What was built (cumulative across both revisions) lines 45-54; Federation v0 UX report — the guided CLI layer > Independent verification (reproduced, not trusted) > The default `join -> contribute` journey, live, with zero manual `trust` calls lines 140-167; authority prior: current intent anchor because current decision context is present

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

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
- Pack completeness is not high; verify the working set before editing.

## Confidence Summary
- Primary file confidence: high
- Test coverage confidence: high
- Docs/config coverage confidence: medium
- Git receipt confidence: high
- Noise risk: medium
- Pack completeness: medium

Why:
- found 6 likely primary file(s)
- found 3 likely test file(s)
- found 3 related Git receipt(s)
- 2 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `C01-map-http-ui-test-contracts-and-prove-defects-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `C01-map-http-ui-test-contracts-and-prove-defects-result.md` or `ds task checkpoint`.
