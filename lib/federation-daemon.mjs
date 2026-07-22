/**
 * Local Federation daemon: supervises the existing guided CLI and exposes a
 * deliberately small, authenticated localhost surface for the browser UI and
 * tray. It owns no federation-loop logic.
 */
import { createServer } from 'node:http';
import { spawn as spawnChild } from 'node:child_process';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { platform, tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateEvent } from './federation-events.mjs';
import { configHome, loadConfig } from './federation-config.mjs';
import { startSbxDockerLogin } from './federation-sbx-login.mjs';
import { probeFederationIdentity } from './federation-pull-internals.mjs';
import { DockerSbxBackend } from './federation-docker-backend.mjs';
import { startAuthFlow } from './federation-auth-flow.mjs';
import { startGitHubAuthFlow } from './federation-github-auth.mjs';
import { buildValidatedJobSpec, resolveHarness, statusProbeCommand } from './federation-pull-internals.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_CLI_PATH = join(ROOT, 'bin', 'waspflow-federation');
const DEFAULT_PUBLIC_DIR = join(ROOT, 'public');
const MAX_BODY_BYTES = 64 * 1024;
const MAX_SUBMIT_BODY_BYTES = 28 * 1024 * 1024; // 20 MiB files + base64 JSON overhead
const MAX_PROGRESS_BYTES = 8 * 1024;
const MAX_EXECUTION_LOG_BYTES = 256 * 1024;
const MAX_AGENT_TRANSCRIPT_BYTES = 2 * 1024 * 1024;
const APPROVAL_POLL_INTERVAL_MS = 10_000;
const IDENTITY_CACHE_MS = 60_000;
const IDENTITY_NEGATIVE_CONFIRMATIONS = 3;
const PENDING_APPROVAL_DETAIL = "Waiting for the collective owner to approve this machine. No work can start until then.";
const APPROVAL_REVOKED_DETAIL = 'Approval was revoked. No new work will start.';

export const DAEMON_SCHEMA_VERSION = 1;
const execFile = promisify(execFileCb);
const COORDINATOR_SCHEMA_HEADER = 'x-waspflow-federation-coordinator-schema';
const REQUIRED_COORDINATOR_SCHEMA_VERSION = 2;
const COORDINATOR_TOO_OLD = "Your collective's coordinator is running an older version — ask the operator to update it.";

function daemonInfoPath() {
  return join(configHome(), 'daemon.json');
}

function defaultLedgerPath() {
  return join(configHome(), 'ledger.json');
}

function defaultSettingsPath() {
  return join(configHome(), 'settings.json');
}

function defaultLogsDir() {
  return join(configHome(), 'logs');
}

function executionLogPath(logsDir, taskDigest) {
  return join(logsDir, `${taskDigest}.log`);
}

function agentTranscriptPath(logsDir, taskDigest) {
  return join(logsDir, `${taskDigest}.transcript.jsonl`);
}

function boundedAppend(current, next, limit) {
  const combined = Buffer.concat([current, next]);
  return combined.length <= limit ? { value: combined, truncated: false } : { value: combined.subarray(-limit), truncated: true };
}

function isRealDefaultLedgerPath(ledgerPath) {
  return resolve(ledgerPath) === resolve(defaultLedgerPath());
}

function testLedgerGuard(environment, ledgerPath) {
  if (environment?.NODE_TEST_CONTEXT && isRealDefaultLedgerPath(ledgerPath)) {
    throw new Error('refusing to use the real Federation ledger from a Node test; pass a temporary ledgerPath');
  }
}

function lastStderrLine(stderr) {
  return String(stderr || '').split(/\r?\n/).map((line) => line.trim()).filter(Boolean).at(-1) || null;
}

function defaultDetail(state) {
  return {
    not_joined: 'Not joined. Paste an invite to get started.',
    idle: 'Ready to contribute.',
    contributing: 'Contribution is running.',
    pausing: 'Pausing after the current task finishes.',
    paused: 'Contribution is paused.',
    approval_revoked: APPROVAL_REVOKED_DETAIL,
    action_needed: 'Action is needed before contributing can continue.',
    setup_required: 'Your sandbox is not ready yet. Review the failed setup checks.',
    pending_approval: PENDING_APPROVAL_DETAIL,
  }[state];
}

function loadLedger(path) {
  if (!existsSync(path)) return [];
  const parsed = JSON.parse(readFileSync(path, 'utf8'));
  if (!Array.isArray(parsed)) throw new Error('ledger.json must contain an array');
  return parsed.filter((entry) => entry && typeof entry === 'object');
}

function saveLedger(path, entries) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), `.${Math.random().toString(16).slice(2)}.ledger.json.tmp`);
  writeFileSync(temporary, JSON.stringify(entries, null, 2), { mode: 0o600 });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function emptySettings() {
  return { schedule: { enabled: false, start: '', end: '', days: '', timezone: '' } };
}

function loadSettings(path) {
  if (!existsSync(path)) return emptySettings();
  try {
    const parsed = JSON.parse(readFileSync(path, 'utf8'));
    if (!parsed || typeof parsed !== 'object' || !parsed.schedule || typeof parsed.schedule !== 'object') throw new Error('invalid settings');
    return { ...(typeof parsed.collective_name === 'string' ? { collective_name: parsed.collective_name } : {}), schedule: {
      enabled: Boolean(parsed.schedule.enabled),
      start: typeof parsed.schedule.start === 'string' ? parsed.schedule.start : '',
      end: typeof parsed.schedule.end === 'string' ? parsed.schedule.end : '',
      days: typeof parsed.schedule.days === 'string' ? parsed.schedule.days : '',
      timezone: typeof parsed.schedule.timezone === 'string' ? parsed.schedule.timezone : '',
    } };
  } catch {
    // Settings are convenience data. A corrupt local file must not prevent a
    // contributor from pausing or contributing through the daemon.
    return emptySettings();
  }
}

function saveSettings(path, settings) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), `.${Math.random().toString(16).slice(2)}.settings.json.tmp`);
  writeFileSync(temporary, JSON.stringify(settings, null, 2), { mode: 0o600 });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

function ledgerSummary(entries, now) {
  const threshold = now.getTime() - (7 * 24 * 60 * 60 * 1000);
  const count7d = entries.filter((entry) => Date.parse(entry.finished_at) >= threshold).length;
  const lastEntry = entries.at(-1);
  return {
    count_7d: count7d,
    last: lastEntry ? { display_id: lastEntry.display_id, finished_at: lastEntry.finished_at } : null,
  };
}

function approvalConfig(config) {
  if (!config?.coordinator_url || !config.collective_token || !config.key_id) return null;
  return config;
}

function approvalIdentity(config) {
  return `${config.coordinator_url}\u0000${config.collective_token}\u0000${config.key_id}`;
}

function validPort(port) {
  return Number.isInteger(port) && port > 0 && port <= 65535;
}

function writeDaemonInfo(path, info) {
  // POSIX modes document the intended privacy boundary. Windows uses ACLs;
  // installer repair owns any Windows-specific permission remediation.
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = join(dirname(path), `.${Math.random().toString(16).slice(2)}.daemon.json.tmp`);
  writeFileSync(temporary, JSON.stringify(info, null, 2), { mode: 0o600 });
  renameSync(temporary, path);
}

export function readDaemonInfo(path = daemonInfoPath()) {
  if (!existsSync(path)) return null;
  try {
    const info = JSON.parse(readFileSync(path, 'utf8'));
    if (!info || typeof info !== 'object' || !validPort(info.port) || typeof info.token !== 'string' || !info.token) return null;
    return info;
  } catch {
    return null;
  }
}

function removeDaemonInfo(path, token) {
  const current = readDaemonInfo(path);
  if (current && current.token === token) {
    try { unlinkSync(path); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}

function isAllowedHost(host) {
  if (typeof host !== 'string' || !host) return false;
  const value = host.toLowerCase();
  return /^(localhost|127\.0\.0\.1)(?::\d+)?$/.test(value) || /^\[::1\](?::\d+)?$/.test(value);
}

function requestToken(request, url) {
  const header = request.headers['x-waspflow-session-token'];
  return typeof header === 'string' && header ? header : url.searchParams.get('token');
}

function tokensMatch(actual, expected) {
  if (typeof actual !== 'string') return false;
  const actualBytes = Buffer.from(actual);
  const expectedBytes = Buffer.from(expected);
  return actualBytes.length === expectedBytes.length && timingSafeEqual(actualBytes, expectedBytes);
}

function sendJson(response, status, body) {
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' });
  response.end(JSON.stringify(body));
}

async function readJsonBody(request, { allowEmpty = false, maxBytes = MAX_BODY_BYTES } = {}) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > maxBytes) throw new DaemonRequestError('request body exceeds byte limit', 413);
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString('utf8');
  if (allowEmpty && !raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    throw new DaemonRequestError('request body must be valid JSON', 400);
  }
}

class DaemonRequestError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

function coordinatorUrl(value) {
  try {
    const parsed = new URL(value);
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('not HTTP');
    return parsed.toString().replace(/\/$/, '');
  } catch {
    throw new DaemonRequestError('invite coordinator must be an http(s) URL', 400);
  }
}

