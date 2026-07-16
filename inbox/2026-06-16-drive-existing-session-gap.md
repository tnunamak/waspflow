# Waspflow gap: no way to adopt/drive an existing agent session — feedback from a real co-owner run

**Date:** 2026-06-16
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** A long PDPP reference-implementation session where I (Claude) coordinated
with a **pre-existing** Codex session running in a tmux pane (`main:9.0`, "pdpp RI")
as a co-owner — not a worker I spawned. Tim noticed I kept hand-managing the tmux PTY
and asked, twice: "shouldn't waspflow eliminate the need for you to handle this?" He's
right. This note is the honest diagnosis.

## What actually happened (real, not a demo)

I exchanged ~10 substantial messages with Codex (design questions, contract proposals,
a seam review, sign-offs) over a multi-hour pairing session. For every one I drove the
pane with raw tmux primitives:

```
tmux load-buffer -b X /tmp/msg.txt
tmux paste-buffer -b X -t main:9.0
tmux send-keys -t main:9.0 Enter   # often needed 2-3x — see quirk below
# then, to know when Codex finished:
sleep 60; tmux capture-pane -t main:9.0 -p | tail -30   # poll, guess, repeat
```

This worked, but it is exactly the manual toil waspflow exists to remove. Two concrete
frictions, both traceable to **not going through waspflow**:

### 1. Hand-managing PTY submission (the paste/Enter quirk)
Codex's TUI chunks a pasted multi-line message into several "[Pasted Content N chars]"
blocks and does NOT submit on the first Enter — the trailing newline lands in a
multi-line composer, so I had to send Enter 2–3 times (and `(1)`-style text triggered
zsh glob expansion until I switched to file→load-buffer→paste-buffer). I hand-handle
this every message. A `waspflow revise <agent> "<msg>"` should own all of this:
chunking, submission, the extra-Enter dance, escaping. The caller should never touch
`send-keys`.

### 2. Polling instead of waiting
To know when Codex finished a 7–10 minute reasoning turn, I used `sleep N` + capture in
a loop and *guessed* at completion. waspflow has `wait` (block until idle) precisely so
the orchestrator is event-driven. I wasn't using it — because of the root cause below.
From Tim's seat this looked like "did you both get stuck?" when Codex was simply done
and idle and I hadn't polled yet. Event-driven `wait` would have surfaced the result
the instant it landed.

## Root cause: waspflow is spawn-centric; this was an ADOPT case

Both frictions share one cause: **waspflow owns the PTY only for agents it spawned**
(`spawn` → `wait`/`peek`/`revise`/`reap`). Here the Codex session pre-existed — it's
Tim's co-owner session, started outside waspflow. There is no clean way to say "here is
an existing tmux pane running a Codex/Claude TUI; adopt it and give me the same
`wait`/`revise`/`peek`/`reap` surface." So I fell back to raw tmux and paid the manual
tax on every interaction.

This is a legitimate **tool gap**, not just operator laziness — though it's ~40% me,
too: even for spawned agents I should default to `wait`/`revise` over `sleep`+capture,
and I reached for the manual primitives out of habit because the pane was already there.

## Proposed feature: `waspflow adopt`

```
waspflow adopt <agent-name> --pane main:9.0 --provider codex
# then the full surface works against it:
waspflow revise <agent-name> "<message>"   # owns chunking + submission quirks
waspflow wait   <agent-name> --timeout 900 # event-driven idle detection
waspflow peek   <agent-name>
# (no reap — adopt does not own the session's lifecycle; detach instead)
```

Requirements that fall out of this run:
- **`revise` must own submission**: multi-chunk paste, the extra-Enter/carriage-return
  to actually submit, and glob-safe payloads (load-buffer, not send-keys for text).
- **`wait` needs robust idle detection per provider.** Codex shows a `Working (Ns…)`
  spinner and returns to a `›` prompt when idle; Claude has its own markers. Idle =
  "spinner gone AND back at prompt for K stable polls." Encode this in the provider
  adapter (the 5-fn shape already exists), so `wait` is reliable across both.
- **`adopt` has no `reap`** — it doesn't own the session lifecycle. It detaches cleanly,
  leaving the human's session running.

## Why this matters

The whole pitch of waspflow is "turnkey spawn/steer/reap from any dir." But a very common
real shape is: the human already has Codex/Claude sessions open in panes and wants an
orchestrator to *coordinate* them — exactly this PDPP co-owner pairing. Today that case
drops out of waspflow entirely and back into raw tmux, which is where both frictions Tim
flagged came from. `adopt` would close that gap and make the steer/wait surface uniform
whether waspflow spawned the agent or not.

**Not urgent** — logged from a real run, to revisit when waspflow gets attention. The
manual path works; it's just the toil waspflow is supposed to delete.

