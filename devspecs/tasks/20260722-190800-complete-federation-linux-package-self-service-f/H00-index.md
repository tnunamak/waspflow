# Task 20260722-190800-complete-federation-linux-package-self-service-f

## Task
complete Federation Linux package self-service flow

## Status
packed

## Series
H

## Profile
code-change

## Created At
2026-07-22T19:08:00Z

## Original Query
complete Federation Linux package self-service flow

## Repo / Workspace
- Repo: `/home/tnunamak/code/waspflow-fedgui-e2e`
- Workspace: `/home/tnunamak/code/waspflow-fedgui-e2e/devspecs/tasks/20260722-190800-complete-federation-linux-package-self-service-f`

## Resources
- `task.json`
- `H01-make-deb-staging-reproducible-and-build-with-nfp-plan.md`
- `H01-make-deb-staging-reproducible-and-build-with-nfp-result.md`
- `H02-prove-fresh-ubuntu-install-daemon-and-ui-smoke-plan.md`
- `H02-prove-fresh-ubuntu-install-daemon-and-ui-smoke-result.md`
- `H03-add-curl-installer-first-run-ux-and-self-service-plan.md`
- `H03-add-curl-installer-first-run-ux-and-self-service-result.md`

## Task Slices
- H01: make .deb staging reproducible and build with nfpm fallback. Plan: `H01-make-deb-staging-reproducible-and-build-with-nfp-plan.md`. Result: `H01-make-deb-staging-reproducible-and-build-with-nfp-result.md`.
- H02: prove fresh Ubuntu install daemon and UI smoke. Plan: `H02-prove-fresh-ubuntu-install-daemon-and-ui-smoke-plan.md`. Result: `H02-prove-fresh-ubuntu-install-daemon-and-ui-smoke-result.md`.
- H03: add curl installer first-run UX and self-service docs. Plan: `H03-add-curl-installer-first-run-ux-and-self-service-plan.md`. Result: `H03-add-curl-installer-first-run-ux-and-self-service-result.md`.

## Relevant Map Areas
- `lib`
- `tests`
- `tray`

## Likely Primary Files
- `lib/federation-docker-backend.mjs` - lib/federation-docker-backend.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, linux, package; fields path, title, body, symbol; query term match in path: federation; query term match in body: flow
- `lib/federation-auth-flow.mjs` - lib/federation-auth-flow.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches complete, federation, flow; fields body, path, title, symbol; query term match in path: federation; query term match in path: flow
- `lib/federation-daemon.mjs` - lib/federation-daemon.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, flow; fields path, title, symbol, body; query term match in path: federation; query term match in body: complete
- `lib/federation-harnesses.mjs` - lib/federation-harnesses.mjs (javascript)
  Evidence: anchor-first ranking: score 24.000; matches federation, linux, flow; fields path, title, body; query term match in path: federation; query term match in body: complete
- `tray/cmd/waspflow-federation-tray/main.go`
  Evidence: anchor-first ranking: score 24.000; matches federation, package; fields path, title, body; query term match in path: federation; query term match in path: flow
- `lib/federation-submit.mjs` - lib/federation-submit.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: flow
- `lib/federation-harness-spec.mjs` - lib/federation-harness-spec.mjs (javascript)
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: complete

## Likely Tests
- `tests/federation-auth-flow.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation
- `tests/federation-daemon.test.mjs#L582` - POST /identity/signin exposes the existing browser auth handoff for an unauthenticated provider
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in body: complete
- `tests/federation-harnesses.test.mjs#L73` - CLAUDE_CODE_SUBSCRIPTION_HARNESS: scriptable browser flow, proven indefinite refresh
  Evidence: relationship expansion: source_manifest_family_recovery; query term match in path: federation; query term match in title: flow
- `tests/waspflow-federation-cli.test.mjs`
  Evidence: relationship expansion: source_manifest_test_reservation; pack tier: related (reserved manifest test with direct query evidence); query term match in path: federation

