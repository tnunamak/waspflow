# Federation web UI report

## Delivered screens

- Join: one invite paste field accepts the deep link, full guided join command, or raw token. The daemon
  owns parsing; after joining, the coordinator is shown with a trusted badge.
- Contributor status: large Contributing, Paused, and Idle states; a single pause/start control; a visible
  trusted coordinator; live daemon detail; and friendly daemon-unavailable errors.
- Auth handoff: browser authentication opens the daemon-provided URL and keeps polling; manual Claude
  authentication is an honest numbered instruction card with no invented URL button.
- Safety: a collapsed, reachable Docker Sandbox safety panel with the boundary, shared-in/not-touched,
  blocked-everything-else, trusted-coordinator, and pause-anytime copy.
- Requester submission: an advanced three-field form, lifecycle stepper, progress detail, and a decoupled
  result-ready reference-copy action.

## Daemon addition

The daemon now has two token- and Host-gated, no-CORS routes:

- `POST /submit` accepts `{ source, prompt, display_id }`, starts the existing
  `waspflow federation submit` command, and returns `202` with the current `submission` summary in the
  normal daemon-status shape.
- `GET /submit/status?task_digest=sha256:…` runs the existing
  `waspflow federation status --task-digest … --json` command and returns its `task_status` event. If the
  currently supervised submission has not published a digest yet, it returns its daemon-side progress
  summary instead.

The daemon extracts only the published task digest from the submit command's existing progress line. The
coordinator lifecycle remains authoritative through the guided status JSON event.

## Verification

- Focused daemon and renderer tests pass: `node --test tests/federation-daemon.test.mjs tests/federation-webui.test.mjs`.
- A live localhost daemon served `/`, `/app.mjs`, and `/status` with the session token; headless Chrome
  rendered the `not_joined` Join screen. This caught and verified the module-token propagation path.
- The full Node suite was run: 196 passed; one existing live Docker Sandbox integration could not run because
  this environment is not authenticated to Docker Sandbox (`sbx login` is required).

## Decision

The UI stays plain HTML, CSS, and browser modules: no framework or build step. The v0 coordinator reports
`QUEUED`, `CLAIMED`, and `SETTLED`; a claimed task is shown as user-facing **running** with the **claimed**
step complete. It does not provide a branch/diff URL in task status, so the settled-state affordance copies
the verified task reference instead of pretending there is a URL to open.
