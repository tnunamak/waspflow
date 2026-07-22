import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { startCoordinator } from '../lib/federation-coordinator.mjs';
import {
  createJoinInvite,
  ensureHostState,
  parseTunnel,
  readCollectiveToken,
  resolveLanUrl,
} from '../lib/federation-host.mjs';
import { NgrokUnavailableError, ngrokUnavailableGuidance, startNgrokTunnel } from '../lib/federation-coordinator-hosting.mjs';
import { parseJoinInvite } from '../lib/federation-daemon.mjs';

const execFileAsync = promisify(execFile);
const CLI = join(process.cwd(), 'bin', 'waspflow-federation');

test('host state is private and idempotent: its operator is the only initial roster member', async () => {
  const home = await mkdtemp(join(tmpdir(), 'wf-fed-host-'));
  try {
    const first = ensureHostState({ home, operatorKeyId: 'oshin', port: 9123 });
    const token = readCollectiveToken(first.config);
    const second = ensureHostState({ home, operatorKeyId: 'someone-else', port: 9999 });
    const roster = JSON.parse(await readFile(first.config.roster_path, 'utf8'));
    assert.deepEqual(Object.keys(roster), ['oshin']);
    assert.equal(readCollectiveToken(second.config), token, 'resume must not rotate collective access');
    assert.equal(second.config.operator_key_id, 'oshin');
    assert.equal(second.config.port, 9123);
    assert.equal((await stat(home)).mode & 0o777, 0o700);
    assert.equal((await stat(first.config.collective_token_path)).mode & 0o777, 0o600);
    assert.equal((await stat(first.config.operator_private_key_path)).mode & 0o777, 0o600);
    assert.equal((await stat(first.config.roster_path)).mode & 0o777, 0o600);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test('host reachability flags parse strictly and LAN uses the discovered local address', () => {
  assert.deepEqual(parseTunnel('ngrok'), { kind: 'ngrok' });
  assert.deepEqual(parseTunnel('lan'), { kind: 'lan' });
  assert.deepEqual(parseTunnel('url:https://collective.example/'), { kind: 'url', publicUrl: 'https://collective.example' });
  assert.throws(() => parseTunnel('url:http://not-secure.example'), /https origin/);
  assert.throws(() => parseTunnel('other'), /--tunnel must be/);
  assert.equal(resolveLanUrl({ port: 8787, networkInterfaces: { eth0: [{ family: 'IPv4', internal: false, address: '192.168.4.10' }] } }), 'http://192.168.4.10:8787');
});

test('join accepts HTTPS-fragment, legacy scheme, and two-argument invites', async () => {
  const coordinatorData = await mkdtemp(join(tmpdir(), 'wf-fed-host-coordinator-'));
  const memberHomes = await Promise.all(Array.from({ length: 3 }, () => mkdtemp(join(tmpdir(), 'wf-fed-host-member-'))));
  const roster = new Map([['operator', '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n-----END PUBLIC KEY-----\n']]);
  const server = await startCoordinator({ dataDir: coordinatorData, token: 'host-token', roster, port: 0 });
  try {
    const { port } = server.address();
    const invite = createJoinInvite({ coordinatorUrl: `http://127.0.0.1:${port}`, collectiveToken: 'host-token' });
    assert.equal(invite, `http://127.0.0.1:${port}/join#host-token`);
    assert.deepEqual(parseJoinInvite(invite), { coordinatorUrl: `http://127.0.0.1:${port}`, token: 'host-token' });
    assert.deepEqual(
      parseJoinInvite(`waspflow://join?coordinator=${encodeURIComponent(`http://127.0.0.1:${port}`)}&token=host-token&name=Oshin%20collective`),
      { coordinatorUrl: `http://127.0.0.1:${port}`, token: 'host-token', collectiveName: 'Oshin collective' },
    );
    await execFileAsync(process.execPath, [CLI, 'join', invite, '--key-id', 'member'], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHomes[0] },
    });
    await execFileAsync(process.execPath, [CLI, 'join', `waspflow://join?coordinator=${encodeURIComponent(`http://127.0.0.1:${port}`)}&token=host-token`, '--key-id', 'legacy'], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHomes[1] },
    });
    await execFileAsync(process.execPath, [CLI, 'join', `http://127.0.0.1:${port}`, 'host-token', '--key-id', 'two-arg'], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHomes[2] },
    });
    const config = JSON.parse(await readFile(join(memberHomes[0], 'config.json'), 'utf8'));
    assert.equal(config.coordinator_url, `http://127.0.0.1:${port}`);
    assert.equal(config.collective_token, 'host-token');
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(coordinatorData, { recursive: true, force: true });
    await Promise.all(memberHomes.map((home) => rm(home, { recursive: true, force: true })));
  }
});

