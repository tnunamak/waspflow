# Federation GUI design (working notes)

**Status:** SLICE 0 only (event-contract versioning). No GUI code exists yet — this file exists so
the contract a future GUI/tray consumer will build against is nailed down and tested BEFORE any
consumer code depends on it, not discovered ad hoc once one does.

**Base:** `waspflow/fedv0-ux` (PR #17) — the guided CLI (`bin/waspflow-federation
join|contribute|submit|status|trust`) and its `--json` structured-event output, described in
`docs/design/FEDERATION_V0_UX_REPORT.md`.

## Contract discipline

Every `--json` invocation of `bin/waspflow-federation` prints exactly one JSON line to stdout (see
`printResult()` in `bin/waspflow-federation`). A future GUI (or any other programmatic consumer —
tray app, dashboard, CI glue) parses that line rather than screen-scraping the human-readable
progress prose that goes to stderr. That means the shape of those JSON lines IS the integration
surface, and needs the same "no bug-fix semantics, drift is caught at build time" discipline as any
other API contract (JSON Schema's model): version it, define it once, and have a test fail loudly the
moment the CLI's actual output drifts from the documented shape.

**Source of truth:** [`lib/federation-events.mjs`](../../lib/federation-events.mjs) — exports
`SCHEMA_VERSION` (currently `1`) and `EVENT_TYPES`, a map of every event's `type` discriminator to its
required fields. Both the CLI (`bin/waspflow-federation`) and any future consumer should import from
this module rather than each maintaining an independent copy of the vocabulary.

**Discriminator: `type`, not `status`.** Every event already carried a `status` field before this
slice; investigating it to decide the discriminator surfaced that `status` is not safe to switch on:
- `contributed` spreads the underlying `waspflow-federation-pull` bin's own response into the event,
  which has its own `status` field (`'settled'` on success) — this silently overwrites the
  `status: 'contributed'` set earlier in the same object literal. The line a consumer actually
  receives has `status: 'settled'`, not `'contributed'`.
- `task_status` (from `status --task-digest`) spreads the coordinator's task record (`publicView()`
  in `lib/federation-coordinator.mjs`), which has its own `status` field — the task's lifecycle state
  (`QUEUED`/`CLAIMED`/`SETTLED`/...). This overwrites `status: 'task_status'` the same way.

Both are pre-existing behaviors, unchanged by this slice (zero loop-behavior change was in scope) —
but they prove `status` was never a reliable discriminator, only usually-correct. `type` is merged in
last by `printResult()`, after any such spread, so it can never be shadowed. **A consumer should
switch on `event.type`, never `event.status`.** `tests/federation-events-contract.test.mjs` asserts
this explicitly for `task_status` (publishes a real task, confirms the emitted `status` is the
coordinator's `'QUEUED'` while `type` stays `'task_status'`).

**Versioning:** every event carries `schema_version` (integer, currently `1`) alongside `type`. A
future change to an event's *required* shape (renaming/removing a field, changing what a field means)
must bump `SCHEMA_VERSION` and add/adjust the corresponding entry in `lib/federation-events.mjs` —
consumers can then branch on `schema_version` instead of guessing from field presence. Purely additive
field changes (a new optional field) do not require a bump.

**Drift backstop:** `tests/federation-events-contract.test.mjs` runs the real CLI (as a subprocess,
against a real ephemeral coordinator — same harness `tests/waspflow-federation-cli.test.mjs` already
uses) for every event reachable without a real sandboxed run, and for each emitted line asserts:
1. it parses as JSON,
2. `schema_version === 1`,
3. it validates against `lib/federation-events.mjs`'s `EVENT_TYPES[event.type].requiredFields`
   (`validateEvent()`).

`contributed`, `auth_required_manual`, and `awaiting_browser` need a real sandbox/harness-auth flow to
reach live, so they're documented in `lib/federation-events.mjs` (schema entries exist) but not
exercised by this contract test — same scope boundary `tests/waspflow-federation-cli.test.mjs`
already draws for those paths (see that file's module doc).

**Event vocabulary as of `schema_version` 1** (`type` → emitting verb):

| `type` | Verb | Required fields (beyond `status`, `schema_version`, `type`) |
| --- | --- | --- |
| `joined` | `join` (first time) | `key_id`, `coordinator_url`, `config_path`, `peers_auto_fetched`, `roster_snippet`, `next_step` |
| `already_joined` | `join` (repeat) | `key_id`, `coordinator_url`, `config_path` |
| `not_joined` | `status` (no config yet) | — |
| `member_status` | `status` (joined, no `--task-digest`) | `key_id`, `coordinator_url`, `config_path` |
| `task_status` | `status --task-digest` | (spreads the coordinator's task record, incl. its own `status`) |
| `trusted` | `trust` | `key_id` |
| `no_task_available` | `contribute` (no claimable task) | — |
| `auth_required_manual` | `contribute` (harness needs manual login) | `harness`, `flow_shape`, `instruction` |
| `awaiting_browser` | `contribute` (harness auth has a URL) | `harness`, `url` |
| `contributed` | `contribute` (task ran and submitted) | `task_digest` (spreads the pull bin's own response, incl. its own `status`) |

Note `member_status` and the `join`-verb's `joined` are deliberately DIFFERENT `type` values even
though both previously shared `status: 'joined'` with different field sets — that ambiguity (same
`status` string, two incompatible shapes) is exactly the kind of drift this contract exists to catch,
so it was resolved rather than carried forward under one name.
