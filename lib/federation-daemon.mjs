/**
 * Local Federation daemon: supervises the existing guided CLI and exposes a
 * deliberately small, authenticated localhost surface for the browser UI and
 * tray. It owns no federation-loop logic.
 */
import { createServer } from 'node:http';
import { spawn as spawnChild } from 'node:child_process';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from 'node:fs';
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

export const DAEMON_SCHEMA_VERSION = 1;

function daemonInfoPath() {
  return join(configHome(), 'daemon.json');
}

function defaultDetail(state) {
  return {
    not_joined: 'Not joined. Paste an invite to get started.',
    idle: 'Ready to contribute.',
    contributing: 'Contribution is running.',
    paused: 'Contribution is paused.',
    action_needed: 'Action is needed before contributing can continue.',
  }[state];
}

function validPort(port) {
  return Number.isInteger(port) && port > 0 && port <= 65535;
}

function writeDaemonInfo(path, info) {
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

async function readJsonBody(request) {
  const chunks = [];
  let length = 0;
  for await (const chunk of request) {
    length += chunk.length;
    if (length > MAX_BODY_BYTES) throw new DaemonRequestError('request body exceeds byte limit', 413);
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
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
    return { coordinatorUrl: coordinatorUrl(coordinator), token };
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
  if (lines.length !== 1) return null;
  try {
    const event = JSON.parse(lines[0]);
    return validateEvent(event).length === 0 ? event : null;
  } catch {
    return null;
  }
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

function openCommand(url) {
  if (platform() === 'darwin') return ['open', [url]];
  if (platform() === 'win32') return ['cmd.exe', ['/c', 'start', '', url]];
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
} = {}) {
  if (!Number.isInteger(port) || port < 0 || port > 65535) throw new Error('port must be an integer from 0 to 65535');

  let state = configLoader() ? 'idle' : 'not_joined';
  let detail = defaultDetail(state);
  let action = null;
  let contributeChild = null;
  let joinChild = null;
  let submitChild = null;
  let submission = null;
  let closed = false;

  function config() {
    try { return configLoader(); } catch { return null; }
  }

  function status() {
    const currentConfig = config();
    if (!currentConfig && state !== 'paused' && state !== 'action_needed') {
      state = 'not_joined';
      detail = defaultDetail(state);
    } else if (currentConfig && state === 'not_joined') {
      state = 'idle';
      detail = defaultDetail(state);
    }
    const result = { schema_version: DAEMON_SCHEMA_VERSION, type: 'daemon_status', state, detail };
    if (currentConfig && currentConfig.coordinator_url) result.coordinator_url = currentConfig.coordinator_url;
    if (action) result.action = action;
    if (submission) result.submission = submission;
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
    if (!event) {
      setState('idle', exitCode === 0 ? 'Contribution finished.' : `Contribution stopped (exit ${exitCode ?? 'unknown'}).`);
      return;
    }
    if (event.type === 'awaiting_browser') {
      setState('action_needed', 'Finish sign-in in your browser.', { kind: 'awaiting_browser', url: event.url });
    } else if (event.type === 'auth_required_manual') {
      setState('action_needed', 'Complete the required sign-in step, then start contributing again.', { kind: 'auth_required_manual', instruction: event.instruction });
    } else if (event.type === 'no_task_available') {
      setState('idle', 'No task is available right now.');
    } else if (event.type === 'contributed') {
      setState('idle', 'Contribution finished.');
    } else {
      setState('idle', 'Contribution finished.');
    }
  }

  function superviseContribute() {
    if (contributeChild) return false;
    if (!config()) {
      setState('not_joined');
      return false;
    }
    setState('contributing');
    let child;
    try {
      child = spawnProcess(process.execPath, [cliPath, 'contribute', '--json'], { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    } catch (error) {
      setState('idle', `Could not start contribution: ${error.message}`);
      return false;
    }
    contributeChild = child;
    let stdout = '';
    child.stdout?.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
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

  function superviseJoin(invite) {
    if (joinChild) return false;
    const currentConfig = config();
    const parsed = parseJoinInvite(invite, currentConfig?.coordinator_url || process.env.WASPFLOW_FEDERATION_COORDINATOR_URL);
    setState('not_joined', 'Joining the federation…');
    let child;
    try {
      child = spawnProcess(process.execPath, [cliPath, 'join', parsed.coordinatorUrl, parsed.token, '--json'], { stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
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
      if (event?.type === 'joined' || event?.type === 'already_joined') setState('idle', 'Ready to contribute.');
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
      if (request.method === 'POST' && url.pathname === '/contribute/start') {
        const started = superviseContribute();
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
  const shutdown = async () => { await daemon.close(); process.exit(0); };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
}

export async function openFederationUi({ spawnProcess = spawnChild, cliPath = DEFAULT_CLI_PATH, infoPath = daemonInfoPath() } = {}) {
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
  const [command, args] = openCommand(url);
  const browser = spawnProcess(command, args, { detached: true, stdio: 'ignore' });
  browser.unref?.();
  return url;
}
