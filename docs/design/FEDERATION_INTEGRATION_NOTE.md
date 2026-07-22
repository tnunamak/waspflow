# Federation Wave A + B integration note

## Reconciled API

The local daemon exposes the combined authenticated localhost surface:

- Wave A: `GET /identity`, `GET /ledger`, `GET /tasks/:digest`, and `GET /result/:digest`.
- Wave B: `GET`/`POST /settings` and `GET /roster`.

`/ledger` returns the append-only private ledger in newest-first order. Task detail joins a local private receipt only when this device executed the task; shared `execution_metadata` remains identity-free. Result downloads verify artifact bytes against the signed result-envelope SHA-256 before responding.

## Product-contract decisions

Provider capacity is represented by `capacity_kind`, not subscription tier. The UI consumes the Wave A identity shape (`service`, `account_email`, `authed`) and receipt usage/duration fields, while retaining Wave B's schedule, roster, navigation, and status-driven contribution controls. Schedule persistence and the ledger retain owner-only (`0600`) files.

## Verification

`node --test tests/*.test.mjs` completed with 239 passing tests and 0 failures on 2026-07-21. Syntax checks were run for every changed `.mjs` file.
