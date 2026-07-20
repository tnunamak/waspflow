import test from 'node:test';
import assert from 'node:assert/strict';
import { CODEX_HARNESS, CLAUDE_CODE_HARNESS, CLAUDE_CODE_SUBSCRIPTION_HARNESS, CLAUDE_CODE_API_KEY_HARNESS, GH_CLI_HARNESS } from '../lib/federation-harnesses.mjs';
import { hasProvenIndefiniteRefresh } from '../lib/federation-harness-spec.mjs';

test('Codex and Claude Code are both classified docker-native-oauth, not assumed identical mechanisms', () => {
  assert.equal(CODEX_HARNESS.auth_strategy, 'docker-native-oauth');
  assert.equal(CLAUDE_CODE_HARNESS.auth_strategy, 'docker-native-oauth');
  // Distinct login commands even though the strategy label is the same —
  // the correction warns against treating auth as one solved case.
  assert.notEqual(CODEX_HARNESS.credential_discovery.login_command, CLAUDE_CODE_HARNESS.credential_discovery.login_command);
});

test('Codex and Claude Code both report an explicit auth mode, not just request success', () => {
  assert.equal(CODEX_HARNESS.login_status_probe.reports_auth_mode, true);
  assert.equal(CLAUDE_CODE_HARNESS.login_status_probe.reports_auth_mode, true);
  // Corrected after live UAT: `codex login status` does NOT expose a JSON
  // auth_mode field inside an sbx-proxied sandbox (confirmed directly — it
  // always reports "Logged in using an API key" regardless of the real
  // upstream credential, since sbx presents a uniform API-key-shaped
  // sentinel to the guest). The real signal is the sbx proxy-layer
  // SBX_CRED_OPENAI_MODE env var, checked via `sbx exec ... env`.
  assert.match(CODEX_HARNESS.login_status_probe.mode_field_hint, /SBX_CRED_OPENAI_MODE/);
  assert.match(CLAUDE_CODE_HARNESS.login_status_probe.mode_field_hint, /claudeAiOauth/);
});

test('Codex and Claude Code both have proven indefinite refresh (docker-native-oauth + docker-builtin)', () => {
  assert.equal(hasProvenIndefiniteRefresh(CODEX_HARNESS), true);
  assert.equal(hasProvenIndefiniteRefresh(CLAUDE_CODE_HARNESS), true);
});

test('the gh-cli extensibility harness uses host-env-proxy, not docker-native-oauth (it is not a built-in agent)', () => {
  assert.equal(GH_CLI_HARNESS.auth_strategy, 'host-env-proxy');
  assert.notEqual(GH_CLI_HARNESS.install, 'codex');
  assert.notEqual(GH_CLI_HARNESS.install, 'claude');
});

test('gh-cli honestly declares no refresh is needed rather than claiming refresh safety it cannot prove', () => {
  assert.equal(GH_CLI_HARNESS.oauth_refresh.supports_refresh, false);
  assert.equal(GH_CLI_HARNESS.oauth_refresh.refresh_owner, 'none');
  assert.equal(hasProvenIndefiniteRefresh(GH_CLI_HARNESS), false);
});

test('none of the three harnesses claim host-file-proxy/host-env-proxy docker-builtin refresh (the exact bug the correction targets)', () => {
  for (const harness of [CODEX_HARNESS, CLAUDE_CODE_HARNESS, GH_CLI_HARNESS]) {
    if (['host-file-proxy', 'host-env-proxy'].includes(harness.auth_strategy)) {
      assert.notEqual(harness.oauth_refresh.refresh_owner, 'docker-builtin', `${harness.harness_id} must not claim docker-builtin refresh under ${harness.auth_strategy}`);
    }
  }
});

test('Codex and Claude Code have DIFFERENT auth flow_shapes despite sharing an auth_strategy label (auth UX reframe)', () => {
  assert.equal(CODEX_HARNESS.credential_discovery.flow_shape, 'host-url-flow');
  assert.equal(CLAUDE_CODE_HARNESS.credential_discovery.flow_shape, 'interactive-session-flow');
  // The two flow_shapes must stay distinct — collapsing them would force a
  // false uniformity (a host-side URL that Claude's flow does not have).
  assert.notEqual(CODEX_HARNESS.credential_discovery.flow_shape, CLAUDE_CODE_HARNESS.credential_discovery.flow_shape);
});

test('only host-url-flow declares a url_prompt_pattern; interactive-session-flow has none to declare', () => {
  assert.ok(CODEX_HARNESS.credential_discovery.url_prompt_pattern);
  assert.equal(CLAUDE_CODE_HARNESS.credential_discovery.url_prompt_pattern, undefined);
});

test('CLAUDE_CODE_HARNESS default alias resolves to the subscription variant, matching product intent', () => {
  assert.equal(CLAUDE_CODE_HARNESS, CLAUDE_CODE_SUBSCRIPTION_HARNESS);
  assert.equal(CLAUDE_CODE_HARNESS.harness_id, 'claude-code-subscription');
});

test('Claude Code has two real, independently-classified auth strategies — a product tradeoff, not a default silently picked for the operator', () => {
  assert.equal(CLAUDE_CODE_SUBSCRIPTION_HARNESS.auth_strategy, 'docker-native-oauth');
  assert.equal(CLAUDE_CODE_API_KEY_HARNESS.auth_strategy, 'docker-stored-secret');
  assert.notEqual(CLAUDE_CODE_SUBSCRIPTION_HARNESS.harness_id, CLAUDE_CODE_API_KEY_HARNESS.harness_id);
});

