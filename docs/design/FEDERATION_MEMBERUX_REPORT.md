# Federation member-first invite UX

## Result

Members can now join by installing the app, opening it, and pasting one invite
link. The coordinator invite page copies that link itself. The terminal path is
collapsed behind “Using a terminal instead?”.

The daemon accepts the HTTPS invite link, the older Waspflow link, a pasted
terminal command, a coordinator address plus code, or a short code when it
already knows the collective. It uses the same `joinFederation` operation as
the terminal command. After a join, the app says that the request is with the
collective operator and continues to check for approval.

The approval hand-off is now an opaque `wfapr1` value. Members can copy it in
the app or terminal and send it to their operator. `waspflow federation approve`
accepts that value, the prior one-line JSON form, and the prior key/file form.
The normal member-facing join output no longer shows a public-key block.

When a member joins a collective hosted by the same machine, the join operation
recognizes the local host state and matching coordinator address, adds that
member directly to the local member list, and reports automatic approval.

## Stable ngrok addresses

`waspflow federation host` now offers one optional prompt for a free static
domain from the ngrok dashboard. `waspflow federation host --domain <name>`
stores the same choice for a later run. Only that explicitly configured domain
is passed to ngrok on restart. Session addresses are not saved and retried as
if they were permanent. If a configured domain is rejected, Waspflow falls
back so the collective can return, then reports the changed address. A skipped
domain also keeps the changed-address warning when a later session URL differs.

I could not verify a configured static domain against a real ngrok account in
this environment. The forwarding options and rejected-domain fallback are
covered with the injected ngrok SDK tests; that is not equivalent to an
account-backed check.

## Verification

- Rebuilt the browser assets with `npm run build --prefix ui`.
- Restarted `wf-fed-daemon.service` from this worktree on port 4243.
- Exercised the same-machine join path against the local hosted collective
  with isolated member state; it returned `auto_approved: true` and appeared
  in the host member list.
- Ran the 13-step browser journey against an isolated approved local member
  daemon on port 4244: all 13 checks passed with no console errors.
- `node --test --test-timeout=60000 tests/*.test.mjs` passed.
