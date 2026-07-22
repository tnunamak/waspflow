# Federation Wave F report

Date: 2026-07-22

## Red-team findings

| Finding | Status | Result |
| --- | --- | --- |
| Critical: informed consent | Fixed | Specific-task cards now show task, author, age, network state, and a verified first-line prompt preview. “Contribute next available” first opens a one-tap review card with task, requester, prompt preview, Run this, and Skip; it claims only the reviewed digest. Empty queues explicitly say nothing runs automatically. |
| Critical: destructive Pause | Partial | `POST /contribute/pause` now enters `pausing`, leaves the child alive, and becomes `paused` only after it exits. The UI distinguishes “Pausing after current task…” from “Paused”; Pause remains enabled during a coordinator outage. Stop now is secondary and confirms that it abandons the task, but truthfully says it only records a local return because no coordinator-confirmed requester-notification protocol exists. |
| Critical: private accountability receipt | Fixed | Every success and nonzero/unknown/start failure now appends an outcome-bearing local ledger record. Activity renders returned status, reason, requester notice, task reference, prompt/source snapshot where available, lifecycle, harness/capacity/model/usage, sandbox, and private Docker/provider identities with explicit legacy-data wording. |
| High: stale-tab recovery | Fixed | Two 401s lead to a dedicated session-expired screen with the reassurance that no task/account changed and a Reconnect Federation action; polling stops. |
| High: daemon-down recovery | Fixed | Network failure now renders a dedicated local-daemon recovery screen with last-connect time, reconnect action, and non-terminal fallback copy. |
| High: coordinator outage hidden | Fixed | Coordinator fetch failures retain prior data, mark the Contribute surface unavailable, show “Your collective is unreachable right now — tasks will resume when it returns,” and disable new work while Pause remains available. The daemon also includes reachability and last-success status from its coordinator-facing paths. |
| High: failed contribution disappears | Fixed | Failed, unknown, zero-exit-without-a-recognized-result, and child-start exits create `Returned` ledger entries with the bounded stderr reason and an explicit local-only notification status. They no longer silently become a pleasant completed state. |
| High: revoked approval looks pending | Partial | Continuous successful roster polling now distinguishes a later revocation as `approval_revoked`, stops new work, and tells the UI whether a running child may finish before pause. The prior-approval observation is process-local, not persisted through daemon restart; durable revocation history remains follow-up work. |
| High: provider sign-in recovery | Fixed | Browser auth states name the provider and affected task. The terminal-only/manual branch is replaced with a clear unavailable/fallback state, and provider buttons have service-specific accessible labels. |
| High: Settings interruption/time zones | Fixed | Settings now use app-level dirty drafts that polling does not overwrite, warn on unload, display saved/unsaved state, use selectable days, validate enabled schedules, persist an IANA timezone, and render the effective local-time summary. |

## Cheap Medium folds

- Added a skip link, a route `<h1>`, and removed the live region from the entire app shell.
- Humanized unavailable receipt copy and activity outcome chips.
- Replaced the unsupported generic provider Sign in controls with provider-specific names.
- Added an explicit capacity-guard statement rather than promising unknowable unused capacity.

## Verification

- `node --test tests/federation-daemon.test.mjs tests/federation-webui.test.mjs` passed.
- `node tests/e2e-browser/journey.spec.mjs` passed against the restarted live daemon on port 4243; all nine browser checks passed with no console errors.
- Pixel review completed for [session-expired-390.png](../../test-artifacts/federation-ui/session-expired-390.png): the 390px recovery state presents readable, non-overlapping copy and a visible Reconnect Federation action.
- `git diff --check` passed.

## Operational state

`wf-fed-daemon.service` was restarted successfully and is active on port 4243. The refreshed local UI session token is `JSLRlgyrdoA9cyfM3-XPUj9if0vh4tLCROYrK74CIuc`.

## Known follow-up

The remaining Stop now protocol gap is material: local SIGTERM plus a local receipt is not a coordinator-confirmed return. Add an authenticated coordinator return/release endpoint tied to the executor and active lease, make the pull process emit a structured returned event before termination, and record the coordinator acknowledgement in the requester and contributor timelines.
