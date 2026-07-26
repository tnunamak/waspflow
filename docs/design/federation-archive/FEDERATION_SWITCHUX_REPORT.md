# Federation collective switching UX

## Result

`waspflow federation` now checks the configured coordinator before it opens the local app. A network failure says that the collective is unreachable and names the two available switch actions.

`waspflow federation join <invite>` now states the old and new coordinator before it joins a different collective. Rejoining the same coordinator keeps the existing idempotent output.

Settings → Collective now has one invite field named **Join a different collective**. It calls the existing authenticated daemon `/join` endpoint.

The daemon resets collective-scoped state after `/join` succeeds. It reads the saved membership again, clears the old local collective label, starts approval polling for the new membership, and exposes the new coordinator through `/status` without a restart.

A switch waits for an active contribution, submission, or sign-in to finish. Its receipt stays with the collective that started it.

The CLI sends the running local daemon one authenticated loopback `/reload` request after a changed or refreshed join. When no daemon answers, it gives one restart command instead.

## Design

The switch path reuses `joinFederation`, the existing invite parser, config writer, token validation, key handling, roster refresh, and approval hand-off. There is no second switch-only protocol.

`/reload` is loopback-only and requires the daemon session token from the private daemon record. The endpoint has no caller-supplied configuration and only reloads the member configuration already saved by the trusted local join operation.

The prior-art dossier already records the product boundary that membership is a trusted-collective capability and approval remains an operator decision. This change preserves that boundary: a new invite changes the member’s selected collective, but does not create an approval or roster-registration path.

## Regression coverage

- A daemon starts on coordinator A, receives an invite for coordinator B through `/join`, and later reports B from `/status`.
- A real CLI process switches coordinator A to B while a real daemon is running; the daemon reports B without a restart.
- A busy daemon rejects a switch, continues to report coordinator A for the active contribution, and writes the completed receipt under A even if the saved configuration changes underneath it.
- JSON CLI output remains valid JSON when a switch statement is emitted.
- A no-argument CLI process with a dead coordinator prints the unreachable statement and the Settings or CLI switch path, then opens the local app.
- The 13-step browser journey verifies that Settings → Collective renders the switch invite field.

## Verification

The focused CLI suite passed 18 tests. The daemon suite includes the A-to-B `/join` proof and the active-work boundary. The UI source suite passed 6 tests.

`npm run build --prefix ui` completed and rebuilt `public/app.mjs`.

The `wf-fed-daemon` user service was restarted with this checkout as its working directory.

The browser journey ran against an isolated local daemon at `http://127.0.0.1:4244/`: all 13 checks passed and it recorded no console errors in `test-artifacts/federation-ui/sweep-results.json`.

The required full Node command completed with 283 passing tests and one unrelated failure: its live Docker sandbox integration could not decrypt the local Docker Hub credential while creating an image sandbox. The failure was in `tests/federation-pull.test.mjs`, outside this change.