test('CLAUDE_CODE_SUBSCRIPTION_HARNESS: unavoidable interactive-session-flow, proven indefinite refresh', () => {
  assert.equal(CLAUDE_CODE_SUBSCRIPTION_HARNESS.credential_discovery.flow_shape, 'interactive-session-flow');
  assert.equal(hasProvenIndefiniteRefresh(CLAUDE_CODE_SUBSCRIPTION_HARNESS), true);
});

test('CLAUDE_CODE_API_KEY_HARNESS: static docker-stored-secret, honestly no refresh claimed, smooth like Codex', () => {
  assert.equal(CLAUDE_CODE_API_KEY_HARNESS.credential_discovery.secret_name, 'anthropic');
  assert.equal(CLAUDE_CODE_API_KEY_HARNESS.oauth_refresh.supports_refresh, false);
  assert.equal(CLAUDE_CODE_API_KEY_HARNESS.oauth_refresh.refresh_owner, 'none');
  assert.equal(hasProvenIndefiniteRefresh(CLAUDE_CODE_API_KEY_HARNESS), false);
});

test('Claude Code variants need DIFFERENT login-status probes — corrected after live UAT found /status does not work headlessly', () => {
  // Originally both variants shared one probe based on `/status`. Confirmed
  // directly against a real install that `/status` is a REPL-only slash
  // command, unavailable in --print (federation's only headless mode):
  // `claude --print --dangerously-skip-permissions "/status"` returns
  // "/status isn't available in this environment." Each variant now has its
  // own probe using a signal that's actually checkable non-interactively —
  // and they are deliberately NOT the same signal, because
  // SBX_CRED_ANTHROPIC_MODE only reflects the docker-stored-secret path
  // (confirmed: it stays "none" through a successful subscription-authed
  // task run), so it cannot serve as the subscription variant's probe too.
  assert.notDeepEqual(CLAUDE_CODE_SUBSCRIPTION_HARNESS.login_status_probe, CLAUDE_CODE_API_KEY_HARNESS.login_status_probe);
  // The probe must not START with /status (a stray mention explaining why
  // it's avoided is fine — the comment text above legitimately says
  // "NOT /status"; what matters is the actual command isn't literally that).
  assert.match(CLAUDE_CODE_SUBSCRIPTION_HARNESS.login_status_probe.command, /^cat ~\/\.claude\/\.credentials\.json/);
  assert.match(CLAUDE_CODE_SUBSCRIPTION_HARNESS.login_status_probe.mode_field_hint, /claudeAiOauth/);
  assert.match(CLAUDE_CODE_API_KEY_HARNESS.login_status_probe.mode_field_hint, /SBX_CRED_ANTHROPIC_MODE/);
});

test('gh-cli install is the kit manifest name (sbx run AGENT positional), not a file path — real sbx errors on a path/agent mismatch', () => {
  // Confirmed against a real sbx v0.35.0 install: `sbx run --name X shell
  // <path> --kit <kit-dir>` fails with 'agent name "shell" does not match
  // agent kit name "wf-gh-cli"' — the AGENT positional for a kind:sandbox
  // kit must equal the kit's own manifest `name`.
  assert.equal(GH_CLI_HARNESS.install, 'wf-gh-cli');
  assert.equal(/[/.]/.test(GH_CLI_HARNESS.install), false, 'install must not look like a path or filename');
});

test('Codex entrypoint includes --dangerously-bypass-approvals-and-sandbox — required for unattended execution inside the sbx microVM', () => {
  // Live UAT found Codex's own first-run "Do you trust the contents of this
  // directory?" trust prompt blocks a federation task forever (no terminal
  // to answer it). Confirmed via `codex exec --help` on a real install that
  // this flag is intended exactly for this case: "Intended solely for
  // running in environments that are externally sandboxed." Reproduced
  // directly: a task with this flag ran to completion and exited; without
  // it, the sandbox sits idle at the prompt.
  assert.match(CODEX_HARNESS.entrypoint, /--dangerously-bypass-approvals-and-sandbox/);
  assert.match(CODEX_HARNESS.entrypoint, /^codex exec/);
});

test('both Claude Code variants include --dangerously-skip-permissions — same external-sandbox rationale as Codex', () => {
  // Confirmed via `claude --help` on a real install: "Bypass all permission
  // checks." Required for the same reason as Codex's bypass flag — a
  // federation task has no terminal to answer an in-process permission
  // prompt, and the microVM (not Claude's own guard) is Federation's real
  // containment boundary.
  assert.match(CLAUDE_CODE_SUBSCRIPTION_HARNESS.entrypoint, /--dangerously-skip-permissions/);
  assert.match(CLAUDE_CODE_API_KEY_HARNESS.entrypoint, /--dangerously-skip-permissions/);
  assert.match(CLAUDE_CODE_SUBSCRIPTION_HARNESS.entrypoint, /^claude --print/);
});

test('gh-cli entrypoint needs no bypass flag — gh subcommands are non-interactive by construction for the harness\'s use case', () => {
  // Confirmed directly: `gh --version` and `gh auth status` both run and
  // exit cleanly with no prompt of any kind — gh is a subcommand CLI, not an
  // interactive agent session, so it has no first-run trust/approval prompt
  // to bypass in the first place.
  assert.equal(GH_CLI_HARNESS.entrypoint, 'gh');
});
