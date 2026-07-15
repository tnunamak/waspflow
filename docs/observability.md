# Structured observation and safe cleanup

`wait` remains the completion oracle. It reads provider session data, not the
terminal. For any other automated observation, use `waspflow events <lane>
--json` (or `status <lane> --tail-events N --json`). It normalizes the small
cross-provider lifecycle vocabulary: turn started, turn completed, and the
derived turn state. It reads a bounded byte tail, so integrity is explicitly
`tail-window-only`, not a claim about malformed data outside that window.

`peek` remains a pane/transcript capture for compatibility and modal/UI
diagnosis. Full-screen TUIs repaint with cursor movement and alternate-screen
deltas, so pane output is not progress or completion evidence. `peek --events`
is the safe structured alternative.

This compatibility choice is deliberate: changing bare `peek` would break
existing human and script workflows. The safe default for new orchestration is
the explicit `events` command; existing `wait`, `peek`, `list`, and fleet JSON
keep their contracts. Event output is whitelist-only: it excludes prompts,
assistant text, tool arguments, environment values, and raw JSON. It exposes
only a source basename and bounded-byte facts, never a full local path.

`list` is a cheap, read-only durable index: it renders stored runtime receipts
and never refreshes provider logs or writes lane state. `status <lane>` remains
the explicit single-lane runtime-refresh surface; there is deliberately no
implicit fleet refresh.

`waspflow inspect --json` is read-only and intentionally more expensive than
`list`: it reads each selected lane's provider tail and tmux ownership facts.
Do not use it as an ordinary fleet list. Its classification is an explanation,
not a `stale` boolean or an authorization to mutate:

- `active-observed`
- `terminal-idle-unclosed`
- `blocked-needs-human`
- `orphaned-control-plane`
- `closeout-ready`
- `corrupt/unknown`

An attached tmux client changes inspection to `blocked-needs-human` with
`eligibility: vetoed-attached-client`; it is an operative veto, not merely a
diagnostic reason.
Inspection never sends keys, attaches, captures a pane, changes lane state, or
parks/reaps a lane. Existing explicit `close`, `park`, and `reap` boundaries
remain responsible for mutation.