## Addendum: the same quirk bites `spawn`, and misreading it causes duplicate queued inputs

Spawning 3 Codex lanes in this same session, the multi-chunk-paste quirk struck again — this
time INSIDE waspflow's own `spawn`. Two of three lanes showed the pasted task prompt with a
"tab to queue message" hint and no obvious "Working" line in a short peek, so I (wrongly)
concluded the prompt hadn't submitted and sent Enter/C-m to nudge them.

Two problems this exposed:
1. **The "tab to queue message" hint is ALWAYS shown at the Codex prompt** — it is not a
   "you have an unsubmitted draft" signal. A short `peek --lines 4` that lands on it reads
   like a stall when the agent is actually `Working` (the spinner was just above the peek
   window). `waspflow peek` should make idle-vs-working unambiguous in its OUTPUT (e.g. a
   one-line `state: working|idle|awaiting-input` header) so the caller never has to infer it
   from raw TUI scrollback.
2. **My nudge created `• Queued follow-up inputs`** — Codex queued my extra Enters as
   duplicate copies of the task prompt, to be processed after the current pass. Harmless here
   (same task) but it's pure noise the worker now has to ignore, and in a worse case a stray
   nudge could queue a partial/garbage instruction. If `spawn`/`revise` owned submission
   reliably, the caller would never be tempted to hand-nudge and create these.

Takeaway reinforcing the main note: callers should NEVER touch `send-keys` on a waspflow
pane. `peek` should report a clear state, `wait` should be the only completion signal, and
`spawn`/`revise` must guarantee submission so there's no reason to nudge. The fix is the same
`adopt`-grade PTY ownership proposed above, applied to spawn/revise too.

## Addendum 2: SHARP finding — `spawn` fails to submit, but `revise` submits reliably

Continuing the same session: I spawned 3 lanes. ONE (`add-source`) submitted and ran to
completion (27 min). The OTHER TWO (`connect-crash`, `sources-clarity`) sat at the prompt
with the task pasted but NEVER SUBMITTED — they did 0 work for ~30 min while I thought they
were running. A single `tmux send-keys Enter` then submitted them cleanly (they were
genuinely stuck-unsubmitted, not working).

Crucially: when I needed to steer the COMPLETED lane, `waspflow revise add-source -- "..."`
submitted RELIABLY first try. So the submission bug is specifically in **`spawn`'s initial
prompt delivery**, not in `revise`. spawn pastes the task but does not guarantee the
submit keystroke lands; revise does. Two fixes implied:
1. `spawn` must use the same reliable submit path `revise` already has.
2. Until then, `spawn` should VERIFY the agent transitioned to "working" within N seconds
   and re-submit (or error) if it's still sitting at an unsubmitted prompt — never report a
   lane as spawned-and-running when it's actually idle-at-prompt.

This also fully explains why `wait` returned early for all three earlier: 2 of 3 were idle
(never-submitted), so `wait`'s "idle" fired immediately on them. `wait` returning is
currently NOT a reliable "work done" signal — it needs the per-provider working-state
detection from the main note PLUS a guard that distinguishes "idle because finished" (has a
final assistant turn / report) from "idle because never started" (prompt still in composer).

## Addendum 3: the submission key DEPENDS ON AGENT STATE (Tab-queue when busy, Enter-submit when idle)
Driving the co-owner Codex pane by hand again, found the precise rule I'd been getting wrong:
- Codex TUI when IDLE at the prompt: Enter SUBMITS.
- Codex TUI when BUSY (mid-turn): the composer shows "tab to queue message" — Enter does NOT
  submit/queue; you must press TAB to QUEUE the message (it then shows "shift + ← edit last
  queued message" and delivers when the current turn finishes).
I'd been sending Enter into a busy composer repeatedly → the message just sat there unsubmitted
(Tim noticed: "you didn't hit enter properly"). It wasn't an Enter-count problem; it was the
WRONG KEY for the agent's state.
Implication for a real `revise`/`adopt`: the PTY driver must DETECT agent state (idle vs busy)
and choose Enter vs Tab accordingly — and ideally just expose `revise <lane> "<msg>"` that does
the right thing (queue-if-busy, submit-if-idle) so the caller never thinks about it. This is the
core of why hand-driving an existing pane is error-prone and why `adopt` + state-aware submit is
the fix. (Provider-specific: Claude TUI has its own submit semantics; encode per provider adapter.)

## SUPERSEDED: Addendum 3 (Tab-vs-Enter framing) is WRONG — see CORRECTION in 2026-06-17-adopt-existing-session-feature.md. Reality: Enter=STEER/interrupt current turn, Tab=QUEUE next turn (version-sensitive; openai/codex#13595). Not "Enter fails when busy".
