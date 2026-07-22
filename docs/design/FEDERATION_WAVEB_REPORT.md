# Federation Wave B — Product UI Report

**Date:** 2026-07-21

## Delivered

The local Federation web UI is now a responsive product surface with persistent hash navigation instead of the former accordion layout. It remains a plain HTML/ES-module application with no build step and uses the existing daemon token boundary for every local API call.

### Screens

1. **Contribute** (default): clear contribution state, pause/resume control, trusted-coordinator context, schedule-backed capacity-guard copy, task picker, task prompt preview, network state, and a link into contribution activity.
2. **Requests**: three-field submit form using the live semantics (**Task name**, **What should be done**, **Folder on this computer**), inline validation/error voice, My Requests list, selected-task detail, lifecycle timeline, receipt, result download, and copy-reference action.
3. **Activity**: separate contribution and requester history, receipt-facing metadata, and purposeful empty states.
4. **Settings**: Accounts in use identity surface (using Wave A's `/identity` contract when present), local pause schedule, and collective roster.
5. **Help**: self-contained how-it-works explanation, Docker-sandbox three-part safety boundary, and FAQ.

The requester stepper is mounted only from a selected task digest, so an unselected Requests screen never displays a fabricated queued lifecycle.

### Capacity-source copy amendment

Provider capacity is treated as a distinct concern from an account. The Identity panel shows every provider's reported **Capacity kind**. Help and safety copy derive their wording from `/identity`: an account uses “your [provider] account”, an API credential uses “your [provider] API key”, and a local runtime uses “the [provider] local model”. The UI does not assume one capacity source.

## Data contracts and compatibility

The UI consumes Wave A's additive `/identity`, rich `/ledger`, `/tasks/:digest`, and `/result/:digest` contracts when they are available. It degrades to existing status/ledger data while those endpoints are absent, rather than presenting an error-only UI during staged rollout. Result downloads carry the current daemon session token because browser navigation cannot attach the header used by module fetches.

Wave B added only these daemon-owned endpoints:

- `GET` / `POST /settings` — owner-only local schedule persistence (`0600` file mode).
- `GET /roster` — token-gated passthrough to the existing authenticated coordinator roster.

No coordinator write capability or UI-side federation-loop logic was added.

## Verification

- `node --test tests/*.test.mjs` — **231 passing, 0 failing**.
- Extended `tests/federation-webui.test.mjs` for route selection, product-surface affordances, Wave A endpoint usage, lifecycle mapping, and capacity-source wording.
- Extended daemon tests for authenticated schedule persistence and roster passthrough authorization.
- Headless Chrome rendered Contribute, Requests, Activity, Settings, and Help with no browser stderr; manually inspected the 390px Requests surface for usable navigation, spacing, and tap targets.

## Confidence and remaining dependency

High confidence in the UI/daemon behavior delivered here: it is covered by the full suite and a rendered narrow-screen journey. Rich receipt details, provider identities, full requester history, per-task detail, and downloadable result bytes become populated as Wave A's documented endpoints land; the UI is intentionally built against those contracts rather than recreating their backend logic in this wave.

## Wave A integration decisions

The integration keeps every Wave A observability endpoint alongside Wave B's settings and roster endpoints. `GET /ledger` uses the Wave A newest-first presentation while the persisted ledger remains append-only; detail and result retrieval retain receipt privacy and signed-artifact digest verification. Settings remain daemon-local with owner-only file permissions, and roster remains a token-gated coordinator proxy. The UI now reads Wave A provider fields (`service`, `account_email`, and `authed`) and receipt metadata (`usage`, `duration_ms`) without assuming a subscription capacity source.
