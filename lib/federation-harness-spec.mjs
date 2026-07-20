/**
 * Backend-neutral HarnessSpec (auth-model tightening, 2026-07-20).
 *
 * Refines the prior "Docker's native OAuth proxy handles Codex/Claude auth"
 * framing, which treated auth as one solved case. Two assumptions that
 * framing risked making, both wrong in general:
 *
 *   1. "Compatible base URL == subscription auth." A CLI hitting a
 *      provider-compatible endpoint tells you nothing about which BILLING
 *      MODE authorized the request — OpenAI's own docs distinguish
 *      ChatGPT-login (subscription allowance) from API-key auth
 *      (usage-billed at standard rates), and Codex can silently use either
 *      depending on which credential the proxy injects.
 *   2. "Reading a host token == OAuth support." Docker's kit
 *      `credentials.sources` file/jsonPath mechanism reads a STATIC value at
 *      discovery time. Codex's own `auth.json` is actively refreshed and
 *      REWRITTEN BY THE CODEX PROCESS ITSELF as tokens near expiry (~1h) —
 *      confirmed against OpenAI's Codex CI/CD docs and Docker's own
 *      docker/sbx-releases#300, which states host-side OAuth refresh for
 *      arbitrary services is an OPEN feature request; only the BUILT-IN
 *      `codex`/`claude` kits currently get privileged host-side refresh.
 *      A generic file/jsonPath source pointed at `~/.codex/auth.json` would
 *      inject a token that goes stale in about an hour, not a working
 *      refresh flow.
 *
 * A HarnessSpec therefore names its auth STRATEGY explicitly (see
 * AUTH_STRATEGIES) rather than assuming one mechanism fits every harness.
 * "A token was found on the host" and "the subscription is usable
 * indefinitely across concurrent/future jobs" are separate claims — see
 * docs/design/FEDERATION_V0_UAT_REPORT.md's per-harness proof matrix.
 */

export const AUTH_STRATEGIES = Object.freeze([
  // Docker's built-in --oauth login for a small, Docker-curated set of
  // agents (Codex, Claude Code). Docker's own docs and docker/sbx-releases#300
  // both state these get privileged host-side token refresh that the
  // generic credentials.sources mechanism does not yet expose to arbitrary
  // kits. This is the ONLY strategy where refresh-across-time is proven by
  // Docker's own product design, not merely assumed from "we can read a file."
  'docker-native-oauth',

  // A kit's credentials.sources declares a HOST FILE + json:<path> parser to
  // extract a credential (see docs.docker.com/ai/sandboxes/customize/kit-reference/).
  // Correct for a STATIC credential a CLI happens to persist to disk. WRONG
  // for a credential the CLI itself refreshes and rewrites (e.g. Codex's
  // auth.json) unless the harness's own refresh cadence is proven compatible
  // with the proxy's discovery-time read (see oauth_refresh_strategy below).
  'host-file-proxy',

  // A kit's credentials.sources declares a HOST ENV VAR. Same static-value
  // caveat as host-file-proxy, simpler and more common for API keys/PATs.
  'host-env-proxy',

  // `sbx secret set -g <service>` (non---oauth form): a secret stored in the
  // OS keychain via sbx's own secret store, injected the same proxy way.
  // Static value; no refresh semantics beyond "operator re-runs the command."
  'docker-stored-secret',

  // The credential is keychain-held and/or refresh-dependent in a way none
  // of the above strategies reach (e.g. a refresh token + client secret that
  // would have to enter the sandbox for the CLI to refresh it itself). No
  // proxy-only mechanism satisfies this today — Waspflow needs a purpose-
  // built host-side adapter (the shape docker/sbx-releases#300 requests) or
  // must decline to support the harness until one exists. NEVER solve this
  // by copying the refresh token / client secret / full auth file into the
  // guest — that is exactly the risk the proxy model exists to avoid.
  'host-auth-adapter-required',

  // No known strategy applies yet (harness undocumented, auth mechanism
  // unresearched, or genuinely unsupported by Docker Sandboxes as of this
  // writing). Fail closed: Waspflow must not guess.
  'unsupported',
]);

export class HarnessSpecError extends Error {
  constructor(message) { super(message); this.name = 'HarnessSpecError'; }
}
const fail = (message) => { throw new HarnessSpecError(message); };
const isPlainObject = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const nonEmptyString = (value, name) => {
  if (typeof value !== 'string' || value.length === 0) fail(`${name} must be a non-empty string`);
};

