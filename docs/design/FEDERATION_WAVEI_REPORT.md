# Federation Wave I report

Date: 2026-07-22

## Delivered

- Requests now renders a persistent **Submission status** row as soon as `POST /submit` returns. It moves from pending to **Published ✓** when the daemon observes the published digest, remains visible while the task settles, captures failures prominently, and has an explicit Acknowledge action. The daemon merges the published submission into My requests before the next coordinator refresh.
- Coordinator responses now carry `x-waspflow-federation-coordinator-schema: 2`. The daemon records the observed schema, surfaces an older coordinator, and turns unknown-field HTTP 400 submission failures into: “Your collective's coordinator is running an older version — ask the operator to update it.” Raw transport wording is not shown to the requester.
- The uploader is now separate **Add files** and **Add folder** controls plus a file/folder drop zone. Selected files list their relative names and byte sizes and can be removed before submission. The local path control is inside an Advanced disclosure with the requested local-machine explanation.
- Git URLs are probed by the daemon with a short unauthenticated `git ls-remote`. Public sources state that no GitHub sign-in is needed. Private or unreachable sources automatically require GitHub and explain why. Git source forces network on and locks the control with its reason.
- A signed `github_access_required` capability is independent of `git_source`. It supports organization/discovery tasks with no repository source, appears as a **Needs: GitHub** chip, gates contribution on the isolated GitHub identity, and is carried into the sandbox job spec. The Docker backend attaches the existing proxy-managed GitHub kit to a capability-bearing agent sandbox, so no host `gh` configuration or token is mounted.
- Every browser-rendered Docker/GitHub device code is a selectable `<code>` value with a **Copy code** button.

## Verification

- Focused protocol, daemon, web UI, runtime, pull, Docker backend, envelope, submit, and coordinator tests passed.
- Complete Node suite passed with no failures (the prior 267-test base remains green; this wave adds regression coverage).
- `git diff --check` passed.
- `wf-fed-daemon.service` was restarted from this exact worktree and was active on port 4243. Its token was read from the fresh daemon record for browser validation.
- Live Playwright journey: **13/13 checks passed**, with no console errors. Fresh screenshots include [the advanced submit/upload view](../../test-artifacts/federation-ui/advanced-submit-expanded.png) and [settings/activity](../../test-artifacts/federation-ui/activity-settings.png).

## Confidence and remaining live boundary

Confidence is high for the signed capability contract, coordinator compatibility signal, daemon normalization, UI lifecycle, uploader behavior, and daemon-backed browser journey. The GitHub kit attachment is covered by the sandbox-job construction and existing kit boundary tests. I did not start a real credential-only provider task against a real GitHub organization, so that final provider/credential consumption path remains unproven live; no personal GitHub authorization was created or changed for this report.
