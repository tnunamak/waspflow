# Federation host — implementation report

## Outcome

`waspflow federation host` turns an operator’s machine into a coordinator in
one guided flow. It creates durable operator credentials and a collective
token under `~/.waspflow/federation-coordinator/`, starts the coordinator, and
prints one paste-able `https://<coordinator>/join#<token>` invite. The matching
`waspflow federation invite` command prints the same kind of invite again
later. `join` now consumes that deep link directly as well as its older
two-argument form.

The new directory is mode `0700`; the token, host configuration, roster, and
ngrok token are mode `0600`; the private operator key is mode `0600`. Initial
setup creates an empty collective roster and then adds the generated operator
key, so the running coordinator satisfies its existing non-empty-roster trust
invariant without inventing a network registration endpoint. Re-running host
does not rotate the token or keypair and repairs the operator roster entry if
needed.

## Operator journey

Without a flag, host asks one reachability question:

1. **ngrok (recommended)** — prints the verified signup URL,
   `https://dashboard.ngrok.com/signup`, then asks for the operator's
   authtoken with masked terminal input and stores it privately.
2. **my own HTTPS address** — accepts the existing reverse-proxy origin and
   binds the coordinator only on loopback.
3. **local network only** — binds on all local interfaces and produces an
   invite using the discovered LAN IPv4 address.

Scripts can select the same choices with `--tunnel ngrok`,
`--tunnel url:<https://address>`, or `--tunnel lan`.

The ngrok connector is the official `@ngrok/ngrok` SDK. The coordinator itself
opens `forward({ addr: 127.0.0.1:<port>, authtoken })`, then writes its actual
public URL to a private status file; the host command waits for that status and
prints the URL prominently. This keeps the tunnel attached to the coordinator
rather than relying on a separately launched tunnel process.

## Important ngrok correction

The original premise that a free account can claim a custom static domain is
not currently true. As verified on 2026-07-22, ngrok Free gives an account one
**automatically assigned development domain**; it may be used for endpoints,
but users cannot reserve, customize, or bring a domain on that plan. The SDK
receives that assigned URL when it creates the endpoint, so Waspflow does not
ask the operator to claim or paste a domain. This is the stable address used
in the invite. See ngrok’s [free-plan limits](https://ngrok.com/docs/pricing-limits/free-plan-limits)
and [JavaScript SDK quickstart](https://ngrok.com/docs/getting-started/javascript).

The same free plan has an HTTP browser interstitial and usage limits. That is
acceptable for this dogfood collective/API flow but is not represented as a
production alias service.

## Lifecycle and dependency boundary

Packaged Linux hosts use a new systemd **user** unit,
`waspflow-federation-coordinator.service`, because the Federation package
already installs and uses the same user-scoped lifecycle model for the local
daemon. It restarts on failure without requiring a root system service. A
source checkout has no installed unit, so host explicitly keeps its child
coordinator attached to the terminal instead of silently leaving an
unmanaged daemon behind.

`coordinator/package.json` is the sole `@ngrok/ngrok` dependency boundary.
The `.deb` stages only that small manifest and lockfile, not `node_modules`;
after the operator chooses ngrok, host copies the manifest to its private
coordinator state and runs `npm ci --omit=dev` there. Contributor/daemon
installations therefore neither download nor load the native SDK. If the
package cannot be installed or its native prebuild will not load, the flow
gives the operator a clear fallback: install the ngrok agent from its official
download page and point it at the local coordinator, or use an
operator-managed HTTPS URL. It does not crash with a Node require stack.

## Evidence

Added `tests/federation-host.test.mjs`, which uses injected fakes and covers:

- token/key/roster generation, privacy modes, and idempotent resume;
- all three `--tunnel` forms plus LAN address selection;
- invite generation round-tripping through both the pre-existing invite parser
  and the actual `waspflow federation join <invite>` command;
- SDK forwarding to the coordinator port and unavailable-native-SDK guidance.

The focused host test passes. The required complete Node test suite is run as
the final repository gate for this change.

## Honest boundary

No ngrok account or live tunnel was created. The endpoint-dial path is proven
against an injected SDK contract, but a real auth token is required to verify
the live assigned URL, account limits, and service restart recovery. That is
the remaining owner dogfood step; it is not claimed as automated coverage.
