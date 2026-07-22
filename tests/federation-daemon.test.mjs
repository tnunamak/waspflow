import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { statSync } from 'node:fs';
import { mkdtemp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { request as httpRequest } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openFederationUi, parseJoinInvite, startFederationDaemon } from '../lib/federation-daemon.mjs';
import { configHome } from '../lib/federation-config.mjs';

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

async function withDaemon(fn, daemonOptions = {}) {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-daemon-'));
  const ledgerPath = join(directory, 'ledger.json');
  const settingsPath = join(directory, 'settings.json');
  const logsDir = join(directory, 'logs');
  const sourcePath = join(directory, 'source');
  await mkdir(sourcePath);
  let config = null;
  const children = [];
  const coordinatorCalls = [];
  let taskListResponse = { status: 200, body: [] };
  const daemon = await startFederationDaemon({
    token: 'test-session-token',
    infoPath: join(directory, 'daemon.json'),
    ledgerPath,
    settingsPath,
    logsDir,
    cliPath: '/real/path/to/bin/waspflow-federation',
    configLoader: () => config,
    spawnProcess: (...args) => {
      const child = fakeChild();
      children.push({ args, child });
      return child;
    },
    fetchImpl: async (url, requestOptions) => {
      coordinatorCalls.push({ url, options: requestOptions });
      if (daemonOptions.fetchImpl) return daemonOptions.fetchImpl(url, requestOptions);
      return new Response(JSON.stringify(taskListResponse.body), {
        status: taskListResponse.status,
        headers: { 'content-type': 'application/json' },
      });
    },
    startDockerLogin: daemonOptions.startDockerLogin,
    startProviderSignIn: daemonOptions.startProviderSignIn,
    identityProbe: daemonOptions.identityProbe || (async () => ({ docker_account: null, providers: [] })),
    now: daemonOptions.now,
  });
  const base = `http://127.0.0.1:${daemon.info.port}`;
  try {
    await fn({
      base,
      daemon,
      children,
      coordinatorCalls,
      ledgerPath,
      settingsPath,
      logsDir,
      sourcePath,
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
    assert.equal(pending.detail, 'Waiting for the collective owner to approve this machine. No work can start until then.');
    const blocked = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    assert.equal(blocked.status, 409);
    assert.equal(JSON.parse(blocked.text).error, 'Waiting for the collective owner to approve this machine. No work can start until then.');

    approved = true;
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'idle');
    approved = false;
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'approval_revoked');
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
      receipt: {
        schema_version: 1, task_digest: 'a'.repeat(64), harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5',
        usage: { input_tokens: 12, output_tokens: 4 }, duration_ms: 1200,
        started_at: '2026-07-21T10:00:00.000Z', finished_at: '2026-07-21T10:00:01.200Z', sandbox_id: 'wf-123',
        identities: { docker_account: 'oshin', provider_account: { email: 'oshin@example.test', tier: 'max' } },
      },
    }) + '\n'));
    children[0].child.emit('close', 0);

    const ledger = await request(base, '/ledger', { token: 'test-session-token' });
    assert.equal(ledger.status, 200);
    const entries = JSON.parse(ledger.text);
    assert.equal(entries.length, 1);
    assert.deepEqual(entries[0], {
      display_id: 'Fix onboarding', coordinator: 'http://coordinator.example', outcome: 'completed', status: 'Completed', started_at: entries[0].started_at, finished_at: entries[0].finished_at,
      task_digest: 'a'.repeat(64),
      task_reference: 'a'.repeat(64),
      receipt: {
        schema_version: 1, task_digest: 'a'.repeat(64), harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5',
        usage: { input_tokens: 12, output_tokens: 4 }, duration_ms: 1200,
        started_at: '2026-07-21T10:00:00.000Z', finished_at: '2026-07-21T10:00:01.200Z', sandbox_id: 'wf-123',
        identities: { docker_account: 'oshin', provider_account: { email: 'oshin@example.test', tier: 'max' } },
      },
    });
    const status = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.deepEqual(status.ledger_summary, { count_7d: 1, last: { display_id: 'Fix onboarding', finished_at: entries[0].finished_at } });
    assert.deepEqual(status.last_completed, entries[0]);
    assert.equal(entries[0].receipt.identities.provider_account.email, 'oshin@example.test');
    assert.equal((await stat(ledgerPath)).mode & 0o777, 0o600);
    assert.deepEqual(JSON.parse(await readFile(ledgerPath, 'utf8')), entries);
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('GET /ledger returns completed entries newest first', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-federation-ledger-order-'));
  const ledgerPath = join(directory, 'ledger.json');
  await (await import('node:fs/promises')).writeFile(ledgerPath, JSON.stringify([
    { display_id: 'First', finished_at: '2026-07-21T10:00:00.000Z' },
    { display_id: 'Second', finished_at: '2026-07-21T11:00:00.000Z' },
  ]));
  const daemon = await startFederationDaemon({ token: 'test-session-token', infoPath: join(directory, 'daemon.json'), ledgerPath, configLoader: () => null });
  try {
    const response = await request(`http://127.0.0.1:${daemon.info.port}`, '/ledger', { token: 'test-session-token' });
    assert.deepEqual(JSON.parse(response.text).map((entry) => entry.display_id), ['Second', 'First']);
  } finally {
    await daemon.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test('identity, task detail, and verified result endpoints keep identities private and cache identity probes', async () => {
  const digest = 'a'.repeat(64);
  const artifactBytes = Buffer.from('result artifact bytes');
  const artifactDigest = (await import('node:crypto')).createHash('sha256').update(artifactBytes).digest('hex');
  const receipt = {
    schema_version: 1, task_digest: digest, harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5',
    usage: { input_tokens: 12, output_tokens: 4 }, duration_ms: 1200,
    started_at: '2026-07-21T10:00:00.000Z', finished_at: '2026-07-21T10:00:01.200Z', sandbox_id: 'wf-private',
    identities: { docker_account: 'oshin', provider_account: { email: 'oshin@example.test', tier: 'max' } },
  };
  const task = {
    task_digest: digest, status: 'SETTLED', display_id: 'Fix receipt UI', author: 'tim',
    published_at: '2026-07-21T09:00:00.000Z', claimed_at: '2026-07-21T10:00:00.000Z', settled_at: '2026-07-21T10:00:02.000Z',
    result_envelope: { payload: { candidate: { artifact: { sha256: artifactDigest, media_type: 'application/gzip' } }, execution_metadata: { harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5', usage: { input_tokens: 12, output_tokens: 4 }, duration_ms: 1200 } } },
  };
  let identityCalls = 0;
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token', key_id: 'oshin', collective_name: 'Friends' });
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'idle');
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({ schema_version: 1, type: 'contributed', status: 'settled', task_digest: digest, receipt }) + '\n'));
    children[0].child.emit('close', 0);

    const firstIdentity = await request(base, '/identity', { token: 'test-session-token' });
    const secondIdentity = await request(base, '/identity', { token: 'test-session-token' });
    assert.deepEqual(JSON.parse(firstIdentity.text), {
      docker_account: 'oshin', docker_status: 'detected', providers: [{ service: 'anthropic', capacity_kind: 'subscription', account_email: 'oshin@example.test', tier: 'max', authed: true }],
      key_id: 'oshin', coordinator_url: 'http://coordinator.example', collective_name: 'Friends', refreshing: false,
    });
    assert.equal(identityCalls, 1);
    assert.equal(secondIdentity.status, 200);

    const detail = await request(base, `/tasks/${digest}`, { token: 'test-session-token' });
    const detailBody = JSON.parse(detail.text);
    assert.deepEqual(detailBody.receipt, receipt);
    assert.deepEqual(detailBody.execution_metadata, task.result_envelope.payload.execution_metadata);
    assert.equal(JSON.stringify(detailBody.execution_metadata).includes('oshin@example.test'), false);

    const result = await request(base, `/result/${digest}`, { token: 'test-session-token' });
    assert.equal(result.status, 200);
    assert.equal(result.text, artifactBytes.toString('utf8'));
  }, {
    identityProbe: async () => {
      identityCalls += 1;
      return { docker_account: 'oshin', providers: [{ service: 'anthropic', capacity_kind: 'subscription', account_email: 'oshin@example.test', tier: 'max', authed: true }] };
    },
    fetchImpl: async (url) => {
      if (url.endsWith('/roster')) return new Response(JSON.stringify({ roster: [{ key_id: 'oshin' }] }), { status: 200, headers: { 'content-type': 'application/json' } });
      if (url.endsWith(`/tasks/${digest}`)) return new Response(JSON.stringify(task), { status: 200, headers: { 'content-type': 'application/json' } });
      if (url.endsWith(`/artifacts/${artifactDigest}`)) return new Response(artifactBytes, { status: 200 });
      return new Response(JSON.stringify({ error: 'not found' }), { status: 404, headers: { 'content-type': 'application/json' } });
    },
  });
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

    const pausing = statusBody(await request(base, '/contribute/pause', { method: 'POST', token }));
    assert.equal(pausing.state, 'pausing');
    assert.equal(children[0].child.killed, undefined);
    children[0].child.emit('close', 0);
    assert.equal(statusBody(await request(base, '/status', { token })).state, 'paused');

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
    assert.deepEqual(actionNeeded.action, { kind: 'awaiting_browser', service: 'codex', url: 'https://auth.example/login' });

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
    assert.deepEqual(manualAction.action, { kind: 'auth_required_manual', service: 'claude', instruction: 'Run the supplied login command.' });

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

test('Docker device sign-in becomes an awaiting_browser action with its code, then automatically resumes contribution', async () => {
  let completeLogin;
  const loginDone = new Promise((resolve) => { completeLogin = resolve; });
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1,
      type: 'sandbox_preflight',
      status: 'setup_required',
      backend_id: 'docker-sbx',
      checks: [{ name: 'docker_login', ok: false, detail: "The sandbox service isn't signed in to Docker yet.", fix: 'sbx login' }],
    }) + '\n'));
    children[0].child.emit('close', 1);

    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).action?.code === 'XQZN-BWCH');
    const awaitingBrowser = statusBody(await request(base, '/status', { token: 'test-session-token' }));
    assert.deepEqual(awaitingBrowser.action, {
      kind: 'awaiting_browser',
      url: 'https://login.docker.com/activate?user_code=XQZN-BWCH',
      code: 'XQZN-BWCH',
    });

    completeLogin({ status: 'complete' });
    await waitFor(() => children.length === 2);
    assert.deepEqual(children[1].args[1], ['/real/path/to/bin/waspflow-federation', 'contribute', '--json']);
    children[1].child.stdout.emit('data', Buffer.from(JSON.stringify({
      schema_version: 1, type: 'contributed', status: 'settled', task_digest: 'a'.repeat(64),
    }) + '\n'));
    children[1].child.emit('close', 0);
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).state, 'idle');
  }, {
    startDockerLogin: async () => ({
      url: 'https://login.docker.com/activate?user_code=XQZN-BWCH',
      code: 'XQZN-BWCH',
      cancel: () => {},
      waitForCompletion: () => loginDone,
    }),
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
    assert.deepEqual(waiting.action, { kind: 'awaiting_browser', service: 'claude-code-subscription', url: 'https://claude.com/cai/oauth/authorize?state=abc' });
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
    assert.deepEqual(JSON.parse(listed.text), [{ ...tasks[0], source_bytes: 12 }]);
    assert.deepEqual(coordinatorCalls, [
      { url: 'http://coordinator.example/tasks', options: { headers: { authorization: 'Bearer collective-token' } } },
      { url: `http://coordinator.example/artifacts/${'c'.repeat(64)}`, options: { headers: { authorization: 'Bearer collective-token' } } },
    ]);

    const started = await request(base, '/contribute/start', {
      method: 'POST',
      token: 'test-session-token',
      body: { task_digest: digest },
    });
    assert.equal(started.status, 202);
    assert.deepEqual(children[0].args[1], [
      '/real/path/to/bin/waspflow-federation', 'contribute', '--task-digest', digest, '--json',
    ]);
    assert.deepEqual(JSON.parse(started.text).contribution, { selection: 'chosen', task_digest: digest, display_id: 'Fix the login test', started_at: JSON.parse(started.text).contribution.started_at });
    const activeContribution = statusBody(await request(base, '/status', { token: 'test-session-token' })).contribution;
    assert.deepEqual(activeContribution, { selection: 'chosen', task_digest: digest, display_id: 'Fix the login test', started_at: activeContribution.started_at });
  });
});

