/**
 * Local Federation daemon: supervises the existing guided CLI and exposes a
 * deliberately small, authenticated localhost surface for the browser UI and
 * tray. It owns no federation-loop logic.
 */
import { createServer } from 'node:http';
import { spawn as spawnChild } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { chmodSync, existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
import { platform } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { validateEvent } from './federation-events.mjs';
import { configHome, loadConfig } from './federation-config.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const DEFAULT_CLI_PATH = join(ROOT, 'bin', 'waspflow-federation');
const DEFAULT_PUBLIC_DIR = join(ROOT, 'public');
const MAX_BODY_BYTES = 64 * 1024;
const MAX_PROGRESS_BYTES = 8 * 1024;
const APPROVAL_POLL_INTERVAL_MS = 10_000;
const PENDING_APPROVAL_DETAIL = "Waiting for the collective owner to approve you — you'll start automatically once approved.";

export const DAEMON_SCHEMA_VERSION = 1;

function daemonInfoPath() {
  return join(configHome(), 'daemon.json');
}

function defaultLedgerPath() {
  return join(configHome(), 'ledger.json');
}

function defaultDetail(state) {
  return {
    not_joined: 'Not joined. Paste an invite to get started.',
    idle: 'Ready to contribute.',
    contributing: 'Contribution is running.',
    paused: 'Contribution is paused.',
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

async function readJsonBody(request, { allowEmpty = false } = {}) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_BODY_BYTES) throw new DaemonRequestError('request body exceeds byte limit', 413);
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
  const match = /^\s*(?:waspflow\s+federation\s+join)\s+(\S+)\s+(\S+)\s*$/.exec(value);
  return match ? { coordinator: match[1], token: match[2] } : null;
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
  const command = commandParts(value);
  if (command) return { coordinatorUrl: coordinatorUrl(command.coordinator), token: command.token };
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
  const fields = ['source', 'prompt', 'display_id'];
  for (const field of fields) {
    if (typeof body[field] !== 'string' || !body[field].trim()) {
      throw new DaemonRequestError(`submit body requires a non-empty ${field} string`, 400);
    }
  }
  return { source: body.source, prompt: body.prompt, displayId: body.display_id };
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
  now = () => new Date(),
} = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('port must be an integer from 0 to 65535');

  let state = approvalConfig(configLoader()) ? 'pending_approval' : (configLoader() ? 'idle' : 'not_joined');
  let detail = defaultDetail(state);
  let action = null;
  let contributeChild = null;
  let contribution = null;
  let joinChild = null;
  let submitChild = null;
  let submission = null;
  let approvalTimer = null;
  let approvalRequestInFlight = false;
  let activeApprovalIdentity = null;
  let approvedApprovalIdentity = null;
  let ledgerEntries = loadLedger(ledgerPath);
  let lastCompleted = ledgerEntries.at(-1) || null;
  const taskDisplayIds = new Map();
  let closed = false;

  function config() {
    try { return configLoader(); } catch { return null; }
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
      const approved = response.ok && Array.isArray(body?.roster)
        && body.roster.some((entry) => entry?.key_id === currentConfig.key_id);
      if (activeApprovalIdentity !== identity) return;
      if (approved) {
        approvedApprovalIdentity = identity;
        stopApprovalPolling();
        if (state === 'pending_approval' || state === 'not_joined') setState('idle');
      } else if (state !== 'contributing' && state !== 'paused') {
        setState('pending_approval', PENDING_APPROVAL_DETAIL);
      }
    } catch {
      if (activeApprovalIdentity === identity && state !== 'contributing' && state !== 'paused') {
        setState('pending_approval', PENDING_APPROVAL_DETAIL);
      }
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

  function recordCompletedContribution(event) {
    const currentConfig = config();
    const taskDigest = event?.task_digest || contribution?.task_digest;
    const entry = {
      display_id: event?.display_id || contribution?.display_id || taskDisplayIds.get(taskDigest) || taskDigest || 'A Federation task',
      coordinator: currentConfig?.coordinator_url || null,
      finished_at: now().toISOString(),
    };
    ledgerEntries = [...ledgerEntries, entry];
    saveLedger(ledgerPath, ledgerEntries);
    lastCompleted = entry;
  }

  function status() {
    const currentConfig = config();
    if (!currentConfig && state !== 'paused' && state !== 'action_needed' && state !== 'setup_required') {
      state = 'not_joined';
      detail = defaultDetail(state);
    } else if (currentConfig && state === 'not_joined') {
      ensureApprovalPolling();
      if (state === 'not_joined') setState('idle');
    }
    ensureApprovalPolling();
    const result = { schema_version: DAEMON_SCHEMA_VERSION, type: 'daemon_status', state, detail };
    if (currentConfig && currentConfig.coordinator_url) result.coordinator_url = currentConfig.coordinator_url;
    if (currentConfig?.collective_name) result.collective_name = currentConfig.collective_name;
    if (action) result.action = action;
    if (submission) result.submission = submission;
    if (contribution) result.contribution = contribution;
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
    const progress = `${detail}\n${chunk.toString('utf8')}`.slice(-MAX_PROGRESS_BYTES).trim();
    if (progress) detail = progress;
  }

  function reflectContributeEvent(event, exitCode) {
    if (event?.task_digest && contribution) contribution = { ...contribution, task_digest: event.task_digest };
    if (!event) {
      setState('idle', exitCode === 0 ? 'Contribution finished.' : `Contribution stopped (exit ${exitCode ?? 'unknown'}).`);
      return;
    }
    if (event.type === 'awaiting_browser') {
      setState('action_needed', 'Finish sign-in in your browser.', { kind: 'awaiting_browser', url: event.url });
    } else if (event.type === 'auth_required_manual') {
      setState('action_needed', 'Complete the required sign-in step, then start contributing again.', { kind: 'auth_required_manual', instruction: event.instruction });
    } else if (event.type === 'sandbox_preflight' && event.status === 'setup_required') {
      const failedChecks = Array.isArray(event.checks) ? event.checks.filter((item) => item && item.ok === false) : [];
      if (failedChecks.length === 1 && failedChecks[0].name === 'docker_login') {
        setState('action_needed', 'Sign in to Docker for the Waspflow sandbox identity, then start contributing again.', {
          kind: 'docker_login',
          url: 'https://app.docker.com/',
        });
      } else {
        setState('setup_required', 'Your sandbox is not ready yet. Fix the failed checks before contributing again.', {
          kind: 'sandbox_preflight',
          checks: failedChecks,
        });
      }
    } else if (event.type === 'no_task_available') {
      setState('idle', 'No task is available right now.');
    } else if (event.type === 'contributed') {
      recordCompletedContribution(event);
      setState('idle', 'Contribution finished.');
    } else {
      setState('idle', 'Contribution finished.');
    }
  }

  function superviseContribute(taskDigest = null) {
    if (contributeChild) return false;
    if (!config()) {
      setState('not_joined');
      return false;
    }
    if (!ensureApprovalPolling()) return false;
    setState('contributing');
    contribution = {
      selection: taskDigest ? 'chosen' : 'next',
      task_digest: taskDigest,
      ...(taskDigest && taskDisplayIds.has(taskDigest) ? { display_id: taskDisplayIds.get(taskDigest) } : {}),
    };
    let child;
    try {
      const args = [cliPath, 'contribute'];
      if (taskDigest) args.push('--task-digest', taskDigest);
      args.push('--json');
      child = spawnProcess(process.execPath, args, { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      setState('idle', `Could not start contribution: ${error.message}`);
      return false;
    }
    contributeChild = child;
    let stdout = '';
    child.stdout?.on('data', (chunk) => {
      stdout += chunk.toString('utf8');
      const event = finalEvent(stdout);
      if (event?.type === 'awaiting_browser' || event?.type === 'auth_required_manual') reflectContributeEvent(event);
    });
    child.stderr?.on('data', appendProgress);
    child.once('error', (error) => {
      if (contributeChild === child) {
        contributeChild = null;
        setState('idle', `Could not start contribution: ${error.message}`);
      }
    });
    child.once('close', (code) => {
      if (contributeChild !== child) return;
      contributeChild = null;
      reflectContributeEvent(finalEvent(stdout), code);
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
      throw new DaemonRequestError('could not reach the coordinator to list available tasks', 502);
    }
    const body = await response.json().catch(() => null);
    if (!response.ok) throw new DaemonRequestError(body?.error || `coordinator returned ${response.status} while listing available tasks`, 502);
    if (!Array.isArray(body)) throw new DaemonRequestError('coordinator returned an invalid task list', 502);
    for (const task of body) {
      if (typeof task?.task_digest === 'string' && typeof task.display_id === 'string') taskDisplayIds.set(task.task_digest, task.display_id);
    }
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
      else setState(config() ? 'idle' : 'not_joined', code === 0 ? 'Join did not return a recognized result.' : (stderr.trim() || `Join stopped (exit ${code ?? 'unknown'}).`));
    });
    return true;
  }

  // Requester submission remains the guided CLI's job. The daemon only keeps
  // the browser informed while that CLI packages, publishes, and waits. The
  // first task digest is deliberately extracted from its existing stable
  // progress line; lifecycle truth still comes from `status --json` below.
  function superviseSubmit(body) {
    if (submitChild) return false;
    if (!config()) {
      setState('not_joined');
      return false;
    }
    const input = submitBody(body);
    submission = { state: 'submitting', detail: 'Preparing and publishing your task.', task_digest: null };
    let child;
    try {
      child = spawnProcess(process.execPath, [
        cliPath, 'submit', '--display-id', input.displayId,
        '--source', input.source, '--prompt', input.prompt,
      ], { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      submission = { ...submission, state: 'failed', detail: `Could not start submission: ${error.message}` };
      return false;
    }
    submitChild = child;
    const append = (chunk) => {
      if (!submission) return;
      const detail = `${submission.detail}\n${chunk.toString('utf8')}`.slice(-MAX_PROGRESS_BYTES).trim();
      const taskDigest = taskDigestFromProgress(detail);
      submission = {
        ...submission,
        detail,
        task_digest: taskDigest || submission.task_digest,
        state: taskDigest ? 'queued' : submission.state,
      };
    };
    child.stdout?.on('data', append);
    child.stderr?.on('data', append);
    child.once('error', (error) => {
      if (submitChild === child) {
        submitChild = null;
        submission = { ...submission, state: 'failed', detail: `Submission stopped: ${error.message}` };
      }
    });
    child.once('close', (code) => {
      if (submitChild !== child) return;
      submitChild = null;
      submission = {
        ...submission,
        state: code === 0 ? 'settled' : 'failed',
        detail: code === 0 ? 'Submission settled. Your result is ready to review.' : `Submission stopped (exit ${code ?? 'unknown'}).`,
      };
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
        reject(new DaemonRequestError(stderr.trim() || `Could not read task status (exit ${code ?? 'unknown'}).`, 502));
      });
    });
  }

  const server = createServer(async (request, response) => {
    const url = new URL(request.url || '/', 'http://localhost');
    if (!isAllowedHost(request.headers.host)) return sendJson(response, 400, { error: 'invalid Host header' });
    if (!tokensMatch(requestToken(request, url), token)) return sendJson(response, 401, { error: 'missing or invalid daemon session token' });
    try {
      if (request.method === 'GET' && url.pathname === '/status') return sendJson(response, 200, status());
      if (request.method === 'GET' && url.pathname === '/tasks') return sendJson(response, 200, await listClaimableTasks());
      if (request.method === 'GET' && url.pathname === '/ledger') return sendJson(response, 200, ledgerEntries);
      if (request.method === 'POST' && url.pathname === '/contribute/start') {
        const taskDigest = contributeBody(await readJsonBody(request, { allowEmpty: true }));
        if (!ensureApprovalPolling()) throw new DaemonRequestError(PENDING_APPROVAL_DETAIL, 409);
        const started = superviseContribute(taskDigest);
        return sendJson(response, started ? 202 : 200, { ...status(), started });
      }
      if (request.method === 'POST' && url.pathname === '/contribute/stop') {
        if (contributeChild) {
          const child = contributeChild;
          contributeChild = null;
          child.kill('SIGTERM');
        }
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
        const body = await readJsonBody(request);
        const started = superviseSubmit(body);
        return sendJson(response, started ? 202 : 409, { ...status(), started });
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

  async function close() {
    if (closed) return;
    closed = true;
    if (contributeChild) contributeChild.kill('SIGTERM');
    if (joinChild) joinChild.kill('SIGTERM');
    if (submitChild) submitChild.kill('SIGTERM');
    stopApprovalPolling();
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
  browser.unref?.();
  return url;
}
