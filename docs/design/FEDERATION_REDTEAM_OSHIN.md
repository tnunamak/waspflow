# Federation red-team: Oshin Mylvaganam

**Persona:** Executive Assistant to the COO, Operations; Brisbane (UTC+10);
lightly technical; interruption-driven; no terminal access; normally has no
synchronous access to the Chicago-based owner.

**Verdict:** **do not put Oshin on this surface unattended yet.** The happy
path is calm and legible, but it asks her to donate accounts without providing
the consent, accountability, or self-recovery required when support is asleep.
The most serious defects are not visual polish; they are misleading safety
claims, silent/unnamed failure paths, and actions whose real consequence is
hidden behind a benign label.

## Scope and evidence

- Read `docs/design/FEDERATION_PRODUCT_V1_PRD.md`, `public/index.html`, and
  `public/app.mjs`; checked the daemon failure/state contracts that supply the
  UI.
- Exercised the live daemon at `127.0.0.1:8904` with its local session token.
  It was `idle`, had five completed ledger entries, one settled request, three
  roster entries, and no available task. A safe start returned
  `contributing`, then `idle` / **“No task is available right now.”**; I also
  sent `POST /contribute/stop` after that start and restored the final state to
  `idle` with a no-task start. No task was submitted and no sign-in button was
  used.
- Probed missing and invalid tokens: both are real `401` responses with
  `{"error":"missing or invalid daemon session token"}`. Rendered all five
  routes in headless Chrome at 390 px and inspected live text, controls, and
  keyboard focus. The static error-only states below are marked as code/daemon
  contract evidence rather than claimed as a live outage.

Severity means impact on Oshin completing work safely without synchronous
support: **CRITICAL** = unsafe donation or a no-way-out state; **HIGH** = she
is likely stranded, misled, or loses meaningful work; **MEDIUM** = trust,
clarity, or accessibility erosion that will produce a UI bug or avoidance.
There are no standalone LOW findings: the smaller visual and copy defects here
materially compound a trust or recovery failure, so they are included at
MEDIUM.

## Ranked findings

### CRITICAL — “Contribute next available” accepts work without meaningful informed consent

**Screen + state:** Contribute, `idle`, including the automatic next-task path
after Oshin presses **Start contributing**. The task picker exposes only a
two-line prompt preview, author when supplied, task age, and `Network: on/off`
(`public/app.mjs:183-196`). The live empty state then promises that Waspflow
will pick up “the next trusted request.”

**Why this breaks trust:** Oshin is lending *her* machine and provider account
to a colleague's work. “Trusted” is undefined and the automatic option gives
her no chance to inspect the full request, source name/size, expected harness
and account, spend/quota policy, expected duration, or an explicit statement
of what can access the network. The adjacent assertion, **“Waspflow only helps
out with capacity you’re not using,”** is stronger than the product actually
shows: there is no visible quota, cap, estimate, or guard decision. This is an
unearned promise, not informed consent.

**Concrete fix:** Before enabling automatic contribution, show a persistent
consent summary: collective/coordinator, account and capacity source, actual
guard state (schedule, quota/cap, or explicitly “schedule-only; usage is not
available”), and exactly what “automatic” accepts. For a chosen task, provide
a full review sheet with source name/size, complete prompt, requester identity,
network permission, harness/model, and an explicit **Accept this task**. Make
automatic contribution an opt-in setting with a reversible scope, not the
default implication of a primary button.

### CRITICAL — Pause is a destructive stop disguised as a harmless pause

**Screen + state:** Contribute, `contributing`; Help FAQ, **“How do I stop?”**
(`public/app.mjs:162-179`, `371-376`).

**What actually happens:** `POST /contribute/stop` kills the supervised child
immediately (`lib/federation-daemon.mjs:1031-1049`). The UI says only
**“Pause contributing”** and Help says **“Nothing new starts while paused.”**
It does not say whether a current task is cancelled, whether account usage has
already occurred, whether the task will be retried/requeued, or what the
requester will see. The live safe test confirmed that stop changes the state to
`paused`; it cannot establish the effect on a real task, but the kill call can.

