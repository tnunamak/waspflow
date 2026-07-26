# Federation task discovery and contributor choice

Status: implemented
Date: 2026-07-21

## Contract

`GET /tasks` is an authenticated coordinator discovery endpoint. It requires
the same `Authorization: Bearer <collective-token>` header as
`GET /tasks/next`, claim, submit, and publish. It returns a JSON array; an
empty queue returns `[]`.

Each entry is:

```json
{
  "task_digest": "<64 lowercase sha256 hex characters>",
  "display_id": "task label",
  "published_at": "RFC 3339 timestamp",
  "network": "enabled",
  "source": { "base_artifact": { "sha256": "…", "bytes": 0, "media_type": "…" } },
  "prompt": { "artifact": { "sha256": "…", "bytes": 0, "media_type": "…" } }
}
```

`network`, `source`, and `prompt` are the resource-relevant signed fields the
v0 task envelope currently has. It has no harness or human-readable description
field. The list is oldest-first and has no pagination by design for the current
friends-and-family scale; a larger coordinator needs an indexed, paginated
contract.

Only `QUEUED` tasks appear. A `CLAIMED` task with an expired lease is lazily
settled back to `QUEUED` during the same scan and then appears; live claims and
`SETTLED` tasks do not. `GET /tasks/next` remains available and uses this exact
same scan, returning the first digest or `{"task_digest": null}`.

## Contributor choice

The local daemon proxies the list as authenticated `GET /tasks`. It also accepts
an optional bare digest at:

```json
POST /contribute/start
{ "task_digest": "<64 lowercase sha256 hex characters>" }
```

With a digest, it invokes the existing guided command as:

```text
waspflow federation contribute --task-digest <digest> --json
```

Without a body or digest, it preserves the one-click behavior and lets the CLI
call `GET /tasks/next`. Daemon status exposes `contribution` with the choice
mode and chosen digest. No claim, execution, or submission logic was copied:
the existing pull path still refreshes the roster and verifies the claimed,
signed task envelope before execution.

## UI

While idle, the contributor view has a **Contribute next available** button and
a short **Choose a task** list. Each available task is shown by `display_id`
and has a **Contribute this** action. The UI can render an optional description
if a future task-list entry supplies one; task v0 currently supplies none.

## Verification

- `tests/federation-coordinator.test.mjs`: empty list, token gate, all
  claimable entries, lazy expired-lease requeue, exclusion of live claims and
  settled tasks, and signed resource hints.
- `tests/federation-daemon.test.mjs`: coordinator list passthrough, selected
  digest delegation, and selected task reflected in daemon status.
- `tests/federation-webui.test.mjs`: idle task-selection and one-click affordance.
- A local coordinator → daemon → selected contribution smoke test published a
  signed task, listed it through the daemon, and verified that the daemon
  invoked the existing CLI with that exact digest.

The deterministic suite passed 202 of 203 tests. The remaining live `sbx`
integration test is blocked before application code because this environment is
not authenticated to Docker Sandbox (`sbx login` is required). Confidence: high
for the local API and daemon/UI handoff; an actual contributor browser session
remains the normal post-merge smoke test.
