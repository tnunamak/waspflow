# Federation MVP north-star — consumer-ready for Oshin, launchable (2026-07-24)

Owner directive: this must be an actual consumer-friendly PRODUCT, not a tech
demo, before we bet on it. Take a HOSTILE posture toward added lines of code —
"0 new LOC can be transformative." Improve + validate against best ground truth,
not just build/fix.

## Ground truth (research corpus, sourced — not taste)
- **Actionability ≠ status** (`product-design/actionability-is-a-separate-signal...`):
  Stripe/Plaid/Datadog/Sentry — NEVER a health label ("unreachable") without an
  explicit next-action + a named repair flow. The screenshot violates this: a
  yellow "unreachable / will refresh" banner with no way out.
- **First-class objects, not modes** (`product-design/multi-object-admin-consoles...`):
  Tailscale Machines / Vercel deployments — every entity is a renamable, listable
  row with a detail page and an everywhere-identical verb set. A "collective"
  should be such an object. Being in one that's down = one red row, not a global
  block. Status is a named state WITH a remedy, never raw evidence.
- **Home routes to "the few things that need you"** (Stripe Home) — not a lonely card.
- **Second-person "how this works" in the product's own voice** is the single
  strongest lever for "not vibe-coded / I'd show a friend."
- **Guided first-run, staged per subject, product-observed status, clear "you're
  done"** (`onboarding-ux/...`; Tailscale/Stripe/Plaid/Vercel/Supabase).

## The core conceptual flaw (owner-named)
Federation models "you belong to ONE collective" as a hard state
(`config.json` has a single `coordinator_url`/roster; ~26 refs across 6 files,
16 in the daemon). Consequences: a dead collective BLOCKS you with no escape;
you cannot fluidly join many, host multiple or none. This is a category error —
membership should be plural and a down collective should be a non-event.

## MVP scope decision (hostile to LOC; launchable)
Two tiers, and the discipline is to ship Tier 1 (mostly reframe/copy/routing,
near-0-to-low LOC) and only take Tier 2 if it's genuinely required for Oshin:

**Tier 1 — un-block + make it feel like a product (LAUNCH BLOCKER, low LOC):**
1. Kill every dead-end. The unreachable/pending screen gets an explicit
   next-action + the join-another-collective flow REACHABLE FROM the dead end
   (the escape already exists in Settings — route to it; ~0 new logic).
2. The raw `wfapr1…` blob overflowing off-screen → contained, copyable, with a
   plain-language "what this is / send it to your operator" (the object, not the
   token, is the subject).
3. Status is always a named state + remedy. No lonely card in a white void — a
   real shell + "here's what's happening / here's your next step."
4. A short second-person "how Federation works" in the product's voice.
5. Real reachability for testing via Traefik (not ngrok) so the live journey
   can be validated end to end.

**Tier 2 — true multi-collective membership (take ONLY if Tier 1 isn't enough
for a credible Oshin launch; it's a real architectural change, guard the LOC):**
- config holds a LIST of collectives; daemon can poll/contribute across them;
  "collectives" is a first-class list surface (join/leave/rename, host 0..n).
- If deferred: Tier 1 must still let a user LEAVE a dead collective and JOIN
  another without being stuck — which delivers 80% of the felt benefit at ~5% of
  the cost. The single-active-collective limit is then an honest, stated
  constraint ("one active collective at a time for now"), not a silent dead-end.

## Validation bar (before claiming MVP-ready)
- The full Oshin journey walked live over a REAL public reachability path
  (Traefik), not a loopback demo: install → join → approve → see a task →
  consent → run → settle, plus the FAILURE paths (collective down → clear
  recovery; wrong invite → clear error).
- Every screen passes the actionability test: can a non-technical user always
  see what's happening AND what to do next? No lonely cards, no raw blobs, no
  dead ends.
- Independent verification (maker≠judge), not self-report.

## Not forgetting
clawmeter + waspflow are the sibling products; keep their health in view, don't
let Federation regress them.

## DECISION (2026-07-24, research-backed) — the switcher model, not simultaneous membership

Ground truth (Slack/Discord/Teams/WorkOS/Clerk, sourced via web 2026): consumer
multi-tenant apps converge on **one session + an active-org SWITCHER**, NOT
simultaneous side-by-side membership. You belong to many, are ACTIVE in one at a
time, with a rail preserving awareness. Simultaneous is the harder, rarer thing
even Teams does badly. Critical data-model rule they all cite: **membership is its
own entity, not a column on the user — this early decision sets the UX ceiling.**

Current Federation config is single-collective and join OVERWRITES it (leaving a
dead collective forgets it entirely — the root of the dead-end + "can't be in
many"). 26 `coordinator_url` refs (16 in the daemon) all assume one active.

**MVP = the switcher model:**
- **DO (transformative, low LOC):** store a LIST of known collectives (membership
  as its own entity). Surface join-many / leave / switch / rename. A dead active
  collective → switch away freely, never blocked. This is Slack's real model and
  ~80% of the felt benefit at ~5% of a full rearchitecture.
- **KEEP:** single ACTIVE collective drives the contribution loop — the 26 daemon
  refs point at the active one, unchanged. No loop rewrite.
- **DEFER (Tier 2, not MVP):** simultaneous contribution across collectives. The
  list-based config does NOT foreclose it; it's the future ceiling, not now.

This kills the dead-end at the data-model level (the strongest fix), matches
consumer expectation, and guards LOC.
