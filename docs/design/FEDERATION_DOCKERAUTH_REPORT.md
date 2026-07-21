# Federation Docker sign-in UX

## Delivered

Federation now drives Docker Sandbox sign-in itself when its preflight has
exactly one failed check: `docker_login`.

1. The daemon runs `sbx login` with `sbxChildEnv()`, so it uses the isolated
   Federation Docker identity rather than a contributor's personal profile.
2. It parses the device-flow activation URL and optional one-time code, then
   exposes the normal `awaiting_browser` action. The web UI labels that action
   **Sign in to Docker**, displays the code, and keeps polling automatically.
3. Completion is proved by a new `probeSbxPreflight()` result with
   `docker_login.ok === true`; a browser click alone is not trusted. The daemon
   then starts the guided contribution again. That retry uses the existing
   preflight repair path, which starts the daemon and initializes the balanced
   network policy where needed before continuing to claim and run the task.
4. Pausing or closing the daemon cancels a pending `sbx login` child.

No manual-login fallback was needed. The live isolated probe showed a
non-interactive, URL-capturable device flow:

```text
Your one-time device confirmation code is: XQZN-BWCH
Open this URL to sign in: https://login.docker.com/activate?user_code=XQZN-BWCH
Waiting for authentication...
```

The probe used `timeout 8 sbx login </dev/null` with a fresh empty `HOME`,
`XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, and `XDG_DATA_HOME`; it did not access an
existing Docker identity. It timed out as expected while waiting for browser
approval.

## Diagnostic boundary

Every sandbox preflight check now has a one-sentence, plain-language `detail`.
Raw command stdout/stderr is retained in each check's `diagnostics` field for
`waspflow federation doctor --json` debugging, but the web UI renders only
`detail` and `fix`. This prevents ANSI-styled `sbx diagnose` output, newlines,
and terminal box drawing from reaching Oshin's setup screen.

## Verification

- `tests/federation-sbx-login.test.mjs` stubs `sbx login` output and verifies
  URL/code parsing plus authenticated-preflight completion.
- `tests/federation-daemon.test.mjs` proves
  preflight → Docker browser action → completion → automatic contribution
  restart → contribution completion.
- `tests/federation-sbx-preflight.test.mjs` checks every Linux and Windows
  detail for newlines, ANSI escapes, and box-drawing characters, while proving
  raw output remains in `diagnostics`.
- Full Node suite: 222 passing, 1 skipped live Docker Sandbox integration.
- Shell federation runner and sandbox-detector regression suites pass.
