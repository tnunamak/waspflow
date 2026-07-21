import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openFederationUi, parseJoinInvite, startFederationDaemon } from '../lib/federation-daemon.mjs';

function fakeChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.stderr = new EventEmitter();
  child.kill = () => { child.killed = true; };
  return child;
}

function request(base, path, { method = 'GET', token, host, body } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(path, base);
    const headers = {};
    if (token !== undefined) headers['x-waspflow-session-token'] = token;
    if (host !== undefined) headers.host = host;
    if (body !== undefined) headers['content-type'] = 'application/json';
    const req = httpRequest(url, { method, headers }, (res) => {
      const chunks = [];
      res.on('data', (chunk) => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, text: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject);
    if (body !== undefined) req.write(JSON.stringify(body));
    req.end();
  });
}

async function withDaemon(fn) {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-daemon-'));
  let config = null;
  const children = [];
  const daemon = await startFederationDaemon({
    token: 'test-session-token',
    infoPath: join(directory, 'daemon.json'),
    cliPath: '/real/path/to/bin/waspflow-federation',
    configLoader: () => config,
    spawnProcess: (...args) => {
      const child = fakeChild();
      children.push({ args, child });
      return child;
    },
  });
  const base = `http://127.0.0.1:${daemon.info.port}`;
  try {
    await fn({ base, daemon, children, setConfig: (value) => { config = value; } });
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
}

function statusBody(response) {
  assert.equal(response.status, 200, response.text);
  const body = JSON.parse(response.text);
  assert.equal(body.schema_version, 1);
  assert.equal(body.type, 'daemon_status');
  assert.equal(typeof body.detail, 'string');
  return body;
}

test('GET /status exposes every daemon state and auth handoff payloads', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    const token = 'test-session-token';
    assert.equal(statusBody(await request(base, '/status', { token })).state, 'not_joined');

    setConfig({ coordinator_url: 'http://coordinator.example' });
    const idle = statusBody(await request(base, '/status', { token }));
    assert.equal(idle.state, 'idle');
    assert.equal(idle.coordinator_url, 'http://coordinator.example');

    const started = await request(base, '/contribute/start', { method: 'POST', token });
    assert.equal(started.status, 202);
    assert.equal(JSON.parse(started.text).state, 'contributing');
    assert.equal(children[0].args[0], process.execPath);
    assert.deepEqual(children[0].args[1], ['/real/path/to/bin/waspflow-federation', 'contribute', '--json']);

    const paused = statusBody(await request(base, '/contribute/stop', { method: 'POST', token }));
    assert.equal(paused.state, 'paused');
    assert.equal(children[0].child.killed, true);

    await request(base, '/contribute/start', { method: 'POST', token });
    children[1].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'awaiting_browser',
      status: 'awaiting_browser',
      harness: 'codex',
      url: 'https://auth.example/login',
    }) + '\n'));
    children[1].child.emit('close', 1);
    const actionNeeded = statusBody(await request(base, '/status', { token }));
    assert.equal(actionNeeded.state, 'action_needed');
    assert.deepEqual(actionNeeded.action, { kind: 'awaiting_browser', url: 'https://auth.example/login' });

    await request(base, '/contribute/start', { method: 'POST', token });
    children[2].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'auth_required_manual',
      status: 'auth_required_manual',
      harness: 'claude',
      flow_shape: 'interactive-session-flow',
      instruction: 'Run the supplied login command.',
    }) + '\n'));
    children[2].child.emit('close', 1);
    const manualAction = statusBody(await request(base, '/status', { token }));
    assert.equal(manualAction.state, 'action_needed');
    assert.deepEqual(manualAction.action, { kind: 'auth_required_manual', instruction: 'Run the supplied login command.' });

    await request(base, '/contribute/start', { method: 'POST', token });
    children[3].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'sandbox_preflight',
      status: 'setup_required',
      backend_id: 'docker-sbx',
      checks: [
        { name: 'network_policy', ok: false, detail: 'global network policy has not been initialized.', fix: 'sbx policy init balanced' },
        { name: 'docker_login', ok: true, detail: 'authenticated', fix: '' },
      ],
    }) + '\n'));
    children[3].child.emit('close', 1);
    const setupRequired = statusBody(await request(base, '/status', { token }));
    assert.equal(setupRequired.state, 'setup_required');
    assert.equal(setupRequired.action.kind, 'sandbox_preflight');
    assert.deepEqual(setupRequired.action.checks, [{ name: 'network_policy', ok: false, detail: 'global network policy has not been initialized.', fix: 'sbx policy init balanced' }]);
  });
});

