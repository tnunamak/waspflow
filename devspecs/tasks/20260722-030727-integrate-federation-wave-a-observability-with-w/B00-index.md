# Task 20260722-030727-integrate-federation-wave-a-observability-with-w

## Task
integrate Federation Wave A observability with Wave B product UI

## Status
packed

## Series
B

## Profile
code-change

## Created At
2026-07-22T03:07:27Z

## Original Query
integrate Federation Wave A observability with Wave B product UI

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-030727-integrate-federation-wave-a-observability-with-w`

## Resources
- `task.json`
- `B01-reconcile-daemon-api-and-test-helper-conflicts-plan.md`
- `B01-reconcile-daemon-api-and-test-helper-conflicts-result.md`
- `B02-verify-contracts-document-decisions-and-commit-m-plan.md`
- `B02-verify-contracts-document-decisions-and-commit-m-result.md`

## Task Slices
- B01: reconcile daemon API and test helper conflicts. Plan: `B01-reconcile-daemon-api-and-test-helper-conflicts-plan.md`. Result: `B01-reconcile-daemon-api-and-test-helper-conflicts-result.md`.
- B02: verify contracts, document decisions, and commit merge. Plan: `B02-verify-contracts-document-decisions-and-commit-m-plan.md`. Result: `B02-verify-contracts-document-decisions-and-commit-m-result.md`.

## Relevant Map Areas
- `docs`
- `lib`
- `tests`

## Likely Primary Files
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: product
- `lib/federation-harnesses.mjs` - lib/federation-harnesses.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: product

## Likely Tests
- `tests/federation-harness-spec.test.mjs` - tests/federation-harness-spec.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation
- `tests/federation-harnesses.test.mjs` - tests/federation-harnesses.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: product
- `lib/federation-harness-spec.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `tests/federation-webui.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
- `docs/design/FEDERATION_WAVEB_REPORT.md` - Federation Wave B — Product UI Report
  Evidence: section-packed context: Federation Wave B — Product UI Report > Delivered; Federation Wave B — Product UI Report > Data contracts and compatibility; Federation Wave B — Product UI Report > Verification; indexed section match: Federation Wave B — Product UI Report > Data contracts and compatibility lines 23-33; Federation Wave B — Product UI Report > Verification lines 34-40; anchor-first ranking: score 24.000; matches federation, wave, product; fields path, title, heading, body
- `docs/design/FEDERATION_WAVEA_REPORT.md` - Federation Wave A report
  Evidence: section-packed context: Federation Wave A report; Federation Wave A report > Scope; Federation Wave A report > Shared result metadata; indexed section match: Federation Wave A report > Scope lines 3-10; Federation Wave A report > Shared result metadata lines 62-88; anchor-first ranking: score 24.000; matches federation, wave; fields path, title, heading, body
- `docs/design/FEDERATION_WAVE2_REPORT.md` - Federation Wave 2 Report
  Evidence: section-packed context: Federation Wave 2 Report > Result; Federation Wave 2 Report > Main implementation surfaces; Federation Wave 2 Report > Constraint noted; indexed section match: Federation Wave 2 Report > Result lines 6-34; Federation Wave 2 Report > Main implementation surfaces lines 35-45; anchor-first ranking: score 24.000; matches federation, wave; fields path, title, heading, body
- `docs/design/FEDERATION_PRODUCT_V1_PRD.md` - Waspflow Federation — Product v1 PRD ("sellable" bar)
  Evidence: section-packed context: Waspflow Federation — Product v1 PRD ("sellable" bar) > The six pillars (all required for v1) > P3 — Trust & control; Waspflow Federation — Product v1 PRD ("sellable" bar) > Build plan; Waspflow Federation — Product v1 PRD ("sellable" bar) > Horizon (v2+, owner-directional 2026-07-21 — shapes v1 architecture, NOT v1 scope); indexed section match: Waspflow Federation — Product v1 PRD ("sellable" bar) > The six pillars (all required for v1) > P3 — Trust & control lines 34-41; Waspflow Federation — Product v1 PRD ("sellable" bar) > Build plan lines 66-73; anchor-first ranking: score 24.000; matches federation, wave, product; fields path, title, heading, body

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `305e039` 2026-07-21 - feat(federation): add Wave A observability receipts
  Matched paths: `docs/design/FEDERATION_WAVEA_REPORT.md`, `lib/federation-coordinator.mjs`, `lib/federation-harnesses.mjs`
- `04f55f8` 2026-07-21 - feat(federation): complete Wave 2 onboarding and sbx setup
  Matched paths: `docs/design/FEDERATION_WAVE2_REPORT.md`, `tests/federation-webui.test.mjs`
- `78a1f04` 2026-07-21 - feat(federation): let contributors choose claimable tasks
  Matched paths: `lib/federation-coordinator.mjs`, `tests/federation-webui.test.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Claude Code auth: a real product tradeoff, not a default we silently picked; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge); Federation v0 UAT report — Docker Sandboxes backend > Owner handoff: what's left after the autonomous fix loop; indexed section match: Federation v0 UAT report — Docker Sandboxes backend lines 1-32; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; authority prior: current intent anchor because current decision context is present

## Known Knowns
- The preflight found likely primary implementation files.
- The preflight found likely behavior/test artifacts.
- Git receipts provide historical trust evidence for packed paths.

## Known Unknowns
- Pack completeness is not high; verify the working set before editing.

## Confidence Summary
- Primary file confidence: high
- Test coverage confidence: high
- Docs/config coverage confidence: high
- Git receipt confidence: high
- Noise risk: medium
- Pack completeness: medium

Why:
- found 2 likely primary file(s)
- found 4 likely test file(s)
- found 3 related Git receipt(s)
- 1 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `B01-reconcile-daemon-api-and-test-helper-conflicts-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `B01-reconcile-daemon-api-and-test-helper-conflicts-result.md` or `ds task checkpoint`.
