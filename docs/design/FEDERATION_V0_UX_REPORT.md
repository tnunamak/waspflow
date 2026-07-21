# Federation v0 UX report — the guided CLI layer

**Date:** 2026-07-20 (updated 2026-07-21 — `GET /roster` auto-fetch, owner decision)
**Branch:** `waspflow/fedv0-ux`, built on top of `waspflow/federation-v0-orchestrator` +
`waspflow/fedv0-full-loop` (merged in; those branches hold the proven loop — coordinator, signed
envelopes, independent re-verification, real sandboxed execution — this work does not touch it).
**Scope:** UX HARDENING ONLY. The federation loop already works (see
`docs/design/FEDERATION_V0_UAT_REPORT.md`'s live end-to-end proof, 2026-07-21). This pass wraps that
loop in a consumable CLI a non-technical contributor (the "Oshin" persona) can actually run, per the
owner's clawmeter-style, no-PEM-no-flags bar. **No loop internals were changed except one, owner-
approved addition**: a new, read-only `GET /roster` coordinator endpoint (below) — no write/
registration surface was added, and the claim/lease/signature state machine is untouched.

**Verdict: the two-command contributor journey is real, drives the actual loop (not simulated), and
now genuinely needs no manual key-relay step for an already-approved member.** `waspflow federation
join` then `waspflow federation contribute` — no flags, no PEM paths, no task-digest paste, and (as
of this revision) no manual `trust` call either — drove a real coordinator, a real signed task, real
independent signature re-verification, and a real sandboxed Claude Code subscription run on this
machine, live, with `trust` never invoked at any point. `waspflow federation trust` still exists as
the offline/air-gapped/older-coordinator fallback, documented under "Advanced." Full commands and
evidence below, including a second, independent adversarial review (Fable) whose findings are now
fixed and re-verified.

## What changed in this revision (owner decision, 2026-07-21)

The owner reviewed the prior revision of this report and made two calls:

1. **Add `GET /roster`, a read-only endpoint, as the default path.** The prior revision's
   "still-manual" list named the roster hand-relay (`join`'s printed snippet, `trust`'s pasted
   pubkey) as unavoidable in v0, reasoning that adding any roster-serving endpoint would be the same
   security-posture change as adding a write/registration endpoint. **The owner corrected that
   framing**: a read-only public-key directory, gated by the same collective bearer token as every
   other endpoint, discloses nothing a registered member doesn't already have access to (public keys
   are public by definition) and does not weaken the trust model — only an unauthenticated **write**
   surface would do that, and none was added. This revision implements it: `bin/waspflow-federation
   join`/`contribute`/`submit` now auto-fetch and merge the coordinator's roster; `trust` becomes the
   fallback for when that fetch can't happen (offline, air-gapped, or an older coordinator that
   predates this endpoint).
2. **Correct a misattribution in the prior revision.** That revision's "Decisions made autonomously"
   section said the roster-cache design gap was "flagged to the owner mid-session via
   `AskUserQuestion`, who chose this option." **That is factually wrong — no `AskUserQuestion` call
   happened for that decision; the Fable orchestrator steered it via `waspflow revise`.** Corrected
   below, not repeated.

## What was built (cumulative across both revisions)

| Component | File | Role |
| --- | --- | --- |
| Managed local config | `lib/federation-config.mjs` | Reads/writes `~/.waspflow/federation/config.json` (coordinator URL, collective token, key_id, private key path, local roster cache); generates and stores ed25519 keypairs. Filesystem-only — never talks to the coordinator. |
| **`GET /roster` (new this revision)** | `lib/federation-coordinator.mjs` (`handleRoster`), route table | Read-only, token-gated `[{key_id, public_key_pem}]` directory over the coordinator's existing hand-edited, hot-reloaded roster `Map`. No write/registration counterpart exists or was added. |
| Guided CLI | `bin/waspflow-federation` | Implements `join`, `contribute`, `submit`, `status`, `trust`. `join`/`contribute`/`submit` now call `refreshRosterCache()` (new this revision) to auto-populate the local roster cache from `GET /roster` before doing anything else that needs it. Thin: wires the auth pre-flight, task discovery, roster refresh, and config-filling, then shells out to the real `bin/waspflow-federation-{pull,submit}` for the actual claim/verify/run/submit sequence. |
| Dispatcher wiring | `bin/waspflow` (`cmd_federation`, usage text) | `waspflow federation ...` is a real top-level verb, passthrough to the Node CLI above. |
| Tests | `tests/federation-coordinator.test.mjs` (+3, new this revision), `tests/federation-config.test.mjs` (7), `tests/waspflow-federation-cli.test.mjs` (10, +3 new this revision) | `GET /roster` endpoint tests (shape, auth gate, hot-reload visibility); config lifecycle; CLI integration against a real ephemeral coordinator, including `join` auto-populating from `GET /roster` and `contribute` succeeding with **zero manual trust** when the coordinator's roster already has the author's key. Full federation suite: **181/181 passing**, no regressions. |

