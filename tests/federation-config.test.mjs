import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Every test gets its own WASPFLOW_FEDERATION_HOME so config.json writes
// never touch the real ~/.waspflow/federation/ used by an actual joined
// collective member on this machine.
async function withConfigHome(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-federation-config-'));
  const prior = process.env.WASPFLOW_FEDERATION_HOME;
  process.env.WASPFLOW_FEDERATION_HOME = dir;
  try {
    // Re-import isn't needed: configHome() reads process.env at call time,
    // not at module-load time (matching federation-docker-backend.mjs's own
    // "read at call time" pattern for WASPFLOW_SBX_BIN), so importing the
    // module once at file scope is safe across differently-homed tests.
    const mod = await import('../lib/federation-config.mjs');
    await fn(mod, dir);
  } finally {
    if (prior === undefined) delete process.env.WASPFLOW_FEDERATION_HOME;
    else process.env.WASPFLOW_FEDERATION_HOME = prior;
    await rm(dir, { recursive: true, force: true });
  }
}

test('loadConfig returns null when join has never been run', async () => {
  await withConfigHome(async ({ loadConfig }) => {
    assert.equal(loadConfig(), null);
  });
});

test('requireConfig throws a clear "run join first" message when absent', async () => {
  await withConfigHome(async ({ requireConfig, FederationConfigError }) => {
    assert.throws(() => requireConfig(), (error) => {
      assert.ok(error instanceof FederationConfigError);
      assert.match(error.message, /Run 'waspflow federation join/);
      return true;
    });
  });
});

test('saveConfig then loadConfig round-trips exactly', async () => {
  await withConfigHome(async ({ saveConfig, loadConfig }) => {
    const config = { coordinator_url: 'http://example.test:8787', collective_token: 'tok', key_id: 'tim-author', private_key_path: '/tmp/x.pem' };
    saveConfig(config);
    assert.deepEqual(loadConfig(), config);
  });
});

test('saveConfig writes config.json with owner-only permissions (0600)', async () => {
  await withConfigHome(async ({ saveConfig, configPath }) => {
    saveConfig({ coordinator_url: 'http://x', collective_token: 't', key_id: 'k', private_key_path: '/tmp/k.pem' });
    const info = await stat(configPath());
    assert.equal(info.mode & 0o777, 0o600);
  });
});

test('loadConfig rejects non-JSON config.json with a clear error rather than crashing raw', async () => {
  await withConfigHome(async ({ loadConfig, configHome, FederationConfigError }) => {
    const { writeFile, mkdir } = await import('node:fs/promises');
    await mkdir(configHome(), { recursive: true });
    await writeFile(join(configHome(), 'config.json'), 'not json{{{');
    assert.throws(() => loadConfig(), (error) => {
      assert.ok(error instanceof FederationConfigError);
      assert.match(error.message, /not valid JSON/);
      return true;
    });
  });
});

test('generateAndStoreKeypair writes a private key (0600) and public key usable by federation-envelope signEnvelope/verifyEnvelope', async () => {
  await withConfigHome(async ({ generateAndStoreKeypair }) => {
    const { privateKeyPath, publicKeyPath, privateKeyPem, publicKeyPem } = generateAndStoreKeypair('tim-author');

    assert.match(privateKeyPem, /BEGIN PRIVATE KEY/);
    assert.match(publicKeyPem, /BEGIN PUBLIC KEY/);
    assert.equal(await readFile(privateKeyPath, 'utf8'), privateKeyPem);
    assert.equal(await readFile(publicKeyPath, 'utf8'), publicKeyPem);

    const privateInfo = await stat(privateKeyPath);
    assert.equal(privateInfo.mode & 0o777, 0o600);

    // Prove the generated key is actually usable by the real envelope
    // module, not merely PEM-shaped — sign with the private key this
    // function wrote, verify with the public key it wrote alongside it.
    const { verifyEnvelope } = await import('../lib/federation-envelope.mjs');
    const { buildTaskPayload, signTaskEnvelope } = await import('../lib/federation-submit.mjs');
    const payload = buildTaskPayload({
      collective: 'test',
      displayId: 'x',
      authorKeyId: 'tim-author',
      source: { sha256: 'a'.repeat(64), bytes: 1, media_type: 'application/x-tar' },
      prompt: { sha256: 'b'.repeat(64), bytes: 1, media_type: 'text/markdown' },
    });
    const envelope = signTaskEnvelope(payload, privateKeyPem, 'tim-author');
    const verification = verifyEnvelope(envelope, publicKeyPem);
    assert.equal(verification.kind, 'task');
  });
});

test('generateAndStoreKeypair produces distinct keys for distinct key_ids (never reuses a keypair across identities)', async () => {
  await withConfigHome(async ({ generateAndStoreKeypair }) => {
    const a = generateAndStoreKeypair('tim-author');
    const b = generateAndStoreKeypair('ocean-executor');
    assert.notEqual(a.privateKeyPem, b.privateKeyPem);
    assert.notEqual(a.publicKeyPem, b.publicKeyPem);
  });
});