test('schedule settings persist behind the daemon token and roster is a token-gated coordinator passthrough', async () => {
  await withDaemon(async ({ base, coordinatorCalls, setConfig, setTaskListResponse, settingsPath }) => {
    const settings = await request(base, '/settings', { method: 'POST', token: 'test-session-token', body: {
      schedule: { enabled: true, start: '18:00', end: '08:00', days: 'Weekdays', timezone: 'Australia/Brisbane' },
    } });
    assert.equal(settings.status, 200);
    assert.deepEqual(JSON.parse(settings.text), { schedule: { enabled: true, start: '18:00', end: '08:00', days: 'Weekdays', timezone: 'Australia/Brisbane' } });
    assert.deepEqual(JSON.parse((await request(base, '/settings', { token: 'test-session-token' })).text), JSON.parse(settings.text));
    assert.equal((await stat(settingsPath)).mode & 0o777, 0o600);

    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-secret' });
    setTaskListResponse({ status: 200, body: { roster: [{ key_id: 'oshin', public_key_pem: 'PUBLIC KEY' }] } });
    const roster = await request(base, '/roster', { token: 'test-session-token' });
    assert.equal(roster.status, 200, roster.text);
    assert.deepEqual(JSON.parse(roster.text), { roster: [{ key_id: 'oshin', public_key_pem: 'PUBLIC KEY' }] });
    assert.ok(coordinatorCalls.some((call) => call.url === 'http://coordinator.example/roster' && call.options.headers.authorization === 'Bearer collective-secret'));
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
  await withDaemon(async ({ base, children, setConfig, sourcePath }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const response = await request(base, '/submit', {
      method: 'POST',
      token: 'test-session-token',
      body: { source: sourcePath, prompt: 'Fix the test failure.', display_id: 'oshin' },
    });
    assert.equal(response.status, 202);
    assert.deepEqual(children[0].args[1], [
      '/real/path/to/bin/waspflow-federation', 'submit', '--display-id', 'oshin',
      '--source', sourcePath, '--prompt', 'Fix the test failure.', '--network', 'disabled',
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

test('POST /submit accepts a prompt-only request by packaging a temporary empty workspace', async () => {
  await withDaemon(async ({ base, children, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const response = await request(base, '/submit', {
      method: 'POST',
      token: 'test-session-token',
      body: { source: '', prompt: 'Write a plan without project files.', display_id: 'Prompt only' },
    });
    assert.equal(response.status, 202, response.text);
    const args = children[0].args[1];
    const sourceIndex = args.indexOf('--source');
    assert.match(args[sourceIndex + 1], /waspflow-federation-empty-source-/);
    assert.equal(statSync(args[sourceIndex + 1]).isDirectory(), true);
    children[0].child.emit('close', 1);
    await waitFor(async () => {
      try { statSync(args[sourceIndex + 1]); return false; } catch { return true; }
    });
  });
});

test('POST /identity/signin exposes the existing browser auth handoff for an unauthenticated provider', async () => {
  let finish;
  const completion = new Promise((resolve) => { finish = resolve; });
  await withDaemon(async ({ base, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const response = await request(base, '/identity/signin', { method: 'POST', token: 'test-session-token', body: { service: 'anthropic' } });
    assert.equal(response.status, 202, response.text);
    const body = JSON.parse(response.text);
    assert.equal(body.state, 'action_needed');
    assert.deepEqual(body.action, { kind: 'awaiting_browser', service: 'anthropic', url: 'https://auth.example/signin', code: 'ABCD-EFGH' });
    finish({ status: 'complete', detail: 'signed in' });
    await waitFor(async () => statusBody(await request(base, '/status', { token: 'test-session-token' })).state === 'idle');
  }, { startProviderSignIn: async () => ({ status: 'awaiting-browser', url: 'https://auth.example/signin', code: 'ABCD-EFGH', waitForCompletion: async () => completion, cancel() {} }) });
});

test('a private GitHub task is gated before contribution and the daemon exposes the GitHub browser handoff', async () => {
  const deviceFlow = {
    url: 'https://github.com/login/device', code: 'TEST-1234', status: 'awaiting-browser',
    cancel() {}, waitForCompletion: async () => ({ status: 'failed', detail: 'not completed in test' }),
  };
  await withDaemon(async ({ base, setConfig, setTaskListResponse }) => {
    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token' });
    setTaskListResponse({ status: 200, body: [{
      task_digest: 'a'.repeat(64), display_id: 'private repo', author: 'tim', network: 'enabled',
      git_source: { url: 'https://github.com/octocat/Hello-World.git', authentication_required: true },
      prompt: 'work from repo', source: { base_artifact: { bytes: 0 } },
    }] });
    const tasks = await request(base, '/tasks', { token: 'test-session-token' });
    assert.equal(tasks.status, 200, tasks.text);
    const blocked = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token', body: { task_digest: 'a'.repeat(64) } });
    assert.equal(blocked.status, 409);
    assert.match(JSON.parse(blocked.text).error, /Set up GitHub access in Settings/);
    const signIn = await request(base, '/identity/signin', { method: 'POST', token: 'test-session-token', body: { service: 'github' } });
    assert.equal(signIn.status, 202, signIn.text);
    assert.equal(JSON.parse(signIn.text).action.code, 'TEST-1234');
  }, {
    identityProbe: async () => ({ docker_account: null, providers: [{ service: 'github', capacity_kind: 'n/a', authed: false }] }),
    startProviderSignIn: async (service) => { assert.equal(service, 'github'); return deviceFlow; },
  });
});

test('a public GitHub task may start without GitHub task access', async () => {
  const digest = 'b'.repeat(64);
  await withDaemon(async ({ base, children, setConfig, setTaskListResponse }) => {
    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token' });
    setTaskListResponse({ status: 200, body: [{
      task_digest: digest, display_id: 'public repo', author: 'tim', network: 'enabled',
      git_source: { url: 'https://github.com/octocat/Hello-World.git' },
      prompt: 'work from repo', source: { base_artifact: { bytes: 0 } },
    }] });
    await request(base, '/tasks', { token: 'test-session-token' });
    const response = await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token', body: { task_digest: digest } });
    assert.equal(response.status, 202, response.text);
    assert.equal(children.length, 1);
  }, {
    identityProbe: async () => ({ docker_account: null, providers: [{ service: 'github', capacity_kind: 'n/a', authed: false }] }),
  });
});

test('provider sign-in replaces a stale flow and returns a clear UI state instead of a gateway error', async () => {
  let starts = 0;
  let cancelled = 0;
  await withDaemon(async ({ base, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const first = await request(base, '/identity/signin', { method: 'POST', token: 'test-session-token', body: { service: 'openai' } });
    assert.equal(first.status, 202, first.text);
    const replacement = await request(base, '/identity/signin', { method: 'POST', token: 'test-session-token', body: { service: 'openai' } });
    assert.equal(replacement.status, 202, replacement.text);
    assert.equal(cancelled, 1, 'the stale auth listener must be cancelled before retrying');
  }, { startProviderSignIn: async () => ({ status: 'awaiting-browser', url: `https://auth.example/${++starts}`, waitForCompletion: async () => new Promise(() => {}), cancel() { cancelled += 1; } }) });

  await withDaemon(async ({ base, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    const response = await request(base, '/identity/signin', { method: 'POST', token: 'test-session-token', body: { service: 'openai' } });
    assert.equal(response.status, 202, response.text);
    const body = JSON.parse(response.text);
    assert.equal(body.state, 'idle');
    assert.match(body.detail, /OpenAI sign-in could not start/);
  }, { startProviderSignIn: async () => { throw new Error('the sandbox is still starting'); } });
});

test('contribution output is stored as a token-gated bounded local execution log', async () => {
  const digest = 'a'.repeat(64);
  await withDaemon(async ({ base, children, logsDir, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token', body: { task_digest: digest } });
    children[0].child.stdout.emit('data', Buffer.alloc(300 * 1024, 'x'));
    children[0].child.stdout.emit('data', Buffer.from('{"schema_version":1,"type":"contributed","status":"settled","task_digest":"' + digest + '"}\n'));
    children[0].child.stderr.emit('data', Buffer.from('harness progress\n'));
    children[0].child.emit('close', 0);
    const log = await request(base, `/tasks/${digest}/log`, { token: 'test-session-token' });
    assert.equal(log.status, 200, log.text);
    const logBody = JSON.parse(log.text);
    assert.match(logBody.output, /harness progress/);
    assert.equal(logBody.truncated, true);
    const logStat = statSync(join(logsDir, `${digest}.log`));
    assert.equal(logStat.mode & 0o777, 0o600);
    assert.ok(logStat.size <= 256 * 1024, 'the persisted transcript must stay bounded');
    assert.equal((await request(base, `/tasks/${digest}/log`, { token: 'wrong-token' })).status, 401);
  });
});

test('agent transcript events are persisted incrementally and support offset tails', async () => {
  const digest = 'b'.repeat(64);
  await withDaemon(async ({ base, children, logsDir, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example' });
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token', body: { task_digest: digest } });
    const raw = '{"type":"assistant","message":{"content":"I am inspecting the test."}}\n';
    children[0].child.stdout.emit('data', Buffer.from(JSON.stringify({ schema_version: 1, type: 'agent_transcript_event', task_digest: digest, stream: 'stdout', raw }) + '\n'));
    const first = await request(base, `/tasks/${digest}/log?since=0`, { token: 'test-session-token' });
    const firstBody = JSON.parse(first.text);
    assert.equal(firstBody.transcript, true);
    assert.match(firstBody.output, /I am inspecting the test/);
    const second = await request(base, `/tasks/${digest}/log?since=${firstBody.next_offset}`, { token: 'test-session-token' });
    assert.equal(JSON.parse(second.text).output, '');
    assert.equal(statSync(join(logsDir, `${digest}.transcript.jsonl`)).mode & 0o777, 0o600);
  });
});

test('settings persist a locally edited collective name without changing the invite-backed identity contract', async () => {
  await withDaemon(async ({ base, setConfig }) => {
    setConfig({ coordinator_url: 'http://coordinator.example', collective_name: 'Invite collective' });
    const response = await request(base, '/settings', {
      method: 'POST', token: 'test-session-token', body: { collective_name: 'Local collective', schedule: { enabled: false, start: '', end: '', days: '', timezone: '' } },
    });
    assert.deepEqual(JSON.parse(response.text), { collective_name: 'Local collective', schedule: { enabled: false, start: '', end: '', days: '', timezone: '' } });
    assert.equal(JSON.parse((await request(base, '/status', { token: 'test-session-token' })).text).collective_name, 'Local collective');
  });
});

test('daemon refuses the real ledger path under a Node test context', async () => {
  await assert.rejects(
    startFederationDaemon({
      token: 'test-session-token',
      ledgerPath: join(configHome(), 'ledger.json'),
      environment: { NODE_TEST_CONTEXT: 'tests/federation-daemon.test.mjs' },
    }),
    /refusing to use the real Federation ledger/,
  );
});

test('GET /identity returns cached or partial data immediately while a slow probe refreshes in the background', async () => {
  let release;
  const probe = new Promise((resolve) => { release = resolve; });
  await withDaemon(async ({ base }) => {
    const started = Date.now();
    const response = await request(base, '/identity', { token: 'test-session-token' });
    assert.ok(Date.now() - started < 100, 'identity response must not await its probe');
    assert.deepEqual(JSON.parse(response.text), { docker_account: null, docker_status: 'checking', providers: [], key_id: null, coordinator_url: null, refreshing: true });
    release({ docker_account: 'oshin', providers: [] });
    await waitFor(async () => JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text).docker_account === 'oshin');
  }, { identityProbe: () => probe });
});

test('GET /identity reports a failed Docker probe separately from an empty cache', async () => {
  await withDaemon(async ({ base }) => {
    await waitFor(async () => JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text).docker_status === 'failed');
    const identity = JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text);
    assert.equal(identity.docker_account, null);
    assert.equal(identity.docker_status, 'failed');
  }, { identityProbe: async () => { throw new Error('docker unavailable'); } });
});

test('identity keeps a last-confirmed provider through probe gaps and requires three negatives before sign-in is shown', async () => {
  let current = Date.parse('2026-07-22T00:00:00.000Z');
  const observations = [
    { docker_account: 'ocean', providers: [{ service: 'anthropic', authed: true, capacity_kind: 'subscription' }] },
    new Error('probe restart'),
    { docker_account: 'ocean', providers: [{ service: 'anthropic', authed: false, capacity_kind: 'subscription' }] },
    { docker_account: 'ocean', providers: [{ service: 'anthropic', authed: false, capacity_kind: 'subscription' }] },
    { docker_account: 'ocean', providers: [{ service: 'anthropic', authed: false, capacity_kind: 'subscription' }] },
  ];
  await withDaemon(async ({ base }) => {
    await waitFor(async () => JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text).providers[0]?.authed === true);
    for (let attempt = 0; attempt < 4; attempt += 1) {
      current += 61_000;
      await request(base, '/identity', { token: 'test-session-token' });
      await waitFor(async () => {
        const account = JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text).providers[0];
        return attempt < 3 ? account?.checking === true : account?.authed === false;
      });
      const account = JSON.parse((await request(base, '/identity', { token: 'test-session-token' })).text).providers[0];
      if (attempt < 3) assert.equal(account.authed, true, 'a transient negative must not erase the confirmed sign-in');
    }
  }, {
    now: () => new Date(current),
    identityProbe: async () => {
      const next = observations.shift();
      if (next instanceof Error) throw next;
      return next;
    },
  });
});

test('GET /requests returns only the local author history and merges the active local submission', async () => {
  const digest = 'a'.repeat(64);
  await withDaemon(async ({ base, children, setConfig, sourcePath, coordinatorCalls }) => {
    setConfig({ coordinator_url: 'http://coordinator.example', collective_token: 'collective-token', key_id: 'tim-author' });
    const response = await request(base, '/submit', { method: 'POST', token: 'test-session-token', body: { source: sourcePath, prompt: 'Fix it', display_id: 'Local request' } });
    assert.equal(response.status, 202);
    children[0].child.stdout.emit('data', Buffer.from(`task_digest=sha256:${digest} status=QUEUED\n`));
    const requests = await request(base, '/requests', { token: 'test-session-token' });
    assert.deepEqual(JSON.parse(requests.text), [{ task_digest: `sha256:${digest}`, display_id: 'Local request', status: 'queued', published_at: null, has_result: false }]);
    assert.ok(coordinatorCalls.some((call) => call.url === 'http://coordinator.example/requests?author=tim-author'));
  }, { fetchImpl: async (url) => {
    if (url.endsWith('/roster')) return new Response(JSON.stringify({ roster: [{ key_id: 'tim-author' }] }), { status: 200 });
    if (url.includes('/requests?')) return new Response(JSON.stringify([{ task_digest: 'b'.repeat(64), author: 'other', display_id: 'Not mine', status: 'SETTLED', published_at: '2026-07-21T00:00:00.000Z', has_result: true }]), { status: 200 });
    return new Response(JSON.stringify([]), { status: 200 });
  } });
});

test('daemon serves a token-exempt favicon and surfaces child stderr for contribution and submission failures', async () => {
  await withDaemon(async ({ base, children, setConfig, sourcePath }) => {
    const icon = await request(base, '/favicon.ico');
    assert.equal(icon.status, 204);
    setConfig({ coordinator_url: 'http://coordinator.example' });
    await request(base, '/contribute/start', { method: 'POST', token: 'test-session-token' });
    children[0].child.stderr.emit('data', Buffer.from('first detail\nactual contribution failure\n'));
    children[0].child.emit('close', 1);
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).detail, 'actual contribution failure');
    await request(base, '/submit', { method: 'POST', token: 'test-session-token', body: { source: sourcePath, prompt: 'Fix it', display_id: 'Broken request' } });
    children[1].child.stderr.emit('data', Buffer.from('actual submission failure\n'));
    children[1].child.emit('close', 1);
    assert.equal(statusBody(await request(base, '/status', { token: 'test-session-token' })).submission.detail, 'actual submission failure');
    const invalid = await request(base, '/submit', { method: 'POST', token: 'test-session-token', body: { source: join(sourcePath, 'missing'), prompt: 'Fix it', display_id: 'Missing folder' } });
    assert.equal(invalid.status, 400);
    assert.match(JSON.parse(invalid.text).error, /source folder does not exist/);
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
  const daemon = await startFederationDaemon({ token: 'ui-session-token', infoPath, ledgerPath: join(directory, 'ledger.json'), configLoader: () => null });
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
  const daemon = await startFederationDaemon({ token: 'ui-session-token', infoPath, ledgerPath: join(directory, 'ledger.json'), configLoader: () => null });
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