## The exact commands a non-technical contributor now runs

**Install waspflow, then:**
```bash
waspflow federation join <coordinator-url> <invite-token>
waspflow federation contribute
```

That really is the whole journey once the coordinator operator has approved this member (added their
key_id to the roster file — the one remaining, genuinely human step; see below). `join` auto-
generates an ed25519 keypair, saves it under `~/.waspflow/federation/`, persists the coordinator URL
+ token + identity, and auto-fetches every OTHER already-approved member's public key from
`GET /roster` into the local cache. `contribute` refreshes that cache again (in case the roster
changed since `join`), detects whether the harness (Claude Code subscription, by default) is already
logged in — if not, runs the login itself and hands back only a URL to click — asks the coordinator
for the next claimable task (`GET /tasks/next`, no digest paste), **independently re-verifies the
task's signature against the auto-fetched roster** (no manual `trust` needed for this to succeed —
proven live, see "Independent verification"), runs it sandboxed via the already-proven
`DockerSbxBackend`, and submits the signed result.

**Owner/requester side** is the same two-command shape:
```bash
waspflow federation join <coordinator-url> <invite-token>
waspflow federation submit --display-id <name> --source <dir> --prompt-file <task.md> --output-dir <result>
```
(`--output-dir` triggers independent result-signature re-verification on materialize, same as
`contribute`'s task-side check — also auto-fed from `GET /roster`, no `trust` required.)

**`waspflow federation trust <key-id> <pubkey-pem-or-@file>`** still exists, now correctly positioned
as the **advanced/fallback** path: use it when the coordinator can't be reached to auto-fetch (air-
gapped, coordinator temporarily down) or against an older coordinator build that predates
`GET /roster`. It is no longer part of the default journey for either role.

## What's auto-managed vs. still manual

**Auto-managed:**
- Keypair generation and storage (`join`) — no more `node -e "generateKeyPairSync(...)"` by hand.
- Coordinator URL / collective token / key path persistence — every later command reads
  `~/.waspflow/federation/config.json`; none of `contribute`/`submit`/`status` take a `--coordinator-url`,
  `--collective-token`, `--private-key-file`, or `--executor-key`/`--author-key-id` flag.
- **Independent signature re-verification's roster (this revision).** `join`/`contribute`/`submit`
  call `refreshRosterCache()`, which fetches `GET /roster` and merges every entry into the local
  cache, persisted to config.json. `--roster-file` (the existing, unchanged defense-in-depth
  mechanism in `bin/waspflow-federation-{pull,submit}`) is fed from that auto-populated cache, so the
  security check the raw bins already perform keeps happening — automatically, for any
  already-approved peer, with no pasted pubkey required.
- Harness auth: `contribute` checks first (`isProviderSecretSet` against the *actual* identity the
  sandboxed job will use, `WASPFLOW_FEDERATION_SBX_HOME` — not the operator's personal `sbx` HOME,
  a correctness detail the orphaned `lib/federation-auth-flow.mjs` didn't itself resolve) and only
  drives a login if actually needed. For Codex (`host-url-flow`), it runs the login itself and
  prints just the URL — verified live against a stub that mimics the real OAuth-URL output shape.
- Task discovery: `contribute` calls `GET /tasks/next` (already added to the coordinator on
  `waspflow/fedv0-full-loop`, commit `ab6b212`, before this UX pass started) instead of requiring a
  pasted `task_digest`. `--task-digest` remains available as an explicit override.
- Clear, non-raw errors for a network-level coordinator failure or a rejected invite token (added
  after the first Fable review — see below).

**Still manual (real, honest v0 limit — flagged for the GUI, not silently smoothed over):**
1. **Membership approval — the coordinator operator adding a new member's key_id to the roster
   file — remains a real, deliberate human decision, and should stay one.** `join` still prints a
   one-line JSON snippet ("send this to whoever runs the coordinator") because that's the one thing
   `GET /roster` cannot do for a BRAND-NEW member: the endpoint can only serve keys the operator has
   already decided belong in the collective. What `GET /roster` removes is the **redundant** relay —
   an already-approved member's public key being hand-pasted by every OTHER member who wants to
   verify their signatures. Deciding *who gets in* is still, correctly, a human call; verifying an
   already-decided member's public key is now automatic.
2. **Claude Code subscription auth cannot be reduced to a clickable URL in this sbx release** — an
   `sbx` platform limitation, unchanged from the prior revision, not a Waspflow gap. `contribute`
   detects this (`describeAuthRequirement`) and prints the exact honest instruction rather than
   faking a URL or hanging silently.
3. **`waspflow federation status` and `contribute --json` are today's renderer, not the final
   surface** — structured JSON output exists for a future tray/GUI to consume, but no GUI exists yet.

## Independent verification (reproduced, not trusted)

### `GET /roster` endpoint

Directly tested against a real coordinator (`tests/federation-coordinator.test.mjs`, 3 new tests):
returns exactly `{key_id, public_key_pem}` per registered member (no other field, no private
material); requires the same bearer token as every other endpoint (401 on missing/wrong token); and
reflects the coordinator's hot-reloaded roster live (adding a member to the same `Map` instance a
`fs.watch`-triggered reload would mutate makes them visible on the very next `GET /roster` call, no
restart) — matching the existing hot-reload guarantee `bin/waspflow-federation-coordinator`'s roster
file watcher already provides for claim/submit/publish.

