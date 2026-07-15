# Verification Split Report

Date: 2026-07-15

## Built

- Added `waspflow verify <lane>`, a non-destructive prepare/verify checkpoint.
  It exits 0 on pass and 2 on failure; it does not touch the lane's tmux window,
  session, worktree, lifecycle status, or final `result`.
- Refactored the command execution into one shared artifact runner used by both
  `verify` and reap. Both paths write `verify-command.txt`, stdout/stderr, and
  `verify-result.json`.
- Added `failure_class` to the verify receipt and `verify_failure_class` to lane
  state: `task`, `prepare`, `timeout`, `infra`, or `none`. A missing cwd and an
  unavailable shell oracle (exit 127) are `infra`; a timeout is `timeout` even
  when it occurs in prepare.
- Added checkpoint state: `verify_checkpoint_epoch`,
  `verify_checkpoint_fingerprint`, and `verify_test_files_changed`. Reap consumes
  a fresh checkpoint and preserves the existing `verified`/`verify_failed`/
  `succeeded` result vocabulary.
- Added documentation in the CLI help, README, and orchestration skill.

## Freshness Rule

A checkpoint is reusable only when its saved Git workspace fingerprint exactly
matches the current fingerprint. The fingerprint covers `HEAD`, the complete
tracked diff from `HEAD`, and untracked paths plus content. It is captured after
prepare/verify so generated verification artifacts are part of the checkpoint.

This is simple and conservative: a changed workspace reruns verification; a
non-Git or missing workspace has no fingerprint and is never reusable. It avoids
pretending an epoch alone proves that an agent did not edit after verification.

## Test-Integrity Heuristic

New isolated lanes save their exact fork commit at spawn. On every verification,
Waspflow compares that fork through `HEAD`, staged/unstaged changes, and
untracked files. It reports `true` if a changed path has a conventional
`test`/`spec`/`verify` shape or is explicitly named by the verification command;
otherwise it reports `false`. Lanes without a trustworthy fork point report
`unknown`.

This is warning-only by design. It is a v1 green-verify signal, not proof that a
test is meaningful or that every relevant test was changed.

## Verification Evidence

`scripts/verify.sh` completed with exit code 0. New deterministic coverage proves:

- pass and fail checkpoints preserve the lane directory, marker file, status,
  and empty final result;
- task, prepare, and timeout failure classes;
- fresh-checkpoint reuse via a counter that stays at one invocation after reap;
- reap without a checkpoint and no-verify lane behavior remain unchanged.

Hand-seeded end-to-end transcript (with `WASPFLOW_LIB` unset so the checkout's
library, rather than an installed older override, is loaded):

```text
$ waspflow verify demo (expected failure)
waspflow: verify: lane 'demo' test-surface changes are false (heuristic; not a gate)
waspflow: verify: lane 'demo' checkpoint failed (failed; class=task)
verify_fail_rc=2 marker=present status=live result= class=task count=3

$ touch gate-passed; waspflow verify demo (expected pass)
waspflow: verify: lane 'demo' checkpoint passed
status=live result= verify_state=passed class=none count=6

$ waspflow reap demo --no-archive (expected fresh-checkpoint reuse)
waspflow: reap: lane 'demo' reaped — result=verified
status=reaped result=verified count=6 receipt_class=none
```

The unchanged counter at reap is the proof that the passing checkpoint was
consumed rather than rerun.

## Confidence and Gaps

Confidence: high for the shell-level lifecycle and receipt contracts: the full
deterministic suite and an independent seeded lifecycle both passed.

Known limits: the test-surface check is intentionally heuristic and can be
false-positive/false-negative; non-Git lanes correctly sacrifice reuse for
safety. `WASPFLOW_LIB` remains an intentional environment override, so invoking
a checkout with it pointed at an older installation can load old library code;
the normal test harness clears it to prove this checkout.
