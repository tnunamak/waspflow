# Task 20260722-020101-implement-federation-wave-a-backend-observabilit

## Task
implement Federation Wave A backend observability

## Status
packed

## Series
A

## Profile
code-change

## Created At
2026-07-22T02:01:01Z

## Original Query
implement Federation Wave A backend observability

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-wavea`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-wavea/devspecs/tasks/20260722-020101-implement-federation-wave-a-backend-observabilit`

## Resources
- `task.json`
- `A01-map-receipt-capture-schemas-and-test-isolation-plan.md`
- `A01-map-receipt-capture-schemas-and-test-isolation-result.md`
- `A02-implement-receipt-capture-and-audience-split-plan.md`
- `A02-implement-receipt-capture-and-audience-split-result.md`
- `A03-implement-daemon-endpoints-and-coordinator-times-plan.md`
- `A03-implement-daemon-endpoints-and-coordinator-times-result.md`
- `A04-add-tests-report-full-verification-and-commit-plan.md`
- `A04-add-tests-report-full-verification-and-commit-result.md`

## Task Slices
- A01: Map receipt capture, schemas, and test isolation. Plan: `A01-map-receipt-capture-schemas-and-test-isolation-plan.md`. Result: `A01-map-receipt-capture-schemas-and-test-isolation-result.md`.
- A02: Implement receipt capture and audience split. Plan: `A02-implement-receipt-capture-and-audience-split-plan.md`. Result: `A02-implement-receipt-capture-and-audience-split-result.md`.
- A03: Implement daemon endpoints and coordinator timestamps. Plan: `A03-implement-daemon-endpoints-and-coordinator-times-plan.md`. Result: `A03-implement-daemon-endpoints-and-coordinator-times-result.md`.
- A04: Add tests, report, full verification, and commit. Plan: `A04-add-tests-report-full-verification-and-commit-plan.md`. Result: `A04-add-tests-report-full-verification-and-commit-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `docs`

## Likely Primary Files
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, backend; fields path, title, body; query term match in path: backend; query term match in path: federation
- `lib/federation-runtime.mjs` - lib/federation-runtime.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, backend; fields path, title, body, symbol; query term match in path: federation; query term match in body: backend
- `lib/federation-pull-internals.mjs` - lib/federation-pull-internals.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: backend
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: implement

## Likely Tests
- `tests/federation-docker-backend.test.mjs` - tests/federation-docker-backend.test.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, backend; fields path, title, test_name, body; query term match in path: backend; query term match in path: federation
- `tests/federation-harness-spec.test.mjs` - tests/federation-harness-spec.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation
- `tests/federation-runtime.test.mjs#L56` - SandboxBackend base methods throw NotImplementedError, never silently no-op
  Evidence: relationship expansion: source_manifest_loss_safe_preserved; anchor-first ranking: score 24.000; matches federation, backend; fields path, body, title, test_name; query term match in path: federation
- `tests/federation-runtime.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `lib/federation-harness-spec.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend; Federation v0 UAT report — Docker Sandboxes backend > What was built; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend lines 1-32; Federation v0 UAT report — Docker Sandboxes backend > What was built lines 261-279; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; authority prior: current intent anchor because current decision context is present

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `ca8ba10` 2026-07-20 - fix(federation): DockerSbxBackend reproduced the sbx run/exec/rm bugs PR #15 already fixed
  Matched paths: `lib/federation-docker-backend.mjs`, `tests/federation-docker-backend.test.mjs`
- `4bc5f57` 2026-07-21 - fix(federation): wait for sandbox readiness after sbx run --detached
  Matched paths: `lib/federation-docker-backend.mjs`, `tests/federation-docker-backend.test.mjs`
- `632e701` 2026-07-20 - feat(federation): requester submit + executor pull CLIs (slices 3-4 of full loop)
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-pull-internals.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UX_REPORT.md` - Federation v0 UX report — the guided CLI layer
  Evidence: section-packed context: Federation v0 UX report — the guided CLI layer; Federation v0 UX report — the guided CLI layer > What was built (cumulative across both revisions); Federation v0 UX report — the guided CLI layer > The exact commands a non-technical contributor now runs; Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual; indexed section match: Federation v0 UX report — the guided CLI layer lines 1-23; Federation v0 UX report — the guided CLI layer > What was built (cumulative across both revisions) lines 45-54; Federation v0 UX report — the guided CLI layer > The exact commands a non-technical contributor now runs lines 55-87; authority prior: current intent anchor because current decision context is present
- `tests/federation-pull.test.mjs` - tests/federation-pull.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: backend

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
- found 4 likely primary file(s)
- found 5 likely test file(s)
- found 3 related Git receipt(s)
- 2 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `A01-map-receipt-capture-schemas-and-test-isolation-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `A01-map-receipt-capture-schemas-and-test-isolation-result.md` or `ds task checkpoint`.
