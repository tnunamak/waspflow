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
  assert.match(CODEX_HARNESS.login_status_probe.mode_field_hint, /chatgpt/i);
  assert.match(CLAUDE_CODE_HARNESS.login_status_probe.mode_field_hint, /CLAUDE_CODE_OAUTH_TOKEN/);
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

test('both Claude Code variants report the SAME login-status probe, so the reported mode (not the strategy label) is what proves which billing path is active', () => {
  assert.deepEqual(CLAUDE_CODE_SUBSCRIPTION_HARNESS.login_status_probe, CLAUDE_CODE_API_KEY_HARNESS.login_status_probe);
  assert.match(CLAUDE_CODE_API_KEY_HARNESS.login_status_probe.mode_field_hint, /ANTHROPIC_API_KEY/);
});

test('gh-cli install is the kit manifest name (sbx run AGENT positional), not a file path — real sbx errors on a path/agent mismatch', () => {
  // Confirmed against a real sbx v0.35.0 install: `sbx run --name X shell
  // <path> --kit <kit-dir>` fails with 'agent name "shell" does not match
  // agent kit name "wf-gh-cli"' — the AGENT positional for a kind:sandbox
  // kit must equal the kit's own manifest `name`.
  assert.equal(GH_CLI_HARNESS.install, 'wf-gh-cli');
  assert.equal(/[/.]/.test(GH_CLI_HARNESS.install), false, 'install must not look like a path or filename');
});