test('daemon rejects rebinding Host headers and absent or invalid session tokens', async () => {
  await withDaemon(async ({ base }) => {
    const hostileHost = await request(base, '/status', { token: 'test-session-token', host: 'attacker.example' });
    assert.equal(hostileHost.status, 400);

    const missingToken = await request(base, '/status');
    assert.equal(missingToken.status, 401);
    const badToken = await request(base, '/status', { token: 'not-the-token' });
    assert.equal(badToken.status, 401);

    const bareRoot = await request(base, '/');
    assert.equal(bareRoot.status, 401);
    const root = await request(base, '/', { token: 'test-session-token' });
    assert.equal(root.status, 200);
    assert.match(root.text, /Loading Waspflow Federation/);
    assert.equal(root.headers['access-control-allow-origin'], undefined);

    const app = await request(base, '/app.mjs', { token: 'test-session-token' });
    assert.equal(app.status, 200);
    assert.match(app.headers['content-type'], /^text\/javascript/);
    assert.match(app.text, /viewForStatus/);
  });
});

test('POST /contribute/start is idempotent and spawns the guided contribute verb once', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const first = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    const second = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    assert.equal(first.status, 202);
    assert.equal(second.status, 200);
    assert.equal(JSON.parse(second.text).started, false);
    assert.equal(children.length, 1);
    assert.deepEqual(children[0].args[1], ['/real/path/to/bin/waspflow-federation', 'contribute', '--json']);
  });
});

test('POST /join accepts an invite and shells out to the guided join verb', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    const response = await request(base, '/join', {
      method: 'POST',
      token: 'test-session-token',
      body: { invite: 'waspflow://join?coordinator=http%3A%2F%2Fcoordinator.example&token=invite-token' },
    });
    assert.equal(response.status, 202);
    assert.deepEqual(children[0].args[1], ['/real/path/to/bin/waspflow-federation', 'join', 'http://coordinator.example', 'invite-token', '--json']);
    setConfig({ coordinator_url: 'http://coordinator.example' });
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'already_joined',
      status: 'already_joined',
      key_id: 'member',
      coordinator_url: 'http://coordinator.example',
      config_path: '/tmp/config.json',
    }) + '\n'));
    children[0].child.emit('close', 0);
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).state, 'idle');
  });
});

test('POST /submit supervises the guided submit verb and GET /submit/status proxies its JSON lifecycle', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const response = await request(base, '/submit', {
      method: 'POST',
      token: 'test-session-token',
      body: { source: '/work/project', prompt: 'Fix the test failure.', display_id: 'oshin' },
    });
    assert.equal(response.status, 202);
    assert.deepEqual(children[0].args[1], [
      '/real/path/to/bin/waspflow-federation', 'submit', '--display-id', 'oshin',
      '--source', '/work/project', '--prompt', 'Fix the test failure.',
    ]);

    const digest = `sha256:${'a'.repeat(64)}`;
    children[0].child.stdout.emit('data', Buffer.from(`waspflow-federation-submit: task_digest=${digest} status=QUEUED\n`));
    const daemonStatus = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.equal(daemonStatus.submission.task_digest, digest);
    assert.equal(daemonStatus.submission.state, 'queued');

    const taskStatusPromise = request(base, `/submit/status?task_digest=${digest}`, { token: 'test-session-token' });
    for (let attempt = 0; children.length < 2 && attempt < 10; attempt++) {
      await new Promise((resolve) => setImmediate(resolve));
    }
    assert.equal(children.length, 2, 'status request should spawn the guided status verb');
    children[1].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'task_status',
      status: 'CLAIMED',
      task_digest: digest,
    }) + '\n'));
    children[1].child.emit('close', 0);
    const taskStatus = await taskStatusPromise;
    assert.equal(taskStatus.status, 200);
    assert.equal(JSON.parse(taskStatus.text).status, 'CLAIMED');
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).submission.state, 'claimed');
  });
});

test('parseJoinInvite normalizes deep links, pasted commands, and raw tokens', () => {
  assert.deepEqual(
    parseJoinInvite('waspflow://join?coordinator=https%3A%2F%2Fcoordinator.example%2F&token=deep-token'),
    { coordinatorUrl: 'https://coordinator.example', token: 'deep-token' },
  );
  assert.deepEqual(
    parseJoinInvite('waspflow federation join http://127.0.0.1:8787 command-token'),
    { coordinatorUrl: 'http://127.0.0.1:8787', token: 'command-token' },
  );
  assert.deepEqual(
    parseJoinInvite('raw-token', 'https://coordinator.example/'),
    { coordinatorUrl: 'https://coordinator.example', token: 'raw-token' },
  );
  assert.throws(() => parseJoinInvite('raw-token'), /previously known coordinator/);
});

test('openFederationUi opens the tokenized local URL for a running daemon', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-ui-'));
  const infoPath = join(directory, 'daemon.json');
  const daemon = await startFederationDaemon({ token: 'ui-session-token', infoPath, configLoader: () => null });
  const calls = [];
  try {
    assert.equal((await stat(infoPath)).mode & 0o777, 0o600);
    const url = await openFederationUi({
      infoPath,
      spawnProcess: (...args) => {
        calls.push(args);
        return { unref() {} };
      },
    });
    assert.equal(url, `http://127.0.0.1:${daemon.info.port}/?token=ui-session-token`);
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], process.platform === 'darwin' ? 'open' : process.platform === 'win32' ? 'cmd.exe' : 'xdg-open');
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});