### The default `join -> contribute` journey, live, with zero manual `trust` calls

Ran the real, non-simulated loop end to end on this machine (the same real `sbx` v0.35.0 install the
prior UAT rounds proved against), reproducing the exact scenario the owner asked to see:

1. Started a real coordinator with a placeholder roster (one entry, standing in for "not yet
   configured").
2. **`join` × 2** (Tim/author, Ocean-persona/"Oshin"/executor) — each auto-generated a distinct
   ed25519 keypair, persisted config, and auto-fetched the coordinator's then-current roster (the
   placeholder only, since neither had been added yet) — confirmed via the printed
   "N peer key(s) already known" line and the config.json contents.
3. **Simulated the one remaining human step**: added both real public keys to the coordinator's
   roster file by hand (the membership-approval decision that should stay human) — confirmed via the
   coordinator's own hot-reload log line, no restart.
4. **`submit`** (Tim) — published a real signed task; confirmed `status=queued` via `GET /tasks/next`.
5. **`contribute`** (Ocean/"Oshin", **`trust` never invoked at any point in this run**) — its own
   roster-refresh fetched Tim's newly-added key automatically; detected the Federation-sbx-identity's
   existing Claude Code subscription auth (skipped login, correctly); called `GET /tasks/next`;
   claimed the task; **independently re-verified the task envelope's signature using only the
   auto-fetched roster** (confirmed via the `independently re-verified task envelope signature
   (signer tim-author)` log line); ran it through the real `DockerSbxBackend` (a real, disposable
   sandbox); submitted a signed result. Coordinator confirmed `SETTLED`.
6. Confirmed via `sbx ls` that no sandboxes were left running, and via the coordinator's own
   `GET /tasks/:digest` that the task genuinely reached `SETTLED` — not merely that the CLI exited 0.

This is the strongest evidence class available: not a unit test against a stub, but a real
multi-process run of the exact "two commands, no manual trust" claim the owner asked to see proven.

### The security check is unweakened — an unregistered/untrusted signer is still refused

Automated (`tests/waspflow-federation-cli.test.mjs`, new this revision): a task signed by a key that
is registered on a **different** coordinator (its own separate roster) — never vouched for by the
member's own coordinator/collective at all — cannot be contributed: claiming it via the member's own
coordinator 404s (`unknown task`), because that coordinator never published or heard of the digest.
This is the direct, automatable analogue of the prior revision's manually-verified "claimed but
untrusted, refused before any sandbox executes" scenario (still true and unchanged: `GET /roster`
auto-fetch reflects exactly what the member's own coordinator actually vouches for — it can never
manufacture trust for a key that coordinator doesn't serve).

### Auth-wiring stub tests (unchanged from prior revision, re-confirmed)

No real credential state touched: confirmed `describeAuthRequirement`'s honest "attach and `/login`"
instruction surfaces correctly for Claude Code subscription when not yet authed, and confirmed
`startAuthFlow`'s `{url, waitForCompletion}` handle drives correctly through the CLI's own JSON
output (`{status: 'awaiting_browser', url: ...}`) using a stub that reproduces the real Codex
OAuth-URL stdout shape — without ever invoking a real `--oauth` call.

### Test suite

`tests/federation-coordinator.test.mjs` (+3: `GET /roster` shape/auth/hot-reload),
`tests/federation-config.test.mjs` (7, unchanged), `tests/waspflow-federation-cli.test.mjs` (10, +3:
`join` auto-populating from `GET /roster`; `contribute` succeeding with zero manual trust when the
author's key is pre-registered; `contribute` refusing a signer the member's own coordinator never
vouched for). **Full federation suite: 181/181 passing, zero regressions.** `scripts/verify.sh` (the
full existing bash + lane/escalation suite) also passes unchanged.

All test artifacts, coordinators, and temp directories were cleaned up after every verification pass;
no stray sandboxes or credential state were left behind (`sbx ls` re-checked clean after each round).

