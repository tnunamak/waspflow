# Task 20260722-142121-implement-federation-wave-f-critical-and-high-re

## Task
Implement Federation Wave F critical and high red-team findings

## Status
packed

## Series
D

## Profile
code-change

## Created At
2026-07-22T14:21:21Z

## Original Query
Implement Federation Wave F critical and high red-team findings

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-142121-implement-federation-wave-f-critical-and-high-re`

## Resources
- `task.json`
- `D01-audit-existing-ui-and-daemon-contracts-plan.md`
- `D01-audit-existing-ui-and-daemon-contracts-result.md`
- `D02-implement-consent-lifecycle-recovery-settings-se-plan.md`
- `D02-implement-consent-lifecycle-recovery-settings-se-result.md`
- `D03-run-ui-screenshots-tests-restart-daemon-report-a-plan.md`
- `D03-run-ui-screenshots-tests-restart-daemon-report-a-result.md`

## Task Slices
- D01: Audit existing UI and daemon contracts. Plan: `D01-audit-existing-ui-and-daemon-contracts-plan.md`. Result: `D01-audit-existing-ui-and-daemon-contracts-result.md`.
- D02: Implement consent, lifecycle, recovery, settings semantics. Plan: `D02-implement-consent-lifecycle-recovery-settings-se-plan.md`. Result: `D02-implement-consent-lifecycle-recovery-settings-se-result.md`.
- D03: Run UI screenshots, tests, restart daemon, report and commit. Plan: `D03-run-ui-screenshots-tests-restart-daemon-report-a-plan.md`. Result: `D03-run-ui-screenshots-tests-restart-daemon-report-a-result.md`.

## Relevant Map Areas
- `lib`
- `docs`
- `tests`

## Likely Primary Files
- `lib/federation-runtime.mjs` - lib/federation-runtime.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation; fields path, title, body; query term match in path: federation; query term match in body: implement
- `lib/federation-coordinator.mjs` - lib/federation-coordinator.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: implement
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: findings

## Likely Tests
- `tests/federation-harness-spec.test.mjs` - tests/federation-harness-spec.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: red
- `tests/federation-docker-hygiene.test.mjs` - tests/federation-docker-hygiene.test.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: red
- `lib/federation-harness-spec.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `tests/federation-runtime.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
- `docs/design/FEDERATION_WAVE2_REPORT.md` - Federation Wave 2 Report
  Evidence: indexed section match: Federation Wave 2 Report > Result lines 6-34; Federation Wave 2 Report > Main implementation surfaces lines 35-45; Federation Wave 2 Report > Constraint noted lines 66-72; anchor-first ranking: score 24.000; matches federation, wave; fields path, title, heading, body; query term match in path: federation
- `docs/design/FEDERATION_WAVEB_REPORT.md` - Federation Wave B — Product UI Report
  Evidence: section-packed context: Federation Wave B — Product UI Report > Delivered; Federation Wave B — Product UI Report > Data contracts and compatibility; Federation Wave B — Product UI Report > Confidence and remaining dependency; Federation Wave B — Product UI Report > Wave A integration decisions; indexed section match: Federation Wave B — Product UI Report > Delivered lines 5-8; Federation Wave B — Product UI Report > Delivered > Screens lines 9-18; Federation Wave B — Product UI Report > Confidence and remaining dependency lines 41-44; anchor-first ranking: score 24.000; matches federation, wave, high; fields path, title, heading, body
- `docs/design/FEDERATION_WAVEA_REPORT.md` - Federation Wave A report
  Evidence: section-packed context: Federation Wave A report; Federation Wave A report > Scope; Federation Wave A report > Private receipt; Federation Wave A report > Shared result metadata; indexed section match: Federation Wave A report > Scope lines 3-10; Federation Wave A report > Shared result metadata lines 62-88; Federation Wave A report > Daemon API for the UI > `GET /tasks/:digest` lines 143-157; anchor-first ranking: score 24.000; matches federation, wave; fields path, title, heading, body

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `305e039` 2026-07-21 - feat(federation): add Wave A observability receipts
  Matched paths: `docs/design/FEDERATION_WAVEA_REPORT.md`, `lib/federation-coordinator.mjs`, `lib/federation-docker-backend.mjs`
- `1e15edd` 2026-07-21 - fix(federation): close Wave C evidence gates
  Matched paths: `lib/federation-coordinator.mjs`, `lib/federation-docker-backend.mjs`
- `04f55f8` 2026-07-21 - feat(federation): complete Wave 2 onboarding and sbx setup
  Matched paths: `docs/design/FEDERATION_WAVE2_REPORT.md`, `lib/federation-docker-backend.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend > Owner UAT findings and fixes (2026-07-20, real sbx v0.35.0); Federation v0 UAT report — Docker Sandboxes backend > Claude Code auth: a real product tradeoff, not a default we silently picked; Federation v0 UAT report — Docker Sandboxes backend > Graduation gates: what actually passes; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Owner UAT findings and fixes (2026-07-20, real sbx v0.35.0) lines 33-93; Federation v0 UAT report — Docker Sandboxes backend > Independent verification (maker ≠ judge) lines 669-800; Federation v0 UAT report — Docker Sandboxes backend > Honest confidence lines 1157-1235; authority prior: current intent anchor because current decision context is present
- `docs/design/FEDERATION_V0_UX_REPORT.md` - Federation v0 UX report — the guided CLI layer
  Evidence: section-packed context: Federation v0 UX report — the guided CLI layer; Federation v0 UX report — the guided CLI layer > What was built (cumulative across both revisions); Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual; Federation v0 UX report — the guided CLI layer > First independent review (Fable), and fixes applied (carried over from the prior revision); indexed section match: Federation v0 UX report — the guided CLI layer > What's auto-managed vs. still manual lines 88-127; Federation v0 UX report — the guided CLI layer > Independent verification (reproduced, not trusted) > The security check is unweakened — an unregistered/untrusted signer is still refused lines 168-178; Federation v0 UX report — the guided CLI layer > First independent review (Fable), and fixes applied (carried over from the prior revision) lines 199-233; authority prior: current intent anchor because current decision context is present

## Freshness Warnings
These on-disk paths match the task wording but were not present in the indexed candidate set. Treat them as stale-index risk, not proof that the initial pack is wrong.

- `docs/redteam-2026-07-10/excellence-audit-codex.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team
- `docs/redteam-2026-07-10/rt-honesty.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team
- `docs/redteam-2026-07-10/rt-input.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team
- `docs/redteam-2026-07-10/rt-state.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

- On-disk paths matched the task but were not indexed [medium, freshness]
  Agent check: Inspect the warned files or refresh the index before trusting missing context.
  Evidence: `docs/redteam-2026-07-10/excellence-audit-codex.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team; `docs/redteam-2026-07-10/rt-honesty.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team; `docs/redteam-2026-07-10/rt-input.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team; `docs/redteam-2026-07-10/rt-state.md` - on-disk path matched task terms but was not in the indexed candidate set: red, team
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
- Docs/config coverage confidence: high
- Git receipt confidence: high
- Noise risk: medium
- Pack completeness: medium

Why:
- found 3 likely primary file(s)
- found 4 likely test file(s)
- found 3 related Git receipt(s)
- 2 file(s) were downgraded as likely noise

Agent instruction:
Validate the test and integration surface before editing. Record critical misses and distracting inclusions in the slice result or a task checkpoint.

## Suggested Starting Slice
Use `D01-audit-existing-ui-and-daemon-contracts-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `D01-audit-existing-ui-and-daemon-contracts-result.md` or `ds task checkpoint`.
