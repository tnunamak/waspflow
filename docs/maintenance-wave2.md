# Maintenance-mode safety controls

## Exec access checks

Repeat `--needs-path PATH` on `waspflow exec` to require host-readable inputs
before invocation. Relative paths resolve against `--cwd`. Output parents must
be writable/searchable, support file creation, and output targets must be
regular files rather than symlinks or directories. Existing output is not
truncated during preflight.

The preflight diagnostic and exec receipt describe provider, cwd, requested
sandbox, required paths, output state and bytes. Host-readable does not prove
provider access: effective sandbox and provider access remain explicitly
unknown. Existing output freshness is not an attestation. There is no new
exec timeout; callers must not assume arbitrary descendants can safely be killed.

## Worktree placement

Set `WASPFLOW_WORKTREE_ROOT=/existing/absolute/root` or project Git config
`waspflow.worktreeRoot`. Both are canonicalized; conflicting explicit roots
fail before worktree creation. An absent policy preserves historical sibling
placement. Explicit roots must exist and be writable/searchable. Child-name
traversal and destination symlinks are refused. No repository instructions are
executed to discover policy.

`waspflow spawn --cwd REPO --lane NAME --preview-worktree` prints the resolved
path without launching a provider or creating a worktree. Isolation and
verification baseline worktrees use the same resolver. New lanes retain their
resolved root for later baseline verification; changed conflicting project
policy fails closed.

## Recovery and operation locks

`waspflow reap LANE --no-recovery` prevents recovery provider invocation.
`WASPFLOW_RECOVERY_POLICY=disabled` disables recovery; `original` permits the
existing original-provider/model recovery behavior. Disabling recovery does
not manufacture a successful report.

Operation-lock waits are bounded and diagnose contention. See
`WASPFLOW_LOCK_WAIT_SECONDS` in the implementation for the configured wait.
A lock timeout does not establish that the owning operation has stopped.
