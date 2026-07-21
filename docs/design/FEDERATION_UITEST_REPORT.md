# Federation live browser sweep

Run: 2026-07-21

Target: `http://127.0.0.1:8902/` with the supplied session token in the URL and request header.

Command: `node tests/e2e-browser/journey.spec.mjs`

The target was reachable. Its authenticated status was `setup_required`, not the required
`idle` state. The sweep did not call any mutating endpoint or click a contribution control,
so it left the demo rig in that observed state.

| Check | Result | Evidence |
| --- | --- | --- |
| Page loads with `Waspflow Federation` | PASS | [initial screenshot](../../test-artifacts/federation-ui/initial.png) |
| No console errors except known favicon 401 | PASS | Exact ignored error: `Failed to load resource: the server responded with a status of 401 (Unauthorized)`. Exact unexpected-error list: `[]`. |
| Idle view, ready copy, trusted badge, helping line, zero-task ledger | FAIL | Live status was `setup_required`; idle content was not rendered. |
| Task-choice card, next-available control, and task list | FAIL | The card is rendered only for `idle`; it was absent in `setup_required`. |
| Safety accordion remains expanded after 4 seconds | PASS | [expanded screenshot](../../test-artifacts/federation-ui/safety-expanded.png) |
| Advanced-submit accordion fields visible and remains expanded after 4 seconds | PASS | [expanded screenshot](../../test-artifacts/federation-ui/advanced-submit-expanded.png) |
| Contribution controls exist and are enabled without mutating the rig | FAIL | `Start contributing` and task-choice controls are absent in `setup_required`. No click or API mutation was attempted. |

The raw structured result is [sweep-results.json](../../test-artifacts/federation-ui/sweep-results.json).

## Re-run

```sh
npm install
node tests/e2e-browser/journey.spec.mjs
```

The script defaults to the supplied local target and token. Override them only for another
explicit test rig with `WASPFLOW_UI_URL` and `WASPFLOW_SESSION_TOKEN`. It exits nonzero when
an assertion fails and writes fresh screenshots under `test-artifacts/federation-ui/`.

## Blocker to a fully green sweep

The required idle-only checks cannot pass until the owner returns this demo daemon to `idle`.
This sweep intentionally does not start, stop, configure, or repair the live service.
