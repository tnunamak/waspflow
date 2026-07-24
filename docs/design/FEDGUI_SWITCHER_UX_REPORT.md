# Federation switcher and UX report

## Outcome

Federation now treats collective membership as a list with one active
collective. The contribution loop still receives the same active scalar
config, so it does not poll or contribute to multiple collectives.

Legacy `config.json` files migrate on load into `collectives` plus
`active_collective_id`, while retaining the active `coordinator_url`, token,
key, roster, and approval fields for existing callers. Joining a new invite
adds and activates a membership instead of replacing the old one. `switch`
and `leave` operate on a stable hash-based collective ID and use the existing
daemon reload path.

The daemon exposes a credential-free collective list and switch/leave actions.
It does not probe inactive coordinators: inactive means “switch to check this
collective”; the active row gets its reachable/unreachable state from the
daemon's existing active-coordinator observation.

## Product changes

- Pending approval has a product shell, tells the person to send an approval
  request to their operator, truncates the raw request with Copy, and routes
  an unavailable collective to **View collectives**.
- The contribution outage banner has the same explicit recovery action.
- Settings is a first-class collective list with active/inactive state,
  named remedy copy, Join, Switch, and Leave. It honestly states the
  one-active-collective constraint.
- Help now explains the model directly to the contributor: they choose when
  to contribute, approve every task, and can belong to several collectives.
- CLI supports `waspflow federation switch <collective-id>` and `leave`.

## LOC accounting

Source and tests are **+270 / -34 lines**. `public/app.mjs` is a required
Vite rebuild artifact (**+416 / -402 minified lines**) and was not hand-edited.

The material additions are defensible:

- Config normalization and its narrow switch/leave helpers make the membership
  state explicit while preserving the daemon's scalar interface.
- The daemon endpoint is the smallest shared surface for the UI; it reuses
  existing reload and busy-state checks and exposes no secrets.
- Regression coverage proves migration, append/activate, switch, leave,
  endpoint privacy, dead-active switching, and the 390px pending recovery
  route.
- UI additions are mostly replacement copy/routing and one list row; the only
  token logic truncates display while retaining the full value for Copy.

## Validation

Passed:

```text
cd ui && npm run build
cd ui && npm test
node --test --test-timeout=60000 tests/*.test.mjs
PLAYWRIGHT_CHANNEL=chrome node tests/e2e-browser/journey.spec.mjs
```

The browser journey was run against a disposable daemon from this branch with
a copy of the approved desktop membership. It reached the live LAN coordinator
at `http://192.168.1.7:37257` only through the normal active-collective read
paths; it did not join, switch, approve, submit a valid task, or start a
contribution. The journey includes the new 390px pending/unreachable case.

Read-only inspection of the real desktop daemon confirmed it remained idle,
joined, approved, and reachable before this test. No coordinator or desktop
daemon state was changed.

An independent diff-and-oracle review passed after checking the active-work
switch blocker and the A → B → Join A hot-reload path.

Visual evidence:

- Before baseline: `test-artifacts/federation-ui/switcher-before.png`
- After pending/unreachable screen:
  `test-artifacts/federation-ui/pending-unreachable-390.png`

The original long-token pending capture could not complete because the old raw
blob overflowed the renderer; that is the pre-fix failure reproduced by this
work. The after capture shows the request contained in its row with Copy and
the recovery action visible.

## Confidence and gaps

High confidence in the config migration, active projection, and tested UI
recovery path. The intentional gap is inactive reachability: Federation does
not background-poll non-active collectives, so an inactive row asks the user
to switch to check it. Simultaneous contribution remains explicitly deferred.