**Why this breaks trust:** An interrupted EA will reasonably use Pause before
answering a call. She can unintentionally terminate someone else's task after
spending her quota, then has no receipt or recovery explanation. This violates
both the usual destructive-action expectation and the PRD's zero-silent-failure
bar.

**Concrete fix:** Split the action into **Stop accepting new tasks** and
**Cancel current task**. The latter needs a confirmation that names the task,
explains its effect, shows elapsed usage, and offers “let it finish, then
pause.” Persist a clear cancellation/requeue outcome in both her ledger and
the requester timeline.

### CRITICAL — Her private “receipt” is not an accountability record

**Screen + state:** Activity → Contribution history → select an entry. The
live list exposes title, finish time, model (sometimes), and tokens (sometimes).
The detail view supplies duration, “Models (combined),” “Usage (combined),”
and requester; it omits task prompt/source, harness, sandbox ID, capacity
source, the Docker/provider identities that were used, and a durable result or
task reference (`public/app.mjs:286-315`). Several live entries say **“Receipt
pending”** or **“Not reported”** without explanation or a recovery path.

**Why this breaks trust:** P1 promises Oshin a full private receipt of what
ran on her account, including identity, model, token usage, duration,
timestamps, sandbox ID, and identities involved. The daemon ledger contains
many of these facts, but the UI does not render them. A professional QA
reviewer will see “private receipts” as an overclaim when she cannot answer
“what did this do on my account?” after the fact.

**Concrete fix:** Make every activity row open a complete private receipt:
task/requester, source name/size, full lifecycle, harness/model, capacity
source and policy decision, input/output tokens, duration/timestamps, sandbox
ID, Docker/provider account identity, result status, and a copyable support
reference. Show data provenance and a specific unavailable reason (for
example, “legacy task completed before receipts were captured”), never a bare
“Not reported.”

### HIGH — A stale tab produces an opaque dead end, not a session recovery

**Screen + state:** Any route reopened with a missing or expired `?token=`.
The live API returned the exact 401 above. The app surfaces that raw backend
string in the red alert and retains only the loading/previous shell
(`public/app.mjs:386-390`, `418-434`).

**Why this strands Oshin:** At 2 am she does not know what a daemon session
token is, cannot obtain one from a terminal, and **“missing or invalid daemon
session token”** gives no recovery action. “Open Federation again from
Waspflow” exists only for a missing *query parameter*, not for the real 401.

**Concrete fix:** Treat 401 as a first-class `session_expired` screen: “This
local link has expired; no task or account change was made.” Give one visible
**Reconnect Federation** action that opens/asks the local launcher for a fresh
link, plus concise fallback instructions appropriate to a non-terminal user.
Never display the transport/authentication error as the primary copy.

### HIGH — If the daemon is down, “open it again” is not self-service

**Screen + state:** Any route while the local daemon is not running. The app
maps a network exception to **“Waspflow is not running. Open Federation again
from Waspflow.”** (`public/app.mjs:433`).

**Why this strands Oshin:** Reloading a stale browser tab does not start a
daemon. The product supplies no launch/reconnect action, no check of whether
her work is still running, no preserved state, and no way to distinguish a
local daemon problem from Wi-Fi or an expired session. This is especially
untenable in Brisbane while the owner is asleep.

**Concrete fix:** Present a dedicated recovery screen with a one-click local
launcher/reconnect action, last-known state and timestamp, and plain-language
fallback (“Federation is not running on this computer; no new task can start”).
After reconnect, restore the route and selected detail rather than dropping
her at a generic landing state.

### HIGH — Coordinator outages are hidden until she tries to donate work

**Screen + state:** Contribute `idle`, Requests, Settings roster, and task
detail while the coordinator is unreachable. `/tasks`, `/requests`,
`/roster`, and task-detail fetch failures are deliberately swallowed as
“optional” fallbacks (`public/app.mjs:394-405`, `418-428`). The result looks
like an empty task list, “Roster unavailable,” or an incomplete history while
the local status can still say “Ready when you are.”