## First independent review (Fable), and fixes applied (carried over from the prior revision)

A second agent with no context from the original build independently re-verified that revision —
reading the code fresh, running the tests itself, and reproducing the journey live — rather than
trusting the report's own narrative. Verdict: **PASS WITH CAVEATS**. Four real, concrete issues were
found; the first is superseded by this revision's `GET /roster` work, the other three are fixed and
still apply:

1. ~~The "two-command" headline overstated the journey (a `trust` call was actually required).~~
   **Superseded by this revision**: `GET /roster` auto-fetch means the two-command journey is now
   accurate for an already-approved member, not merely aspirational.
2. **An unreachable/mistyped coordinator produced a raw `TypeError: fetch failed` stack trace.**
   Fixed: `bin/waspflow-federation`'s coordinator fetches now go through a shared `fetchCoordinator()`
   helper that turns a network-level failure into `could not reach the coordinator at <url>: <reason>`.
3. **`join` never validated the coordinator URL or invite token before saving config.** Fixed: `join`
   now probes the coordinator with the given token before generating a keypair or writing config, and
   reports "coordinator rejected the invite token" or an unreachable-coordinator message immediately.
4. **Temp roster files (`wf-federation-roster-<pid>.json`, public keys only) were never deleted** from
   `os.tmpdir()`. Fixed: `rosterFileFor()` registers a `process.on('exit', ...)` cleanup so the file
   is removed on every exit path.

One real bug was also found and fixed by writing the original tests, not assumed correct:
`bin/waspflow-federation`'s flag parser treated any argument starting with `--` as an unknown flag,
which broke `trust <key-id> <pubkey-pem>` — a multi-line PEM string literally starts with
`-----BEGIN PUBLIC KEY-----`. Fixed to only match a positional-vs-flag decision against the verb's
known flag names, not a blind starts-with scan.

Two lower-severity findings from that same review remain accurate, unfixed, and worth restating:
the stderr-substring matching used to translate `waspflow-federation-pull`/`-submit`'s raw
"not in roster" errors into `trust` guidance is coupled to that exact wording (a future wording
change in those bins would silently degrade to the raw error, not break anything); and after a
refused `contribute` (untrusted signer), the task stays `CLAIMED` for its lease duration on the
coordinator, so an immediate retry reports "no task available" rather than re-surfacing the same
task — a coordinator-side lease-expiry behavior, unchanged and out of this pass's scope.

## Residual friction — flagged for the eventual GUI, not solved here

1. **Membership approval (adding a brand-new member's key_id to the coordinator's roster file) is
   the one remaining "send a message to a human, who then edits a file" step**, by design — see
   "What's auto-managed vs. still manual" above. A GUI's natural fix is a "share my join code" button
   for the new member and an "approve" action for the operator — no further trust-model change
   required, since the underlying mechanism (an operator deciding to add a key_id) stays identical;
   only the relay/approval UX improves.
2. **Claude Code subscription login is unavoidably an in-sandbox `/login`, not a clickable link**,
   until Docker Sandboxes ships a host-drivable Anthropic OAuth flow — a platform limitation,
   independently reconfirmed in this pass, not a Waspflow implementation gap.
3. **No progress bar / percentage for a running `contribute`** — today's CLI streams the underlying
   bin's stderr lines live, which is honest but not a polished progress indicator. A GUI has an
   obvious opportunity here since the loop already emits discrete, ordered milestones (claimed →
   verified → fetched → running → collected → submitted) that a progress list could render directly.
4. The two lower-severity Fable findings restated above (stderr-substring coupling; post-refusal
   lease-hold confusion) remain open, low-severity, and out of this pass's scope.

## Decisions made this session

- **Added `GET /roster`** (owner decision, this revision): a read-only, token-gated public-key
  directory over the coordinator's existing hand-edited roster. Deliberately no write/registration
  counterpart — membership approval stays a human decision enacted by editing the roster file, which
  keeps hot-reloading exactly as before. This removes the redundant public-key relay for
  already-approved members without weakening the trust model (public keys are public; only a write
  surface would be a real security-posture change, and none was added).
- **Correction of a factual error from the prior revision**: that revision incorrectly stated the
  roster-cache design gap (why `waspflow federation trust` was added, with no coordinator roster-read
  endpoint to auto-populate it from at the time) was "flagged to the owner mid-session via
  `AskUserQuestion`, who chose this option." **No `AskUserQuestion` call was made for that decision —
  the Fable orchestrator steered it via `waspflow revise`.** This report does not invent or restate
  an owner quote that didn't happen; the actual owner decision on this topic is the one recorded
  above (add `GET /roster` as the default path, keep `trust` as the fallback).
