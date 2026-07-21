import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
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
  const coordinatorCalls = [];
  let taskListResponse = { status: 200, body: [] };
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
    fetchImpl: async (url, options) => {
      coordinatorCalls.push({ url, options });
      return new Response(JSON.stringify(taskListResponse.body), {
        status: taskListResponse.status,
        headers: { 'content-type': 'application/json' },
      });
    },
  });
  const base = `http://127.0.0.1:${daemon.info.port}`;
  try {
    await fn({
      base,
      daemon,
      children,
      coordinatorCalls,
      setConfig: (value) => { config = value; },
      setTaskListResponse: (value) => { taskListResponse = value; },
    });
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

function waitFor(predicate, timeoutMs = 250) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + timeoutMs;
    const poll = async () => {
      if (await predicate()) return resolve();
      if (Date.now() >= deadline) return reject(new Error('timed out waiting for expected daemon state'));
      setTimeout(poll, 5);
    };
    void poll();
  });
}

test('approval polling keeps a newly joined member pending, rejects contribution, then flips to idle after their key appears in GET /roster', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-approval-'));
  let approved = false;
  const daemon = await startFederationDaemon({
    token: 'test-session-token',
    infoPath: join(directory, 'daemon.json'),
    ledgerPath: join(directory, 'ledger.json'),
    approvalPollIntervalMs: 5,
    configLoader: () => ({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token', key_id: 'oshin' }),
    fetchImpl: async () => new Response(JSON.stringify({ roster: approved ? [{ key_id: 'oshin' }] : [] }), { status: 200 }),
  });
  const base = `http://127.0.0.1:${daemon.info.port}`;
  try {
    const pending = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.equal(pending.state, 'pending_approval');
    assert.equal(pending.detail, "Waiting for the collective owner to approve you — you'll start automatically once approved.");
    const blocked = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    assert.equal(blocked.status, 409);
    assert.equal(JSON.parse(blocked.text).error, "Waiting for the collective owner to approve you — you'll start automatically once approved.");

    approved = true;
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'idle');
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('completed contribution appends a private ledger entry and exposes its weekly summary and last completion', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-ledger-'));
  const ledgerPath = join(directory, 'ledger.json');
  const children = [];
  const daemon = await startFederationDaemon({
    token: 'test-session-token',
    infoPath: join(directory, 'daemon.json'),
    ledgerPath,
    approvalPollIntervalMs: 5,
    configLoader: () => ({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token', key_id: 'oshin' }),
    fetchImpl: async () => new Response(JSON.stringify({ roster: [{ key_id: 'oshin' }] }), { status: 200 }),
    spawnProcess: (...args) => {
      const child = fakeChild();
      children.push({ args, child });
      return child;
    },
  });
  const base = `http://127.0.0.1:${daemon.info.port}`;
  try {
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'idle');
    const started = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    assert.equal(started.status, 202);
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1, type: 'contributed', status: 'settled', task_digest: 'a'.repeat(64), display_id: 'Fix onboarding',
    }) + '\n'));
    children[0].child.emit('close', 0);

    const ledger = await request(base, '/ledger', { token: 'test-session-token' });
    assert.equal(ledger.status, 200);
    const entries = JSON.parse(ledger.text);
    assert.equal(entries.length, 1);
    assert.deepEqual(entries[0], {
      display_id: 'Fix onboarding', coordinator: 'http://coordinator.example', finished_at: entries[0].finished_at,
    });
    const status = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.deepEqual(status.ledger_summary, { count_7d: 1, last: { display_id: 'Fix onboarding', finished_at: entries[0].finished_at } });
    assert.deepEqual(status.last_completed, entries[0]);
    assert.equal((await stat(ledgerPath)).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(await readFile(ledgerPath, 'utf8')), entries);
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});

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

    await request(base, '/contribute/start', { method: 'POST', token });
    children[4].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'sandbox_preflight',
      status: 'setup_required',
      backend_id: 'docker-sbx',
      checks: [{ name: 'docker_login', ok: false, detail: 'not authenticated', fix: 'sbx login' }],
    }) + '\n'));
    children[4].child.emit('close', 1);
    const dockerLogin = statusBody(await request(base, '/status', { token }));
    assert.equal(dockerLogin.state, 'action_needed');
    assert.deepEqual(dockerLogin.action, { kind: 'docker_login', url: 'https://app.docker.com/' });
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

