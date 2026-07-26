# Federation MVP — Live Validation Report

**Date:** 2026-07-26
**Branch:** `waspflow/fedgui-switcher-ux` @ `a18ed3c` (reconciled: switcher + collective names
+ `--collective-name` flag + PR #22 tray/persistence/stuck-approval fixes cherry-picked in)
**Validator:** parent agent (maker≠judge — I ran every step against live infrastructure and
rendered the real UI; I did not trust worker-lane self-reports).

## What was validated (against real infrastructure, not stubs)

Two live coordinators on the LAN (no ngrok, no proxy — the product's own `--tunnel lan`):
- **A:** `http://192.168.1.7:37257` (source-checkout coordinator on the `simon` box)
- **B (Simon Lab):** `http://192.168.1.180:8787` (named via the new `--collective-name` flag)

Desktop daemon = a real member; Docker 29.6.2 + docker-sbx present and exercised.

### 1. Full contribute→settle journey — PASS (deepest proof)
Requester: `submit` → source packaged → artifacts uploaded → envelope published →
`task_digest` → **coordinator reports `SETTLED`**.
Contributor: `claim` → **independently re-verified the envelope signature (signer tnunamak)**
→ fetched artifacts → built ValidatedJobSpec → ran in Docker sandbox `wf-6033508a80d6f57c`
(`apiKeySource: none` → subscription capacity, **not** the API-key billing trap) → produced
exactly the requested output → `destroy removed=true` → **`status: settled`** with a signed
receipt (`capacity_kind: subscription`, harness `claude-code-subscription`, model, duration,
sandbox_id, identities).

### 2. Daemon-driven contribute (the product path Oshin clicks) — PASS
Toggling contribute via the daemon claimed a queued task, ran it in the sandbox, and returned
`Finished 'validation-echo'`. The transient `failed`→`idle` seen when the queue is empty is
**correct**: "No task is available right now" (daemon-daemon.mjs:824) — a contributor with no
work returns cleanly instead of hanging.

### 3. Switcher: belong to many, one active — PASS
Joining B **appended** to the list (A preserved, not overwritten — the root-cause fix for the
old dead-end). Both memberships listed; switch between them works (HTTP 200).

### 4. Never blocked by a dead active collective — PASS
Switched to A, then **killed A's coordinator while it was active**. The daemon detected
`coordinator_unavailable: true` within one poll cycle (~5s), yet the collectives list stayed
listable and switchable — I switched away freely. The old hard dead-end is provably gone.

### 5. Distinct collective names (no raw URLs) — PASS (+ a real gap found & fixed)
**Gap found:** `federation host`'s name prompt uses `askOptional`, which no-ops on non-TTY
stdin (`!process.stdin.isTTY → return ''`). So a GUI/daemon/headless host left every collective
unnamed — members saw the coordinator URL, the exact "tech demo" tell. **Fix:** added
`--collective-name` (flag-first → prompt → default), reusing existing `parseFlags` /
`saveCollectiveName`. +5 LOC net, one focused test (spawns a real headless host, asserts the
name persists). Proven live: `--collective-name 'Simon Lab'` → `host.json` + `/roster` serve
the name → member captures it → switcher UI shows two distinctly named collectives.

### 6. UI rendered live (maker≠judge visual proof)
Screenshots in `.playwright-mcp/`:
- `live-switcher-named-desktop.png` — "Your collectives": *tnunamak's collective* (Inactive ·
  switch to check) + *Simon Lab* (Active · ready to use), Switch/Leave/Join verbs, no URLs.
- `live-pending-offline-final.png` — the reconciled offline-pending screen: named collective,
  contained approval blob + Copy code + "Send this any way you like", the warm "…nothing here
  is broken" reassurance, and "View collectives →" escape. The original janky screenshot's
  every failure mode is fixed.
- `live-contribute-home.png` — clean product shell (Contribute/Requests/Activity/Help/Settings).

### 7. Test suite — 294/294 PASS (0 fail, 0 skip)
Includes the new `--collective-name` test. Earlier transient failures were the two live-sbx
tests contending on Docker network-proxy injection under my concurrent validation load — they
pass in isolation and in a clean full run (see `inbox/2026-07-26-live-sbx-network-proxy-contention.md`).

### 8. Sibling products healthy (quarantine holds)
`waspflow` main @ `09a236c` and `clawmeter` main @ `9dceb98` unregressed; Federation lives only
on branches. Federation tray = exactly 1 process; installed binary is the honest-states build.

## Honest confidence & remaining gaps

**High confidence** the core loop, switcher, names, and consumer-grade UI are real and work
end-to-end on live infrastructure. What I have NOT closed:

- **The GUI stack is unmerged** (PRs #18–#22 + this branch, 112 commits ahead of main). This
  branch is the coherent tip, but nothing has landed on `main`. Launch requires landing the
  stack in order. **This is the largest remaining item — it is release management, not code.**
- **Name refresh for pre-existing memberships:** a membership joined before the coordinator had
  a name shows the cleaned host label until the next roster refresh. Documented, acceptable.
- **Live-sbx test race** (flagged, not fixed): serialize the two real-sandbox tests to stop the
  network-proxy contention from reading as a red suite.
- **The GUI "host a collective" journey** (the fedgui hosting lane) must pass `--collective-name`
  from its form — the flag now exists; the GUI wiring is that lane's job.
- **Second-machine contributor:** every live run used the desktop as both requester and
  contributor (against a remote coordinator). A genuinely remote *contributor* machine was not
  exercised this session.

**Bottom line:** the product experience clears the "consumer-friendly, not a tech demo" bar for
the single-operator + one-remote-coordinator MVP. The gating work before "launch to Oshin" is
merging the stack to main and the GUI-host name wiring — not further core hardening.