**What she would see on start:** The daemon preserves only the final stderr
line (`lib/federation-daemon.mjs:55-57`, `596-601`). The contributor CLI's
actionable two-line coordinator failure is reduced to a terminal-oriented
instruction such as **“Check the coordinator URL (see: waspflow federation
status) and that the coordinator is running.”** (`bin/waspflow-federation:159-170`).

**Why this strands Oshin:** The product creates a false “nothing is waiting”
or “ready” state, then tells a non-terminal user to run a command. She cannot
tell whether pausing is prudent, whether an active task completed, or whether
the issue is hers versus the coordinator's.

**Concrete fix:** Preserve the last successful coordinator data, timestamp it,
and show a persistent **Coordinator unavailable** banner/status on every
affected view. Disable new starts with a reason; leave Pause available. Give a
plain retry action and a support/reference ID, not a CLI command. Retain the
full child failure reason as structured status history rather than truncating
it to its last line.

### HIGH — A failed contribution disappears into an idle state with no accountable outcome

**Screen + state:** Contribute after a claimed/running task exits nonzero. If
the child emits no recognized event, `reflectContributeEvent` sets `idle` with
only the final stderr line; if it emits an unrecognized event it instead says
**“Contribution finished.”** (`lib/federation-daemon.mjs:596-632`). The
Contribute screen then renders the pleasant **“Ready when you are”** status,
and Activity only lists completed contributions (`public/app.mjs:300-315`).

**Why this strands Oshin:** A provider, sandbox, or task failure can happen
after work and account use have begun. She cannot identify the task, learn
whether it was retried or requeued, know whether her account consumed usage,
or provide a useful report to the requester. The PRD expressly requires the
actual failure reason in contribution detail; this is the opposite.

**Concrete fix:** Add a durable `failed` contribution state and an Activity
entry immediately, with task identity, full structured reason/stderr tail,
timeline, elapsed usage, sandbox status, next automatic behavior, and clear
actions (Retry safely, Pause, or Copy incident reference). Do not collapse a
failure into idle until that outcome has been acknowledged or remains visibly
available.

### HIGH — Revoked approval is indistinguishable from waiting, and can be invisible mid-task

**Screen + state:** Contribute after the member disappears from the roster.
When idle, the daemon changes to `pending_approval`; the screen says
**“Waiting for approval”** and **“Your collective owner needs to approve this
machine”** (`public/app.mjs:144-147`). It does not identify a revocation,
when it changed, who can fix it, or whether a task/account was affected.
While `contributing` or `paused`, the approval poll intentionally does not
change state when the roster no longer contains her (`lib/federation-daemon.mjs:415-438`).

**Why this breaks trust:** “Not yet approved,” “coordinator unreachable,” and
“approval revoked” are materially different events in an asymmetric-power
relationship. The latter is a consent boundary change. Hiding it while a task
runs means Oshin may believe she remains authorized; hiding it while idle
makes her wait for a person who may never act.

**Concrete fix:** Model `approval_revoked` separately with the detected time,
current-task policy, and a clear statement that no new work will start. If a
task may finish, say so explicitly and pause afterward; otherwise cancel it
with the transparent outcome described above. Include owner/coordinator
contact and a self-service refresh/retry action.

### HIGH — Provider-sign-in recovery has a terminal-only branch and weak context

**Screen + state:** `action_needed` after provider auth expires. Browser
handoff says **“Complete the sign-in in your browser. Contribution will resume
automatically.”**; the manual branch says **“Complete the listed step inside
your agent, then start contributing again”** and renders raw instruction text
(`public/app.mjs:152-157`). The latter is a hard dead end for Oshin. The live
Settings view also exposes two identical **Sign in** buttons (OpenAI and
Google) with no accessible service name or explanation of which account will
actually run work.

**Why this breaks trust:** She does not use agents or terminals, and a
provider prompt may expire while she is pulled away. The UI neither names the
affected account/capacity source on the action screen nor records the task and
usage that are waiting. “Automatically” is an uncontrolled promise; she
cannot tell whether it will resume the same task after an interruption.

