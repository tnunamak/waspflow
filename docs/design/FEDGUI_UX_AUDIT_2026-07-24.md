# Federation contributor UX audit (2026-07-24)

Owner used the tray live after a reboot, called it "janky and clunky." Bar:
excellent UX (bet-the-company). This is the DISCOVERY pass — ranked findings,
grounded in code + live daemon state; fixes triaged separately.

## Root cause that cascades (the one to internalize)
The **daemon has a rich state vocabulary** — `contributing, paused, idle,
action_needed, pending_approval, not_joined, setup_required, approval_revoked`
(federation-daemon.mjs). The **tray collapses all but four into one bucket**:
`VisualStateForDaemonState` (tray/.../federation.go:81) maps only
contributing/paused/idle/action_needed; EVERYTHING else falls through `default`
→ `VisualSetup`. And `applyVisualState` (main.go) has no `VisualSetup` case, so
setup falls through ITS `default` → the label **"Federation daemon is not
running."** Net: the daemon truthfully says "pending_approval," the tray discards
it and tells the user the daemon is dead. Most findings below are children of this.

## Findings (ranked)

### P0 — the tray lies about a running daemon (WRONG)
`tray/.../main.go applyVisualState` default branch. Daemon up + `pending_approval`
→ menu reads "Federation daemon is not running" and offers "Start Federation
daemon." User is told the opposite of the truth. **Fix:** add explicit VisualSetup
handling; only say "not running" when the daemon is genuinely unreachable
(ReadDaemonInfo fails OR /status errors), which the tray must detect separately
from "running but not contributing."

### P0 — tray cannot distinguish "down" from "up-but-waiting" (WRONG, structural)
Only 4 VisualStates for 8 daemon states. `pending_approval`, `not_joined`,
`setup_required`, `approval_revoked` are all one grey blob. A contributor can't
tell "I need to do X" from "the app is broken." **Fix:** expand the visual
vocabulary (at least: down / setup-needed / waiting-on-operator / needs-action /
active / idle) with distinct icon + honest menu copy + a real next-step per state.

### P0 — "Start Federation daemon" is a dead button (DEAD)
`main.go:165` `exec.Command("waspflow", ...)` — bare binary name; a GUI/autostart
tray often lacks `~/.local/bin` on PATH → silent no-op. Also shown when a daemon is
already running. Owner clicked it; nothing happened, no feedback. **Fix:** resolve
an absolute path (or a packaged launcher), surface start errors to the user, and
never show Start when a daemon is live.

### P0 — no reboot persistence (WRONG expectation)
The `.desktop` autostart targets `/usr/lib/waspflow/waspflow-federation-tray` — a
packaged path not installed on the dev machine. Reboot ⇒ no tray, no daemon
autostart. For a "clawmeter-style ambient tray" (owner: non-negotiable), vanishing
on reboot is disqualifying. **Fix:** a from-source install path that drops a
working autostart `.desktop` + a built binary (or a user-level systemd unit for the
daemon, per the design's Syncthing/Jellyfin model), so the icon returns like
clawmeter's does.

### P1 — stuck-at-pending-approval dead-ends the user (ACCURATE-but-poor)
Browser shows "Approval requested / Your collective is unreachable right now." The
STATE is truthful (operator/coordinator on remote box is down). But a
non-technical user has no path: no "your operator is offline — here's how to reach
them," no retry affordance, no "join a different collective" surfaced at the point
of pain (it's buried in Settings). The tray compounds it by calling this "not
running." **Fix:** the pending/unreachable screen and tray both need a plain-language
explanation + concrete next action, and self-heal messaging when the collective
returns (the polling already refreshes — say so).

### P1 — "task details are still loading" never backfills (WRONG, known wart)
Contribute/task route: `What was asked` shows "Task details are still loading"
indefinitely; the prompt text doesn't backfill on the task view (the review card
has it). A contributor reviewing a task to consent can't see what they're
approving on that screen. **Fix:** backfill the prompt on the task route.

### P1 — daemon.json omits `url`; on-demand vs recorded daemon can diverge
Record has pid/port/token, no `url`; earlier tooling reading `.url` got null, and
an auto-started daemon (via `waspflow federation`) vs. a tray-started one can be
two different processes on different ports, so tray and browser can disagree about
which daemon is "the" daemon. **Fix:** single source of truth for the running
daemon (one record, one process), and include what consumers need.

### P2 — keyring prompt coupling (LIKELY ALREADY FIXED — verify)
Owner previously hit repeated KWallet prompts; the log shows a v0.1.6 fix
(federation sbx children no longer see DBUS_SESSION_BUS_ADDRESS). Verify it holds
on the reboot path and that no new keyring nag appears at first `Run this`.

### P2 — first-run / empty states unassessed
Fresh-install first-`waspflow federation`, no-Docker, no-subscription-signed-in,
and the very first tray appearance (before any join) weren't exercised live here
(no clean machine). Flag as a gap; walk on a fresh VM before calling excellence
done.

## What is NOT the problem (scope discipline)
The **core engine — coordinator, signed envelopes, sandbox backend, contribution
loop — was not modified by recent work** (FEDERATION_DAEMON_REPORT.md:50) and is
not implicated in this jank. Every finding above lives in the **GUI / daemon /
tray presentation layer**. That's the good news: the polish target is bounded to
UX, not the trust/execution machinery.

## Confidence + gaps
High confidence on P0/P1 (code-grounded + reproduced against the live daemon).
Not exercised: fresh-install first-run, no-Docker/no-subscription paths, the actual
contribute→settle happy path end-to-end (blocked by the dead collective). Those
need a live two-machine loop (fix simon's coordinator) before "excellent" is
claimable.
