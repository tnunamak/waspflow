/**
 * Concrete HarnessSpec instances for Federation v0's three UAT harnesses.
 * See lib/federation-harness-spec.mjs for the schema and the auth-strategy
 * rationale. Classification evidence for each spec is cited inline; every
 * claim here was independently checked against Docker's own documentation
 * and open issues, not inferred from the auth correction's wording alone.
 */
import { validateHarnessSpec } from './federation-harness-spec.mjs';

/**
 * Codex: docker-native-oauth. Confirmed — NOT assumed — that Codex specifically
 * (not just Claude) gets Docker's built-in, host-refreshing OAuth handling:
 * `sbx secret set -g openai --oauth` stores the token in the OS keychain and
 * the flow "runs on the host, so the token is never exposed inside the
 * sandbox" (docs.docker.com/ai/sandboxes/security/credentials/). Separately,
 * Codex's own `codex login status` reports an explicit `auth_mode` field —
 * `apiKey` | `chatgpt` | `chatgptAuthTokens` — which is the REPORTED-mode
 * proof the correction requires (a successful request through a compatible
 * endpoint is not sufficient; the CLI's own status output is).
 *
 * Caveat (usability, not a correctness gap): Docker's `--oauth` flow expects
 * a local browser callback, which is awkward on a headless Linux host; an
 * open Docker feature request (docker/sbx-releases#208) asks for a
 * device-code flow. This affects HOW an operator completes step 1 of the
 * proof, not whether the resulting auth is subscription-backed or
 * guest-isolated once established.
 */
