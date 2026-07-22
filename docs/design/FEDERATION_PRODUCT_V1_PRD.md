# Waspflow Federation — Product v1 PRD ("sellable" bar)

**Owner mandate (2026-07-21):** drive as PM; show the owner nothing until it could be sold.
**Grounding:** tonight's live friction log (real usage by the owner on a phone) — not imagined needs.

## Personas & jobs
- **Contributor ("Oshin")**: donate idle subscription capacity to people I trust, safely, ambiently.
  Job: "help without thinking; never get surprised; see what my machine did on whose behalf."
- **Requester ("Tim")**: turn my network's idle capacity into completed work.
  Job: "submit work, watch it, get results, know exactly what ran where with what."

## The six pillars (all required for v1)

### P1 — Total transparency (the owner's explicit ask)
Every task produces a **receipt**: harness, **model**, **token usage** (in/out), duration,
started/finished timestamps, sandbox id, and the **identities involved** — Docker account,
provider account (email + subscription tier). Split by audience:
- **Contributor-private** (her ledger): full receipt incl. her account identities.
- **Shared with requester** (result metadata): harness, model, duration, token counts — never the
  contributor's account identities.
Sources (verified capturable): `claude --print --output-format json` (model/usage/duration);
`claude auth status --json` (email, subscriptionType); `sbx diagnose` (Docker account);
codex/gemini JSON outputs equivalently. A **Settings→Identity** panel answers "which of my accounts
are in use" at rest, not just per-task.

### P2 — Complete task lifecycle
- **Activity/history** for both roles (full lists, not a one-line count).
- **Task detail view**: prompt, source name/size, author, timeline (queued→claimed→running→settled
  with timestamps), receipt, result.
- **Result access in-app**: view/download the result artifact from the requester surface.
- **Zero silent failures**: every failure carries its actual reason to the UI (daemon must surface
  child stderr tails into submission/contribution detail).

### P3 — Trust & control
- **Roster view**: who is in my collective (names/keys, added when).
- **Authorization clarity**: what each sign-in granted, revoke pointers.
- **Capacity guard**: never contribute capacity the contributor needs (quota-aware via provider
  usage through the federation credential; degrade to schedule-only + always-visible pause).
  Open probe: sbx proxy on usage endpoints; if infeasible in v1 → schedule-only + honest copy.
- **Pause/schedule** as a first-class setting.

### P4 — Coherent IA
Top-level navigation: **Contribute · Requests · Activity · Settings · Help** (not accordions under
one card). Contributor surface: status, guard state, task picker, ledger. Requester surface: submit
form (honest labels), my-requests list, task detail, results. Settings: identity panel, coordinator,
collective, schedule. Help: how it works, safety, FAQ (in-app, not repo docs).

### P5 — First-run integrity
Fresh-machine journey: invite (deep link/paste) → join → pending-approval (voiced) → approve →
one-click auths (Docker, provider — each with clear "why") → first contribution → thank-you.
Every intermediate state has copy; every failure a reason and a next step. `doctor` absorbed into
UI states (buttons/plain words), never raw checks.

### P6 — Evidence gate (how "done" is judged)
- Full test suite green (baseline 226, growing).
- Scripted Playwright journeys: contributor-fresh, contributor-steady, requester-submit-to-result,
  every error voice (bad path, unreachable coordinator, unapproved member, auth-needed).
- PM screen review of every surface against this PRD.
- No known silent-failure path.

## Explicitly OUT of v1 (documented, not hidden)
Payments/credits economy, multi-collective membership UI, Windows installer signing, coordinator
web UI, capacity guard beyond schedule+quota-read (no predictive modeling), VM/nested-virt
contributor support (sbx limitation), mobile-native apps (responsive web is the surface).

## Build plan
- **Wave A (backend observability):** receipts capture (JSON output formats per harness), ledger v2,
  result-metadata split, daemon endpoints: /identity, /ledger (rich), /tasks/:digest (detail+receipt).
- **Wave B (product UI):** the full IA above, consuming Wave A's endpoints; all copy per this PRD.
- **Wave C (error voices):** stderr surfacing, submit pre-validation, stepper only-with-submission,
  test-ledger isolation.
- **Gate:** P6 evidence run; iterate waves until pass; then (and only then) owner sees it.

## Horizon (v2+, owner-directional 2026-07-21 — shapes v1 architecture, NOT v1 scope)
Owner (thinking out loud, consistent with earlier design discussions): likely **integrations with
Linear / Trello / GitHub Issues** so teams externalize task creation/prioritization; possibly
**crypto bounties or credits** later (undecided).

**Architecture-fit audit of what v1 is building (verified, not asserted):**
- **External task sources fit the existing model**: tasks are signed envelopes published to a dumb
  coordinator — an integration adapter (Linear issue → task envelope) is just another author.
  v1 keeps payloads versioned/extensible; a future optional `external_ref` {system, id, url} field
  is additive. Do NOT bake submit-form assumptions into the coordinator.
- **Externalized prioritization fits client-side choice**: the coordinator deliberately does not
  pick tasks; clients list-and-choose. Integration-fed priority metadata later just enriches the
  listing — no coordinator redesign.
- **Receipts (Wave A) are the metering primitive for any future credits/bounties**: per-task
  model/tokens/duration inside the **signed** result envelope (`execution_metadata`) makes usage
  claims executor-signed and tamper-evident — exactly what settlement would need. The coordinator's
  reserved (deferred) settlement/escrow slots remain reserved.
- Guardrail: v1 ships NONE of this — no integration stubs, no credit UI — but v1 must not make any
  of it harder (reviewed at the evidence gate).

## Separation of concerns: capacity sources ≠ subscriptions (owner-ratified 2026-07-21)
Five separated layers: **Task** (signed envelope; power-agnostic) · **Harness** (which agent) ·
**Capacity source** (a credential + its spend semantics) · **Sandbox** (containment) ·
**Settlement** (receipts now, credits later). "Subscription" is ONE KIND of capacity source —
peers: API key (dollar-metered), gateway-issued scoped key, self-hosted/local model (unmetered;
the ToS-clean tier already in the vision). Consequences for v1:
- Receipts: `provider_account.tier`/subscription fields are OPTIONAL metadata; usage semantics
  typed by source kind (quota-tokens vs billed-tokens vs local-unmetered). No schema requires
  subscription-ness.
- Capacity guard = a SPEND POLICY per capacity source; quota-awareness is the subscription
  sensor, dollar caps the API-key sensor, schedule-only the local sensor. Never "the
  subscription guard."
- UI copy: never hardcode "subscription" — reflect the actual source kind ("your Claude
  account", "your API key", "your local model").
- HarnessSpec's auth strategies already encode most of this; v1 must not collapse it in
  receipts, guard, or copy.
