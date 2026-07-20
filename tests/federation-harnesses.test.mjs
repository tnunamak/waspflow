import test from 'node:test';
import assert from 'node:assert/strict';
import { CODEX_HARNESS, CLAUDE_CODE_HARNESS, GH_CLI_HARNESS } from '../lib/federation-harnesses.mjs';
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
