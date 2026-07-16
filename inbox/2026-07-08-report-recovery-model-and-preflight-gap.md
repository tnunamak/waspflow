# Waspflow gap: report deliverables are only enforced at reap, and recovery can spend the wrong model

**Date:** 2026-07-08
**Author:** Codex, at operator request
**Context:** A PDPP harvest pass spawned three `waspflow` lanes with `--report`. All three agents finished their work and left useful pane summaries, but the expected report files were absent until the orchestrator manually reconstructed them. This happened during a cost-sensitive cleanup where the operator explicitly wanted low-burn fan-out.

## What happened

The lanes were spawned with report paths under each worktree's `tmp/workstreams/`.
After `waspflow wait`, the panes were idle/done and contained enough information to close out the work, but the report files were not present. The orchestrator then wrote compact report files manually to avoid triggering an automatic recovery pass.

This is not a clear violation of the current documented `--report` contract: `skill/SKILL.md` says report existence is verified during `waspflow reap`, and `reap` may run one recovery pass if the file is missing.

It is still a tooling gap because an orchestrator can easily discover the missing report only after the expensive worker has already finished, and the recovery path may resume the lane using the original/default provider or model rather than the cheapest acceptable recovery model.

## Why it matters

- Missing report files turn fan-in into transcript archaeology unless `reap` is allowed to spend more model tokens.
- In cost-sensitive mode, recovery should be cheap and explicit, not an accidental high-tier resume.
- `waspflow status` exposes the report path, but does not make "report missing" a first-class state before `reap`.
- The prompt asks the agent to write the report, but prompt compliance is not reliable enough to be the only guard.

## Proposed fixes

1. Add a pre-reap report check:
   - `waspflow status <lane>` should include `report_exists`, `report_bytes`, and a clear `report_state`.
   - `waspflow wait <lane>` could optionally warn when a lane is idle and the required report is missing.

2. Make recovery model/provider explicit:
   - `waspflow reap <lane> --recovery-provider codex --recovery-model gpt-5.5-mini`
   - Or a config/env default such as `WASPFLOW_RECOVERY_PROVIDER` / `WASPFLOW_RECOVERY_MODEL`.
   - If no recovery model is configured in cost-sensitive mode, fail closed with a command to run rather than silently spending a high-tier model.

3. Consider a cheap "write report now" helper:
   - `waspflow report <lane> --model gpt-5.5-mini`
   - It should use the saved prompt, transcript tail, git diff, and git status to reconstruct the report without resuming the original worker session.

## Priority

Medium. The current behavior is recoverable and documented, but it undermines low-burn fan-in. This should be fixed before the next large multi-lane cleanup.

## 2026-07-10 reproduction: recovery instruction was lost

PDPP lane `browser-poison-prevention-audit-0710` completed a useful read-only
audit in Codex `gpt-5.4-mini`, but did not write its required report. `waspflow
reap` correctly detected the absent report and started the documented recovery
pass. The resumed session then received only the waspflow correlation-marker
message, replied "What do you want me to work on next?", and exited without the
report. A subsequent explicit `waspflow revise` carrying the exact report path
also resumed headlessly but produced the same marker-only outcome. Final lane
state was `result=failed`, `report_state=absent`.

This sharpens the issue above: report recovery is not merely expensive or late;
the resumed Codex input can omit the recovery instruction entirely. Add an
integration test that reaps an exited Codex lane with a missing report and
asserts that the resumed turn receives both the lane marker and the complete
report-recovery prompt, then verifies the report exists before marking recovery
successful.
