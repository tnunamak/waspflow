# Feature request: `waspflow adopt` — drive a pre-existing agent pane with state-aware submit

**Date:** 2026-06-17
**Author:** Claude (orchestrating agent), at Tim's request
**Status:** distilled from a real multi-day session hand-driving a co-owner Codex pane.
Companion: `2026-06-16-drive-existing-session-gap.md` (incident-by-incident evidence). NOTE:
that note's "Addendum 3" Enter/Tab framing is SUPERSEDED by the corrected behavior below.

## The gap
waspflow owns the PTY only for agents it SPAWNED (`spawn` → `wait`/`peek`/`revise`/`reap`). A
common real shape has no support: **a human already has a Codex/Claude session running in a tmux
pane** (e.g. Tim's `9:pdpp RI` co-owner Codex), and an orchestrator needs to COORDINATE with it —
send messages, know when it's idle, read its output. Today that drops to raw
`tmux send-keys`/`paste-buffer`/`capture-pane`, which is error-prone (below). There is no `adopt`.

## Proposed surface
```
waspflow adopt <name> --pane <session:window.pane> --provider <codex|claude>
waspflow revise <name> [--steer] -- "<message>"   # queue-by-default; --steer to interrupt
waspflow wait   <name> [--timeout S]              # block until idle
waspflow peek   <name> [--lines N]                # de-escaped tail + one-line state header
waspflow detach <name>                            # stop tracking; never reap
```
No `reap` for adopted sessions — adopt doesn't own the lifecycle; `detach` leaves it running.

## The hard part #1 — message submission (VERIFIED against OpenAI Codex docs; my first take was wrong)
Codex TUI behavior WHILE RUNNING (official docs — developers.openai.com/codex/cli/features):
- **Enter = STEER:** immediately injects the message into the CURRENT turn (interrupts/redirects).
- **Tab = QUEUE:** holds it for the NEXT turn.
So for an orchestrator coordinating a busy co-owner, **QUEUE (Tab) is almost always the right
intent** (don't interrupt the agent's current work). An earlier draft of this note claimed "Enter
doesn't submit when busy, you must use Tab" — that's WRONG: Enter *does* act when busy, it
*steers/interrupts*, which is usually not what you want. The correct framing is INTENT, not state.

It is also VERSION-SENSITIVE and not safe to hardcode:
- openai/codex#13595 (~v0.110.0): a regression where BOTH Enter and Tab queue (Enter stopped
  sending immediately).
- openai/codex#12569: fixes a race where Enter-while-final-answer-streaming could strand the turn.
- `/keymap` (v0.128.0): users can REMAP these shortcuts.

Plus the mechanical paste hazards (real, version-independent):
- Multi-line pastes arrive as several `[Pasted Content N chars]` chunks; the submit/queue key must
  come AFTER the paste settles.
- Glob chars (`(1)`, `*`) corrupt via send-keys → use `load-buffer`/`paste-buffer` for the text.

`revise` should therefore: load-buffer the text (glob-safe); DEFAULT to queue (Tab) for a busy
agent, `--steer` (Enter) only when the caller explicitly wants to interrupt; be robust to the
#13595 regression; respect `/keymap`; and CONFIRM the composer cleared (message actually left).
The caller should never reason about Enter vs Tab vs chunking.

## The hard part #2 — reliable idle/working detection per provider (for `wait` + state header)
- Codex shows `Working (Nm Ns • esc to interrupt)` / `Pursuing goal (...)` while busy, and a bare
  `›` prompt + a "tab to queue message" hint. **The hint is ALWAYS shown — do NOT read it as
  "unsubmitted draft."** A short peek that lands on it reads like a stall when the agent is
  actually Working just above the window. (This bit me: I mistook Working-agents for stalled ones,
  and conversely thought a queued message hadn't been sent.)
- "Idle" = no Working spinner AND back at prompt for K stable polls. Distinguish "idle because
  finished" (has a final assistant turn) from "idle because never submitted" (composer holds text).
- `peek` should emit a one-line `state: working|idle|awaiting-input` header so the caller never
  infers state from raw scrollback.
- A blind `wait` returned early when a SPAWNED lane was actually idle-at-prompt (never submitted) —
  so `wait` returning is not currently a trustworthy "work done" signal. Fixing #1+#2 fixes that;
  the same submit reliability should back-port to `spawn`'s initial prompt delivery.

## Why it matters
The pitch is "turnkey orchestration of Claude/Codex from any dir." The human-already-has-a-pane
case is common (multi-agent co-ownership) and is exactly where waspflow isn't, so the friction
Tim saw came from hand-driving. `adopt` + intent-aware `revise` + reliable `wait`/`peek` closes
it. Provider-specific submit/state semantics belong in the existing 5-fn provider adapter.

**Priority:** medium — manual path works, but it's the toil waspflow exists to delete, and the
silent-failed/mis-submitted-message class wastes real cycles and confuses the watching human.
Logged from a real run; not urgent.

Sources: developers.openai.com/codex/cli/features ; github.com/openai/codex/issues/13595 ;
github.com/openai/codex/pull/12569 ; codex.danielvaughan.com/2026/04/08/codex-cli-tui-shortcuts-slash-commands/
