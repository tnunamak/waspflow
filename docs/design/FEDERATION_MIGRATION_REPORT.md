# Federation Vite + Preact migration report

Date: 2026-07-22

## Delivered

- Replaced the hand-rolled browser DOM renderer with a Vite + Preact application in `ui/src/`.
  Component-local state and one polling state owner now preserve form drafts, task selection, stop
  confirmation, and settings drafts without the old layout-signature or live-binding machinery.
- Added the structural UX tier from `FEDERATION_UX_PROPOSAL.md`:
  - mode-first Contribute, Requests, Activity, and Help navigation, with Settings behind a gear;
  - Requests list first, then a dedicated New request route;
  - one `#/tasks/:digest` screen for live task watching and request detail;
  - Activity lenses for **What I did** and **What I asked for**;
  - Device & accounts and Collective settings routes;
  - full-bleed join, approval, setup, and sign-in flows;
  - the four uniform `active`, `ready`, `attention`, and `problem` status roles;
  - proposal copy replacements for consent, GitHub access, receipts, machine identity, status casing,
    and interruption support.
- Preserved daemon endpoints, token propagation, hash routing, result URLs, uploads, Git fields,
  device-code copy controls, submission state, session expiry, and coordinator-error recovery.
- The static build is intentionally committed in `public/app.mjs`. `ui/` owns the build toolchain;
  production daemon installs need only the committed static output and do not require npm, Vite, or
  `node_modules` at runtime. The one plain CSS module is inlined into the JavaScript bundle because the
  existing daemon contract serves `/app.mjs` and `index.html`, not a new stylesheet route.

## Verification

- `npm run build --prefix ui`
- `npm run test --prefix ui` — 2/2 component/helper smoke checks passed.
- `node --test tests/federation-webui.test.mjs` — 6/6 passed.
- `node --test --test-reporter=dot tests/*.mjs` — complete Node suite passed.
- Live daemon: restarted `wf-fed-daemon.service` from this worktree on port 4243. Its prior
  `sbx` child did not exit after SIGTERM, so only that daemon service cgroup was SIGKILLed before the
  service was restarted; the restarted unit is active with this worktree as its working directory.
- Live Playwright journey: 13/13 passed with zero console errors, including form persistence over a poll,
  task-route live transcript rendering, device-code copy, session-expiry recovery, and a 10.5-second
  active-contribution text-selection survival check. Updated screenshots are under
  `test-artifacts/federation-ui/`.

## Evidence-led fixes during migration

- The first served run found that an external Vite CSS file would 401 because adding an asset route would
  violate the daemon contract. CSS is now bundled into `app.mjs` instead.
- The shared-task route test found that its initial loading state passed `null` to the timeline helper.
  The helper now accepts the loading state and the task screen renders before its detail response arrives.

## Deferred

The UX proposal's visual-polish and animation tier remains deferred as requested. This change establishes
the route/component and status-token foundations without adding that visual scope.
