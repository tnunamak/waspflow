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
  credential_discovery: { login_command: 'sbx secret set -g openai --oauth' },
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
 * Claude Code: docker-native-oauth. Docker's own docs state Claude Code
 * "prompt[s] interactively inside the sandbox" for `/login` — this phrasing
 * could be misread as "the credential lives in the sandbox." Independently
 * confirmed (this repo's prior verification pass, and re-confirmed here)
 * that the underlying mechanism is the same host-side HTTP/HTTPS proxy
 * interception as Codex's: the login INTERACTION happens in-session, but the
 * real credential material does not become guest-resident.
 *
 * Claude Code's own `/status` command reports an "Auth token" field
 * distinguishing CLAUDE_CODE_OAUTH_TOKEN (subscription) from
 * ANTHROPIC_API_KEY (usage-billed) from ANTHROPIC_AUTH_TOKEN (gateway) — the
 * same category of REPORTED-mode proof as Codex's auth_mode field. Waspflow
 * already has billing-safety logic (lib/billing.sh) built around exactly
 * this ambiguity for its own headless Claude workers — a stray
 * ANTHROPIC_API_KEY silently overriding subscription auth is a known,
 * previously-encountered failure mode, not a hypothetical one.
 */
export const CLAUDE_CODE_HARNESS = validateHarnessSpec({
  harness_id: 'claude-code',
  install: 'claude', // built-in sbx agent template name
  entrypoint: 'claude --print',
  pinned_cli_version: 'unpinned — see profiles/wf-federation-docker-v0.json for the sbx floor; Claude Code version pinning is a separate follow-up',
  provider_service_id: 'anthropic',
  provider_domains: ['api.anthropic.com', 'claude.ai'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-native-oauth',
  credential_discovery: { login_command: '/login (typed inside the sandbox session; proxy-mediated per Docker credential-isolation docs, not guest-resident)' },
  oauth_refresh: {
    supports_refresh: true,
    refresh_owner: 'docker-builtin',
    evidence: 'docs.docker.com/ai/sandboxes/security/credentials/: identical host-side HTTP/HTTPS proxy interception mechanism as Codex OAuth; the interaction is in-session but the credential material is not.',
  },
  login_status_probe: {
    command: '/status (inside the Claude Code session)',
    reports_auth_mode: true,
    mode_field_hint: '"Auth token" field: CLAUDE_CODE_OAUTH_TOKEN (subscription) | ANTHROPIC_API_KEY (usage-billed) | ANTHROPIC_AUTH_TOKEN (gateway) — waspflow\'s own lib/billing.sh already treats this exact ambiguity as a real, previously-encountered risk for headless Claude workers.',
  },
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (claude --print) or streamed session events' },
});

/**
 * GitHub CLI (`gh`): host-env-proxy. NOT a built-in sbx agent — this is the
 * extensibility proof, onboarded via a Waspflow-authored custom kit
 * (kits/wf-gh-cli.kit.yaml) using Docker's documented `credentials.sources`
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
 */
export const GH_CLI_HARNESS = validateHarnessSpec({
  harness_id: 'gh-cli',
  install: 'kits/wf-gh-cli.kit.yaml', // custom Waspflow-authored kit, not a built-in template name
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
