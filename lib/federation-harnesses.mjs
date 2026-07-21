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
  // `--dangerously-bypass-approvals-and-sandbox` (confirmed via `codex exec
  // --help` on a real install): "Skip all confirmation prompts and execute
  // commands without sandboxing. EXTREMELY DANGEROUS. Intended solely for
  // running in environments that are externally sandboxed."
  //
  // Without it, Codex's own first-run "Do you trust the contents of this
  // directory?" prompt blocks a federation task forever — a headless job has
  // no terminal to answer it, and the sandbox launch just hangs (confirmed
  // live: this exact prompt stalled the owner's first successful `sbx run`
  // after the argument-order fix). This is not a workaround for that hang;
  // it is the flag's INTENDED use per Codex's own documentation. Federation
  // v0's Docker Sandboxes microVM IS the "externally sandboxed" environment
  // the flag requires — per Docker's own isolation model (confirmed earlier
  // in this project: 5 isolation layers, credential proxy, deny-by-default
  // network, per-sandbox filesystem), Codex's in-VM
  // approval/trust/no-sandboxing concerns are already handled ONE LEVEL
  // OUTSIDE the process this flag affects. Codex's own `--sandbox` flag
  // governs command execution INSIDE its own process (read-only,
  // workspace-write, danger-full-access) — a second, redundant containment
  // layer for a process that is already running inside a full microVM with
  // its own kernel, filesystem, and network boundary. Bypassing Codex's
  // in-process sandbox does not weaken Federation's actual security
  // boundary, which is the microVM itself (graduation gates A-G), not
  // Codex's own opt-in command-execution guard.
  //
  // This is scoped narrowly: it is safe BECAUSE the entrypoint always runs
  // inside a fresh, disposable sbx sandbox (never on the bare host — see
  // lib/federation-docker-backend.mjs, which never mounts a real repo or
  // home directory). Using this flag OUTSIDE that context — e.g. on a bare
  // host, or a container without its own kernel/network isolation — would
  // be exactly as dangerous as Codex's own docs warn.
  entrypoint: 'codex exec --dangerously-bypass-approvals-and-sandbox',
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
  // CORRECTED against a real sbx v0.35.0 install (the original claim below
  // was wrong, inferred from third-party research rather than verified):
  // `codex login status` does NOT expose a JSON `auth_mode` field inside an
  // sbx-proxied sandbox, and it reports "Logged in using an API key" even
  // when the real upstream credential is `sbx secret set -g openai --oauth`
  // (subscription-derived). Root cause, confirmed by reading the guest's own
  // `~/.codex/auth.json`: sbx's proxy model ALWAYS presents Codex with an
  // API-key-shaped sentinel (`{"OPENAI_API_KEY": "proxy-managed"}`) — the
  // guest process has no way to distinguish "the proxy is backed by OAuth"
  // from "the proxy is backed by a real API key" from inside the sandbox.
  // The real signal lives at the sbx proxy layer instead:
  // `sbx exec <sandbox> -- env | grep SBX_CRED_OPENAI_MODE` reports `oauth`
  // when `--oauth` was used to configure the secret. This is a HOST-visible
  // (via sbx exec), not guest-CLI-reported, signal — a real limitation on
  // "the harness's own reported mode" as proof, worth being honest about
  // rather than continuing to claim the original (incorrect) mechanism.
  login_status_probe: {
    command: 'env (inside the sandbox, via sbx exec — NOT `codex login status`, which cannot distinguish oauth/apiKey from inside an sbx-proxied guest)',
    reports_auth_mode: true,
    mode_field_hint: 'SBX_CRED_OPENAI_MODE env var: "oauth" (subscription-derived, set via `sbx secret set -g openai --oauth`) vs "apikey"/"none" (a directly-configured API key or no secret at all). This is an sbx PROXY-layer signal, not something `codex login status` itself can report — confirmed by inspecting the guest\'s own auth.json, which always shows an API-key shape regardless of the real upstream credential.',
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
// CORRECTED against a real sbx v0.35.0 install (the original single probe
// below was wrong for headless use): `/status` is a Claude Code SLASH
// COMMAND, only available in the interactive REPL — confirmed directly:
// `claude --print --dangerously-skip-permissions "/status"` returns
// "/status isn't available in this environment." rather than the Auth token
// field. It cannot be the reported-mode proof for a `--print`-driven
// federation task, which is the only mode Federation v0 runs headlessly.
//
// Each Claude Code variant needs its OWN probe, because they differ in what
// is actually checkable non-interactively:
//   - Subscription: no env-var equivalent of Codex's SBX_CRED_ANTHROPIC_MODE
//     reflects the in-session /login state (confirmed: it stays "none" even
//     after a successful task run using genuine subscription auth, because
//     that env var only reflects an `sbx secret`-CONFIGURED credential, not
//     an in-session OAuth login). The only confirmed non-interactive signal
//     is the guest's own `~/.claude/.credentials.json`, which contains a
//     `claudeAiOauth` block with sentinel token values
//     (`sk-ant-oat01-proxy-managed`) once /login has completed — presence of
//     that block (not its content, which is a sentinel) is the proof.
//   - Api-key: `SBX_CRED_ANTHROPIC_MODE` DOES correctly reflect this path,
//     since it is exactly the `sbx secret set -g anthropic` mechanism that
//     variable exists to report.
const CLAUDE_SUBSCRIPTION_STATUS_PROBE = {
  command: 'cat ~/.claude/.credentials.json (inside the sandbox, via sbx exec — NOT /status, which is REPL-only and unavailable in --print mode)',
  reports_auth_mode: true,
  mode_field_hint: 'Presence of a "claudeAiOauth" block (with sentinel token values like "sk-ant-oat01-proxy-managed", never a real credential — confirmed by direct inspection) indicates a completed /login subscription session. Absence means no subscription auth is active.',
};
const CLAUDE_API_KEY_STATUS_PROBE = {
  command: 'env (inside the sandbox, via sbx exec)',
  reports_auth_mode: true,
  mode_field_hint: 'SBX_CRED_ANTHROPIC_MODE env var: "apikey" once `sbx secret set -g anthropic` has been configured with a static key, vs "none". Confirmed against a real install as the correct, working signal for this specific strategy (unlike the subscription variant, where this same env var does NOT reflect the in-session /login state).',
};

// `--dangerously-skip-permissions` (confirmed via `claude --help` on a real
// install): "Bypass all permission checks." See CODEX_HARNESS's entrypoint
// comment above for the full external-sandbox rationale this shares — brief
// recap: a federation task runs unattended inside a fresh, disposable sbx
// microVM (never the bare host); that microVM is Federation's real
// containment boundary (graduation gates A-G), so each harness's OWN
// in-process permission/trust/approval prompt is a SECOND, redundant guard
// for a process that's already fully contained one level out. Bypassing it
// does not weaken Federation's security boundary; leaving it enabled would
// only replace a real boundary (the microVM) with a prompt no unattended
// job can ever answer, hanging every run forever.
export const CLAUDE_CODE_SUBSCRIPTION_HARNESS = validateHarnessSpec({
  harness_id: 'claude-code-subscription',
  install: 'claude', // built-in sbx agent template name
  entrypoint: 'claude --print --dangerously-skip-permissions',
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
  login_status_probe: CLAUDE_SUBSCRIPTION_STATUS_PROBE,
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (claude --print) or streamed session events' },
});

export const CLAUDE_CODE_API_KEY_HARNESS = validateHarnessSpec({
  harness_id: 'claude-code-api-key',
  install: 'claude', // built-in sbx agent template name
  entrypoint: 'claude --print --dangerously-skip-permissions', // same external-sandbox rationale as CLAUDE_CODE_SUBSCRIPTION_HARNESS above
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
  login_status_probe: CLAUDE_API_KEY_STATUS_PROBE,
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
 * Gemini CLI: docker-stored-secret, NOT docker-native-oauth — confirmed
 * directly against a real sbx v0.35.0 install, same limitation class already
 * found for Anthropic. `sbx secret set --help` lists `google` as a supported
 * service (`gemini` itself is not a valid `--oauth`/`secret set` service
 * name — the service is `google`), but `--oauth` is HARD-CODED
 * openai/global-only: there is no host-drivable Google subscription OAuth in
 * this sbx release, only a static, `sbx secret set -g google`-configured
 * credential. This is an sbx limitation, not a Waspflow design choice.
 *
 * Confirmed the resulting proxy-layer signal live: `echo "$KEY" | sbx secret
 * set -g google`, then `sbx run gemini --name X <dir> --detached`, then
 * `sbx exec X -- env` showed `SBX_CRED_GOOGLE_MODE=apikey` and
 * `GEMINI_API_KEY=proxy-managed` (the same never-a-real-credential sentinel
 * pattern as Codex's `OPENAI_API_KEY=proxy-managed` and Claude's
 * `.credentials.json`) — the mechanism is real and matches the other
 * docker-stored-secret harness (CLAUDE_CODE_API_KEY_HARNESS) exactly.
 *
 * Separately confirmed (2026-07-21, see docs/design/FEDERATION_V0_UAT_REPORT.md
 * and lib/providers/gemini.sh's module doc): the gemini-cli binary itself
 * additionally requires --skip-trust (a first-run directory-trust gate
 * distinct from --approval-mode yolo, which only clears tool-call approval)
 * and has no --effort/--reasoning-effort flag at all — both reflected in the
 * entrypoint and the deliberate absence of an effort field below.
 *
 * NOT independently proven end-to-end against a real task: this machine's
 * linked Google account is rejected by gemini-cli 0.50.0/0.51.0 with
 * IneligibleTierError ("no longer supported for Gemini Code Assist for
 * individuals... migrate to Antigravity") before any task can run — a
 * server-side account-tier check, unrelated to sbx or this harness's
 * classification. What WAS proven live: sandbox creation, credential
 * injection (SBX_CRED_GOOGLE_MODE, GEMINI_API_KEY sentinel), and a real,
 * correctly-enforced network-policy rejection (a fresh deny-all sbx identity
 * blocked generativelanguage.googleapis.com with a clear, structured `-o
 * json` error) — i.e., everything up to the account-tier wall.
 */
export const GEMINI_HARNESS = validateHarnessSpec({
  harness_id: 'gemini',
  install: 'gemini', // built-in sbx agent template name (confirmed: `sbx run --help` lists gemini among built-in agents)
  // --skip-trust clears the first-run directory-trust gate (distinct from
  // --approval-mode yolo, which only clears tool-call approval — confirmed
  // directly that yolo alone left an untrusted-dir headless run blocked).
  // Same external-sandbox rationale as every other harness's bypass flag
  // here: the sbx microVM is Federation's real containment boundary: see
  // CODEX_HARNESS's entrypoint comment above for the full argument.
  entrypoint: 'gemini -o json --approval-mode yolo --skip-trust -p',
  pinned_cli_version: 'unpinned — see profiles/wf-federation-docker-v0.json for the sbx floor; gemini-cli version pinning is a separate follow-up',
  provider_service_id: 'google',
  provider_domains: ['generativelanguage.googleapis.com', 'oauth2.googleapis.com'],
  auth_header: { header: 'Authorization', format: 'Bearer %s' },
  auth_strategy: 'docker-stored-secret',
  credential_discovery: {
    // Confirmed against a real install: `sbx secret set --help` lists
    // 'google' as a supported service; `echo "$GEMINI_API_KEY" | sbx secret
    // set -g google` is the documented non-interactive form (same pattern as
    // CLAUDE_CODE_API_KEY_HARNESS's anthropic secret).
    secret_name: 'google',
  },
  oauth_refresh: {
    supports_refresh: false,
    refresh_owner: 'none',
    evidence: 'A static Google API key does not refresh; docker-stored-secret is the correct strategy for a static, host-side-settable credential — mirrors CLAUDE_CODE_API_KEY_HARNESS.',
  },
  login_status_probe: {
    command: 'env (inside the sandbox, via sbx exec)',
    reports_auth_mode: true,
    mode_field_hint: 'SBX_CRED_GOOGLE_MODE env var: "apikey" once `sbx secret set -g google` has been configured with a static key, vs "none". Confirmed live against a real install.',
  },
  cancellation: { cancel_signal: 'sbx stop <sandbox>', on_cancel: 'sandbox process terminated; sandbox state preserved until sbx rm' },
  result_behavior: { result_transport: 'stdout (gemini -o json), structured JSON per turn' },
});

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
