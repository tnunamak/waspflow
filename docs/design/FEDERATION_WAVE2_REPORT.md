# Federation Wave 2 Report

**Date:** 2026-07-21
**Scope:** pending approval, contributor acknowledgement ledger, and collective-name personalization.

## Result

Wave 2 is implemented and covered by automated tests.

- A joined member is held in `pending_approval` until the coordinator's
  token-gated `GET /roster` contains their own `key_id`. The daemon polls
  immediately and then every 10 seconds. It automatically returns to `idle`
  on approval.
- `POST /contribute/start` returns HTTP 409 with the requested waiting message
  while approval is pending. `/status` exposes that state for the tray.
- `waspflow federation approve <key_id> <public_key_pem_file|->` updates the
  coordinator's local roster JSON via `--roster-file` or
  `WASPFLOW_FEDERATION_COORDINATOR_ROSTER_FILE`. It performs no network call;
  the existing coordinator watcher hot-reloads the edit.
- Finished contributions append `{display_id, coordinator, finished_at}` to
  `~/.waspflow/federation/ledger.json` (0600). `/status` now includes
  `ledger_summary` and `last_completed`; authenticated `GET /ledger` returns
  the stored list.
- Invite deep links may carry `&name=...`. The name is saved as
  `collective_name` and the UI prefers it over the coordinator URL in its
  helping and safety copy. The pending screen is a calm waiting card and the
  normal status card includes the weekly contribution acknowledgement.
- Before every Federation sandbox preflight, Waspflow now repairs two safe,
  isolated-identity prerequisites: it starts a stopped `sbx` daemon with
  `sbx daemon start --detach`, and initializes a missing balanced policy with
  `sbx policy init balanced`. Both run under the Waspflow-owned sbx `HOME`,
  then re-probe. Docker login remains the manual action and is presented as an
  “Open Docker sign-in” card in the local UI.

## Main implementation surfaces

- `lib/federation-daemon.mjs`
- `bin/waspflow-federation`
- `public/app.mjs`
- `lib/federation-events.mjs`

No coordinator API write endpoint was added. The existing `GET /roster` and
the coordinator's existing hot-reloaded local roster file are the only
membership mechanism used.

## Verification

- Focused Wave 2 suite: 45 pass, 0 fail.
- Full Node suite: `node --test tests/*.test.mjs` → **215 pass, 0 fail, 1
  skipped**. The skip is the pre-existing live Docker Sandbox integration
  gate; this host lacks Docker `sbx` authentication and KVM access.
- Tray suite: `cd tray && go test ./...` → pass.
- `git diff --check` passed.

The regression coverage includes:

1. Stubbed roster polling from pending approval to idle, including the 409
   contribution rejection.
2. Ledger append, 0600 permissions, weekly summary, and `last_completed`.
3. Local roster approval preserving existing JSON entries, for both explicit
   `--roster-file` and environment-variable path selection.
4. Invite-name forwarding/configuration and UI waiting/personalization copy.
5. Stubbed `sbx` identity repair: daemon start, balanced-policy initialization,
   and Docker-login-only manual failure.

## Constraint noted

`docs/design/FEDERATION_OSHIN_EXPERIENCE.md`, named as authoritative in the
task request, was not present in this worktree, repository history, or the
neighboring repositories searched before implementation. The explicit Wave 2
requirements in the task were therefore used as the binding specification.
