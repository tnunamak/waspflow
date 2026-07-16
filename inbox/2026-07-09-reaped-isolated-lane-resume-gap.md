# Reaped isolated lane cannot be resumed after worktree removal

## Status

Open bug / feature request.

## Observed behavior

`waspflow reap` can successfully verify a report for a clean isolated lane, archive
the branch bundle, remove the isolated worktree, and mark the lane `reaped`.
After that, `waspflow revise <lane> --out <file> -- "..."` advertises/resumes the
exited session, but provider startup fails because the saved lane `cwd` still
points at the removed isolated worktree.

Observed failure shape:

```text
waspflow: revise: lane '<lane>' window exited; resuming session headlessly
.../lib/providers/claude.sh: line 217: cd: <removed isolated worktree>: No such file or directory
```

The lane state still contains useful metadata and an archive bundle, but the
resume path cannot use it.

## Why this matters

This breaks a core promise of lane state: a reaped lane remains inspectable and
recoverable enough to ask follow-up questions. It is especially painful for
clean/no-code report lanes:

- `reap` verifies the report exists.
- `reap` removes the clean isolated worktree.
- The report path stored in state points inside that removed worktree.
- `revise --out ...` cannot reconstruct the report because it tries to `cd`
  into the removed worktree.

Result: the owner has a `succeeded` reaped lane but loses the easy path to ask
the worker for a concise reconstruction. The fallback is scraping transcripts or
manually restoring the archived bundle.

## Expected behavior

At least one of these should be true:

1. `reap` copies required report artifacts into the lane state directory before
   removing an isolated worktree, and `status` points to the retained artifact.
2. `revise` on a reaped isolated lane detects a missing `cwd` and either:
   - restores the archived bundle to a temporary worktree, then resumes there;
   - falls back to `origin_cwd` when the requested follow-up is report-only; or
   - fails with an explicit recovery instruction instead of a provider `cd`
     error.
3. `reap` defaults to `--keep-worktree` for clean isolated lanes with report
   contracts until `close --status harvested|superseded|abandoned` is recorded.

## Suggested fix

Short-term:

- Before removing a clean isolated worktree, copy `--report`, `git-diff.txt`,
  `git-status-*`, and any `--out` recovery artifacts into the lane state dir.
- Update `state.json.report` or add `retained_report` so post-reap readers do
  not point at deleted paths.

Medium-term:

- Make `revise` cwd selection resilient:
  - if `cwd` exists, use it;
  - else if `worktree` has an archive bundle, restore to a temp worktree;
  - else if `origin_cwd` exists and the lane was clean/no-code, use `origin_cwd`;
  - else fail with a typed message explaining how to restore the bundle.

Regression coverage should include:

- isolated lane with clean worktree + report contract;
- `reap` removes worktree;
- `revise --out` after reap succeeds or emits the typed recovery guidance;
- retained report path is readable after reap.

