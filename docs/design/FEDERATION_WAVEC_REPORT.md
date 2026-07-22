# Federation Wave C evidence gate

Date: 2026-07-22

## Result

The Wave C evidence gate passed on the integrated worktree. The live daemon is
running on port 4243 and was idle after the final contribution.

## Fixed behavior

- `GET /requests` now returns the local author's complete coordinator history
  plus an active local submission. The coordinator has an authenticated
  author-filtered projection, so claimed and settled requests are retained.
- The browser waits for the first `/status` result before it chooses Join,
  backs off failed optional reads, and no longer emits a favicon authentication
  error. A stepper requires a real `sha256:` task digest.
- The daemon keeps a bounded stderr tail for contribution and submission
  failures. Submission rejects a missing or non-directory source before it
  starts the child process.
- Node-test execution cannot write the real default Federation ledger. All
  daemon tests use a temporary ledger path.
- Identity is cached and refreshed in the background. `/identity` responds
  immediately with partial data and `refreshing: true` when needed. The Docker
  username is read from the non-interactive authenticated `sbx login` status
  response after `sbx diagnose` confirms authentication.
- Claude receipt parsing preserves direct model fields and every model named
  by multi-model `modelUsage` output.

## Live evidence

The daemon was restarted after daemon changes and its final status was:

```json
{"state":"idle","detail":"Contribution finished."}
```

`/identity` returned Docker account `timodl`. `/requests` returned requester
history with settled results. `/favicon.ico` returned HTTP 204 without a token.

The final real run submitted `wavec-model-receipt-proof` through
`bin/waspflow-federation-submit` using the supplied `tim-author` key, then
contributed it through the live daemon. The settled task and private ledger
receipt contained:

```json
{
  "model": "claude-haiku-4-5-20251001, claude-sonnet-4-6",
  "usage": {"input_tokens": 6, "output_tokens": 558},
  "duration_ms": 16723,
  "capacity_kind": "subscription",
  "docker_account": "timodl"
}
```

The scripted Playwright journey passed every top-level view (Contribute,
Requests, Activity, Settings, Help) with `consoleErrors: []`.

## Verification

- `node --test tests/*.mjs`: 244 passed, 0 failed, 1 documented live-sbx
  preflight skip (245 tests total).
- `WASPFLOW_UI_URL=http://127.0.0.1:4243/ WASPFLOW_SESSION_TOKEN=<daemon token> node tests/e2e-browser/journey.spec.mjs`:
  8 checks passed; zero console errors.
- Grep of the real ledger found no `aaaa` fixture IDs or `.example`
  coordinator entries after the full suite.
