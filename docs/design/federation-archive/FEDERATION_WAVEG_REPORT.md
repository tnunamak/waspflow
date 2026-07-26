# Federation Wave G report

Date: 2026-07-22

## Delivered

| Finding | Result |
| --- | --- |
| Polling replaced the whole UI | Fixed. The UI now has a layout signature and updates the active contribution's status text, guard copy, and state attribute in place. The root is replaced only for a real layout transition. A browser test kept a real text selection and its original DOM node through 10.5 seconds of 1.5-second active-status polls. |
| OpenAI sign-in first run and retry | Login-URL wait is 75 seconds; the auth handle is published as soon as the child exists, so retry, Stop, and daemon close cancel even a pre-URL attempt. URLs are recognized from stdout or stderr. A pre-existing OAuth overwrite prompt becomes clear Settings copy instead of a timeout or 502. |
| Identity flapping | Fixed. Last-confirmed provider state survives probe gaps and remains visibly `Checking…`; three completed negative probes are required before sign-in is shown. |
| Capacity wording | Replaced with “You approve every task before it runs. Pause anytime.” The schedule suffix appears only when enabled. |
| Task review attribution and copy | `GET /tasks` now includes the signed `author_key`. The card says “Review this task” and “Nothing runs until you approve.” |
| Completed copy while running | The previous-completion activity line is hidden for active/pausing work. |
| Execution transcript | The daemon persists a task child’s stdout/stderr transcript under `~/.waspflow/federation/logs/<digest>.log`, owner-only (0600), capped at 256 KiB with a truncation marker. `GET /tasks/:digest/log` is session-token gated. Requester task detail and contributor activity can render it in an escaped, scrollable monospace panel. |

## Verification

- Focused Wave G checks passed after the final changes: auth-flow + web UI (21 tests), daemon regression cases (3 tests), and coordinator author discovery (1 test).
- A parallel full-suite run reached 256/257 passing tests; its unrelated real `federation-pull` integration then failed its sandbox preflight (`sbx_daemon`, network policy, Docker login) from the isolated systemd test unit. A direct `sbx diagnose` immediately afterward reported the local daemon healthy and authenticated. This is an environment/isolation failure, not a Wave G assertion failure; I did not relabel it green.
- `node tests/e2e-browser/journey.spec.mjs` passed against the restarted local daemon on port 4243: 12 checks, no console errors.
- Browser proof selected the active guard text, waited 10.5 seconds, and confirmed both the selection and selected DOM node survived polling. Screenshot: [active-selection-stable.png](../../test-artifacts/federation-ui/active-selection-stable.png).
- Browser task-detail proof rendered the execution transcript panel. Screenshot: [execution-log.png](../../test-artifacts/federation-ui/execution-log.png).
- Browser proof rendered the Settings failure state without a console error. Screenshot: [openai-signin-attention.png](../../test-artifacts/federation-ui/openai-signin-attention.png).
- `git diff --check` passed.

## Live OpenAI handoff

The real OpenAI command was started without completing any browser authorization. This machine already has Docker's global `openai` OAuth credential; Docker safely stopped at `OPENAI OAuth token already exists. Overwrite? (y/N):`, so I did not overwrite or remove a security-relevant credential merely to force a fresh flow. The daemon maps that exact condition to a 202 status with Settings copy instead of a browser-visible 502; the UI rendering is screenshot-verified above. Consequently, I cannot honestly claim that a fresh live URL (or a confirmation code) was observed in this environment. Codex's host flow has no separate confirmation code by design. Fresh-flow URL capture, slow wait, stderr capture, handle publication, retry, and cancellation are covered deterministically.

## Operational state

`wf-fed-daemon.service` was restarted from this worktree and is active on port 4243. The prior service cgroup contained an idle probe sandbox that did not exit on SIGTERM; only that daemon cgroup was SIGKILLed before restart. No contribution was active.