**Concrete fix:** Every auth state must name the provider/account, task,
reason, expiry/timeout if known, and exact next outcome. Eliminate terminal
instructions from this product surface: provide a supported browser/device
flow or mark the provider unavailable with an owner-free fallback. Give each
Sign in button an accessible, specific name (for example, “Sign in to OpenAI”)
and retain a resumable task/auth state across reloads.

### HIGH — Interruption destroys unsaved Settings edits; schedule is unsafe across time zones

**Screen + state:** Settings while editing collective name or schedule. Those
controls are initialized from persisted settings each render but have no local
form state (`public/app.mjs:327-340`). The app polls every 1.5 seconds and
replaces the whole root whenever fetched state changes (`public/app.mjs:418-450`);
there is no dirty-state warning on navigation/reload.

**Why this matters for Oshin:** An EA will be interrupted halfway through a
schedule change. A refresh can silently reset unsaved Settings fields. Even a
saved schedule has only bare Start, End, and free-text Days—no timezone,
current/next active period, validation, or “this is Brisbane local time”
statement. She and the owner are roughly 15 hours apart, so this is a
predictable accidental-donation risk.

**Concrete fix:** Keep a dirty draft independent of polling renders; warn
before route/unload loss; show saved/unsaved state and Save progress. Replace
free-text Days with selectable days, validate start/end, declare and display
the timezone (default to the contributor machine), and show a human next-run
preview plus the currently effective pause/schedule state.

### MEDIUM — The first minute does not establish identity, purpose, or what changed

**Screen + state:** Live Contribute `idle`. Rendered text says
**“Collective: your collective,” “Ready when you are,”** and **“No task is
available right now.”** The main explanatory safety/identity content is buried
under Help and Settings.

**Why this will generate a QA bug:** The page does not answer “whose
collective is this?”, “which account will be used?”, “what changed since I
last looked?”, or “what should I do now?” before presenting Start. A real
first-time reviewer will read “your collective” as placeholder copy. The
current status also preserves the prior automatic selection (`selection:
"next"`) after no task was found, but the screen does not distinguish that
from an untouched idle state.

**Concrete fix:** Make the default card a compact orientation/status summary:
collective and coordinator identity, provider/capacity source, schedule/guard
state, last event with time, and one recommended next action. If identity data
is missing, say why and offer a concrete repair, never substitute “your
collective.”

### MEDIUM — Roster and identity surfaces expose mystery identifiers, not people or authority

**Screen + state:** Settings → Accounts in use / Collective roster. The live
screen showed raw member IDs such as `oshin`, `tim-author`, and `tnunamak`
twice (once as the name and once as code) and calls `tnunamak` a **Member ID**.
It also exposes a raw local connection URL. Roster entries have no person
name, role, date added, requester/contributor relationship, approval status,
or explanation of who controls membership (`public/app.mjs:358-367`).

**Why this breaks trust:** A key ID is not a person Oshin can recognize or
hold accountable. It is precisely the kind of technical residue she would file
as a UI defect. The PRD asks for names/keys and added dates, not a key dump.

**Concrete fix:** Lead with verified display name and role; put copyable
technical ID under “Technical details” with an explanation. Show who approved
her, when membership last changed, and a human-readable coordinator name. Do
not show a raw connection address as primary product information.

### MEDIUM — Copy and empty states signal unfinished software

**Screen + state:** Activity and Settings. Live examples include **“Receipt
pending,” “Not reported,” “Not reported yet,”** and incorrectly title-cased
**“Api Key.”** Activity detail is permanently labeled **“Usage as reported by
the agent (Claude Code)”** even though the product supports other providers
(`public/app.mjs:286-295`). A task selector uses raw lower-case lifecycle chips
such as `settled`.

**Why this breaks trust:** These phrases do not say whether information is
late, unavailable by design, failed to load, or a defect. The provider-specific
claim makes the identity surface look copied from a prototype. Oshin is paid
to notice this level of quality.

**Concrete fix:** Use specific states with reason and next action: “Receipt
data unavailable for this legacy task,” “Refreshing account identity,” or
“Could not load—Retry.” Use human casing (`API key`, `Settled`) and provider-
neutral copy drawn from actual receipt data.