test('daemon immediately exposes awaiting_browser for a host-url-flow and never downgrades it to manual auth', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'awaiting_browser',
      status: 'awaiting_browser',
      harness: 'claude-code-subscription',
      url: 'https://claude.com/cai/oauth/authorize?state=abc',
    }) + '\n'));
    const waiting = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.deepEqual(waiting.action, { kind: 'awaiting_browser', url: 'https://claude.com/cai/oauth/authorize?state=abc' });
    assert.notEqual(waiting.action.kind, 'auth_required_manual');

    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'contributed',
      status: 'settled',
      task_digest: 'a'.repeat(64),
    }) + '\n'));
    children[0].child.emit('close', 0);
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).state, 'idle');
  });
});

test('GET /tasks passes through claimable tasks and POST /contribute/start delegates a chosen digest to the existing pull path', async () => {
  await withDaemon(async ({ base, children, coordinatorCalls, setConfig, setTaskListResponse }) => {
    const digest = 'a'.repeat(64);
    const tasks = [{
      task_digest: digest,
      display_id: 'Fix the login test',
      published_at: '2026-07-21T21:00:00.000Z',
      network: 'enabled',
      source: { base_artifact: { sha256: 'b'.repeat(64), bytes: 12, media_type: 'application/x-tar' } },
      prompt: { artifact: { sha256: 'c'.repeat(64), bytes: 8, media_type: 'text/plain' } },
    }];
    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token' });
    setTaskListResponse({ status: 200, body: tasks });

    const listed = await request(base, '/tasks', { token: 'test-session-token' });
    assert.equal(listed.status, 200);
    assert.deepEqual(JSON.parse(listed.text), tasks);
    assert.deepEqual(coordinatorCalls, [{
      url: 'http://coordinator.example/tasks',
      options: { headers: { authorization: 'Bearer collective-token' } },
    }]);

    const started = await request(base, '/contribute/start', {
      method: 'POST',
      token: 'test-session-token',
      body: { task_digest: digest },
    });
    assert.equal(started.status, 202);
    assert.deepEqual(children[0].args[1], [
      '/real/path/to/bin/waspflow-federation', 'contribute', '--task-digest', digest, '--json',
    ]);
    assert.deepEqual(JSON.parse(started.text).contribution, { selection: 'chosen', task_digest: digest, display_id: 'Fix the login test' });
    assert.deepEqual(statusBody(await request(base, '/status', { token: 'test-session-token' })).contribution, {
      selection: 'chosen', task_digest: digest, display_id: 'Fix the login test',
    });
  });
});

test('POST /join accepts an invite and shells out to the guided join verb', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    const response = await request(base, '/join', {
      method: 'POST',
      token: 'test-session-token',
      body: { invite: 'waspflow://join?coordinator=http%3A%2F%2Fcoordinator.example&token=invite-token&name=Oshin%27s%20Collective' },
    });
    assert.equal(response.status, 202);
    assert.deepEqual(children[0].args[1], ['/real/path/to/bin/waspflow-federation', 'join', 'http://coordinator.example', 'invite-token', '--collective-name', "Oshin's Collective", '--json']);
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
    parseJoinInvite('waspflow://join?coordinator=https%3A%2F%2Fcoordinator.example%2F&token=deep-token&name=Oshin%27s%20Collective'),
    { coordinatorUrl: 'https://coordinator.example', token: 'deep-token', collectiveName: "Oshin's Collective" },
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

test('openFederationUi uses cmd start with an empty title on Windows', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-ui-windows-'));
  const infoPath = join(directory, 'daemon.json');
  const daemon = await startFederationDaemon({ token: 'ui-session-token', infoPath, configLoader: () => null });
  const calls = [];
  try {
    const url = await openFederationUi({
      infoPath,
      platformName: 'win32',
      spawnProcess: (...args) => {
        calls.push(args);
        return { unref() {} };
      },
    });
    assert.deepEqual(calls, [['cmd.exe', ['/c', 'start', '', url], { detached: true, stdio: 'ignore' }]]);
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});
