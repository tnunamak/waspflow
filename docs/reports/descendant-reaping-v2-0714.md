# Descendant reaping v2 — 2026-07-14

## Decision

The earlier `f19d454`/`56007b0` approach was used as prior art but was not
cherry-picked. Its single mutable scope receipt only supervised the initial
tmux pane and could drop the original command when scope creation failed.

This change makes a systemd user scope an execution-level receipt:

- The initial pane, every headless provider resume, and report recovery enter a
  fresh lane-owned scope when user systemd is usable.
- A successful scope writes `{unit, invocation_id}` from inside the scope before
  the provider command begins. `cgroup_scope_receipts` is append-only, so an
  old daemon-bearing scope remains reapable while a later headless turn starts.
- Reap checks each live unit's `InvocationID` before `kill --kill-whom=all`.
  A missing, stopped, or name-reused unit is skipped; unrelated scopes are not
  selected.
- Headless commands use `systemd-run --no-block` plus a completion receipt, so
  a daemon does not make the provider CLI wait for the cgroup to empty. Its
  stdout/stderr and exit status are replayed to the provider caller.
- If scope creation definitively fails after preflight, the exact original
  command runs with tmux-only ownership and appends a `cgroup_fallbacks` record.
  An accepted but unconfirmed asynchronous launch fails closed rather than
  risking a duplicate unsupervised command.

Park remains intentionally unchanged: it stops the owned tmux pane but does
not reap its scopes, preserving the existing resumable-session contract. Reap
is the destructive lifecycle boundary and cleans all owned receipts after any
recovery pass.

## Evidence

Ran on 2026-07-14:

```text
bash -n bin/waspflow lib/*.sh lib/providers/*.sh scripts/verify.sh
git diff --check
bash scripts/verify.sh
# waspflow verify: ok
```

The isolated verifier uses its own tmux socket and uniquely named throwaway
user scopes. It covers normal completion; an initial scope plus a daemonized
headless resume; append-only multiple receipts; daemonized report recovery;
invocation-ID reuse and a live bystander scope; idempotent reap; actual
`systemd-run` launch failure with tmux fallback; and the no-systemd path.

An additional focused smoke test exercised a daemonized headless command while
holding the lane operation lock, then immediately reacquired that lock. Scope
entry closes inherited fd 9 before launching the provider process, preventing a
detached child from pinning the lifecycle lock.

## Residual risks

- User-systemd is optional. Hosts without a usable user bus retain tmux-only
  cleanup; this is recorded as degraded and cannot reap double-forked children.
- If an asynchronous headless scope request is accepted but does not produce its
  in-scope start marker within five seconds, the command fails closed with
  `scope-start-unconfirmed`. It is not retried outside a scope because doing so
  could run a duplicate provider turn.
- Receipt persistence failure after a scope has started also fails closed before
  the provider command executes. This favors no unowned work over availability.
