# Federation Git Repository Task Access

## Delivered

- A task envelope may now carry the signed, additive `git_source` field:
  `{url, ref?, authentication_required?}`. It accepts HTTPS `github.com`
  repository URLs only. Because it is inside the signed payload, changing the
  repository, ref, or access requirement changes the task digest.
- Requests now support a Git repository URL, optional branch/ref, and an
  explicit private-access checkbox. Git sources force the task's network
  requirement on; file/folder sources and Git sources are mutually exclusive.
- Contributors see `Needs: internet` for every Git source and `Needs: GitHub`
  when the requester marks its source private, in the task review, task list,
  and task detail. A missing required GitHub credential shows **Set up GitHub
  access** and routes to Settings rather than starting a failed contribution.
  Public repositories remain runnable anonymously; the daemon independently
  enforces the private-source gate.
- Settings now exposes GitHub as **Task access**, not capacity. The real
  default `gh auth login` device flow is driven under Federation's isolated
  sbx identity, renders its URL and one-time code, then pipes the resulting
  token directly into `sbx secret set -g github`. The token is never passed in
  argv, returned to the UI, or read from the user's personal gh configuration.
  The temporary isolated gh config is deleted after success, failure, timeout,
  or cancellation.
- The existing `wf-gh-cli` kit remains the credential/proxy boundary. Git
  cloning occurs in a dedicated kit sandbox. The runner attempts anonymous
  `git clone` first (public repos require no account); only a failed anonymous
  clone tries `gh repo clone` through the kit's proxy-managed task credential.
  The clone is copied into the execution sandbox workspace before task code
  starts.

## Device-flow conclusion

`gh` 2.82.1 on this host rejects `gh auth login --device`; its default
non-interactive login is nevertheless a capturable device flow. It printed a
one-time code and `https://github.com/login/device` under an isolated HOME.
Therefore no PAT fallback or fake button was needed. The browser UI has a
verified device-code render; no real GitHub login or token was completed.

## Verification

- Focused schema, submit, coordinator, UI, auth cleanup, daemon gate, and
  sandbox-clone tests: 140 passed.
- The complete Node test suite passed 264/264 with Node's stable in-process
  isolation mode (`--test-isolation=none --test-force-exit`).
- Full daemon test file with Node's in-process test isolation: 29 passed.
  The default process-isolated Node runner leaves a pre-existing test-worker
  handle alive after all daemon assertions; `--test-isolation=none
  --test-force-exit` is the stable suite invocation in this environment.
- Restarted the Federation daemon on port 4243 and verified its new session
  token reaches `idle`.
- Full Playwright Federation journey passed 13/13 with no console errors.
  The device-code panel screenshot is
  `test-artifacts/federation-ui/github-device-flow.png`.
- Live Docker Sandboxes proof: `sbx kit validate kits/wf-gh-cli` passed, then
  a real `wf-gh-cli` sandbox anonymously cloned
  `https://github.com/octocat/Hello-World.git`; its `README` and git HEAD
  (`7fd1a60b01f91b314f59955a4e4d4e80d8edf11d`) were verified inside the
  sandbox and after transfer to the task workspace. The sandbox was removed.
- Private-repository behavior is proven to the auth gate and the browser
  device-code rendering without creating or completing a token.

## Deliberate constraints

- Git source URLs are deliberately limited to GitHub HTTPS. SSH URLs and
  arbitrary Git hosts would require different credential/egress capability
  contracts.
- The named `FEDERATION_CAPABILITY_MATCHING.md` specification was not present
  in this worktree or any reachable local Git ref. This implementation follows
  the owner-requested capability model and the existing HarnessSpec/kit
  boundary; that missing document should be restored as the canonical design
  reference.
