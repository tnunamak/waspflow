# Federation host UX follow-up

## Outcome

This follow-up fixes four defects found during the first live dogfood of
`waspflow federation host` while preserving the coordinator JSON protocol.

- ngrok guidance now consists only of the signup URL and a masked authtoken
  prompt. TTY input uses raw mode, does not echo characters, and confirms only
  `authtoken saved`; piped input remains supported.
- Printed invites now use `https://<coordinator>/join#<token>`. The token is a
  fragment and is therefore not sent in the HTTP request. Legacy
  `waspflow://` parsing remains for compatibility, but host and invite no
  longer print it.
- A browser landing page is available at `/`; `/join` provides the install
  link and a client-side copy button for `waspflow federation join "<url>"`.
  HTML is served only for browser navigation. JSON clients and API routes keep
  their existing JSON behavior.
- `waspflow federation host --rotate-token` validates that the local managed
  coordinator accepts its current token, atomically rotates the token file,
  verifies the new token is live and the old token is rejected, and restores
  the old token if that verification fails. Successful rotation prints one
  operator warning that members must re-join and old invites are dead. Reusing
  `join` with the new invite updates an existing member configuration without
  replacing its keypair.

## Verification

Coverage includes raw-mode masking, piped input, all three join forms,
browser/JSON content negotiation, fragment-only join content, successful
rotation with old-token rejection, rotation refusal when no managed
coordinator is available, and fresh invite generation after rotation.

The requested complete Node suite is the final gate. The live `sbx` test may
still fail when its external sandbox environment is unavailable; that is an
environmental boundary rather than a host UX failure.