function commandParts(value) {
  const match = /^\s*waspflow\s+federation\s+join\s+(?:"([^"]+)"|'([^']+)'|(\S+))(?:\s+(\S+))?\s*$/.exec(value);
  return match ? { coordinator: match[1] || match[2] || match[3], token: match[4] } : null;
}

/**
 * Normalizes the three invite forms accepted by the planned join screen.
 * A bare token necessarily needs a known coordinator, so callers supply the
 * existing config's URL or WASPFLOW_FEDERATION_COORDINATOR_URL as a fallback.
 */
export function parseJoinInvite(invite, fallbackCoordinatorUrl) {
  if (typeof invite !== 'string' || !invite.trim()) throw new DaemonRequestError('invite must be a non-empty string', 400);
  const value = invite.trim();
  if (value.startsWith('waspflow://')) {
    let link;
    try { link = new URL(value); } catch { throw new DaemonRequestError('invite deep link is invalid', 400); }
    if (link.hostname !== 'join') throw new DaemonRequestError('invite deep link must use waspflow://join', 400);
    const coordinator = link.searchParams.get('coordinator') || link.searchParams.get('coordinator_url');
    const token = link.searchParams.get('token');
    if (!coordinator || !token) throw new DaemonRequestError('invite deep link needs coordinator and token', 400);
    const collectiveName = link.searchParams.get('name');
    return {
      coordinatorUrl: coordinatorUrl(coordinator),
      token,
      ...(collectiveName && collectiveName.trim() ? { collectiveName: collectiveName.trim() } : {}),
    };
  }
  if (/^https?:\/\//i.test(value)) {
    let link;
    try { link = new URL(value); } catch { throw new DaemonRequestError('invite URL is invalid', 400); }
    if (link.pathname !== '/join' || !link.hash.slice(1)) {
      throw new DaemonRequestError('invite URL must use https://<coordinator>/join#<token>', 400);
    }
    let token;
    try { token = decodeURIComponent(link.hash.slice(1)); } catch { throw new DaemonRequestError('invite URL has an invalid token fragment', 400); }
    return { coordinatorUrl: coordinatorUrl(link.origin), token };
  }
  const command = commandParts(value);
  if (command) {
    if (command.token) return { coordinatorUrl: coordinatorUrl(command.coordinator), token: command.token };
    return parseJoinInvite(command.coordinator, fallbackCoordinatorUrl);
  }
  if (/\s/.test(value)) throw new DaemonRequestError('invite must be a deep link, join command, or raw token', 400);
  if (!fallbackCoordinatorUrl) {
    throw new DaemonRequestError('a raw invite token needs a previously known coordinator URL', 400);
  }
  return { coordinatorUrl: coordinatorUrl(fallbackCoordinatorUrl), token: value };
}

function finalEvent(stdout) {
  const lines = stdout.split(/\r?\n/).filter(Boolean);
  for (const line of lines.reverse()) {
    try {
      const event = JSON.parse(line);
      if (validateEvent(event).length === 0) return event;
    } catch { /* non-event progress is allowed */ }
  }
  return null;
}

function taskDigestFromProgress(progress) {
  const match = /task_digest=(sha256:[a-f0-9]{64})\b/i.exec(progress);
  return match ? match[1] : null;
}

function submitBody(body) {
  if (!body || typeof body !== 'object') throw new DaemonRequestError('submit body must be a JSON object', 400);
  const fields = ['prompt', 'display_id'];
  for (const field of fields) {
    if (typeof body[field] !== 'string' || !body[field].trim()) {
      throw new DaemonRequestError(`submit body requires a non-empty ${field} string`, 400);
    }
  }
  if (body.source !== undefined && typeof body.source !== 'string') throw new DaemonRequestError('submit source must be a string when provided', 400);
  if (body.git_url !== undefined && typeof body.git_url !== 'string') throw new DaemonRequestError('submit git_url must be a string when provided', 400);
  if (body.git_ref !== undefined && typeof body.git_ref !== 'string') throw new DaemonRequestError('submit git_ref must be a string when provided', 400);
  if (body.github_access_required !== undefined && typeof body.github_access_required !== 'boolean') throw new DaemonRequestError('submit github_access_required must be boolean when provided', 400);
  if (body.network !== undefined && !['enabled', 'disabled'].includes(body.network)) throw new DaemonRequestError('submit network must be enabled or disabled', 400);
  if (body.attachments !== undefined && !Array.isArray(body.attachments)) throw new DaemonRequestError('submit attachments must be an array when provided', 400);
  const attachments = (body.attachments || []).map((file) => {
    if (!file || typeof file.name !== 'string' || typeof file.data_base64 !== 'string') throw new DaemonRequestError('each attachment needs a name and base64 data', 400);
    const relative = typeof file.relative_path === 'string' && file.relative_path ? file.relative_path : file.name;
    if (relative.startsWith('/') || relative.includes('\\') || relative.split('/').some((part) => !part || part === '.' || part === '..')) throw new DaemonRequestError('attachment paths must stay inside the submitted folder', 400);
    const bytes = Buffer.from(file.data_base64, 'base64');
    if (!bytes.length && file.data_base64) throw new DaemonRequestError('attachment data is not valid base64', 400);
    return { relative, bytes };
  });
  const attachmentBytes = attachments.reduce((total, file) => total + file.bytes.length, 0);
  if (attachmentBytes > 20 * 1024 * 1024) throw new DaemonRequestError('Attachments are limited to 20 MB. Choose fewer or smaller files.', 413);
  const gitUrl = body.git_url?.trim() || '';
  if (gitUrl && !/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(gitUrl)) throw new DaemonRequestError('Git repository must be an HTTPS github.com owner/repository URL.', 400);
  if (gitUrl && (body.source?.trim() || attachments.length)) throw new DaemonRequestError('Choose a Git repository or uploaded/local files, not both.', 400);
  return { source: body.source?.trim() || '', gitUrl, gitRef: body.git_ref?.trim() || '', githubAccessRequired: body.github_access_required === true, prompt: body.prompt, displayId: body.display_id.trim(), network: gitUrl ? 'enabled' : body.network || 'disabled', attachments };
}

function isUnknownFieldFailure(text) {
  return /(?:HTTP\s*400|\b400\b)[^\n]*(?:unknown field|unknown .*field)|(?:unknown field|unknown .*field)[^\n]*(?:HTTP\s*400|\b400\b)/i.test(String(text || ''));
}

function submissionFailureReason(error) {
  const raw = String(error || 'Submission could not be completed.').trim();
  return isUnknownFieldFailure(raw) ? COORDINATOR_TOO_OLD : raw;
}

async function defaultGitVisibilityProbe(url) {
  try {
    await execFile('git', ['ls-remote', '--exit-code', url, 'HEAD'], { timeout: 5_000, maxBuffer: 64 * 1024 });
    return 'public';
  } catch {
    return 'private_or_unreachable';
  }
}

function contributeBody(body) {
  if (body === null) return null;
  if (!body || Array.isArray(body) || typeof body !== 'object') {
    throw new DaemonRequestError('contribute body must be a JSON object', 400);
  }
  if (!Object.hasOwn(body, 'task_digest')) return null;
  if (typeof body.task_digest !== 'string' || !/^[a-f0-9]{64}$/i.test(body.task_digest)) {
    throw new DaemonRequestError('task_digest must be a 64-character sha256 digest', 400);
  }
  return body.task_digest.toLowerCase();
}

function settingsBody(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || !body.schedule || typeof body.schedule !== 'object' || Array.isArray(body.schedule)) {
    throw new DaemonRequestError('settings body requires a schedule object', 400);
  }
  const { enabled, start = '', end = '', days = '', timezone = '' } = body.schedule;
  const collectiveName = body.collective_name;
  if (typeof enabled !== 'boolean' || typeof start !== 'string' || typeof end !== 'string' || typeof days !== 'string' || typeof timezone !== 'string' || (collectiveName !== undefined && typeof collectiveName !== 'string')) {
    throw new DaemonRequestError('schedule requires boolean enabled and string start, end, days, and timezone values', 400);
  }
  if (start.length > 16 || end.length > 16 || days.length > 120 || timezone.length > 120 || collectiveName?.length > 120) throw new DaemonRequestError('settings values are too long', 400);
  if (enabled && (!/^\d{2}:\d{2}$/.test(start) || !/^\d{2}:\d{2}$/.test(end) || !days.trim() || !timezone.trim())) {
    throw new DaemonRequestError('an enabled schedule needs start, end, selected days, and a timezone', 400);
  }
  return { ...(typeof collectiveName === 'string' ? { collective_name: collectiveName.trim() } : {}), schedule: { enabled, start, end, days, timezone } };
}

const IDENTITY_HARNESS_BY_SERVICE = Object.freeze({ openai: 'codex', anthropic: 'claude-code-subscription' });

