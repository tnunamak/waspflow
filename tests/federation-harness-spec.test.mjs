import test from 'node:test';
import assert from 'node:assert/strict';
import { validateHarnessSpec, HarnessSpecError, AUTH_STRATEGIES, hasProvenIndefiniteRefresh } from '../lib/federation-harness-spec.mjs';

const base = (overrides = {}) => ({
  harness_id: 'test-harness',
  install: 'codex',
  entrypoint: 'codex exec',
  pinned_cli_version: '0.1.0',
  provider_service_id: 'openai',
  provider_domains: ['api.openai.com'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-native-oauth',
  credential_discovery: { login_command: 'sbx secret set -g openai --oauth' },
  oauth_refresh: { supports_refresh: true, refresh_owner: 'docker-builtin', evidence: 'docker/sbx-releases#300' },
  login_status_probe: { command: 'codex login status', reports_auth_mode: true, mode_field_hint: 'auth_mode' },
  cancellation: { cancel_signal: 'sbx stop', on_cancel: 'sandbox stopped, process killed' },
  result_behavior: { result_transport: 'stdout' },
  ...overrides,
});

test('accepts a well-formed docker-native-oauth spec (Codex/Claude shape)', () => {
  assert.deepEqual(validateHarnessSpec(base()), base());
});

test('rejects an unknown auth_strategy', () => {
  assert.throws(() => validateHarnessSpec(base({ auth_strategy: 'made-up-strategy' })), HarnessSpecError);
});

test('every documented AUTH_STRATEGIES value is exactly 6, matching the correction', () => {
  assert.equal(AUTH_STRATEGIES.length, 6);
  assert.deepEqual(AUTH_STRATEGIES, [
    'docker-native-oauth', 'host-file-proxy', 'host-env-proxy',
    'docker-stored-secret', 'host-auth-adapter-required', 'unsupported',
  ]);
});

test('host-file-proxy requires an explicit value_is_static boolean', () => {
  const spec = base({
    auth_strategy: 'host-file-proxy',
    credential_discovery: { path: '~/.codex/auth.json', parser: 'json:tokens.access_token' },
    oauth_refresh: { supports_refresh: false, refresh_owner: 'none', evidence: 'static snapshot only' },
  });
  assert.throws(() => validateHarnessSpec(spec), /value_is_static/);
});

test('CORE SAFETY CHECK: host-file-proxy cannot claim docker-builtin refresh — this is the exact bug the correction warns about', () => {
  const spec = base({
    auth_strategy: 'host-file-proxy',
    credential_discovery: { path: '~/.codex/auth.json', parser: 'json:tokens.access_token', value_is_static: false },
    oauth_refresh: { supports_refresh: true, refresh_owner: 'docker-builtin', evidence: 'wrong: file/jsonPath is not refresh-aware' },
  });
  assert.throws(() => validateHarnessSpec(spec), /docker\/sbx-releases#300/);
});

test('host-file-proxy MAY claim harness-cli refresh honestly (the CLI refreshes its own file; still flagged as a real risk elsewhere)', () => {
  const spec = base({
    auth_strategy: 'host-file-proxy',
    credential_discovery: { path: '~/.codex/auth.json', parser: 'json:tokens.access_token', value_is_static: false },
    oauth_refresh: { supports_refresh: true, refresh_owner: 'harness-cli', evidence: 'codex rewrites auth.json; proxy re-read cadence unverified' },
  });
  assert.deepEqual(validateHarnessSpec(spec), spec);
});

test('host-env-proxy hits the same docker-builtin refresh guard as host-file-proxy', () => {
  const spec = base({
    auth_strategy: 'host-env-proxy',
    credential_discovery: { env_var: 'MY_SERVICE_API_KEY' },
    oauth_refresh: { supports_refresh: true, refresh_owner: 'docker-builtin', evidence: 'wrong' },
  });
  assert.throws(() => validateHarnessSpec(spec), /docker\/sbx-releases#300/);
});

test('docker-stored-secret requires a secret_name', () => {
  const spec = base({
    auth_strategy: 'docker-stored-secret',
    credential_discovery: {},
    oauth_refresh: { supports_refresh: false, refresh_owner: 'none', evidence: 'static secret, no refresh' },
  });
  assert.throws(() => validateHarnessSpec(spec), /secret_name/);
});

test('host-auth-adapter-required requires a blocking_reason and never claims docker-builtin refresh implicitly', () => {
  const spec = base({
    auth_strategy: 'host-auth-adapter-required',
    credential_discovery: { blocking_reason: 'refresh token + client secret would have to enter the guest for the CLI to self-refresh' },
    oauth_refresh: { supports_refresh: false, refresh_owner: 'none', evidence: 'no adapter built yet' },
  });
  assert.deepEqual(validateHarnessSpec(spec), spec);
});

test('unsupported requires a reason and fails closed rather than guessing', () => {
  const spec = base({
    auth_strategy: 'unsupported',
    credential_discovery: { reason: 'harness undocumented, no known Docker Sandboxes auth path' },
    oauth_refresh: { supports_refresh: false, refresh_owner: 'none', evidence: 'n/a' },
  });
  assert.deepEqual(validateHarnessSpec(spec), spec);
});

test('rejects auth_header.format without a %s placeholder', () => {
  const spec = base({ auth_header: { header: 'Authorization', format: 'Bearer static-no-placeholder' } });
  assert.throws(() => validateHarnessSpec(spec), /%s/);
});

test('rejects unknown top-level fields', () => {
  assert.throws(() => validateHarnessSpec(base({ base_url_override: 'https://evil.example' })), HarnessSpecError);
});

test('hasProvenIndefiniteRefresh is true only for docker-native-oauth with docker-builtin refresh', () => {
  assert.equal(hasProvenIndefiniteRefresh(base()), true);

  const harnessCli = base({
    auth_strategy: 'host-file-proxy',
    credential_discovery: { path: '~/.codex/auth.json', parser: 'json:tokens.access_token', value_is_static: false },
    oauth_refresh: { supports_refresh: true, refresh_owner: 'harness-cli', evidence: 'unverified proxy re-read cadence' },
  });
  assert.equal(hasProvenIndefiniteRefresh(harnessCli), false);

  const staticKey = base({
    auth_strategy: 'docker-stored-secret',
    credential_discovery: { secret_name: 'my-service' },
    oauth_refresh: { supports_refresh: false, refresh_owner: 'none', evidence: 'static PAT, no refresh needed' },
  });
  assert.equal(hasProvenIndefiniteRefresh(staticKey), false);
});