/**
 * @typedef {object} HarnessSpec
 * @property {string} harness_id                 opaque identifier, e.g. 'claude-code', 'codex', 'gogcli'
 * @property {string} install                    how the harness gets into the guest: a built-in sbx
 *                                                agent template name ('codex'|'claude') OR a kit
 *                                                identifier/path for a custom, Waspflow-authored kit
 * @property {string} entrypoint                 fixed guest command run to invoke the harness
 * @property {string} pinned_cli_version          exact/range-pinned CLI version this spec was proven against
 * @property {string} provider_service_id         the kit/built-in service id the proxy matches requests
 *                                                against (e.g. 'openai', 'anthropic', a custom service id)
 * @property {string[]} provider_domains          the harness's NORMAL provider domains (no base-URL
 *                                                rewrite — the CLI hits its real endpoint; Docker's
 *                                                proxy intercepts and substitutes the credential)
 * @property {{header: string, format: string}} auth_header   header name + value format (e.g.
 *                                                {header:'Authorization', format:'Bearer %s'})
 * @property {'docker-native-oauth'|'host-file-proxy'|'host-env-proxy'|'docker-stored-secret'|'host-auth-adapter-required'|'unsupported'} auth_strategy
 * @property {object} credential_discovery        strategy-specific detail; see credentialDiscoveryShape()
 * @property {{supports_refresh: boolean, refresh_owner: 'docker-builtin'|'harness-cli'|'none', evidence: string}} oauth_refresh
 *                                                'docker-builtin' = proven by Docker's own built-in
 *                                                --oauth handling; 'harness-cli' = the CLI refreshes
 *                                                its OWN on-disk credential but Docker's generic proxy
 *                                                only reads a static snapshot at discovery time, so
 *                                                refresh is NOT transparently proxy-mediated (a real
 *                                                risk for host-file-proxy/host-env-proxy strategies);
 *                                                'none' = no refresh needed (static key/PAT)
 * @property {{command: string, reports_auth_mode: boolean, mode_field_hint: string}} login_status_probe
 *                                                how to ask the CLI itself which auth mode is active
 *                                                (e.g. `codex login status`, `claude /status`) — the
 *                                                REPORTED mode is required proof, not just "a request
 *                                                succeeded through a compatible endpoint"
 * @property {{cancel_signal: string, on_cancel: string}} cancellation
 * @property {{result_transport: string}} result_behavior
 */
export function validateHarnessSpec(spec) {
  isPlainObject(spec) || fail('harness spec must be an object');

  const allowed = [
    'harness_id', 'install', 'entrypoint', 'pinned_cli_version', 'provider_service_id',
    'provider_domains', 'auth_header', 'auth_strategy', 'credential_discovery',
    'oauth_refresh', 'login_status_probe', 'cancellation', 'result_behavior',
  ];
  for (const key of Object.keys(spec)) {
    if (!allowed.includes(key)) fail(`harness spec has unknown field: ${key}`);
  }

  nonEmptyString(spec.harness_id, 'harness_id');
  nonEmptyString(spec.install, 'install');
  nonEmptyString(spec.entrypoint, 'entrypoint');
  nonEmptyString(spec.pinned_cli_version, 'pinned_cli_version');
  nonEmptyString(spec.provider_service_id, 'provider_service_id');

  Array.isArray(spec.provider_domains) && spec.provider_domains.length > 0
    || fail('provider_domains must be a non-empty array');
  for (const domain of spec.provider_domains) nonEmptyString(domain, 'provider_domains entry');

  isPlainObject(spec.auth_header) || fail('auth_header must be an object');
  nonEmptyString(spec.auth_header.header, 'auth_header.header');
  nonEmptyString(spec.auth_header.format, 'auth_header.format');
  spec.auth_header.format.includes('%s') || fail('auth_header.format must contain a %s placeholder for the injected credential');

  AUTH_STRATEGIES.includes(spec.auth_strategy) || fail(`auth_strategy must be one of: ${AUTH_STRATEGIES.join(', ')}`);

  validateCredentialDiscovery(spec.auth_strategy, spec.credential_discovery);
  validateOauthRefresh(spec.auth_strategy, spec.oauth_refresh);

  isPlainObject(spec.login_status_probe) || fail('login_status_probe must be an object');
  nonEmptyString(spec.login_status_probe.command, 'login_status_probe.command');
  typeof spec.login_status_probe.reports_auth_mode === 'boolean' || fail('login_status_probe.reports_auth_mode must be a boolean');
  nonEmptyString(spec.login_status_probe.mode_field_hint, 'login_status_probe.mode_field_hint');

  isPlainObject(spec.cancellation) || fail('cancellation must be an object');
  nonEmptyString(spec.cancellation.cancel_signal, 'cancellation.cancel_signal');
  nonEmptyString(spec.cancellation.on_cancel, 'cancellation.on_cancel');

  isPlainObject(spec.result_behavior) || fail('result_behavior must be an object');
  nonEmptyString(spec.result_behavior.result_transport, 'result_behavior.result_transport');

  return spec;
}

const OAUTH_FLOW_SHAPES = Object.freeze(['host-url-flow', 'interactive-session-flow']);