async function startProviderSignIn(service, { onHandle } = {}) {
  const harnessName = IDENTITY_HARNESS_BY_SERVICE[String(service || '').toLowerCase()];
  if (!harnessName) throw new DaemonRequestError(`Waspflow cannot start a browser sign-in for ${service || 'this provider'} yet.`, 409);
  const harness = resolveHarness(harnessName);
  const backend = new DockerSbxBackend();
  const capabilities = await backend.probeCapabilities();
  if (!capabilities.available) throw new DaemonRequestError('Your sandbox needs attention before signing in.', 409);
  const jobSpec = buildValidatedJobSpec({ taskDigest: '0'.repeat(64), harness, entrypointWithPrompt: statusProbeCommand(harness.harness_id) || 'true' });
  let handle;
  try {
    handle = await backend.prepare(jobSpec);
    const flow = await startAuthFlow(harness, { sandboxId: handle.sandbox_id, onHandle });
    const cleanup = () => handle ? backend.destroy(handle).catch(() => {}) : undefined;
    return {
      ...flow,
      async waitForCompletion() { try { return await flow.waitForCompletion(); } finally { await cleanup(); } },
      cancel() { flow.cancel(); void cleanup(); },
    };
  } catch (error) {
    if (handle) await backend.destroy(handle).catch(() => {});
    throw error;
  }
}

async function startIdentitySignIn(service, options = {}) {
  if (String(service).toLowerCase() === 'github') return startGitHubAuthFlow(options);
  return startProviderSignIn(service, options);
}

function openCommand(url, platformName = platform()) {
  if (platformName === 'darwin') return ['open', [url]];
  if (platformName === 'win32') return ['cmd.exe', ['/c', 'start', '', url]];
  return ['xdg-open', [url]];
}

