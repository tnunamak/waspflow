# Federation Wave D report

Date: 2026-07-22

## Delivered

- Request form state is application-owned. A failed submit keeps all field values and its inline error through poll-driven renders; editing any field clears that error.
- Empty task queues disable **Contribute next available**.
- Folder is optional in the UI and daemon API. The v0 signed envelope still requires `source.base_artifact`, so prompt-only requests package a daemon-created empty directory as the source artifact. The executor therefore receives an empty workspace plus the prompt; the wire schema was not weakened.
- Settings now exposes provider sign-in for unauthenticated providers through `POST /identity/signin {service}` and the existing structured browser-auth flow. Anthropic shows the honest **Managed automatically by Waspflow** note when authenticated; no fake sign-out control was added.
- Contribution status is collective-first and task-named when task metadata is known. The capacity guard now leads with: “Waspflow only helps out with capacity you’re not using. Pause anytime.” Scheduling moved to Settings as **Limit to certain hours (optional)**.
- Settings uses **Member ID**, short per-row explainers, local collective-name editing, and keeps the connection URL there rather than in the contribution surface.
- Activity rows are clickable and show labeled started/finished times, duration, requester, task, model, and token units. Claude’s currently parsed receipt has only aggregate usage/model fields, so the UI labels those values **(combined)** rather than inventing a per-model split.
- Request detail now includes labeled times and duration.

## Verification

- `node --test tests/*.mjs` — passed.
- `bash scripts/verify.sh` — passed.
- Focused additions cover prompt-only submission cleanup, provider browser-auth handoff, local collective-name persistence, empty-queue disabling, and persistent form state.
- Live Chromium check passed for the failed-submit journey: a nonexistent folder produced the inline error; name, prompt, folder, and error survived 3.5 seconds of polling; editing cleared the error. Activity and Settings rendered the new labeled details with no page JavaScript errors.

## Live-state note

The restarted `wf-fed-daemon` is running, but the current real collective is in `pending_approval`, so the live browser cannot honestly exercise idle-only task selection or a real contribution without owner approval. The browser did render the requester, activity, and settings flows. Provider browser-sign-in launch is covered by an injected daemon contract test; it was not clicked live because that would open a real external account-authentication flow.

## Restart

The daemon was restarted as the transient user unit `wf-fed-daemon.service`. During the first restart, an existing background identity-probe `sbx` child prevented a graceful stop; only that service cgroup was terminated, then the transient unit was started fresh. The final daemon is active with no contribution or auth child running; its product state is pending collective approval.