test('host --rotate-token updates a running managed coordinator and fresh invites carry only the new token', async () => {
  const home = await mkdtemp(join(tmpdir(), 'wf-fed-host-rotate-'));
  const memberHome = await mkdtemp(join(tmpdir(), 'wf-fed-host-rotate-member-'));
  const state = ensureHostState({ home, port: 8787 });
  const roster = new Map(Object.entries(JSON.parse(await readFile(state.config.roster_path, 'utf8'))));
  const server = await startCoordinator({
    dataDir: state.config.data_dir,
    token: () => readCollectiveToken(state.config),
    roster,
    port: 0,
  });
  try {
    const { port } = server.address();
    await writeFile(state.config.status_path, JSON.stringify({ status: 'listening', port }), { mode: 0o600 });
    const oldToken = readCollectiveToken(state.config);
    const coordinatorUrl = `http://127.0.0.1:${port}`;
    await execFileAsync(process.execPath, [CLI, 'join', coordinatorUrl, oldToken, '--key-id', 'member'], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHome },
    });
    const { stdout } = await execFileAsync(process.execPath, [CLI, 'host', '--rotate-token'], {
      env: { ...process.env, WASPFLOW_FEDERATION_COORDINATOR_HOME: home },
    });
    const newToken = readCollectiveToken(state.config);
    assert.notEqual(newToken, oldToken);
    assert.equal(stdout, 'Collective token rotated; existing members must re-join with a new invite, and old invites are dead.\n');
    assert.equal((await fetch(`${coordinatorUrl}/tasks/next`, { headers: { authorization: `Bearer ${oldToken}` } })).status, 401);
    assert.equal((await fetch(`${coordinatorUrl}/tasks/next`, { headers: { authorization: `Bearer ${newToken}` } })).status, 200);
    assert.equal(createJoinInvite({ coordinatorUrl: `https://collective.example`, collectiveToken: newToken }), `https://collective.example/join#${newToken}`);
    await execFileAsync(process.execPath, [CLI, 'join', createJoinInvite({ coordinatorUrl, collectiveToken: newToken })], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHome },
    });
    assert.equal(JSON.parse(await readFile(join(memberHome, 'config.json'), 'utf8')).collective_token, newToken);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(home, { recursive: true, force: true });
    await rm(memberHome, { recursive: true, force: true });
  }
});

test('host --rotate-token rotates the file directly when the coordinator is not running', async () => {
  // A stopped coordinator has no live state to update — its token file is the
  // only token source at startup, so refusing here (the old behavior) just
  // trapped the operator with a leaked token and a stale status file.
  const home = await mkdtemp(join(tmpdir(), 'wf-fed-host-rotate-stopped-'));
  try {
    const state = ensureHostState({ home, port: 8787 });
    const oldToken = readCollectiveToken(state.config);
    const { stdout } = await execFileAsync(process.execPath, [CLI, 'host', '--rotate-token'], {
      env: { ...process.env, WASPFLOW_FEDERATION_COORDINATOR_HOME: home },
    });
    assert.match(stdout, /Collective token rotated\. Your coordinator is not running/);
    assert.match(stdout, /Old invites are dead/);
    assert.notEqual(readCollectiveToken(state.config), oldToken);
  } finally {
    await rm(home, { recursive: true, force: true });
  }
});

test('the coordinator tunnel uses an injected SDK and gives a guided fallback for unavailable native prebuilds', async () => {
  const forwarded = [];
  const tunnel = await startNgrokTunnel({
    port: 8787,
    authtoken: 'secret-token',
    loadSdk: () => ({ forward: async (options) => {
      forwarded.push(options);
      return { url: () => 'https://assigned.ngrok-free.app', close: async () => {} };
    } }),
  });
  assert.deepEqual(forwarded, [{ addr: '127.0.0.1:8787', authtoken: 'secret-token', proto: 'http' }]);
  assert.equal(tunnel.url, 'https://assigned.ngrok-free.app');
  await assert.rejects(
    startNgrokTunnel({ port: 8787, authtoken: 'secret-token', loadSdk: () => { throw new NgrokUnavailableError('unsupported platform'); } }),
    NgrokUnavailableError,
  );
  assert.match(ngrokUnavailableGuidance(), /Install the ngrok agent/);
});

test('the tunnel pins a previously assigned domain and falls back unpinned when ngrok rejects it', async () => {
  // Stable public URL across coordinator restarts: the recorded hostname is
  // passed as `domain`; a rejected pin retries unpinned rather than staying down.
  const forwarded = [];
  const pinned = await startNgrokTunnel({
    port: 8787,
    authtoken: 'secret-token',
    domain: 'quiet-otter.ngrok-free.dev',
    loadSdk: () => ({ forward: async (options) => {
      forwarded.push(options);
      return { url: () => `https://${options.domain}`, close: async () => {} };
    } }),
  });
  assert.equal(forwarded[0].domain, 'quiet-otter.ngrok-free.dev');
  assert.equal(pinned.url, 'https://quiet-otter.ngrok-free.dev');
  assert.ok(!pinned.domainFellBack);

  const attempts = [];
  const fallback = await startNgrokTunnel({
    port: 8787,
    authtoken: 'secret-token',
    domain: 'revoked.ngrok-free.dev',
    loadSdk: () => ({ forward: async (options) => {
      attempts.push(options);
      if (options.domain) throw new Error('domain not allowed for this account');
      return { url: () => 'https://fresh-crab.ngrok-free.dev', close: async () => {} };
    } }),
  });
  assert.equal(attempts.length, 2);
  assert.equal(attempts[1].domain, undefined);
  assert.equal(fallback.url, 'https://fresh-crab.ngrok-free.dev');
  assert.equal(fallback.domainFellBack, true);
  assert.match(fallback.domainError, /not allowed/);
});