export const CODEX_HARNESS = validateHarnessSpec({
  harness_id: 'codex',
  install: 'codex', // built-in sbx agent template name, not a custom image
  entrypoint: 'codex exec',
  pinned_cli_version: 'unpinned — see profiles/wf-federation-docker-v0.json for the sbx floor; Codex CLI version pinning is a separate follow-up',
  provider_service_id: 'openai',
  provider_domains: ['api.openai.com', 'auth.openai.com', 'chatgpt.com'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-native-oauth',
  credential_discovery: {
    login_command: 'sbx secret set -g openai --oauth',
    // Confirmed against the real flow's own output (not assumed): it prints
    // "Open this URL to sign in to Codex OAuth:" followed by a plain URL,
    // then blocks on a local callback (localhost:1455) until the browser
    // step completes. No separate device code — reducible to a single URL +
    // a completion wait. See lib/federation-auth-flow.mjs, which waspflow
    // uses to drive this command itself rather than telling the user to run
    // it (auth UX reframe, 2026-07-20).
    flow_shape: 'host-url-flow',
    url_prompt_pattern: 'Open this URL to sign in',
  },
  oauth_refresh: {
    supports_refresh: true,
    refresh_owner: 'docker-builtin',
    evidence: 'docs.docker.com/ai/sandboxes/security/credentials/: "the flow runs on the host, so the token is never exposed inside the sandbox" — Docker performs the refresh, not a generic file/jsonPath read.',
  },
  login_status_probe: {
    command: 'codex login status',
    reports_auth_mode: true,
    mode_field_hint: 'auth_mode field: "apiKey" | "chatgpt" | "chatgptAuthTokens" — "chatgpt"/"chatgptAuthTokens" confirms subscription billing; "apiKey" confirms usage-billed API auth. A successful request alone does not distinguish these.',
  },
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (codex exec) or streamed agent turn events' },
});

/**
 * Claude Code has TWO real, independently-confirmed auth paths — a product
 * tradeoff the operator must choose, not something this module silently
 * picks (owner steer, 2026-07-20). Confirmed directly against a real sbx
 * v0.35.0 install: `sbx secret set --oauth` is HARD-CODED to openai/global
 * only — `sbx secret set -g anthropic --oauth` fails with the CLI's own
 * error, "anthropic OAuth cannot be started from `sbx secret set`; sign in
 * from inside the Claude sandbox." There is no host-drivable Anthropic
 * subscription OAuth in this sbx release. That is an sbx limitation, not a
 * Waspflow design choice — documented here so it isn't mistaken for one.
 *
 * 1. CLAUDE_CODE_SUBSCRIPTION_HARNESS (default — the product intent: pooling
 *    otherwise-wasted SUBSCRIPTION capacity, not paying per-token). Auth is
 *    `/login` typed inside an attached, interactive sandbox session
 *    (`sbx run claude` then `/login`) — `interactive-session-flow`,
 *    UNAVOIDABLE in v0 because sbx exposes no host-side path for it. Docker's
 *    own docs phrase this as "prompt[s] interactively inside the sandbox,"
 *    which could be misread as "the credential lives in the sandbox";
 *    independently confirmed the underlying mechanism is the same host-side
 *    HTTP/HTTPS proxy interception as Codex's OAuth — the INTERACTION is
 *    in-session, the credential material is not. If/when sbx adds a
 *    host-drivable Anthropic OAuth flow (mirroring the openai one), this
 *    harness should be revisited to use `startAuthFlow()` like Codex's.
 * 2. CLAUDE_CODE_API_KEY_HARNESS (operator-selectable for smoothness). Auth
 *    is `echo "$ANTHROPIC_API_KEY" | sbx secret set -g anthropic` — host-side,
 *    waspflow-drivable via the SAME `docker-stored-secret` mechanism as any
 *    other static secret, same smooth shape as Codex's OAuth from the
 *    operator's point of view. The real cost: USAGE-BILLED at standard API
 *    rates, not covered by a Claude subscription — this is not "the same
 *    thing but easier," it is a different billing relationship entirely.
 *
 * Both report their active mode via Claude Code's own `/status` command
 * ("Auth token" field: CLAUDE_CODE_OAUTH_TOKEN = subscription,
 * ANTHROPIC_API_KEY = usage-billed, ANTHROPIC_AUTH_TOKEN = gateway) — the
 * REPORTED-mode proof this project requires, not a bare "request succeeded."
 * Waspflow's own `lib/billing.sh` already treats a stray ANTHROPIC_API_KEY
 * silently overriding subscription auth as a real, previously-encountered
 * risk for headless Claude workers, not a hypothetical one.
 */
const CLAUDE_STATUS_PROBE = {
  command: '/status (inside the Claude Code session)',
  reports_auth_mode: true,
  mode_field_hint: '"Auth token" field: CLAUDE_CODE_OAUTH_TOKEN (subscription) | ANTHROPIC_API_KEY (usage-billed) | ANTHROPIC_AUTH_TOKEN (gateway) — waspflow\'s own lib/billing.sh already treats this exact ambiguity as a real, previously-encountered risk for headless Claude workers.',
};

export const CLAUDE_CODE_SUBSCRIPTION_HARNESS = validateHarnessSpec({
  harness_id: 'claude-code-subscription',
  install: 'claude', // built-in sbx agent template name
  entrypoint: 'claude --print',
  pinned_cli_version: 'unpinned — see profiles/wf-federation-docker-v0.json for the sbx floor; Claude Code version pinning is a separate follow-up',
  provider_service_id: 'anthropic',
  provider_domains: ['api.anthropic.com', 'claude.ai'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-native-oauth',
  credential_discovery: {
    login_command: '/login',
    // NOT reducible to {url, waitForCompletion} the way Codex's flow is —
    // `/login` must run INSIDE an attached, interactive sandbox session
    // (`sbx run claude`); there is no host-side URL for waspflow to capture
    // and hand to a non-terminal UI. This asymmetry is real, not a gap in
    // this module: see lib/federation-auth-flow.mjs's module doc for how
    // v0 handles it honestly rather than forcing a false uniformity with
    // Codex's flow_shape. It is also NOT avoidable while staying on the
    // subscription billing path — sbx's --oauth flag is openai-only,
    // confirmed directly against a real install (see module doc above).
    flow_shape: 'interactive-session-flow',
  },
  oauth_refresh: {
    supports_refresh: true,
    refresh_owner: 'docker-builtin',
    evidence: 'docs.docker.com/ai/sandboxes/security/credentials/: identical host-side HTTP/HTTPS proxy interception mechanism as Codex OAuth; the interaction is in-session but the credential material is not.',
  },
  login_status_probe: CLAUDE_STATUS_PROBE,
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (claude --print) or streamed session events' },
});

export const CLAUDE_CODE_API_KEY_HARNESS = validateHarnessSpec({
  harness_id: 'claude-code-api-key',
  install: 'claude', // built-in sbx agent template name
  entrypoint: 'claude --print',
  pinned_cli_version: 'unpinned — see profiles/wf-federation-docker-v0.json for the sbx floor; Claude Code version pinning is a separate follow-up',
  provider_service_id: 'anthropic',
  provider_domains: ['api.anthropic.com', 'claude.ai'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-stored-secret',
  credential_discovery: {
    // Confirmed against a real install: `sbx secret set --help` lists
    // 'anthropic' as a supported service; `echo "$ANTHROPIC_API_KEY" |
    // sbx secret set -g anthropic` is the documented non-interactive form
    // (the same pattern Docker's own examples use for openai/github/etc).
    // Host-side, waspflow-drivable via startAuthFlow-equivalent tooling —
    // smooth like Codex's OAuth — but the resulting secret is a STATIC API
    // key, not a refreshing OAuth token, and it is USAGE-BILLED.
    secret_name: 'anthropic',
  },
  oauth_refresh: {
    supports_refresh: false,
    refresh_owner: 'none',
    evidence: 'A static Anthropic API key does not refresh; docker-stored-secret is the correct strategy for a static, host-side-settable credential.',
  },
  login_status_probe: CLAUDE_STATUS_PROBE,
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (claude --print) or streamed session events' },
});

/**
 * Default export for callers that haven't opted into the explicit choice
 * above — resolves to the SUBSCRIPTION variant, matching the product intent
 * (pooling wasted subscription capacity, not routing spend through
 * usage-billed API keys). Callers who want the smoother, usage-billed path
 * should import `CLAUDE_CODE_API_KEY_HARNESS` explicitly rather than rely on
 * this default silently changing meaning later.
 */
export const CLAUDE_CODE_HARNESS = CLAUDE_CODE_SUBSCRIPTION_HARNESS;

/**
 * GitHub CLI (`gh`): host-env-proxy. NOT a built-in sbx agent — this is the
 * extensibility proof, onboarded via a Waspflow-authored custom kit
 * (kits/wf-gh-cli/spec.yaml) using Docker's documented `credentials.sources`
 * env-var injection (docs.docker.com/ai/sandboxes/customize/kit-reference/),
 * not a Waspflow-built gateway.
 *
 * Deliberately chosen because its credential (a GitHub Personal Access Token
 * via GH_TOKEN) is STATIC — `gh` does not self-refresh or rewrite its token
 * the way Codex's auth.json does. This keeps the extensibility proof honest:
 * it demonstrates that a NEW harness can be onboarded via the documented kit
 * mechanism, without also having to (mis)claim that mechanism handles
 * refresh — refresh_owner is 'none' because none is needed, not because
 * refresh was proven safe for this strategy.
 *
 * `install` is the kit's own `name` field ("wf-gh-cli") — confirmed against a
 * real, detached `sbx run` that for a `kind: sandbox` kit the AGENT
 * positional must equal the kit's manifest name (sbx errors explicitly:
 * `agent name "shell" does not match agent kit name "wf-gh-cli"` if it
 * doesn't). Callers treat `install` as the `sbx run` agent positional for
 * every strategy uniformly; the kit directory itself (`kits/<install>/`) is
 * passed separately via `--kit`, by convention (`install` names the kit
 * subdirectory 1:1), not a separate spec field — see
 * scripts/federation-harness-auth-proof-live-run.sh's `run_sandbox()`.
 */
export const GH_CLI_HARNESS = validateHarnessSpec({
  harness_id: 'gh-cli',
  install: 'wf-gh-cli', // the kit's own manifest `name` — the sbx run AGENT positional for a kind:sandbox kit
  entrypoint: 'gh',
  pinned_cli_version: 'unpinned — follow-up: pin to a specific gh CLI release once this kit is exercised against real sbx',
  provider_service_id: 'github',
  provider_domains: ['api.github.com', 'github.com', 'objects.githubusercontent.com'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'host-env-proxy',
  credential_discovery: { env_var: 'GH_TOKEN' },
  oauth_refresh: {
    supports_refresh: false,
    refresh_owner: 'none',
    evidence: 'GH_TOKEN is a static Personal Access Token; gh does not self-refresh it. No refresh mechanism is needed or claimed.',
  },
  login_status_probe: {
    command: 'gh auth status',
    reports_auth_mode: true,
    mode_field_hint: '"Logged in to github.com account <user> (GH_TOKEN)" vs an unauthenticated/error message — gh reports the active token source explicitly.',
  },
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout' },
});