function validateCredentialDiscovery(strategy, discovery) {
  isPlainObject(discovery) || fail('credential_discovery must be an object');
  switch (strategy) {
    case 'docker-native-oauth':
      nonEmptyString(discovery.login_command, 'credential_discovery.login_command (docker-native-oauth)');
      // Auth UX reframe (2026-07-20): waspflow drives this command itself —
      // it must never be presented to the user as "run this yourself." The
      // flow_shape says WHICH structured interaction waspflow needs to
      // mediate, because the two docker-native-oauth harnesses genuinely
      // differ here, not just cosmetically:
      //   'host-url-flow' — the command runs on the HOST, prints a URL, and
      //     completes when the user finishes in a browser (Codex: `sbx
      //     secret set -g openai --oauth` -> "Open this URL..." + a plain
      //     URL, local callback on localhost:1455). Reducible to
      //     {url, waitForCompletion} — no separate device code, confirmed
      //     against the real flow's actual output, not assumed.
      //   'interactive-session-flow' — the command must run INSIDE an
      //     attached, interactive sandbox session (Claude Code: `/login`
      //     typed inside `sbx run claude`). There is no host-side URL to
      //     capture; waspflow cannot reduce this to {url, code} without
      //     misrepresenting the mechanism. See federation-auth-flow.mjs.
      OAUTH_FLOW_SHAPES.includes(discovery.flow_shape)
        || fail(`credential_discovery.flow_shape (docker-native-oauth) must be one of: ${OAUTH_FLOW_SHAPES.join(', ')}`);
      if (discovery.flow_shape === 'host-url-flow') {
        nonEmptyString(discovery.url_prompt_pattern, 'credential_discovery.url_prompt_pattern (host-url-flow) — regex text preceding the URL in the command\'s stdout, used to parse it out');
      }
      return;
    case 'host-file-proxy':
      nonEmptyString(discovery.path, 'credential_discovery.path (host-file-proxy)');
      nonEmptyString(discovery.parser, 'credential_discovery.parser (host-file-proxy, e.g. "json:tokens.access_token")');
      typeof discovery.value_is_static === 'boolean'
        || fail('credential_discovery.value_is_static must be an explicit boolean for host-file-proxy — this is the exact fact that determines whether the strategy is safe to use');
      return;
    case 'host-env-proxy':
      nonEmptyString(discovery.env_var, 'credential_discovery.env_var (host-env-proxy)');
      return;
    case 'docker-stored-secret':
      nonEmptyString(discovery.secret_name, 'credential_discovery.secret_name (docker-stored-secret)');
      return;
    case 'host-auth-adapter-required':
      nonEmptyString(discovery.blocking_reason, 'credential_discovery.blocking_reason (host-auth-adapter-required)');
      return;
    case 'unsupported':
      nonEmptyString(discovery.reason, 'credential_discovery.reason (unsupported)');
      return;
  }
}

function validateOauthRefresh(strategy, refresh) {
  isPlainObject(refresh) || fail('oauth_refresh must be an object');
  typeof refresh.supports_refresh === 'boolean' || fail('oauth_refresh.supports_refresh must be a boolean');
  ['docker-builtin', 'harness-cli', 'none'].includes(refresh.refresh_owner)
    || fail("oauth_refresh.refresh_owner must be one of: 'docker-builtin', 'harness-cli', 'none'");
  nonEmptyString(refresh.evidence, 'oauth_refresh.evidence');

  // The dangerous case this module exists to prevent: claiming refresh works
  // via a strategy that cannot actually observe the harness's own refresh
  // cycle. host-file-proxy/host-env-proxy read a value ONCE at discovery
  // time; if the harness rewrites its own credential file out-of-band (like
  // Codex's auth.json), refresh_owner must never be 'docker-builtin' under
  // those strategies, because Docker's generic proxy did not perform it.
  if (['host-file-proxy', 'host-env-proxy'].includes(strategy) && refresh.supports_refresh && refresh.refresh_owner === 'docker-builtin') {
    fail(
      `oauth_refresh claims 'docker-builtin' refresh under strategy '${strategy}', but Docker's generic ` +
      "credentials.sources mechanism reads a static value at discovery time (docker/sbx-releases#300: " +
      "host-side refresh for non-built-in services is an open feature request). Use refresh_owner " +
      "'harness-cli' if the CLI refreshes its own on-disk file (and prove the proxy re-reads it), " +
      "or 'none' if no refresh is needed."
    );
  }
}

/**
 * True only when a harness's auth strategy has Docker-documented,
 * currently-shipping support for keeping a REFRESHING credential out of the
 * guest indefinitely. Every other strategy either doesn't need refresh
 * (static key) or has NOT been shown to handle refresh safely — callers
 * must not treat "credential_discovery exists" as equivalent to this.
 */
export function hasProvenIndefiniteRefresh(spec) {
  return spec.auth_strategy === 'docker-native-oauth' && spec.oauth_refresh.supports_refresh === true && spec.oauth_refresh.refresh_owner === 'docker-builtin';
}