### MEDIUM — Accessibility/state delivery will be noisy and ambiguous for keyboard and assistive-tech users

**Screen + state:** All routes. The entire `<main>` is `aria-live="polite"`
and its children are replaced on polling renders (`public/index.html:115`,
`public/app.mjs:447-450`), so an assistive technology can be asked to re-read
large changing regions repeatedly. There is no page `<h1>` or skip link.
The two rendered Settings buttons both have the accessible name **“Sign in”**;
form fields have visible labels but no `name`/`autocomplete` metadata.

**Why this matters:** This adds cognitive load during an interruption and
makes the service-provider choice uncertain even without a screen reader. It
also fails the expected first-minute hierarchy for a page that must survive
without help.

**Concrete fix:** Announce only small, meaningful status updates in a dedicated
live region; do not live-announce the app shell. Add one `<h1>`, a skip link,
specific button names, and semantic form names/autocomplete settings. Move
focus to a new blocking error/recovery action, not to every polling update.

## 2 am Brisbane recovery matrix

| Scenario | What Oshin actually sees | Can she recover alone? | Dead end / required product behavior |
| --- | --- | --- | --- |
| Coordinator unreachable | Usually a deceptively normal local `idle` screen with empty optional data; on Start, only the last CLI stderr line survives, instructing her to check a URL/run `waspflow federation status`. | No. | Visible coordinator-outage state, retry, last-known task status, and non-terminal recovery. |
| Stale/expired session | Actual 401 text: “missing or invalid daemon session token.” | No. | Recognize 401; offer one-click reconnect/fresh link and reassure her no work changed. |
| Contribution fails mid-task | Unstructured nonzero child output becomes `idle` with only its final stderr line, or generic “Contribution finished”; no failed ledger entry/timeline. | Not reliably. | Structured failed state tied to task, full reason, spend/elapsed usage, retry/requeue result, and durable history. |
| Approval revoked | Generic “Waiting for approval” while idle; no distinction from first approval or outage. While contributing/paused, poll code leaves the old state visible. | No. | Distinct revocation state with time, task policy, owner/contact, and no-new-work enforcement. |
| Provider sign-in expires | Browser handoff may work, but manual auth says to act “inside your agent”; Settings has indistinguishable Sign in buttons. | Only for the browser branch, and only if she returns before expiry. | Provider/task-specific browser recovery, expiry/resume status, and no terminal-only instruction. |
| Daemon not running | “Waspflow is not running. Open Federation again from Waspflow.” | No. | One-click local launcher/reconnect, last-known state, and clear fallback. |

## Interruption and asymmetric-power gaps

- Request-form fields are kept in in-memory state while the current tab
  remains, but they are lost on reload/new tab and there is no unsaved-change
  warning. Settings drafts are more fragile: polling re-renders can reset them
  before Save.
- Browser auth has no expiry/resume indicator or saved handoff context. A
  delayed return is indistinguishable from a failed handoff.
- Paused, scheduled, idle, and “automatically looking for the next task” are
  not explained as distinct operational states. The contributor cannot tell
  whether a schedule is governing right now.
- Gratitude is reduced to a count/link or “Finished ‘task’.” It neither names
  the person helped in a human way nor acknowledges the account/capacity she
  donated. More importantly, it does not give her the full evidence she needs
  to decide whether to do it again.

## What would make Oshin file a bug or stop using it

She would file “Sign in buttons do not say which account,” “member names are
raw IDs / duplicated,” “API key casing is wrong,” “receipt says pending forever
with no explanation,” “pause killed a task without warning,” and “schedule has
no timezone.” She would quietly stop contributing after any one of these: a
task runs automatically without a full review, a contribution consumes account
capacity but cannot be audited afterward, or an overnight error tells her to
use a terminal.

The UI has a solid visual baseline—responsive structure, visible focus styling,
and clear primary navigation—but that baseline does not yet meet the PRD's
total-transparency and zero-silent-failure promises. Confidence is **high** for
the live and source-backed findings above; the outage/auth branches not safely
triggered against the shared daemon are **high-confidence contract findings**,
not claimed live reproductions.