function wait(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function daemonIsReachable(info) {
  try {
    const response = await fetch(`http://127.0.0.1:${info.port}/status?token=${encodeURIComponent(info.token)}`, { signal: AbortSignal.timeout(500) });
    return response.ok;
  } catch {
    return false;
  }
}

export async function startFederationDaemon({
  port = 0,
  token = randomBytes(32).toString('base64url'),
  spawnProcess = spawnChild,
  cliPath = DEFAULT_CLI_PATH,
  infoPath = daemonInfoPath(),
  publicDir = DEFAULT_PUBLIC_DIR,
  configLoader = loadConfig,
  fetchImpl = fetch,
  approvalPollIntervalMs = APPROVAL_POLL_INTERVAL_MS,
  ledgerPath = defaultLedgerPath(),
  settingsPath = defaultSettingsPath(),
  logsDir = null,
  now = () => new Date(),
  startDockerLogin = startSbxDockerLogin,
  startProviderSignIn: providerSignInStarter = startIdentitySignIn,
  identityProbe = probeFederationIdentity,
  gitVisibilityProbe = defaultGitVisibilityProbe,
  environment = process.env,
} = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('port must be an integer from 0 to 65535');
  testLedgerGuard(environment, ledgerPath);
  const executionLogsDir = logsDir || (isRealDefaultLedgerPath(ledgerPath) ? defaultLogsDir() : join(dirname(ledgerPath), 'logs'));

  let state = approvalConfig(configLoader()) ? 'pending_approval' : (configLoader() ? 'idle' : 'not_joined');
  let detail = defaultDetail(state);
  let action = null;
  let contributeChild = null;
  let dockerLoginFlow = null;
  let providerLoginFlow = null;
  let providerLoginStarting = null;
  let providerLoginGeneration = 0;
  let dockerLoginStarting = false;
  let dockerLoginCancelled = false;
  let dockerLoginResume = null;
  let contribution = null;
  let pauseAfterCurrent = false;
  let joinChild = null;
  let submitChild = null;
  let submission = null;
  let approvalTimer = null;
  let approvalRequestInFlight = false;
  let activeApprovalIdentity = null;
  let approvedApprovalIdentity = null;
  let approvalWasGranted = false;
  let coordinatorUnavailable = false;
  let coordinatorLastSuccessAt = null;
  let coordinatorSchemaVersion = null;
  let coordinatorOutdated = false;
  let ledgerEntries = loadLedger(ledgerPath);
  let settings = loadSettings(settingsPath);
  let lastCompleted = ledgerEntries.at(-1) || null;
  let identityCache = null;
  let identityRefreshInFlight = null;
  let identityRefreshTimer = null;
  let identityProbeFailed = false;
  let identityProviders = [];
  const confirmedIdentityProviders = new Map();
  const identityNegativeCounts = new Map();
  const taskDisplayIds = new Map();
  const taskRequesters = new Map();
  const taskDetails = new Map();
  let closed = false;

  function config() {
    try { return configLoader(); } catch { return null; }
  }

  function collectiveName(currentConfig = config()) {
    return settings.collective_name || currentConfig?.collective_name || null;
  }

  function observeCoordinatorSchema(response) {
    const value = Number(response?.headers?.get?.(COORDINATOR_SCHEMA_HEADER));
    if (Number.isSafeInteger(value) && value > 0) {
      coordinatorSchemaVersion = value;
      coordinatorOutdated = value < REQUIRED_COORDINATOR_SCHEMA_VERSION;
    }
  }

  function stopApprovalPolling() {
    if (approvalTimer) clearInterval(approvalTimer);
    approvalTimer = null;
  }

  async function pollApproval() {
    const currentConfig = approvalConfig(config());
    if (!currentConfig || approvalRequestInFlight) return;
    const identity = approvalIdentity(currentConfig);
    approvalRequestInFlight = true;
    try {
      const response = await fetchImpl(`${currentConfig.coordinator_url}/roster`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
      const body = await response.json().catch(() => null);
      coordinatorUnavailable = !response.ok;
      if (response.ok) coordinatorLastSuccessAt = now().toISOString();
      const approved = response.ok && Array.isArray(body?.roster)
        && body.roster.some((entry) => entry?.key_id === currentConfig.key_id);
      if (activeApprovalIdentity !== identity) return;
      if (approved) {
        approvedApprovalIdentity = identity;
        approvalWasGranted = true;
        if (state === 'pending_approval' || state === 'not_joined' || (state === 'approval_revoked' && !contributeChild)) setState('idle');
      } else if (approvalWasGranted) {
        pauseAfterCurrent = true;
        setState('approval_revoked', contributeChild
          ? 'Approval was revoked. The current task may finish, then Waspflow will pause.'
          : APPROVAL_REVOKED_DETAIL);
      } else if (state !== 'contributing' && state !== 'paused') {
        setState('pending_approval', PENDING_APPROVAL_DETAIL);
      }
    } catch {
      coordinatorUnavailable = true;
    } finally {
      approvalRequestInFlight = false;
    }
  }

  function ensureApprovalPolling() {
    const currentConfig = approvalConfig(config());
    if (!currentConfig) {
      activeApprovalIdentity = null;
      approvedApprovalIdentity = null;
      stopApprovalPolling();
      // Test doubles and legacy callers sometimes provide only the
      // coordinator URL. They are not a persisted Federation identity, so
      // they cannot be meaningfully approval-gated; real joined configs
      // always include token + key_id and take the branch below.
      return true;
    }
    const identity = approvalIdentity(currentConfig);
    if (activeApprovalIdentity !== identity) {
      activeApprovalIdentity = identity;
      approvedApprovalIdentity = null;
      approvalWasGranted = false;
      if (state !== 'contributing' && state !== 'paused') setState('pending_approval', PENDING_APPROVAL_DETAIL);
    }
    if (approvedApprovalIdentity === identity) return true;
    if (!approvalTimer) {
      approvalTimer = setInterval(() => { void pollApproval(); }, approvalPollIntervalMs);
      approvalTimer.unref?.();
    }
    void pollApproval();
    return false;
  }

  function recordContribution({ event = null, outcome, reason = null, requesterNotice = null } = {}) {
    const currentConfig = config();
    const taskDigest = event?.task_digest || contribution?.task_digest;
    const task = taskDetails.get(taskDigest) || {};
    const entry = {
      display_id: event?.display_id || contribution?.display_id || taskDisplayIds.get(taskDigest) || task.display_id || taskDigest || 'A Federation task',
      coordinator: currentConfig?.coordinator_url || null,
      outcome,
      status: outcome === 'returned' ? 'Returned' : 'Completed',
      started_at: contribution?.started_at || null,
      finished_at: now().toISOString(),
      ...(taskDigest ? { task_digest: taskDigest } : {}),
      ...(taskDigest ? { task_reference: taskDigest } : {}),
      ...(event?.requester || contribution?.requester || task.requester ? { requester: event?.requester || contribution?.requester || task.requester } : {}),
      ...(event?.prompt || task.prompt ? { prompt: event?.prompt || task.prompt } : {}),
      ...(event?.source || task.source ? { source: event?.source || task.source } : {}),
      ...(reason ? { reason } : {}),
      ...(requesterNotice ? { requester_notice: requesterNotice } : {}),
      ...(event?.receipt ? { receipt: event.receipt } : {}),
    };
    ledgerEntries = [...ledgerEntries, entry];
    saveLedger(ledgerPath, ledgerEntries);
    lastCompleted = outcome === 'completed' ? entry : lastCompleted;
    return entry;
  }

  function status() {
    const currentConfig = config();
    if (!currentConfig && state !== 'paused' && state !== 'action_needed' && state !== 'setup_required' && state !== 'approval_revoked') {
      state = 'not_joined';
      detail = defaultDetail(state);
    } else if (currentConfig && state === 'not_joined') {
      ensureApprovalPolling();
      if (state === 'not_joined') setState('idle');
    }
    ensureApprovalPolling();
    const result = { schema_version: DAEMON_SCHEMA_VERSION, type: 'daemon_status', state, detail };
    if (currentConfig && currentConfig.coordinator_url) result.coordinator_url = currentConfig.coordinator_url;
    if (collectiveName(currentConfig)) result.collective_name = collectiveName(currentConfig);
    if (action) result.action = action;
    if (submission) result.submission = submission;
    if (contribution) result.contribution = contribution;
    result.coordinator_unavailable = coordinatorUnavailable;
    if (coordinatorLastSuccessAt) result.coordinator_last_success_at = coordinatorLastSuccessAt;
    if (coordinatorSchemaVersion !== null) result.coordinator_schema_version = coordinatorSchemaVersion;
    if (coordinatorOutdated) result.coordinator_outdated = true;
    result.ledger_summary = ledgerSummary(ledgerEntries, now());
    if (lastCompleted) result.last_completed = lastCompleted;
    return result;
  }

  function setState(nextState, nextDetail = defaultDetail(nextState), nextAction = null) {
    state = nextState;
    detail = nextDetail;
    action = nextAction;
  }

  function appendProgress(chunk) {
    // CLI output is for local logs, not for the non-technical web UI.
    if (chunk.length > 0 && state === 'contributing') detail = 'Contribution is running.';
  }

  function resumeAfterDockerLogin() {
    if (!dockerLoginResume || contributeChild || state === 'paused') return;
    const { taskDigest } = dockerLoginResume;
    dockerLoginResume = null;
    superviseContribute(taskDigest);
  }

  async function beginDockerLogin() {
    if (dockerLoginFlow || dockerLoginStarting) return;
    dockerLoginStarting = true;
    dockerLoginCancelled = false;
    setState('contributing', 'Preparing Docker sign-in.');
    try {
      const flow = await startDockerLogin();
      dockerLoginStarting = false;
      if (dockerLoginCancelled || state === 'paused' || closed) {
        flow.cancel();
        return;
      }
      dockerLoginFlow = flow;
      setState('action_needed', 'Finish signing in to Docker in your browser. This page will continue automatically.', {
        kind: 'awaiting_browser', url: flow.url, ...(flow.code ? { code: flow.code } : {}),
      });
      const result = await flow.waitForCompletion();
      dockerLoginFlow = null;
      if (dockerLoginCancelled || state === 'paused' || closed) return;
      if (result.status !== 'complete') {
        setState('setup_required', 'Docker sign-in was not completed. Try again when you are ready.', {
          kind: 'sandbox_preflight',
          checks: [{ name: 'docker_login', ok: false, detail: 'The sandbox service is not signed in to Docker yet.', fix: 'sbx login' }],
        });
        return;
      }
      dockerLoginResume = { taskDigest: contribution?.selection === 'chosen' ? contribution.task_digest : null };
      resumeAfterDockerLogin();
    } catch (error) {
      dockerLoginStarting = false;
      dockerLoginFlow = null;
      if (dockerLoginCancelled || state === 'paused' || closed) return;
      console.error('Docker sign-in could not be started:', error);
      setState('setup_required', 'Docker sign-in could not be started. Try again when you are ready.', {
        kind: 'sandbox_preflight',
        checks: [{ name: 'docker_login', ok: false, detail: 'The sandbox service is not signed in to Docker yet.', fix: 'sbx login' }],
      });
    }
  }

  async function beginProviderLogin(service) {
    if (dockerLoginFlow) return status();
    // Starting over is intentional: a previous URL wait can be stale or
    // wedged. Cancel it before creating the replacement so the provider
    // listener cannot keep the next attempt in a 409 loop.
    providerLoginGeneration += 1;
    const generation = providerLoginGeneration;
    providerLoginFlow?.cancel();
    providerLoginStarting?.cancel();
    providerLoginFlow = null;
    providerLoginStarting = null;
    let flow;
    try {
      flow = await providerSignInStarter(service, {
        onHandle(handle) {
          if (generation !== providerLoginGeneration || closed) handle.cancel();
          else providerLoginStarting = handle;
        },
      });
    } catch (error) {
      if (generation !== providerLoginGeneration || closed) return status();
      providerLoginStarting = null;
      const provider = service === 'openai' ? 'OpenAI' : service === 'anthropic' ? 'Anthropic' : service;
      setState('idle', `${provider} sign-in could not start. ${error.message || 'Try again in a moment.'}`);
      return status();
    }
    if (generation !== providerLoginGeneration || closed) {
      flow.cancel();
      return status();
    }
    providerLoginStarting = null;
    providerLoginFlow = flow;
    if (flow.status === 'complete') {
      providerLoginFlow = null;
      identityCache = null;
      setState('idle', 'Provider is already signed in.');
      return status();
    }
    setState('action_needed', `Finish ${service} sign-in in your browser.`, {
      kind: 'awaiting_browser', service, url: flow.url, ...(flow.code ? { code: flow.code } : {}),
    });
    void flow.waitForCompletion().then((result) => {
      if (providerLoginFlow !== flow || closed) return;
      providerLoginFlow = null;
      identityCache = null;
      setState('idle', result.status === 'complete' ? `${service} sign-in complete.` : result.detail || `${service} sign-in was not completed.`);
    }).catch((error) => {
      if (providerLoginFlow !== flow || closed) return;
      providerLoginFlow = null;
      setState('idle', error.message || `${service} sign-in was not completed.`);
    });
    return status();
  }

  function reflectContributeEvent(event, exitCode, stderr = '') {
    if (event?.task_digest && contribution) contribution = { ...contribution, task_digest: event.task_digest };
    const finishPaused = () => {
      if (!pauseAfterCurrent) return false;
      pauseAfterCurrent = false;
      setState('paused', 'Paused. The current task finished and no new work will start.');
      return true;
    };
    if (!event) {
      const childDetail = String(stderr || '').trim() || lastStderrLine(stderr) || `Contribution stopped (exit ${exitCode ?? 'unknown'}).`;
      recordContribution({ outcome: 'returned', reason: childDetail, requesterNotice: 'Waspflow recorded this returned attempt locally; requester confirmation is unavailable.' });
      if (!finishPaused()) setState('idle', exitCode === 0 ? 'Contribution finished without a task result.' : lastStderrLine(stderr) || childDetail);
      return;
    }
    if (event.type === 'awaiting_browser') {
      setState('action_needed', 'Finish sign-in in your browser.', { kind: 'awaiting_browser', service: event.service || event.harness, url: event.url });
    } else if (event.type === 'auth_required_manual') {
      setState('action_needed', 'Complete the required sign-in step, then start contributing again.', { kind: 'auth_required_manual', service: event.service || event.harness, instruction: event.instruction });
    } else if (event.type === 'sandbox_preflight' && event.status === 'setup_required') {
      const failedChecks = Array.isArray(event.checks) ? event.checks.filter((item) => item && item.ok === false) : [];
      // Drive the one-click Docker sign-in whenever docker_login is among the
      // failures and every OTHER failure is auth-DEPENDENT (network_policy
      // cannot even be read before Docker sign-in, so it always co-fails —
      // requiring docker_login to be the SOLE failure made the button
      // unreachable in practice). Post-auth, the absorb re-preflights and
      // auto-initializes the policy; anything genuinely unfixable resurfaces.
      const AUTH_DEPENDENT = new Set(['docker_login', 'network_policy']);
      const dockerLoginFailed = failedChecks.some((item) => item.name === 'docker_login');
      if (dockerLoginFailed && failedChecks.every((item) => AUTH_DEPENDENT.has(item.name))) {
        void beginDockerLogin();
      } else {
        setState('setup_required', 'Your sandbox is not ready yet. Fix the failed checks before contributing again.', {
          kind: 'sandbox_preflight',
          checks: failedChecks,
        });
      }
    } else if (event.type === 'no_task_available') {
      if (!finishPaused()) setState('idle', 'No task is available right now.');
    } else if (event.type === 'contributed') {
      const entry = recordContribution({ event, outcome: 'completed' });
      if (!finishPaused()) setState('idle', `Finished '${entry.display_id || 'a task'}'.`);
    } else {
      const reason = String(stderr || '').trim() || `The contribution ended with an unrecognized result (exit ${exitCode ?? 'unknown'}).`;
      recordContribution({ outcome: 'returned', reason, requesterNotice: 'Waspflow recorded this returned attempt locally; requester confirmation is unavailable.' });
      if (!finishPaused()) setState('idle', reason);
    }
  }

  function superviseContribute(taskDigest = null) {
    if (contributeChild) return false;
    if (!config()) {
      setState('not_joined');
      return false;
    }
    if (!ensureApprovalPolling()) return false;
    pauseAfterCurrent = false;
    setState('contributing');
    contribution = {
      selection: taskDigest ? 'chosen' : 'next',
      task_digest: taskDigest,
      ...(taskDigest && taskDisplayIds.has(taskDigest) ? { display_id: taskDisplayIds.get(taskDigest) } : {}),
      ...(taskDigest && taskRequesters.has(taskDigest) ? { requester: taskRequesters.get(taskDigest) } : {}),
      started_at: now().toISOString(),
    };
    let child;
    try {
      const args = [cliPath, 'contribute'];
      if (taskDigest) args.push('--task-digest', taskDigest);
      args.push('--json');
      child = spawnProcess(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      recordContribution({ outcome: 'returned', reason: `Could not start contribution: ${error.message}`, requesterNotice: 'Waspflow recorded this returned attempt locally; requester confirmation is unavailable.' });
      setState('idle', `Could not start contribution: ${error.message}`);
      return false;
    }
    contributeChild = child;
    let stdout = '';
    let transcript = Buffer.alloc(0);
    let transcriptTruncated = false;
    let agentTranscriptTruncated = false;
    const appendTranscript = (stream, chunk) => {
      const appended = boundedAppend(transcript, Buffer.concat([Buffer.from(`[${stream}] `), Buffer.from(chunk)]), MAX_EXECUTION_LOG_BYTES);
      transcript = appended.value;
      transcriptTruncated ||= appended.truncated;
    };
    const persistTranscript = (event) => {
      const bareDigest = event?.task_digest || contribution?.task_digest;
      if (!/^[a-f0-9]{64}$/i.test(bareDigest || '')) return null;
      mkdirSync(executionLogsDir, { recursive: true, mode: 0o700 });
      const note = transcriptTruncated ? Buffer.from('[Waspflow: earlier output was truncated to the last 256 KiB.]\n') : Buffer.alloc(0);
      // Keep the on-disk file itself bounded, including the honest notice.
      const output = note.length ? transcript.subarray(Math.max(0, transcript.length - (MAX_EXECUTION_LOG_BYTES - note.length))) : transcript;
      writeFileSync(executionLogPath(executionLogsDir, bareDigest), Buffer.concat([note, output]), { mode: 0o600 });
      chmodSync(executionLogPath(executionLogsDir, bareDigest), 0o600);
      return { available: true, truncated: transcriptTruncated };
    };
    const appendAgentTranscript = (event) => {
      const bareDigest = event?.task_digest || contribution?.task_digest;
      if (!/^[a-f0-9]{64}$/i.test(bareDigest || '') || typeof event?.raw !== 'string') return;
      mkdirSync(executionLogsDir, { recursive: true, mode: 0o700 });
      const path = agentTranscriptPath(executionLogsDir, bareDigest);
      const next = Buffer.from(event.raw);
      const currentSize = existsSync(path) ? statSync(path).size : 0;
      if (currentSize + next.length > MAX_AGENT_TRANSCRIPT_BYTES) {
        agentTranscriptTruncated = true;
        return;
      }
      appendFileSync(path, next, { mode: 0o600 });
      chmodSync(path, 0o600);
      if (contribution) contribution = { ...contribution, transcript: { available: true, truncated: agentTranscriptTruncated } };
    };
    child.stdout?.on('data', (chunk) => {
      const text = chunk.toString('utf8');
      stdout = boundedAppend(Buffer.from(stdout), Buffer.from(text), MAX_EXECUTION_LOG_BYTES).value.toString('utf8');
      appendTranscript('stdout', text);
      for (const line of text.split(/\r?\n/)) {
        try {
          const event = JSON.parse(line);
          if (event?.type === 'agent_transcript_event') appendAgentTranscript(event);
        } catch { /* wrapper progress is deliberately allowed */ }
      }
      const event = finalEvent(stdout);
      if (event?.type === 'awaiting_browser' || event?.type === 'auth_required_manual') reflectContributeEvent(event);
    });
    let stderr = '';
    child.stderr?.on('data', (chunk) => {
      stderr = `${stderr}${chunk}`.slice(-MAX_PROGRESS_BYTES);
      appendTranscript('stderr', chunk);
      appendProgress(chunk.toString('utf8'));
    });
    child.once('error', (error) => {
      if (contributeChild === child) {
        contributeChild = null;
        recordContribution({ outcome: 'returned', reason: `Could not start contribution: ${error.message}`, requesterNotice: 'Waspflow recorded this returned attempt locally; requester confirmation is unavailable.' });
        setState('idle', `Could not start contribution: ${error.message}`);
      }
    });
    child.once('close', (code) => {
      if (contributeChild !== child) return;
      contributeChild = null;
      const event = finalEvent(stdout);
      const executionLog = persistTranscript(event);
      if (executionLog && contribution) contribution = { ...contribution, execution_log: executionLog, transcript: { available: existsSync(agentTranscriptPath(executionLogsDir, event?.task_digest || contribution.task_digest || '')), truncated: agentTranscriptTruncated } };
      reflectContributeEvent(event, code, stderr);
      resumeAfterDockerLogin();
    });
    return true;
  }

  async function listClaimableTasks() {
    const currentConfig = config();
    if (!currentConfig?.coordinator_url || !currentConfig?.collective_token) {
      throw new DaemonRequestError('join the federation before checking available tasks', 409);
    }
    let response;
    try {
      response = await fetchImpl(`${currentConfig.coordinator_url}/tasks`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
    } catch {
      coordinatorUnavailable = true;
      throw new DaemonRequestError('could not reach the coordinator to list available tasks', 502);
    }
    const body = await response.json().catch(() => null);
    observeCoordinatorSchema(response);
    coordinatorUnavailable = !response.ok;
    if (response.ok) coordinatorLastSuccessAt = now().toISOString();
    if (!response.ok) throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} while listing available tasks`, 502);
    if (!Array.isArray(body)) throw new DaemonRequestError('coordinator returned an invalid task list', 502);
    const tasks = await Promise.all(body.map(async (task) => {
      const promptArtifact = task?.prompt?.artifact || task?.prompt_artifact;
      let promptPreview = typeof task?.prompt === 'string' ? task.prompt.split(/\r?\n/).find((line) => line.trim()) || '' : '';
      if (!promptPreview && typeof promptArtifact?.sha256 === 'string' && /^[a-f0-9]{64}$/i.test(promptArtifact.sha256)) {
        try {
          const artifactResponse = await fetchImpl(`${currentConfig.coordinator_url}/artifacts/${promptArtifact.sha256}`, {
            headers: { authorization: `Bearer ${currentConfig.collective_token}` },
          });
          if (artifactResponse.ok) {
            const artifactBytes = Buffer.from(await artifactResponse.arrayBuffer());
            if (createHash('sha256').update(artifactBytes).digest('hex') === promptArtifact.sha256.toLowerCase()) {
              promptPreview = artifactBytes.toString('utf8').slice(0, 2_000).split(/\r?\n/).find((line) => line.trim()) || '';
            }
          }
        } catch { /* A task may remain reviewable by its other signed metadata. */ }
      }
      return {
        ...task,
        ...(promptPreview ? { prompt_preview: promptPreview } : {}),
        ...(task?.source?.base_artifact?.bytes !== undefined ? { source_bytes: task.source.base_artifact.bytes } : {}),
      };
    }));
    for (const task of tasks) {
      if (typeof task?.task_digest === 'string') {
        if (typeof task.display_id === 'string') taskDisplayIds.set(task.task_digest, task.display_id);
        if (typeof task.author === 'string') taskRequesters.set(task.task_digest, task.author);
        taskDetails.set(task.task_digest, {
          display_id: task.display_id,
          requester: task.author,
          prompt: task.prompt_preview || task.prompt,
          source: task.source,
          git_source: task.git_source,
          github_access_required: task.github_access_required,
        });
      }
    }
    return tasks;
  }

  async function listRequests() {
    const currentConfig = configuredCoordinator();
    if (!currentConfig.key_id) throw new DaemonRequestError('the local Federation key is unavailable; rejoin before viewing requests', 409);
    let response;
    try {
      response = await fetchImpl(`${currentConfig.coordinator_url}/requests?author=${encodeURIComponent(currentConfig.key_id)}`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
    } catch {
      throw new DaemonRequestError('could not reach the coordinator to list your requests', 502);
    }
    const body = await response.json().catch(() => null);
    observeCoordinatorSchema(response);
    if (!response.ok || !Array.isArray(body)) throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} while listing your requests`, 502);
    const byDigest = new Map(body.filter((task) => task?.author === currentConfig.key_id && typeof task.task_digest === 'string').map((task) => [task.task_digest.replace(/^sha256:/, ''), task]));
    if (submission?.task_digest) {
      const digest = submission.task_digest.replace(/^sha256:/, '');
      const existing = byDigest.get(digest) || {};
      byDigest.set(digest, {
        ...existing,
        task_digest: submission.task_digest,
        display_id: existing.display_id || submission.display_id || 'Untitled task',
        status: String(existing.status || submission.state || 'queued').toLowerCase(),
        published_at: existing.published_at || submission.published_at || null,
        ...(existing.settled_at ? { settled_at: existing.settled_at } : {}),
        has_result: Boolean(existing.has_result),
      });
    }
    return [...byDigest.values()]
      .map((task) => ({
        task_digest: task.task_digest,
        display_id: task.display_id || 'Untitled task',
        status: String(task.status || 'queued').toLowerCase(),
        published_at: task.published_at || null,
        ...(task.settled_at ? { settled_at: task.settled_at } : {}),
        has_result: Boolean(task.has_result || task.result_envelope),
      }))
      .sort((left, right) => String(right.published_at || '').localeCompare(String(left.published_at || '')));
  }

  async function requireGitHubTaskAccess(taskDigest) {
    const bare = String(taskDigest || '').replace(/^sha256:/, '');
    let task = taskDetails.get(taskDigest) || taskDetails.get(bare) || taskDetails.get(`sha256:${bare}`);
    if (!task) {
      try {
        task = (await listClaimableTasks()).find((candidate) => String(candidate?.task_digest || '').replace(/^sha256:/, '') === bare);
      } catch { /* claim flow remains authoritative for malformed/unknown tasks */ }
    }
    if (!task?.github_access_required && !task?.git_source?.authentication_required) return;
    const github = identityProviders.find((provider) => provider.service === 'github');
    if (!github?.authed) throw new DaemonRequestError('Set up GitHub access in Settings before contributing to this task.', 409);
  }

  async function listCollectiveActivity() {
    const currentConfig = configuredCoordinator();
    let response;
    try {
      response = await fetchImpl(`${currentConfig.coordinator_url}/activity`, { headers: { authorization: `Bearer ${currentConfig.collective_token}` } });
    } catch {
      throw new DaemonRequestError('could not reach the coordinator for collective activity', 502);
    }
    const body = await response.json().catch(() => null);
    observeCoordinatorSchema(response);
    if (!response.ok || !Array.isArray(body)) throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} while viewing collective activity`, 502);
    return body;
  }

  function localReceipt(taskDigest) {
    const bareDigest = taskDigest.replace(/^sha256:/, '');
    const entry = ledgerEntries.findLast((item) => item?.task_digest?.replace(/^sha256:/, '') === bareDigest
      || item?.receipt?.task_digest?.replace(/^sha256:/, '') === bareDigest);
    return entry?.receipt || null;
  }

  function readExecutionLog(taskDigest, since = 0) {
    if (!/^[a-f0-9]{64}$/i.test(taskDigest)) throw new DaemonRequestError('task digest must be a 64-character sha256 digest', 400);
    const transcript = agentTranscriptPath(executionLogsDir, taskDigest);
    const path = existsSync(transcript) ? transcript : executionLogPath(executionLogsDir, taskDigest);
    if (!existsSync(path)) throw new DaemonRequestError('No execution log is available on this machine for this task.', 404);
    const bytes = readFileSync(path);
    const offset = Number.isSafeInteger(since) && since >= 0 ? Math.min(since, bytes.length) : 0;
    return {
      task_digest: `sha256:${taskDigest}`,
      output: bytes.subarray(offset).toString('utf8'),
      since: offset,
      next_offset: bytes.length,
      transcript: path === transcript,
      truncated: path === transcript ? bytes.length >= MAX_AGENT_TRANSCRIPT_BYTES : bytes.toString('utf8').startsWith('[Waspflow: earlier output was truncated'),
    };
  }

  function configuredCoordinator() {
    const currentConfig = config();
    if (!currentConfig?.coordinator_url || !currentConfig?.collective_token) {
      throw new DaemonRequestError('join the federation before viewing task details', 409);
    }
    return currentConfig;
  }

  async function readTaskDetail(taskDigest) {
    if (!/^[a-f0-9]{64}$/i.test(taskDigest)) throw new DaemonRequestError('task digest must be a 64-character sha256 digest', 400);
    const currentConfig = configuredCoordinator();
    let response;
    try {
      response = await fetchImpl(`${currentConfig.coordinator_url}/tasks/${taskDigest}`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
    } catch {
      throw new DaemonRequestError('could not reach the coordinator for task details', 502);
    }
    const body = await response.json().catch(() => null);
    observeCoordinatorSchema(response);
    if (!response.ok || !body || typeof body !== 'object') {
      throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} for task details`, response.status === 404 ? 404 : 502);
    }
    const receipt = localReceipt(taskDigest);
    const execution = body.result_envelope?.payload?.execution_metadata;
    return {
      ...body,
      receipt,
      execution_log_available: existsSync(executionLogPath(executionLogsDir, taskDigest)) || existsSync(agentTranscriptPath(executionLogsDir, taskDigest)),
      transcript_available: existsSync(agentTranscriptPath(executionLogsDir, taskDigest)),
      ...(execution ? { execution_metadata: execution } : {}),
    };
  }

  function updateIdentityProviders(observedProviders) {
    const next = [];
    for (const observed of Array.isArray(observedProviders) ? observedProviders : []) {
      const service = String(observed?.service || observed?.provider || '').toLowerCase();
      if (!service) continue;
      const authenticated = observed.authenticated ?? observed.authed;
      if (authenticated === true) {
        const confirmed = { ...observed };
        confirmedIdentityProviders.set(service, confirmed);
        identityNegativeCounts.delete(service);
        next.push(confirmed);
        continue;
      }
      const confirmed = confirmedIdentityProviders.get(service);
      const negatives = (identityNegativeCounts.get(service) || 0) + 1;
      identityNegativeCounts.set(service, negatives);
      if (confirmed && negatives < IDENTITY_NEGATIVE_CONFIRMATIONS) {
        next.push({ ...confirmed, checking: true });
      } else {
        if (negatives >= IDENTITY_NEGATIVE_CONFIRMATIONS) confirmedIdentityProviders.delete(service);
        next.push({ ...observed });
      }
    }
    // A probe gap is not a negative sign-in result. Keep known accounts in
    // their last-confirmed state and make the in-flight check visible.
    for (const [service, confirmed] of confirmedIdentityProviders) {
      if (!next.some((entry) => String(entry.service || entry.provider || '').toLowerCase() === service)) {
        next.push({ ...confirmed, checking: true });
      }
    }
    identityProviders = next;
  }

  function refreshIdentity() {
    if (identityRefreshInFlight) return identityRefreshInFlight;
    identityRefreshInFlight = Promise.resolve(identityProbe())
      .then((observed) => {
        identityCache = { at: now().getTime(), observed };
        updateIdentityProviders(observed?.providers);
        identityProbeFailed = false;
      })
      .catch(() => {
        identityCache = { at: now().getTime(), observed: identityCache?.observed || {} };
        identityProbeFailed = true;
      })
      .finally(() => { identityRefreshInFlight = null; });
    return identityRefreshInFlight;
  }

  function identity() {
    const current = now().getTime();
    const stale = !identityCache || current - identityCache.at >= IDENTITY_CACHE_MS;
    if (stale) void refreshIdentity();
    const currentConfig = config();
    const observed = identityCache?.observed || {};
    return {
      docker_account: observed.docker_account || null,
      docker_status: observed.docker_account ? 'detected' : identityRefreshInFlight ? 'checking' : identityProbeFailed ? 'failed' : 'not_reported',
      providers: identityProviders.map((provider) => {
        const checking = Boolean(provider.checking || identityRefreshInFlight || identityProbeFailed);
        return checking ? { ...provider, checking: true } : { ...provider };
      }),
      key_id: currentConfig?.key_id || null,
      coordinator_url: currentConfig?.coordinator_url || null,
      ...(collectiveName(currentConfig) ? { collective_name: collectiveName(currentConfig) } : {}),
      refreshing: Boolean(identityRefreshInFlight || stale),
    };
  }

  async function streamResultArtifact(taskDigest, response) {
    const detail = await readTaskDetail(taskDigest);
    const artifact = detail.result_envelope?.payload?.candidate?.artifact;
    if (!artifact?.sha256 || !/^[a-f0-9]{64}$/i.test(artifact.sha256)) {
      throw new DaemonRequestError('this task has no settled result artifact', 404);
    }
    const currentConfig = configuredCoordinator();
    let artifactResponse;
    try {
      artifactResponse = await fetchImpl(`${currentConfig.coordinator_url}/artifacts/${artifact.sha256}`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
    } catch {
      throw new DaemonRequestError('could not reach the coordinator for the result artifact', 502);
    }
    if (!artifactResponse.ok) throw new DaemonRequestError(`coordinator returned ${artifactResponse.status} for the result artifact`, artifactResponse.status === 404 ? 404 : 502);
    const bytes = Buffer.from(await artifactResponse.arrayBuffer());
    const actual = createHash('sha256').update(bytes).digest('hex');
    if (actual !== artifact.sha256) throw new DaemonRequestError('result artifact digest did not match the signed result envelope', 502);
    response.writeHead(200, {
      'content-type': artifact.media_type || 'application/octet-stream',
      'content-length': bytes.length,
      'cache-control': 'no-store',
    });
    response.end(bytes);
  }

  async function listRoster() {
    const currentConfig = config();
    if (!currentConfig?.coordinator_url || !currentConfig?.collective_token) {
      throw new DaemonRequestError('join the federation before viewing the roster', 409);
    }
    let response;
    try {
      response = await fetchImpl(`${currentConfig.coordinator_url}/roster`, {
        headers: { authorization: `Bearer ${currentConfig.collective_token}` },
      });
    } catch {
      coordinatorUnavailable = true;
      throw new DaemonRequestError('could not reach the coordinator to view the roster', 502);
    }
    const body = await response.json().catch(() => null);
    coordinatorUnavailable = !response.ok;
    if (response.ok) coordinatorLastSuccessAt = now().toISOString();
    if (!response.ok) throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} while viewing the roster`, 502);
    if (!Array.isArray(body?.roster)) throw new DaemonRequestError('coordinator returned an invalid roster', 502);
    return body;
  }

  function superviseJoin(invite) {
    if (joinChild) return false;
    const currentConfig = config();
    const parsed = parseJoinInvite(invite, currentConfig?.coordinator_url || process.env.WASPFLOW_FEDERATION_COORDINATOR_URL);
    setState('not_joined', 'Joining the federation…');
    let child;
    try {
      const args = [cliPath, 'join', parsed.coordinatorUrl, parsed.token];
      if (parsed.collectiveName) args.push('--collective-name', parsed.collectiveName);
      args.push('--json');
      child = spawnProcess(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      setState(config() ? 'idle' : 'not_joined', `Could not start join: ${error.message}`);
      return false;
    }
    joinChild = child;
    let stdout = '';
    let stderr = '';
    child.stdout?.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
    child.stderr?.on('data', (chunk) => { stderr = `${stderr}${chunk}`.slice(-MAX_PROGRESS_BYTES); });
    child.once('error', (error) => {
      if (joinChild === child) {
        joinChild = null;
        setState(config() ? 'idle' : 'not_joined', `Could not start join: ${error.message}`);
      }
    });
    child.once('close', (code) => {
      if (joinChild !== child) return;
      joinChild = null;
      const event = finalEvent(stdout);
      if (event?.type === 'joined' || event?.type === 'already_joined') {
        activeApprovalIdentity = null;
        ensureApprovalPolling();
      }
      else setState(config() ? 'idle' : 'not_joined', code === 0 ? 'Join did not return a recognized result.' : 'Join could not be completed.');
    });
    return true;
  }

  // Requester submission remains the guided CLI's job. The daemon only keeps
  // the browser informed while that CLI packages, publishes, and waits. The
  // first task digest is deliberately extracted from its existing stable
  // progress line; lifecycle truth still comes from `status --json` below.
  async function superviseSubmit(body) {
    if (submitChild) return false;
    if (!config()) {
      setState('not_joined');
      return false;
    }
    const input = submitBody(body);
    if (coordinatorOutdated && input.githubAccessRequired) {
      submission = { state: 'failed', detail: COORDINATOR_TOO_OLD, reason: COORDINATOR_TOO_OLD, task_digest: null, display_id: input.displayId, published_at: null };
      return false;
    }
    let sourcePath = input.source;
    let temporarySourcePath = null;
    if (input.gitUrl) {
      // The executor clones repository sources in its sandbox; the requester
      // never downloads a private repository merely to submit it.
    } else if (input.attachments.length) {
      if (sourcePath) throw new DaemonRequestError('Choose uploaded files or an advanced folder path, not both.', 400);
      temporarySourcePath = await mkdtemp(join(tmpdir(), 'waspflow-federation-upload-'));
      for (const file of input.attachments) {
        const target = join(temporarySourcePath, file.relative);
        mkdirSync(dirname(target), { recursive: true, mode: 0o700 });
        writeFileSync(target, file.bytes, { mode: 0o600 });
      }
      sourcePath = temporarySourcePath;
    } else if (sourcePath) {
      let sourceInfo;
      try { sourceInfo = statSync(sourcePath); } catch { throw new DaemonRequestError('The source folder does not exist. Choose an existing folder on this computer.', 400); }
      if (!sourceInfo.isDirectory()) throw new DaemonRequestError('The source path is not a folder. Choose a folder to package for this task.', 400);
    } else {
      // v0 envelopes require a signed source artifact. Preserve that contract
      // while giving prompt-only tasks an honest empty workspace.
      temporarySourcePath = await mkdtemp(join(tmpdir(), 'waspflow-federation-empty-source-'));
      sourcePath = temporarySourcePath;
    }
    submission = { state: 'pending', detail: 'Preparing and publishing your task.', task_digest: null, display_id: input.displayId, published_at: null };
    let child;
    try {
      child = spawnProcess(process.execPath, [
        cliPath, 'submit', '--display-id', input.displayId,
        ...(input.gitUrl ? ['--git-url', input.gitUrl, ...(input.gitRef ? ['--git-ref', input.gitRef] : [])] : ['--source', sourcePath]),
        '--github-access', String(input.githubAccessRequired),
        '--prompt', input.prompt, '--network', input.network,
      ], { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      if (temporarySourcePath) void rm(temporarySourcePath, { recursive: true, force: true });
      submission = { ...submission, state: 'failed', detail: submissionFailureReason(`Could not start submission: ${error.message}`), reason: submissionFailureReason(error.message) };
      return false;
    }
    submitChild = child;
    let stderr = '';
    const append = (chunk) => {
      if (!submission) return;
      const taskDigest = taskDigestFromProgress(chunk.toString('utf8'));
      submission = {
        ...submission,
        detail: taskDigest ? 'Your task is queued for a contributor.' : 'Preparing and publishing your task.',
        task_digest: taskDigest || submission.task_digest,
        state: taskDigest ? 'published' : submission.state,
        published_at: taskDigest ? new Date().toISOString() : submission.published_at,
      };
    };
    child.stdout?.on('data', append);
    child.stderr?.on('data', (chunk) => { stderr = `${stderr}${chunk}`.slice(-MAX_PROGRESS_BYTES); append(chunk); });
    child.once('error', (error) => {
      if (submitChild === child) {
        submitChild = null;
        submission = { ...submission, state: 'failed', detail: submissionFailureReason(error.message), reason: submissionFailureReason(error.message) };
      }
    });
    child.once('close', (code) => {
      if (submitChild !== child) return;
      submitChild = null;
      submission = {
        ...submission,
        state: code === 0 ? 'settled' : 'failed',
        detail: code === 0 ? 'Submission settled. Your result is ready to review.' : submissionFailureReason(lastStderrLine(stderr) || 'Submission could not be completed.'),
        ...(code === 0 ? {} : { reason: submissionFailureReason(lastStderrLine(stderr) || 'Submission could not be completed.') }),
      };
      if (temporarySourcePath) void rm(temporarySourcePath, { recursive: true, force: true });
    });
    return true;
  }

  function readTaskStatus(taskDigest) {
    if (typeof taskDigest !== 'string' || !/^sha256:[a-f0-9]{64}$/i.test(taskDigest)) {
      throw new DaemonRequestError('submit status requires a sha256 task_digest', 400);
    }
    return new Promise((resolve, reject) => {
      let child;
      try {
        child = spawnProcess(process.execPath, [cliPath, 'status', '--task-digest', taskDigest, '--json'], { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
      } catch (error) {
        reject(error);
        return;
      }
      let stdout = '';
      let stderr = '';
      child.stdout?.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
      child.stderr?.on('data', (chunk) => { stderr = `${stderr}${chunk}`.slice(-MAX_PROGRESS_BYTES); });
      child.once('error', reject);
      child.once('close', (code) => {
        const event = finalEvent(stdout);
        if (code === 0 && event?.type === 'task_status') {
          if (submission?.task_digest === taskDigest) {
            submission = { ...submission, state: event.status.toLowerCase(), detail: `Task is ${event.status.toLowerCase()}.` };
          }
          resolve(event);
          return;
        }
        reject(new DaemonRequestError('Could not read task status right now.', 502));
      });
    });
  }

  const server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://localhost');
    if (!isAllowedHost(request.headers.host)) return sendJson(response, 400, { error: 'invalid Host header' });
    if (request.method === 'GET' && url.pathname === '/favicon.ico') {
      response.writeHead(204, { 'cache-control': 'public, max-age=86400' });
      response.end();
      return;
    }
    if (!tokensMatch(requestToken(request, url), token)) return sendJson(response, 401, { error: 'missing or invalid daemon session token' });
    try {
      if (request.method === 'GET' && url.pathname === '/status') return sendJson(response, 200, status());
      if (request.method === 'GET' && url.pathname === '/identity') return sendJson(response, 200, identity());
      if (request.method === 'GET' && url.pathname === '/tasks') return sendJson(response, 200, await listClaimableTasks());
      if (request.method === 'GET' && url.pathname === '/requests') return sendJson(response, 200, await listRequests());
      if (request.method === 'GET' && url.pathname === '/activity') return sendJson(response, 200, await listCollectiveActivity());
      if (request.method === 'GET' && url.pathname === '/ledger') return sendJson(response, 200, ledgerEntries.toReversed());
      const taskMatch = /^\/tasks\/([a-f0-9]{64})$/i.exec(url.pathname);
      const taskLogMatch = /^\/tasks\/([a-f0-9]{64})\/log$/i.exec(url.pathname);
      if (request.method === 'GET' && taskLogMatch) return sendJson(response, 200, readExecutionLog(taskLogMatch[1], Number(url.searchParams.get('since') || 0)));
      if (request.method === 'GET' && taskMatch) return sendJson(response, 200, await readTaskDetail(taskMatch[1]));
      const resultMatch = /^\/result\/([a-f0-9]{64})$/i.exec(url.pathname);
      if (request.method === 'GET' && resultMatch) return streamResultArtifact(resultMatch[1], response);
      if (request.method === 'GET' && url.pathname === '/roster') return sendJson(response, 200, await listRoster());
      if (request.method === 'GET' && url.pathname === '/settings') return sendJson(response, 200, settings);
      if (request.method === 'POST' && url.pathname === '/settings') {
        settings = settingsBody(await readJsonBody(request));
        saveSettings(settingsPath, settings);
        return sendJson(response, 200, settings);
      }
      if (request.method === 'POST' && url.pathname === '/identity/signin') {
        const body = await readJsonBody(request);
        if (!body || typeof body.service !== 'string' || !body.service.trim()) throw new DaemonRequestError('identity sign-in requires a provider service', 400);
        return sendJson(response, 202, await beginProviderLogin(body.service.trim().toLowerCase()));
      }
      if (request.method === 'POST' && url.pathname === '/contribute/start') {
        const taskDigest = contributeBody(await readJsonBody(request, { allowEmpty: true }));
        if (!ensureApprovalPolling()) throw new DaemonRequestError(PENDING_APPROVAL_DETAIL, 409);
        if (taskDigest) await requireGitHubTaskAccess(taskDigest);
        const started = superviseContribute(taskDigest);
        return sendJson(response, started ? 202 : 200, { ...status(), started });
      }
      if (request.method === 'POST' && url.pathname === '/contribute/pause') {
        if (contributeChild) {
          pauseAfterCurrent = true;
          setState('pausing', 'Pausing after current task…');
        } else {
          pauseAfterCurrent = false;
          setState('paused');
        }
        return sendJson(response, 200, status());
      }
      if (request.method === 'POST' && url.pathname === '/contribute/stop') {
        const body = await readJsonBody(request, { allowEmpty: true });
        if (!body?.confirm) throw new DaemonRequestError('Stop now requires an explicit confirmation because it abandons the current task.', 400);
        if (contributeChild) {
          const child = contributeChild;
          contributeChild = null;
          recordContribution({
            outcome: 'returned',
            reason: 'Stopped now by the contributor before the task finished.',
            requesterNotice: 'Waspflow recorded this returned attempt locally; requester confirmation is unavailable.',
          });
          child.kill('SIGTERM');
        }
        if (dockerLoginFlow) {
          dockerLoginCancelled = true;
          dockerLoginFlow.cancel();
          dockerLoginFlow = null;
        }
        if (providerLoginFlow) {
          providerLoginGeneration += 1;
          providerLoginFlow.cancel();
          providerLoginFlow = null;
        }
        if (providerLoginStarting) {
          providerLoginGeneration += 1;
          providerLoginStarting.cancel();
          providerLoginStarting = null;
        }
        dockerLoginCancelled = true;
        dockerLoginResume = null;
        pauseAfterCurrent = false;
        setState('paused');
        return sendJson(response, 200, status());
      }
      if (request.method === 'POST' && url.pathname === '/join') {
        const body = await readJsonBody(request);
        if (!body || typeof body.invite !== 'string') throw new DaemonRequestError('join body requires an invite string', 400);
        const started = superviseJoin(body.invite);
        return sendJson(response, started ? 202 : 409, { ...status(), started });
      }
      if (request.method === 'POST' && url.pathname === '/submit') {
        const body = await readJsonBody(request, { maxBytes: MAX_SUBMIT_BODY_BYTES });
        const started = await superviseSubmit(body);
        return sendJson(response, started || submission?.state === 'failed' ? 202 : 409, { ...status(), started });
      }
      if (request.method === 'POST' && url.pathname === '/submit/ack') {
        submission = null;
        return sendJson(response, 200, { ...status(), acknowledged: true });
      }
      if (request.method === 'POST' && url.pathname === '/git/probe') {
        const body = await readJsonBody(request);
        const gitUrl = body?.git_url?.trim();
        if (!gitUrl || !/^https:\/\/github\.com\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+(?:\.git)?$/.test(gitUrl)) throw new DaemonRequestError('Git repository must be an HTTPS github.com owner/repository URL.', 400);
        const visibility = await gitVisibilityProbe(gitUrl);
        return sendJson(response, 200, { visibility, github_access_required: visibility !== 'public' });
      }
      if (request.method === 'GET' && url.pathname === '/submit/status') {
        const taskDigest = url.searchParams.get('task_digest') || submission?.task_digest;
        if (!taskDigest) return sendJson(response, 200, { submission });
        return sendJson(response, 200, await readTaskStatus(taskDigest));
      }
      if (request.method === 'GET' && url.pathname === '/') {
        const index = join(publicDir, 'index.html');
        if (!existsSync(index)) return sendJson(response, 404, { error: 'web UI assets are not installed' });
        response.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
        response.end(readFileSync(index));
        return;
      }
      if (request.method === 'GET' && url.pathname === '/app.mjs') {
        const app = join(publicDir, 'app.mjs');
        if (!existsSync(app)) return sendJson(response, 404, { error: 'web UI assets are not installed' });
        response.writeHead(200, { 'content-type': 'text/javascript; charset=utf-8', 'cache-control': 'no-store' });
        response.end(readFileSync(app));
        return;
      }
      return sendJson(response, 404, { error: 'not found' });
    } catch (error) {
      if (error instanceof DaemonRequestError) return sendJson(response, error.status, { error: error.message });
      return sendJson(response, 500, { error: 'daemon request failed' });
    }
  });

  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen({ host: '127.0.0.1', port }, () => {
      server.removeListener('error', reject);
      resolve();
    });
  });
  const address = server.address();
  const info = { schema_version: DAEMON_SCHEMA_VERSION, type: 'federation_daemon', pid: process.pid, port: address.port, token };
  writeDaemonInfo(infoPath, info);
  void refreshIdentity();
  identityRefreshTimer = setInterval(() => { void refreshIdentity(); }, IDENTITY_CACHE_MS);
  identityRefreshTimer.unref?.();

  async function close() {
    if (closed) return;
    closed = true;
    if (contributeChild) contributeChild.kill('SIGTERM');
    dockerLoginCancelled = true;
    if (dockerLoginFlow) dockerLoginFlow.cancel();
    if (providerLoginFlow) providerLoginFlow.cancel();
    if (providerLoginStarting) providerLoginStarting.cancel();
    if (joinChild) joinChild.kill('SIGTERM');
    if (submitChild) submitChild.kill('SIGTERM');
    stopApprovalPolling();
    if (identityRefreshTimer) clearInterval(identityRefreshTimer);
    await new Promise((resolve) => server.close(resolve));
    removeDaemonInfo(infoPath, token);
  }

  return { server, info, status, close };
}

export async function runDaemon(argv = []) {
  const portFlag = argv.indexOf('--port');
  const value = portFlag === -1 ? 0 : Number(argv[portFlag + 1]);
  if (portFlag !== -1 && (!Number.isInteger(value) || value < 0 || value > 65535)) throw new Error('daemon --port must be an integer from 0 to 65535');
  const daemon = await startFederationDaemon({ port: value });
  process.stderr.write(`waspflow federation daemon listening on 127.0.0.1:${daemon.info.port}\n`);
  // The daemon is long-running: it must NOT let runDaemon() resolve, or the CLI's
  // top-level main() completing would tear the listening server down (the process
  // exits when main resolves). Block on a promise that only settles when a
  // shutdown signal arrives, so `waspflow federation daemon` stays up until killed.
  await new Promise((resolve) => {
    const shutdown = async () => { await daemon.close(); resolve(); };
    process.once('SIGINT', shutdown);
    process.once('SIGTERM', shutdown);
  });
}

export async function openFederationUi({ spawnProcess = spawnChild, cliPath = DEFAULT_CLI_PATH, infoPath = daemonInfoPath(), platformName = platform() } = {}) {
  let info = readDaemonInfo(infoPath);
  if (!info || !(await daemonIsReachable(info))) {
    const child = spawnProcess(process.execPath, [cliPath, 'daemon'], { detached: true, stdio: 'ignore', env: process.env });
    child.unref?.();
    for (let attempt = 0; attempt < 30; attempt++) {
      await wait(100);
      info = readDaemonInfo(infoPath);
      if (info && await daemonIsReachable(info)) break;
    }
  }
  if (!info || !(await daemonIsReachable(info))) throw new Error('daemon did not start within 3 seconds');
  const url = `http://127.0.0.1:${info.port}/?token=${encodeURIComponent(info.token)}`;
  const [command, args] = openCommand(url, platformName);
  const browser = spawnProcess(command, args, { detached: true, stdio: 'ignore' });
  // A headless host may not have xdg-open (or any browser). The daemon and
  // printed URL are still usable, so a best-effort browser launch must not
  // turn a successful first-run into an unhandled child-process error.
  browser.on?.('error', () => {});
  browser.unref?.();
  return url;
}
