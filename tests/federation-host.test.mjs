import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises';
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

test('invite round-trips through both the existing UI parser and the join CLI unchanged', async () => {
  const coordinatorData = await mkdtemp(join(tmpdir(), 'wf-fed-host-coordinator-'));
  const memberHome = await mkdtemp(join(tmpdir(), 'wf-fed-host-member-'));
  const roster = new Map([['operator', '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n-----END PUBLIC KEY-----\n']]);
  const server = await startCoordinator({ dataDir: coordinatorData, token: 'host-token', roster, port: 0 });
  try {
    const { port } = server.address();
    const invite = createJoinInvite({ coordinatorUrl: `http://127.0.0.1:${port}`, collectiveToken: 'host-token', collectiveName: 'Oshin collective' });
    assert.deepEqual(parseJoinInvite(invite), { coordinatorUrl: `http://127.0.0.1:${port}`, token: 'host-token', collectiveName: 'Oshin collective' });
    await execFileAsync(process.execPath, [CLI, 'join', invite, '--key-id', 'member'], {
      env: { ...process.env, WASPFLOW_FEDERATION_HOME: memberHome },
    });
    const config = JSON.parse(await readFile(join(memberHome, 'config.json'), 'utf8'));
    assert.equal(config.coordinator_url, `http://127.0.0.1:${port}`);
    assert.equal(config.collective_token, 'host-token');
    assert.equal(config.collective_name, 'Oshin collective');
  } finally {
    await new Promise((resolve) => server.close(resolve));
    await rm(coordinatorData, { recursive: true, force: true });
    await rm(memberHome, { recursive: true, force: true });
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
