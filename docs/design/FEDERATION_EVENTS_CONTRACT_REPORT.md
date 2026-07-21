# Federation CLI event-contract versioning — build report (SLICE 0)

**Date:** 2026-07-21
**Branch:** `waspflow/fedv0-ux` (PR #17), extended by this slice.
**Scope:** stack-independent contract work only. ZERO change to federation loop behavior — this adds
a `schema_version` field, a `type` discriminator, a source-of-truth event schema, and a golden
contract test around the EXISTING `--json` events emitted by `bin/waspflow-federation`.

## What changed

1. **`bin/waspflow-federation`'s `printResult()`** now takes a 4th argument, `type`, and merges
   `{ schema_version: 1, type }` into every structured (`--json`) event, merged in LAST so it can
   never be shadowed by a spread of upstream data (see below). All 9 call sites updated to pass an
   explicit `type`. The human-readable (non-`--json`) output path is untouched — verified byte-
   identical before/after via `git stash` diff of `waspflow federation status` output.
2. **New `lib/federation-events.mjs`** — the source-of-truth schema: `SCHEMA_VERSION` (currently `1`)
   and `EVENT_TYPES` (a map of `type` → `{ description, requiredFields }`), plus `validateEvent()` and
   `isKnownEventType()` helpers. Both the CLI and any future consumer (GUI, tray, tests) should import
   from here rather than re-deriving the vocabulary.
3. **New `tests/federation-events-contract.test.mjs`** — the drift backstop. Runs the real CLI as a
   subprocess against a real ephemeral coordinator (same harness pattern as
   `tests/waspflow-federation-cli.test.mjs`) for every event reachable without a real sandboxed run,
   and asserts each emitted line parses as JSON, has `schema_version === 1`, and validates against
   `lib/federation-events.mjs`'s required-field list for its `type`.
4. **`docs/design/FEDERATION_GUI_DESIGN.md`** (new — did not exist before this slice) — the
   "Contract discipline" section documenting the schema, the discriminator decision, and the test.
5. **`tests/waspflow-federation-cli.test.mjs`** — 3 pre-existing `assert.deepEqual` assertions on
   exact `--json` output (`not_joined`, `trusted`, `no_task_available`) updated to include the new
   `schema_version`/`type` fields. These are the only test changes required by the additive schema
   change; no other assertion in that file depended on exact JSON shape.

## Key finding: `status` is not a safe discriminator

Investigating "confirm whether `status` is the right discriminator or whether a separate `type` is
clearer" (per the task) surfaced a real, pre-existing ambiguity:

- **`contributed`**: `printResult(true, [], { status: 'contributed', task_digest, ...submitResponse }, 'contributed')`
  spreads the underlying `waspflow-federation-pull` bin's own JSON response, which has its own
  `status` field (`'settled'` on success). Because the spread comes after the literal `status:
  'contributed'` in the same object, **the actual emitted `status` is `'settled'`, not
  `'contributed'`** — confirmed with a standalone repro (`{status:'contributed', ...{status:'settled'}}`
  → `{status:'settled'}`) before touching any code.
- **`task_status`** (from `status --task-digest`): spreads the coordinator's task record
  (`publicView()` in `lib/federation-coordinator.mjs`), which has its own `status` field — the task's
  lifecycle state (`QUEUED`/`CLAIMED`/`SETTLED`/...). Same overwrite pattern.
- **`joined` (ambiguous name collision, not an overwrite bug):** `join` (first-time) and `status` (no
  `--task-digest`, already joined) both previously emitted `status: 'joined'`, but with two
  INCOMPATIBLE field sets (`join`'s includes `peers_auto_fetched`/`roster_snippet`/`next_step`;
  `status`'s does not). A consumer switching on `status === 'joined'` could not tell which shape it
  received.

Both overwrite behaviors are pre-existing and unchanged by this slice (zero loop-behavior change was
in scope — `status` field values are untouched). This is exactly why `type` was chosen as the
discriminator: it is merged in by `printResult()` after any spread, so it cannot be shadowed. The new
contract test (`task_status` case) asserts this directly — publishes a real signed task, confirms the
emitted `status` is the coordinator's `'QUEUED'` while `type` stays `'task_status'`. The `joined`/
`status` name collision was resolved by giving the `status`-verb's case its own `type`:
`member_status`, distinct from `join`'s `joined`.

## Event vocabulary now versioned (`schema_version` 1)

| `type` | Emitting verb |
| --- | --- |
| `joined` | `join` (first time) |
| `already_joined` | `join` (repeat) |
| `not_joined` | `status` (no config) |
| `member_status` | `status` (joined, no `--task-digest`) |
| `task_status` | `status --task-digest` |
| `trusted` | `trust` |
| `no_task_available` | `contribute` (nothing claimable) |
| `auth_required_manual` | `contribute` (harness needs manual login) |
| `awaiting_browser` | `contribute` (harness auth produced a URL) |
| `contributed` | `contribute` (task ran and submitted) |

Full required-field detail lives in `lib/federation-events.mjs` and
`docs/design/FEDERATION_GUI_DESIGN.md`.

## Verification (run, not assumed)

- `node --test tests/federation-events-contract.test.mjs`: **7/7 passing** (the 7 events reachable
  without a real sandbox/harness-auth flow: `not_joined`, `joined`, `already_joined`,
  `member_status`, `trusted`, `no_task_available`, `task_status`).
- `node --test tests/waspflow-federation-cli.test.mjs`: **10/10 passing** after updating the 3
  affected `deepEqual` assertions.
- `node --test tests/*.test.mjs` (full suite, run 4 times to rule out flakiness): consistently
  **188 tests, 187 pass, 1 fail** — the 1 failure is
  `tests/federation-pull.test.mjs`'s `live sbx integration` test, which requires a real, currently-
  authenticated Docker sandbox session (`sbx login`) not available in this environment; this is the
  SAME pre-existing, environment-dependent failure present on a clean checkout of this branch BEFORE
  any change in this slice (confirmed by running the full suite before starting). **188 = the
  documented 181 baseline + this slice's 7 new contract tests.** No regression was introduced by this
  slice: 187/188 passing, with the 1 failure being pre-existing and environment-specific, not
  behavioral drift from this change.
- Human-readable (non-`--json`) output confirmed byte-identical before/after via `git stash`:
  `waspflow federation status` (not-joined case) produced identical output both before and after this
  change.

## Constraints honored

- Zero change to federation loop behavior (coordinator HTTP behavior, envelope, sandbox, auth
  untouched) — only `bin/waspflow-federation`'s `--json` event-emission surface, a new schema module,
  a new test, and this doc were touched.
- Human-readable output is byte-identical (verified above).
- `status` field VALUES are unchanged everywhere — only the new `schema_version`/`type` fields were
  added; no existing field was renamed, removed, or changed in meaning.