## Likely Docs / Plans / Config
None found in the initial preflight.

## Supporting Context
None found in the initial preflight.

## Related Git Receipts
- `eea4273` 2026-07-21 - fix(federation): drive Claude browser auth in sandbox
  Matched paths: `lib/federation-auth-flow.mjs`, `lib/federation-daemon.mjs`, `lib/federation-harness-spec.mjs`
- `58718b2` 2026-07-20 - feat(federation): auth UX reframe — waspflow drives login, not the operator
  Matched paths: `lib/federation-auth-flow.mjs`, `lib/federation-harness-spec.mjs`, `lib/federation-harnesses.mjs`
- `b1f47bd` 2026-07-22 - fix(federation): resolve Wave G live UI findings
  Matched paths: `lib/federation-auth-flow.mjs`, `lib/federation-daemon.mjs`, `tests/federation-auth-flow.test.mjs`

## Noise Risks
- `docs/design/FEDERATION_V0_UAT_REPORT.md` - Federation v0 UAT report — Docker Sandboxes backend
  Evidence: section-packed context: Federation v0 UAT report — Docker Sandboxes backend; Federation v0 UAT report — Docker Sandboxes backend > Auth UX reframe: waspflow drives login, not the operator (2026-07-20) > Bugs found and fixed while building this module (self-caught, not owner-reported); Federation v0 UAT report — Docker Sandboxes backend > Auth UX reframe: waspflow drives login, not the operator (2026-07-20) > Updated per-harness proof matrix status; indexed section match: Federation v0 UAT report — Docker Sandboxes backend > Auth UX reframe: waspflow drives login, not the operator (2026-07-20) > `lib/federation-auth-flow.mjs`: the structured interface lines 547-563; Federation v0 UAT report — Docker Sandboxes backend > Auth UX reframe: waspflow drives login, not the operator (2026-07-20) > Bugs found and fixed while building this module (self-caught, not owner-reported) lines 601-629; authority prior: current intent anchor because current decision context is present

## Freshness Warnings
These on-disk paths match the task wording but were not present in the indexed candidate set. Treat them as stale-index risk, not proof that the initial pack is wrong.

- `packaging/windows/winget/tnunamak.WaspflowFederation.installer.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow
- `packaging/windows/winget/tnunamak.WaspflowFederation.locale.en-US.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow
- `packaging/windows/winget/tnunamak.WaspflowFederation.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow
- `profiles/wf-federation-linux-v0.json` - on-disk path matched task terms but was not in the indexed candidate set: federation, linux

## Risk Cards
Evidence-backed checks to run before trusting the initial task context. These are not required edit targets.

- On-disk paths matched the task but were not indexed [medium, freshness]
  Agent check: Inspect the warned files or refresh the index before trusting missing context.
  Evidence: `packaging/windows/winget/tnunamak.WaspflowFederation.installer.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow; `packaging/windows/winget/tnunamak.WaspflowFederation.locale.en-US.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow; `packaging/windows/winget/tnunamak.WaspflowFederation.yaml` - on-disk path matched task terms but was not in the indexed candidate set: federation, flow; `profiles/wf-federation-linux-v0.json` - on-disk path matched task terms but was not in the indexed candidate set: federation, linux
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
Use `H01-make-deb-staging-reproducible-and-build-with-nfp-plan.md` as the first bounded plan in this task thread. Refine it before editing if primary files, tests, or integration points look incomplete.

## Agent Preflight Checklist
- [ ] Verify the likely primary files against the repo before editing.
- [ ] Search for same-package or same-command tests if test confidence is not high.
- [ ] Check receipt-touched related files before assuming the pack is complete.
- [ ] Record files actually read, edited, tests run, misses, and noise in `H01-make-deb-staging-reproducible-and-build-with-nfp-result.md` or `ds task checkpoint`.
