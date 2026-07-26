# Federation browser authentication

## Delivered

- `CLAUDE_CODE_SUBSCRIPTION_HARNESS` remains `docker-native-oauth` and is now a `host-url-flow`.
- Its login command is `claude auth login --claudeai`; the URL marker is `visit:`.
- Its status probe is `claude auth status --json`, with the harness-defined success condition `{ "loggedIn": true }`.
- Codex remains a `host-url-flow`; its probe succeeds only when the sandbox proxy reports `SBX_CRED_OPENAI_MODE=oauth`.

## Flow

`runJob()` prepares the contribution sandbox before calling its new `authorize` hook. The hook calls `startAuthFlow()` with that sandbox id. Commands whose login command starts with `sbx` retain their host invocation (Codex); other commands run as `sbx exec <sandbox> -- <login command>` (Claude). The flow parses its harness URL marker, emits `awaiting_browser`, then polls the same harness's status probe until its declared success fields match or the timeout expires. The task entrypoint starts only after that proof succeeds.

The auth-flow child environment is passed through `sanitizedEnv` and uses the Federation sbx home. Credentials continue to flow through sbx's proxy; no host credential is injected into the guest.

## Event behavior

The contributor forwards its immediate `awaiting_browser` event while it keeps polling. The daemon now parses streamed contribute events rather than waiting for child exit, so the existing browser button appears during login. `auth_required_manual` remains only for a future genuine `interactive-session-flow` fallback; no shipped harness uses it.

## Verification

- `tests/federation-harnesses.test.mjs` and `tests/federation-harness-spec.test.mjs`: Claude's reclassified valid spec and success condition.
- `tests/federation-auth-flow.test.mjs`: stubbed Codex URL (`Open this URL to sign in`) and Claude URL (`visit:`), including the guest `sbx exec` path and status-poll completion.
- `tests/federation-daemon.test.mjs`: streamed `awaiting_browser` is exposed immediately and is not downgraded to `auth_required_manual`.
- Full suite: 193 passed. The only attempted live Docker Sandbox integration is blocked before the test body because this machine has no Docker sbx login (`401 Unauthorized`; `sbx login` required).
