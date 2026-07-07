# Verification Result Contract Report

Status: implemented
Date: 2026-07-06

## Built

`waspflow spawn` now accepts a verification contract:

```bash
waspflow spawn --provider codex --lane fix \
  --verify 'npm test' \
  --verify-name test \
  --verify-timeout 1800 \
  --prepare 'npm ci' \
  -- 'Fix the bug.'
```

The contract is stored in lane state as:

- `verify_command`
- `verify_name`
- `verify_timeout`
- `prepare_command`

On `reap`, Waspflow finalizes the existing report contract first, then runs
`--prepare` if present, then runs `--verify` from the lane `cwd`. For isolated
lanes, that is the isolated worktree.

## Result Vocabulary

- `verified`: report contract satisfied, or no report was required, and
  verification exited 0.
- `succeeded`: lane completed and report contract was satisfied, but no verify
  command was configured.
- `verify_failed`: prepare or verify failed, or verify timed out.
- `recovered`: existing missing-report recovery result when no verify command is
  configured.
- `failed` / `report_missing`: existing failed report-contract results.

`reap` exits non-zero for `verify_failed`, matching the existing failed
deliverable behavior.

## Receipts

Verify receipts are written under the lane dir:

```text
verify-command.txt
verify-stdout.txt
verify-stderr.txt
verify-result.json
```

`verify-result.json` shape:

```json
{
  "name": "verify",
  "command": "npm test",
  "cwd": "/repo-waspflow-fix",
  "exit_code": 0,
  "duration_seconds": 74,
  "state": "passed"
}
```

Prepare receipts use the same shape with `prepare-*` filenames. Timeout uses
coreutils `timeout` when available. If `timeout` is unavailable, Waspflow runs
the command without a timeout and emits a warning; it still records the receipt.

## Verification Transcript

Deterministic script:

```text
$ scripts/verify.sh
waspflow: reap: lane 'verify-true' reaped - result=verified
waspflow: reap: lane 'no-verify' reaped - result=succeeded
waspflow verify: ok
```

The script also asserts `verify_failed` for a false verify command, timeout
handling when `timeout` is available, `check --explain` risk surfacing, and a
prepare failure path with `verify_state=skipped`.

Manual real `reap` transcript using synthetic lane state in a scratch git repo:

```text
$ reap verify-pass --verify true with report
waspflow: reap: lane 'verify-pass' reaped - result=verified
{
  "result": "verified",
  "verify_state": "passed",
  "verify_exit_code": "0"
}
{
  "name": "manual",
  "command": "true",
  "exit_code": 0,
  "state": "passed"
}

$ reap verify-fail --verify false
waspflow: reap: lane 'verify-fail' reaped - result=verify_failed
rc=2
{
  "result": "verify_failed",
  "verify_state": "failed",
  "verify_exit_code": "1"
}
! lane has failed verification: lane=verify-fail ...
- Failed verification: inspect the lane verify receipts, then fix the work or explicitly accept the failed gate.

$ reap verify-timeout --verify "sleep 2" --verify-timeout 1
waspflow: reap: lane 'verify-timeout' reaped - result=verify_failed
rc=2
{
  "result": "verify_failed",
  "verify_state": "timeout",
  "verify_exit_code": "124"
}

$ reap no-verify
waspflow: reap: lane 'no-verify' reaped - result=succeeded
{
  "result": "succeeded",
  "verify_state": null
}
```

Additional prepare check:

```text
$ prepare command writes prepared.txt; verify checks it exists
waspflow: reap: lane 'prepare-pass' reaped - result=verified
prepare verify: ok
```

Syntax and diff checks:

```text
$ bash -n bin/waspflow lib/*.sh lib/providers/*.sh
$ git diff --check
```

Both passed.

## Deviations

`docs/design/PRODUCT_SYNTHESIS.md` was not present in this branch. I recovered
and read it from the archived `product-synthesis` Waspflow bundle, then
implemented the explicit contract from that document and this lane prompt.

A failing `--prepare` stamps `result=verify_failed` and `verify_state=skipped`.
That is an implementation choice for the v1 contract: verification cannot be
trusted if the configured lane preparation did not complete.

Confidence: high for the local shell behavior and result stamping. The only
unstated risk is project policy quality: `verified` is only as strong as the
user-provided verify command.
