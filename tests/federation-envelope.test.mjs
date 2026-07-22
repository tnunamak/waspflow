import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, symlink, writeFile, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { jcs, parseCanonicalEnvelope, signEnvelope, verifyEnvelope, payloadDigest, EnvelopeError } from '../lib/federation-envelope.mjs';

const keys = generateKeyPairSync('ed25519');
const privateKey = keys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const publicKey = keys.publicKey.export({ type: 'spki', format: 'pem' });
const artifact = (hex = 'a') => ({ sha256: hex.repeat(64), bytes: 12, media_type: 'text/plain' });
const task = () => ({ schema: 'waspflow.federation.task.v0', collective: 'test', display_id: 'golden', author_key: 'ed25519:test', created_at: '2026-07-18T00:00:00Z', expires_at: '2030-07-18T00:00:00Z', source: { base_artifact: artifact('a'), base_revision: 'git:sha1:display-only' }, prompt: { artifact: artifact('b') }, network: 'enabled', oracle_ref: null, result_verdict: null, settlement: null });
const result = (digest) => ({ schema: 'waspflow.federation.result.v0', task_digest: `sha256:${digest}`, executor_key: 'ed25519:executor', submitted_at: '2026-07-18T01:00:00Z', candidate: { artifact: artifact('c'), tree_digest: `sha256:${'d'.repeat(64)}` }, oracle_ref: null, result_verdict: null, settlement: null });

test('golden task vector has stable JCS digest and domain-separated signature', () => {
  const payload = task(); const envelope = signEnvelope(payload, privateKey, 'author-1');
  assert.equal(payloadDigest(payload), 'd181ca860b0c8e7d2eee67d5fbc6bdc2fdff25e34bf5a3ed7a05282cb3e44072');
  assert.equal(verifyEnvelope(envelope, publicKey).address, 'task:sha256:d181ca860b0c8e7d2eee67d5fbc6bdc2fdff25e34bf5a3ed7a05282cb3e44072');
  assert.throws(() => verifyEnvelope({ ...envelope, payload: result(payloadDigest(payload)) }, publicKey), EnvelopeError);
});
test('canonical parser rejects mutations, duplicate keys, and noncanonical order', () => {
  const envelope = signEnvelope(task(), privateKey, 'author-1');
  assert.deepEqual(parseCanonicalEnvelope(jcs(envelope)), envelope);
  assert.throws(() => parseCanonicalEnvelope('{"signature":{},"payload":{},"payload":{}}'), /duplicate/);
  assert.throws(() => parseCanonicalEnvelope(JSON.stringify(envelope)), /canonical/);
  const altered = structuredClone(envelope); altered.payload.display_id = 'changed';
  assert.throws(() => verifyEnvelope(altered, publicKey), /invalid signature/);
});
test('v0 reserves future verification and settlement slots and rejects executor policy fields', () => {
  for (const mutation of [{ oracle_ref: 'oracle:future' }, { result_verdict: {} }, { settlement: {} }, { mounts: ['/host'] }, { network_rules: ['0.0.0.0/0'] }]) {
    assert.throws(() => signEnvelope({ ...task(), ...mutation }, privateKey, 'author-1'), EnvelopeError);
  }
});
test('result binds task digest without requiring author-side re-verification', () => {
  const taskDigest = payloadDigest(task()); const envelope = signEnvelope(result(taskDigest), privateKey, 'executor-1');
  assert.equal(verifyEnvelope(envelope, publicKey).kind, 'result');
  assert.equal(envelope.payload.task_digest, `sha256:${taskDigest}`);
  assert.equal(payloadDigest(envelope.payload), '85e47bee119e47066501070c3f7e85ca90e22c3588f7b7c47527433468116cc9');
});
test('result execution_metadata is optional, signed when present, and structurally excludes identities', () => {
  const payload = result(payloadDigest(task()));
  payload.execution_metadata = {
    harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5',
    usage: { input_tokens: 10, output_tokens: 4 }, duration_ms: 123,
  };
  assert.doesNotThrow(() => signEnvelope(payload, privateKey, 'executor-1'));
  assert.throws(() => signEnvelope({ ...payload, execution_metadata: { ...payload.execution_metadata, identities: {} } }, privateKey, 'executor-1'), /unknown field/);
});
test('strict parser rejects malformed UTF-8 and noncanonical numeric spellings', () => {
  assert.throws(() => parseCanonicalEnvelope(Buffer.from([0xc3, 0x28])), /encoded|UTF-8|JSON/);
  assert.throws(() => parseCanonicalEnvelope('{"payload":{},"signature":{},"z":1.0}'), /canonical|unknown/);
});
test('schema rejects syntactically shaped but invalid timestamps', () => {
  assert.throws(() => signEnvelope({ ...task(), created_at: '2026-99-99T00:00:00Z' }, privateKey, 'author-1'), /valid/);
});
test('CLI refuses symlink task input rather than following a review-path escape', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'federation-envelope-'));
  const target = join(directory, 'task.json'); const link = join(directory, 'task-link.json');
  await writeFile(target, jcs(signEnvelope(task(), privateKey, 'author-1'))); await symlink(target, link);
  const run = spawnSync(process.execPath, ['bin/federation-envelope', 'verify', 'task', '--envelope', link, '--public-key', '/dev/null'], { encoding: 'utf8' });
  assert.equal(run.status, 2); assert.match(run.stderr, /non-symlink/);
});
test('CLI creates a reviewable result bundle only when candidate bytes match', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'federation-bundle-'));
  const candidate = Buffer.from('candidate patch'); const candidateHash = (await import('node:crypto')).createHash('sha256').update(candidate).digest('hex');
  const taskDigest = payloadDigest(task());
  const payload = result(taskDigest); payload.candidate.artifact = { sha256: candidateHash, bytes: candidate.length, media_type: 'text/x-diff' };
  await writeFile(join(directory, 'result.json'), jcs(signEnvelope(payload, privateKey, 'executor-1')));
  await writeFile(join(directory, 'candidate.patch'), candidate); await writeFile(join(directory, 'public.pem'), publicKey);
  const run = spawnSync(process.execPath, ['bin/federation-envelope', 'bundle', 'result', '--result', join(directory, 'result.json'), '--candidate', join(directory, 'candidate.patch'), '--executor-key', join(directory, 'public.pem'), '--out', join(directory, 'out')], { encoding: 'utf8' });
  assert.equal(run.status, 0, run.stderr);
  assert.deepEqual(await readFile(join(directory, 'out', 'artifacts', candidateHash)), candidate);
});
