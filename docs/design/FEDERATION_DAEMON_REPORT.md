# Federation daemon — slice 1 report

## Delivered

- `waspflow federation daemon [--port N]` starts a foreground local daemon.
- `waspflow federation ui` finds a healthy daemon or starts one detached, then opens its tokenized local URL with `open`, `xdg-open`, or `start` by platform.
- The daemon binds only `127.0.0.1`, writes `~/.waspflow/federation/daemon.json` atomically at mode `0600`, and removes its own metadata at clean shutdown.
- The placeholder web page is at `GET /`; future browser and tray clients use the daemon API rather than the federation loop directly.

## `/status` contract

Every authenticated `GET /status` response is:

```json
{
  "schema_version": 1,
  "type": "daemon_status",
  "state": "not_joined | idle | contributing | paused | action_needed",
  "detail": "human-readable current state or opaque CLI progress",
  "coordinator_url": "optional configured coordinator URL",
  "action": {
    "kind": "awaiting_browser | auth_required_manual",
    "url": "present only for awaiting_browser",
    "instruction": "present only for auth_required_manual"
  }
}
```

`not_joined` derives from missing config. A configured daemon starts `idle`; `POST /contribute/start` changes it to `contributing`; `POST /contribute/stop` changes it to `paused`; `awaiting_browser` and `auth_required_manual` terminal CLI events change it to `action_needed` and preserve the action payload. `no_task_available` and `contributed` return it to `idle`.

## API and security

- `POST /contribute/start` runs the existing `bin/waspflow-federation contribute --json` once; repeated starts while it is live are idempotent.
- `POST /contribute/stop` terminates the supervised child and pauses it.
- `POST /join` accepts `waspflow://join?...`, a pasted `waspflow federation join ...` command, or a raw token. A raw token needs an existing configured coordinator or `WASPFLOW_FEDERATION_COORDINATOR_URL`; a token alone cannot truthfully identify a coordinator.
- Stderr is retained as opaque, bounded progress text. Final stdout is accepted only when it validates against `lib/federation-events.mjs`.
- Every route, including `GET /`, requires the random session token via `X-Waspflow-Session-Token` or `?token=`. This is stricter than the minimum route exception and makes a bare localhost request fail closed.
- Every request validates `Host` as only `localhost`, `127.0.0.1`, or `[::1]` (with an optional port). There is no CORS response header and no wildcard CORS.

## Verification

- New daemon test file: 6 passing subtests covering all status states, both auth handoffs, Host rejection, absent/bad tokens, static page token enforcement, `0600` metadata, idempotent contribute spawn, join parsing/dispatch, and the UI launcher.
- `node --test tests/federation-daemon.test.mjs`: 6 pass, 0 fail.
- `node --test tests/*.test.mjs`: 193 pass; 1 live Docker Sandbox integration is blocked because this host's `sbx` is installed but Docker authentication is absent (`sbx login` required). No sandbox or loop code was changed to mask that environmental failure.
- Hand test against a real daemon: `GET /status` returned `{"schema_version":1,"type":"daemon_status","state":"not_joined","detail":"Not joined. Paste an invite to get started."}`; no token returned 401; hostile `Host: attacker.example` returned 400; `daemon.json` was mode `0600`.

## Deliberate scope decisions

- Server-Sent Events are deferred; slice-2 browser UI and slice-5 tray can poll `GET /status`.
- The coordinator, envelopes, sandbox backend, and contribution-loop implementation were not modified.
