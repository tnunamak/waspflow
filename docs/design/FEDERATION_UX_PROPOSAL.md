# Waspflow Federation — UX & IA Proposal

**Author's mandate:** propose a strong, cohesive IA/visual/interaction revision to feed the
Vite+Preact rewrite. Design document only — no application code touched.

**Grounding:** `public/index.html` + `public/app.mjs` (current hash-router vanilla-JS app,
read in full), `FEDERATION_PRODUCT_V1_PRD.md`, `FEDERATION_REDTEAM_OSHIN.md` (the pain
inventory — cited throughout as **[Redteam: finding name]**), live screenshots in
`test-artifacts/federation-ui/*.png`, and the research corpus at
`~/code/dotfiles/ai/research/` (cited as **[Corpus: entry-slug]**).

**Note on timing:** three commits landed today (`1f33e16`, `0b4d4bd`, `b1f47bd`) that already
fix several redteam findings — Pause/Stop is now split with a confirm step, session-expiry
shows a Reconnect action, consent copy ("You approve every task before it runs") appears on
Contribute. This proposal treats those as done and does not re-litigate them; it targets what
remains and the structural IA for the rewrite.

---

## 1. Diagnosis — the biggest problems, with evidence

### 1.1 The IA has one skeleton for two irreconcilable jobs
Contribute/Requests/Activity/Settings/Help is organized by **screen type** (a form, a list,
a history, a config panel), not by **who the user is**. Oshin never submits a request or
reads "My requests" — Requests is 100% Tim's screen. Tim never contributes capacity —
Contribute is 100% Oshin's screen. Settings mixes Oshin's device config (schedule, provider
accounts) with governance info neither role primarily owns (roster). Every screen has to
hedge for an audience that isn't there — e.g., Requests shows "Submit a request" to a
contributor-only user who opens the tab, and Activity interleaves "Collective" (shared),
"Contribution history" (Oshin-private), and "Requester history" (Tim-private) in one
scroll with three different privacy models **[app.mjs:482-495]**. This is a home-vs-mode
problem, not a labeling problem. **[Corpus: agent-fleet-consoles-separate-lifecycle-state-
from-a-supervisor-action-axis]** — the same principle applies here one level up: separate
the axis of "what kind of user is looking" from "what screen type is this," don't conflate.

### 1.2 Consent for account-spending actions is implicit, not a reviewable moment
**[Redteam: CRITICAL — "Contribute next available" accepts work without meaningful informed
consent]**. Even after today's improvements, the task-review sheet (`taskChoices` in
app.mjs:253-262) shows title, author, a one-line prompt preview, and requirement chips —
never the full prompt, an explicit harness/account statement, or an estimated duration/cost
before the accept button. A professional EA reviewing a GTM UI will read "Contribute next
available" then a thin review card as the product *hoping* she doesn't look closely, not as
consent design. Contrast with Docker Hub's/GitHub Apps' permission-grant screens, which name
the exact resource before the button that grants it.

### 1.3 Identity is scattered and unlabeled — a raw ID is standing in for a person
**[Redteam: MEDIUM — Roster and identity surfaces expose mystery identifiers, not people or
authority]**, confirmed live in the Settings screenshot: `oshin`, `tim-author`, `tnunamak`
appear as both display name and duplicated `<code>` chip, "Member ID: tnunamak" reads like
a bug, and a raw `http://127.0.0.1:9099` connection address sits mid-page as if it were
product information. There is no single place answering "whose collective is this, who
approved me, who is this task from" — that information is distributed across Contribute's
one-line "Collective: —", Settings' roster dump, and task rows' bare `author` string.

### 1.4 Receipts are declared "total transparency" but the UI renders placeholders
**[Redteam: CRITICAL — Her private "receipt" is not an accountability record]**, confirmed
in `activityDetail` (app.mjs:440-465): the function is honest about *listing* every promised
field (harness, capacity source, model, usage, sandbox, Docker account, provider account),
but falls back to a generic `"${label} unavailable for this legacy task."` string for every
missing value — including on entries that should have full data. The PRD (P1) promises a
complete private ledger; the UI's failure mode reads as "we forgot to wire this up," which is
worse for trust than not promising it.

