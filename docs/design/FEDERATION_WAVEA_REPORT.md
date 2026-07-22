# Federation Wave A report

## Scope

Wave A adds the P1 and P2 observability data layer.

Each completed task has a private receipt. The result envelope has a safe public metadata subset.

The daemon provides Identity, ledger, task-detail, and result-artifact endpoints.

## Private receipt

The contributor ledger stores this full receipt under `entry.receipt`.

```json
{
  "schema_version": 1,
  "task_digest": "<64 lowercase hex characters>",
  "harness_id": "claude-code-subscription",
  "capacity_kind": "subscription",
  "model": "claude-fable-5",
  "usage": {
    "input_tokens": 15166,
    "output_tokens": 63
  },
  "duration_ms": 3840,
  "started_at": "2026-07-21T10:00:00.000Z",
  "finished_at": "2026-07-21T10:00:03.840Z",
  "sandbox_id": "wf-1234abcd",
  "identities": {
    "docker_account": "oshin",
    "provider_account": {
      "email": "oshin@example.test",
      "tier": "max"
    }
  }
}
```

`model`, `usage`, `docker_account`, and `provider_account` can be `null`.

The implementation uses `null` when a source does not emit the value.

`capacity_kind` defines the meaning of `usage`. Its allowed values are `subscription`, `api_key`, `local`, and `gateway`.

The harness auth strategy derives the capacity kind. The account tier is optional and does not define the capacity kind.

An account does not need a subscription tier for any receipt, ledger entry, or Identity response.

Claude uses `claude --print --output-format json`. Its result object provides model and token data.

Codex uses `codex exec --json`. Its final `turn.completed` event provides token data in the probed CLI version.

Codex does not provide a model or duration in that event. The receipt records `model: null` and measures duration around the sandbox entrypoint.

Gemini uses `gemini -o json`. A malformed or incomplete output gives `null` values.

The worker runs `claude auth status --json` in the task sandbox for the Claude provider identity.

The worker reads Docker identity from `sbx diagnose` under the Waspflow sbx child environment.

## Shared result metadata

New result envelopes can include this optional field:

```json
{
  "execution_metadata": {
    "harness_id": "claude-code-subscription",
    "capacity_kind": "subscription",
    "model": "claude-fable-5",
    "usage": {
      "input_tokens": 15166,
      "output_tokens": 63
    },
    "duration_ms": 3840
  }
}
```

`model` and `usage` can be `null`. `capacity_kind` is required when `execution_metadata` exists.

The result schema remains `waspflow.federation.result.v0`.

This is an additive optional field. Old signed v0 result envelopes remain valid.

The envelope validator rejects unknown metadata fields. It therefore rejects identity fields in this object.

## Coordinator task detail

`GET /tasks/:digest` on the coordinator now includes these additive fields:

```json
{
  "task_digest": "<64 lowercase hex characters>",
  "status": "SETTLED",
  "display_id": "Fix receipt UI",
  "author": "ed25519:author",
  "created_at": "2026-07-21T09:00:00Z",
  "published_at": "2026-07-21T09:00:00.000Z",
  "claimed_at": "2026-07-21T10:00:00.000Z",
  "settled_at": "2026-07-21T10:00:02.000Z",
  "result_envelope": {}
}
```

`claimed_at` records the successful claim transition. `settled_at` records the successful submit transition.

## Daemon API for the UI

All endpoints require an allowed localhost Host header and the daemon session token.

The daemon sends no CORS headers.

### `GET /identity`

```json
{
  "docker_account": "oshin",
  "providers": [
    {
      "service": "anthropic",
      "capacity_kind": "subscription",
      "account_email": "oshin@example.test",
      "tier": "max",
      "authed": true
    }
  ],
  "key_id": "oshin",
  "coordinator_url": "https://coordinator.example",
  "collective_name": "Friends"
}
```

The daemon caches provider probes for 60 seconds.

### `GET /ledger`

Returns the full contributor-private ledger. Entries are newest first.

Each completed entry includes `task_digest` and, when available, the full `receipt` object.

### `GET /tasks/:digest`

Returns the coordinator task detail plus two local fields:

```json
{
  "receipt": {},
  "execution_metadata": {}
}
```

`receipt` is `null` if this device did not execute the task.

`execution_metadata` comes from the settled result envelope. It has no account identities.

### `GET /result/:digest`

Returns the settled candidate artifact bytes.

The daemon fetches the artifact from the coordinator. It verifies SHA-256 against the signed result envelope before it returns bytes.

## Test isolation

Daemon tests now pass a temporary `ledgerPath` to every daemon instance.

The tests no longer use the real Waspflow ledger path.