### 1.5 The task detail / transcript surface is a single long scroll of six stacked cards
Requests view stacks: submit form → my-requests list → task detail (with embedded timeline)
→ execution receipt → execution transcript button → transcript panel → result — all in one
vertical column regardless of task state (see `advanced-submit-expanded.png`,
`execution-log.png`). For a *running* task this is the single most important screen in the
product (Tim's core job: "watch it live") and it is currently competing for attention with a
submit form above it and a receipt-shaped placeholder below it. **[Corpus: a-kanban-board-
of-worker-states-beats-a-flat-list-for-many-worker-oversight]** and **[Corpus: agent-fleet-
consoles-separate-lifecycle-state-from-a-supervisor-action-axis]**: oversight screens want
state-forward layout (what's running now, ranked by needs-attention), not an undifferentiated
list-then-detail stack.

### 1.6 Copy is dev-speak dressed as product copy, and unfinished-feeling
Confirmed live: "Not reported", "Not reported yet", "Api Key" (mis-cased in the PRD's own
prose too — should be "API key"), raw lifecycle chip text `settled`/`claimed` in lowercase,
"GitHub access is task access, not contribution capacity. The credential stays behind the
sandbox proxy." (architecture-speak on a user-facing form), "Capacity guard: schedule-only"
wording implied by the PRD literally becoming UI text risk. **[Redteam: MEDIUM — Copy and
empty states signal unfinished software]** — Oshin is professionally paid to notice exactly
this register mismatch.

### 1.7 Interruption is not designed for, even though the primary persona is interruption-
driven and 15 hours from support
**[Redteam: HIGH — Interruption destroys unsaved Settings edits...]** — partially mitigated
today by a `dirty` flag + `beforeunload` warning (app.mjs:594-595), but there's still no
route-level guard (navigating within the SPA away from Settings loses the draft silently),
no "Saved 2 minutes ago" persistent state, and schedule editing still uses a raw multi-select
`<select multiple>` for Days (`schedule-days`, app.mjs:543) which is a notoriously bad touch
target and undiscoverable interaction pattern **[Corpus: touch-pickers-need-a-44-48-px-row-
floor]**.

### 1.8 Ambient status has no shared visual vocabulary
Status dots, chips, and banners each invent their own five-ish-color mapping independently
(`.status-dot[data-state]`, `.chip-*`, `.notice`) with overlapping but not identical
semantics — e.g., green means both "idle/ready" and "contributing" for the status dot
(`idle`, `contributing` share one CSS rule, index.html:49) which conflates "waiting" and
"actively spending your account" — precisely the two states Oshin most needs to distinguish
at a glance before an interruption. **[Corpus: false-and-non-actionable-alarms-cause-cry-
wolf-desensitization]** and **[Corpus: aviation-flight-deck-alerting-grades-urgency]**: a
status system that collapses "safe idle" and "actively working" into the same color trains
the user to stop reading it.

---

## 2. Proposed IA

### 2.1 Navigation model: mode-first, not screen-type-first

Replace the single flat nav with **two home surfaces gated by role**, plus shared utility
screens. Most installs are single-role in practice (Oshin only contributes; Tim mostly
requests) but the same person can be both, so this is a **default landing + a switcher**,
never a hard wall:

```
[Waspflow Federation]              Contribute   Requests   Activity   Help    [account/gear]
                                    ───────────
                                    (home = whichever role this install did last;
                                     remembered per-machine, switchable via the tabs)
```

- **Contribute** (Oshin's home) — status, task review/accept, pause/stop, ledger link.
- **Requests** (Tim's home) — submit + live requester view + result access. *Task detail
  and transcript move here as a dedicated sub-route*, not stacked under the form (§3.3).
- **Activity** — now genuinely shared infrastructure, not a third home: a single place for
  "what happened," split by *audience*, not by role-of-viewer (§2.3).
- **Help** stays, content-only, but folds in the onboarding "how it works" as a permanent
  reference (not just a first-run modal).
- **Settings** is demoted from a top-level tab to a gear icon in the header (see §2.4) —
  it is not a place either persona "does their job" in, it's occasional configuration.

This directly answers the brief's contributor-vs-requester tension: **yes, they get
different homes**, because their jobs-to-be-done (`donate ambiently` vs. `submit and
watch`) share almost no screen content today, and today's shared IA is why Settings has
become a junk drawer (roster + schedule + provider accounts + collective name all
competing for one tab). Keeping one shared nav bar (not two separate apps) matters because
a single human can be both, and switching costs must stay near-zero — this is exactly the
"integrating app stays the page owner, one transient surface for the provider step" pattern
**[Corpus: provider-consent-flows-keep-the-integrating-app-as-the-page-owner]** generalized
to internal-mode-switching: the shell persists, only the working surface changes.

### 2.2 Where live transcripts live
**Requests → task detail**, always, for both an in-flight task Tim submitted and (new) a
task Oshin is actively running should be watchable from **Contribute** via a "Watching"
sub-state — today's `Watch live` link (app.mjs:229) already jumps there; keep that
cross-link but make the destination a first-class **Task** route (`#/tasks/:digest`)
addressable independent of which tab launched it, so both a contributor glancing at what
her machine is doing and a requester watching their own task land on the identical
component. One task-detail view, two possible entry points — not two implementations.

### 2.3 Where receipts/ledger live
Split **Activity** into two lenses selected by a segmented control at the top, not by
scrolling past three differently-scoped lists:
- **"What I did"** (private, Oshin's full receipt: harness, model, tokens, duration, sandbox
  id, Docker/provider identity — everything P1 promises, per-entry, never a placeholder that
  doesn't say why data is missing — see §3.5 empty-state copy).
- **"What I asked for"** (Tim's requester history: prompt, result, shared-only receipt
  fields — explicitly *without* contributor identity, matching the PRD's audience split).

Drop the third "Collective" activity feed as its own permanent card; fold a compact "N
members active this week" line into a collapsed disclosure at the bottom of "What I did" —
today it's presented with equal visual weight to the two receipt lenses even though nobody's
job-to-be-done is "read the collective feed."

### 2.4 Local settings vs. collective info
Settings today conflates three different trust boundaries in one scroll: *this device*
(Docker account, provider sign-ins, schedule — Oshin's, local, mutable) vs. *this
collective* (name, roster, coordinator address — shared, read-mostly, governance). Split
into two routes reachable from the gear icon:
- **Device & Accounts** — schedule, provider sign-ins, Docker account, member ID (with a
  plain-language explainer, not "Member ID: tnunamak").
- **Collective** — roster (redesigned per §3.6), coordinator identity, collective name. Make
  explicit in copy that this is *read-only awareness* for v1 ("Collective management happens
  on the operator's machine" already exists as a line — promote it to a section-level
  statement, not a footnote).

### 2.5 Join/onboarding as a first-class path, not a fallback state
Today `authOrJoinView` handles join/pending/revoked/setup/action-needed as *state branches
of the Contribute screen* — meaning the onboarding journey has no dedicated design space; it
inherits Contribute's chrome and never gets to breathe. Promote onboarding to its own
full-bleed flow (no persistent nav during it — there is nothing to navigate to yet):

```
Invite → Joining… → Pending approval → Approved →
  Docker sign-in (why) → Provider sign-in (why) → First task walkthrough → Done
```

Each step: one clear headline, one paragraph of "why this step, what happens next," one
primary action, and a persistent tiny footer link ("Not sure this is right? Ask whoever
invited you" — a copyable, non-terminal escalation, directly answering **[Redteam: HIGH —
Provider-sign-in recovery has a terminal-only branch]** by never introducing a terminal
branch into this flow to begin with). This is the "P5 — First-run integrity" pillar from the
PRD; treating it as five branches bolted onto Contribute's state machine is why it currently
reads as an afterthought. A dedicated onboarding shell also gives natural room for the
consent language from §3.1 to appear once, prominently, rather than being squeezed into a
status card.

---

## 3. Screen-by-screen

### 3.1 Contribute (Oshin's home)

```
┌─ Waspflow Federation ──────────────── Contribute  Requests  Activity  Help  ⚙ ─┐
│                                                                                  │
│  ● Contributing                                    [Pause after this task]      │
│  Working on "render-stability-check" for Tim                     [Stop now ▾]   │
│  ─────────────────────────────────────────────────────────────────────────────  │
│  Collective: Vana Ops · Anthropic (Claude) account · Schedule: always on        │
│                                                                                  │
│  [ Watch what it's doing → ]                                                    │
│                                                                                  │
│  You approve every task before it starts. Nothing runs while paused.           │
└──────────────────────────────────────────────────────────────────────────────────┘
```
Idle / task-review state (the consent moment, §1.2, expanded):
```
┌ Review this task ───────────────────────────────────────────────────────────────┐
│  render-stability-check                                    from Tim             │
│                                                                                  │
│  "Render the transcript for the wave-d demo and confirm timing looks right."    │
│  (full prompt — not a truncated preview)                                        │
│                                                                                  │
│  Will use: your Anthropic (Claude) account · isolated sandbox · no internet     │
│  Estimated: a few minutes, based on similar tasks                               │
│                                                                                  │
│                       [ Accept and run ]      [ Skip this one ]                 │
└──────────────────────────────────────────────────────────────────────────────────┘
```
- **Primary action:** Accept and run (idle) / Pause after this task (active).
- **Empty state:** "No tasks are waiting. You'll see a review card here the moment one is
  ready — nothing runs without your say." (keeps today's honest "nothing will run
  automatically" promise, drops the passive "Choose a task below" CTA copy that implies
  clicking is the only way to get informed).
- **Error/recovery:** coordinator-unreachable banner persists at top of this exact screen
  (not a separate state) with last-known status timestamp and "Retry now" — never collapses
  to a bare idle look, per **[Redteam: HIGH — Coordinator outages are hidden]**.

### 3.2 Onboarding (new first-class flow)
```
┌ Join Vana Ops ───────────────────────────────────────────────────────────────────┐
│  Paste the link or code Tim sent you.                                           │
│  [___________________________________]                                         │
│                                                        [ Join ]                 │
│  Your machine won't do anything until the collective owner approves you.        │
└────────────────────────────────────────────────────────────────────────────────┘
```
Then, one screen per step (Pending → Docker → Claude/OpenAI → first-task walkthrough →
Done), each with the "why" stated before the button, never a bare "Sign in" button with no
context. **Primary action:** always exactly one enabled button. **Empty/waiting state:**
"Pending approval" shows who to ping if it's been a while, with a plain-copy sentence, not a
raw coordinator error. **Error/recovery:** every step defines its own escalation copy;
"needs an agent/terminal" is never a valid recovery instruction on this surface
**[Redteam: HIGH — Provider-sign-in recovery has a terminal-only branch]**.

### 3.3 Requests (Tim's home) — split into two panes, not one long stack
```
┌─ Requests ───────────────────────────────────────────────────────────────────────┐
│  [ + New request ]                                        Filter: All ▾         │
│                                                                                    │
│  ● render-stability-check   Running · claimed by a contributor    2m ago  →      │
│    transcript-check         Settled                               1h ago  →      │
│    laugh                    Settled                                Jul 22 →      │
└────────────────────────────────────────────────────────────────────────────────────┘
```
Clicking a row (or "+ New request") opens a **detail/compose route**, not an inline expand:
```
┌ render-stability-check ──────────────────────────────────────── ● Running ──────┐
│  Queued ●───────● Claimed ───────● Running ───────○ Settled                     │
│         3m ago         2m ago         now                                       │
│                                                                                   │
│  Live transcript                                                    [Raw JSON]  │
│  ┌────────────────────────────────────────────────────────────────────────────┐ │
│  │ Assistant  I'm checking the login test.                                    │ │
│  │ ▸ Tool · bash   ls -la /workspace                                          │ │
│  └────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                   │
│  What was asked                                                                  │
│  "Render the transcript for the wave-d demo..."                                  │
└──────────────────────────────────────────────────────────────────────────────────┘
```
Receipt and result appear as a **collapsed footer that expands only once the task settles**
— don't show "Duration: Not recorded" while a task is still running; that reads as a bug,
not as pending data. The transcript is the primary content for a running task (Tim's actual
job-to-be-done: "watch it"); receipt/result promote to primary content only once settled.
- **Primary action:** New request (list) / none — read-only — while running (detail).
- **Empty state (list):** "No requests yet. Submitted tasks and their live progress will
  show up here."
- **Error/recovery:** a failed task gets a named, red-bordered state in the timeline itself
  ("Failed — see reason below") with the actual stderr-derived reason inline, never silently
  reverting to a generic prior state **[Redteam: HIGH — A failed contribution disappears
  into an idle state]** (this applies symmetrically to the requester's view of a failure,
  not just the contributor's).

### 3.4 Submit form (its own step inside Requests, not competing with the list)
Keep the current field set (name, description, files/folder, advanced git options) but move
it behind "+ New request" so the list-of-requests is the default Requests view, matching
what a returning Tim actually wants (check status), not what a first-time Tim wants (submit).
Retain the honest microcopy win already present ("Without a folder, the task starts in an
empty workspace") — that's a good pattern, keep it as the house style (§4).

### 3.5 Activity — "What I did" (Oshin's private receipt, §2.3)
```
┌ What I did ──────────────────────────────── What I did | What I asked for ──────┐
│  render-stability-check      Completed for Tim         2h ago         ›         │
│  laugh                       Completed for Tim          Jul 21        ›         │
└──────────────────────────────────────────────────────────────────────────────────┘
```
Detail (replacing every bare "Not reported" with a *reasoned* unavailable state):
```
┌ render-stability-check ──────────────────────────────────────────────────────────┐
│  Completed for Tim · finished 2h ago · ran 47s                                   │
│                                                                                    │
│  Model            Claude Sonnet 5                                               │
│  Tokens           1,204 in · 3,880 out                                          │
│  Sandbox          sbx-8a13f0                                                     │
│  Your account     tim@… (Anthropic, subscription)                               │
│  Docker account   timodl                                                        │
│                                                                                    │
│  Prompt: "Render the transcript for the wave-d demo…"     [ Copy reference ]    │
└──────────────────────────────────────────────────────────────────────────────────┘
```
When a field is genuinely unavailable: **"Not captured — this task ran before receipts were
enabled"** or **"Not captured — the harness didn't report token usage for this run"**, never
a bare "Not reported." This is the direct fix for **[Redteam: CRITICAL — Her private
"receipt" is not an accountability record]**: the fields the PRD promises are the fields
that must render or explain themselves, never fall through to an unexplained placeholder.
- **Primary action:** none (read surface) — "Copy reference" for support.
- **Empty state:** "Nothing completed yet. Every task you run will get a full private
  receipt here."
- **Error/recovery:** N/A (read-only historical data; a load failure gets a plain retry).

### 3.6 Collective (under the gear icon, §2.4)
```
┌ Collective ──────────────────────────────────────────────────────────────────────┐
│  Vana Ops · run by Oshin                                                         │
│                                                                                   │
│  Members                                                                         │
│  ● Oshin           You · joined Jul 10                                          │
│  ○ Tim             Requester · added Jul 12                                     │
│  ○ tnunamak        Contributor · added Jul 15                                   │
│                                                                                   │
│  ▸ Technical details (connection address, machine keys)                        │
│                                                                                   │
│  Membership changes happen on Oshin's machine today.                            │
└──────────────────────────────────────────────────────────────────────────────────┘
```
Lead with a **display name + role + human date**; move the raw key-id under a collapsed
"Technical details" disclosure. This directly fixes **[Redteam: MEDIUM — Roster and identity
surfaces expose mystery identifiers]** — a name a person recognizes, not a duplicated code
chip.

### 3.7 Help
Keep the existing three cards (How it works / Your safety boundary / Questions people ask)
— this is one of the stronger existing screens (clear headings, short paragraphs, honest
FAQ). Add one more FAQ entry surfacing "What happens if I get interrupted mid-task?" since
that's the persona's defining constraint and currently unaddressed anywhere in the product.

---

## 4. Design system

### 4.1 Type scale
Keep the existing sans stack (Inter/system-ui) — it's already a reasonable choice. Tighten
to a 4-step scale used consistently (today `h2`/`h3` sizes are set ad hoc per element):

| Role | Size | Weight | Use |
|---|---|---|---|
| Display | 1.5rem / 24px | 760 | Status label ("Contributing", "Ready when you are") |
| Heading | 1.125rem / 18px | 720 | Panel titles |
| Body | 1rem / 16px | 400–650 | Copy, labels |
| Meta | 0.85rem / 13.6px | 500–650 | Timestamps, muted detail, chips |

### 4.2 Spacing
Keep the current 8px-derived rhythm (panel padding 24/18px, gaps 16/9px) — it already reads
as a coherent scale, just formalize it as tokens for the Preact migration:
`--space-1: 4px; --space-2: 8px; --space-3: 12px; --space-4: 16px; --space-5: 24px; --space-6: 32px;`

### 4.3 Color roles — collapse to 4 ambient status colors used consistently everywhere
The current CSS defines overlapping meanings across `.status-dot`, `.chip-*`, and `.notice`.
Unify to one status vocabulary applied identically to dots, chips, and banners:

| Role | Color | Meaning | Current bug it fixes |
|---|---|---|---|
| **Active/spending** | Blue `#19597e` on `#e6f0f7` | Actively using an account right now (contributing, claimed, running) | Currently shares green with "idle" — the single most important distinction Oshin needs before an interruption |
| **Ready/safe** | Green `#176a46` on `#e1f3e8` | Idle-safe, settled, signed in, approved | Currently also used for "contributing" |
| **Needs you** | Amber `#b37d17` on `#fff4dc` | Paused, action-needed, sign-in required, unsaved draft | Consistent already — keep |
| **Problem** | Red-brown `#8b3513` on `#fff0eb` | Failed, revoked, session-expired, coordinator unreachable | Consistent already — keep |

Apply this 4-way mapping to the status dot, every chip, and every banner — a single
`data-status="active|ready|attention|problem"` attribute driving all three components, so a
dot and its adjacent chip can never disagree. This is the direct fix for §1.8, and matches
**[Corpus: aviation-flight-deck-alerting-grades-urgency-into-warning-caution-advisory]**
(a small, fixed vocabulary, consistently applied, beats a large ad hoc palette) and
**[Corpus: false-and-non-actionable-alarms-cause-cry-wolf-desensitization]** (truthfulness
of the signal is the binding constraint — "active" must never quietly mean "idle").

### 4.4 Component inventory (plain CSS, no library — Preact-ready)

- **Panel** — existing `.panel` (white card, 1px border, 12px radius, 24px padding). Keep.
- **Status chip** — rebuilt on the 4-role vocabulary above; capitalized human label always
  (`Settled`, not `settled`); the "role hint" for a person (You / Requester / Contributor)
  is a *separate* chip style (neutral gray, no status color) so it's never confused with
  task-status chips.
- **Device-code panel** — existing one-time-code pattern (`.one-time-code`, click-to-copy +
  explicit Copy button) is good and accessible; keep verbatim, reuse for every future device
  flow (GitHub, OpenAI, Google all converge on it already).
- **Transcript view** — keep the existing readable/raw-JSON toggle (`transcriptPanel`) — a
  strong pattern already: tool calls collapse into `<details>`, assistant turns render as
  plain text. Promote it to a shared component used identically whether reached from
  Contribute's "Watch live" or Requests' task detail (§2.2) — today it only renders inside
  `taskDetail`.
- **Timeline** — keep the 4-stage horizontal stepper, but add a named "Failed" stage that
  can appear instead of "Settled" (currently the model has no failure terminal state, per
  §3.3's error/recovery note).
- **Consent/review card** — new component (§3.1): a distinct, slightly elevated card style
  (not just another `.panel`) used only for irreversible/account-spending confirmations
  (accept task, stop now, revoke). Visually distinguishable from informational panels so its
  higher stakes register at a glance.
- **Empty state** — standardize on: bold one-line statement + one sentence of what will
  appear and when. Never a bare "Not reported."

---

## 5. UX-writing pass

Voice/tone rules (extending the product's existing better instincts — "Ready when you are,"
"Without a folder, the task starts in an empty workspace" are already good models):

1. **Say what happened, then what's true now, then what to do** — never lead with system
   internals (accounts, sandboxes, proxies) when a plain consequence will do.
2. **Never say "not reported" without saying why** — every missing value gets a reason
   clause.
3. **Name the account and the person, not the mechanism** — "your Claude account," "Tim,"
   never "capacity source" or "author_key" in user-facing copy.
4. **One sentence of why before every irreversible or account-touching button.**
5. **Casing:** Title Case for headings/buttons, sentence case for body copy and chip labels
   (never raw enum casing like `settled` or `Api Key`).
6. **No architecture vocabulary in front-stage copy** ("capacity source," "sandbox proxy,"
   "coordinator," "spend policy") — reserve for a collapsed "Technical details" disclosure.

Concrete replacements:

| Current | Replace with | Why |
|---|---|---|
| "Choose a task below" | "Review a task" | The action is reviewing/consenting, not merely choosing — names the actual moment (§1.2). |
| "Contribute next available" | "Review the next task" | Removes the implication that clicking = running; matches the new review-before-accept flow. |
| "GitHub access is task access, not contribution capacity. The credential stays behind the sandbox proxy." | "This only lets the task read the repository it names — never your other GitHub activity." | Same guarantee, zero architecture vocabulary. |
| "Not reported" / "Not reported yet" (identity fields) | "Not detected yet — checking your Docker sign-in…" (or the specific live reason) | Distinguishes "still loading" from "permanently absent." |
| "${label} unavailable for this legacy task." (receipts) | "Not captured — this task ran before receipts were turned on." | States a real, specific, non-alarming reason (§3.5). |
| "Api Key" | "API key" | Basic casing correctness — a visible quality signal to a QA-trained reviewer. |
| Lowercase chip text `settled`, `claimed` | "Settled", "Claimed" | Sentence case throughout, never raw enum text. |
| "Member ID: tnunamak" | "Your machine's ID: tnunamak — this is how Vana Ops recognizes this computer, not a person." | Names what the ID actually is; stops it reading as a person's name. |
| "Collective: your collective" (placeholder-looking default) | Omit the line entirely until a real name exists, or show "Ask Tim what to call this collective" | Never render a value that looks like unfilled template text. |
| "Pause is always available immediately." | "You can stop contributing at any time — nothing is lost by pausing." | Reassures about consequence, not just availability. |
| "Contribution finished." (unrecognized-outcome fallback) | "This task ended without a clear result. [See what happened →]" | Never claim success-shaped language for an unknown outcome (**[Redteam: HIGH — A failed contribution disappears into an idle state]**). |
| "Sign-in needs support" / raw manual-instruction text block | "[Provider] sign-in isn't available from this screen yet. [Contact/][Try again later]" — remove the terminal-instruction branch entirely | Never route a non-technical user to "inside your agent" (**[Redteam: HIGH]**). |
| "Waspflow is not running. Open Federation again from Waspflow." | "Federation isn't running right now. [Reconnect] · Last seen 12:41 PM — nothing changed since then." | Adds the reassurance + timestamp the redteam asked for; already partly shipped, extend with the timestamp. |
| "Days" multi-select showing raw `<select multiple>` | Replace with day-of-week toggle chips (Mon Tue Wed…) | Not a copy fix but a component fix that removes copy ambiguity ("how do I select more than one day?"). |

---

## 6. Prioritized adoption plan for the Vite+Preact migration

**Adopt immediately (structural — cheap now, expensive later):**
1. Two-home IA (§2.1): route structure `#/contribute`, `#/requests`, `#/activity`,
   `#/help`, `#/tasks/:digest`, `#/settings/device`, `#/settings/collective`. Get this right
   at the Preact router layer now — retrofitting IA after component trees calcify is the
   expensive path.
2. One `<Task>` component addressable from both Contribute and Requests (§2.2) — build it
   once as a route-level component, not duplicated per-tab markup.
3. The 4-role status-color system as CSS custom properties + one `data-status` attribute
   (§4.3) — trivial to establish now as design tokens, painful to retrofit across dozens of
   components later.
4. Activity's two-lens split (§2.3) as two routes/components from day one, not a shared
   component with a role prop that special-cases both audiences internally.
5. Settings split into Device vs. Collective as separate routes (§2.4).

**Layer in soon after (behavior, still pre-launch):**
6. The expanded task-review/consent card (§3.1) replacing the thin `taskChoices` preview —
   needs backend support for duration estimate but the component shape should exist now.
7. Onboarding as its own routed flow outside the main nav shell (§2.5, §3.2).
8. Receipt "reasoned unavailable" copy (§3.5, §5) — purely a rendering/copy change, low
   risk, high trust payoff; do early.
9. Day-of-week toggle-chip component replacing the `<select multiple>` (§5 last row).

**Can wait (polish, once the structure is proven):**
10. Full visual system pass (type scale formalization, spacing tokens) — the current values
    are already close; codify as tokens opportunistically as components are ported, not as
    a big-bang restyle.
11. Collective roster redesign (§3.6) full display — can ship the route split first with
    today's roster list, then improve the row design.
12. Failed-task terminal state in the timeline component (§4.4) — valuable, but depends on
    backend surfacing a real `failed` status distinct from `idle`, which is partly a backend
    contract change, not just UI.
13. Micro-interactions/animation — explicitly last; nothing above depends on it.

---

## Summary of what NOT to do

Do not build two separate SPAs for contributor vs. requester — the shared shell (header,
routing, design tokens, the `<Task>` component) is real leverage and a single person is
sometimes both roles. Do not treat Settings as a single tab; it is two different trust
boundaries wearing one hat today, and that's a large share of why the redteam found "Member
ID" and a raw connection address on the reviewer's first pass. Do not keep inventing a new
status-color meaning per component — that is the direct cause of green meaning two different
account-spending states today.
