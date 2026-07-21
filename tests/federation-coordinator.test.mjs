import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signEnvelope, jcs } from '../lib/federation-envelope.mjs';
import { startCoordinator } from '../lib/federation-coordinator.mjs';

// Two genuinely distinct identities, matching the real scenario: an author
// (Tim) and an executor (Ocean) who sign with different ed25519 keypairs.
// The coordinator must verify each envelope against the SPECIFIC key its
// signature's key_id claims, never any-key-matches.
const authorKeys = generateKeyPairSync('ed25519');
const authorPrivateKey = authorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const authorPublicKey = authorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const AUTHOR_KEY_ID = 'tim-author';

const executorKeys = generateKeyPairSync('ed25519');
const executorPrivateKey = executorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const executorPublicKey = executorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const EXECUTOR_KEY_ID = 'ocean-executor';

// A third keypair that is intentionally never added to the roster, used to
// prove unregistered key_ids are rejected outright (not just "bad signature").
const strangerKeys = generateKeyPairSync('ed25519');
const strangerPrivateKey = strangerKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });

const ROSTER = new Map([
  [AUTHOR_KEY_ID, authorPublicKey],
  [EXECUTOR_KEY_ID, executorPublicKey],
]);

const TOKEN = 'test-collective-token';

const artifact = (hex = 'a') => ({ sha256: hex.repeat(64), bytes: 12, media_type: 'text/plain' });
const taskPayload = (overrides = {}) => ({
  schema: 'waspflow.federation.task.v0',
  collective: 'test',
  display_id: 'golden',
  author_key: 'ed25519:author',
  created_at: '2026-07-18T00:00:00Z',
  expires_at: '2030-07-18T00:00:00Z',
  source: { base_artifact: artifact('a'), base_revision: 'git:sha1:display-only' },
  prompt: { artifact: artifact('b') },
  network: 'enabled',
  oracle_ref: null,
  result_verdict: null,
  settlement: null,
  ...overrides,
});
const resultPayload = (taskDigest, overrides = {}) => ({
  schema: 'waspflow.federation.result.v0',
  task_digest: `sha256:${taskDigest}`,
  executor_key: 'ed25519:executor',
  submitted_at: '2026-07-18T01:00:00Z',
  candidate: { artifact: artifact('c'), tree_digest: `sha256:${'d'.repeat(64)}` },
  oracle_ref: null,
  result_verdict: null,
  settlement: null,
  ...overrides,
});

// Sign a task/result payload as a specific collective member. Defaults match
// the real scenario: tasks are authored by Tim, results are executed by
// Ocean. Tests that need a different signer (wrong-key, unregistered-key)
// pass privateKey/keyId explicitly.
function signTask(overrides = {}, { privateKey = authorPrivateKey, keyId = AUTHOR_KEY_ID } = {}) {
  return signEnvelope(taskPayload(overrides), privateKey, keyId);
}
function signResult(taskDigest, overrides = {}, { privateKey = executorPrivateKey, keyId = EXECUTOR_KEY_ID } = {}) {
  return signEnvelope(resultPayload(taskDigest, overrides), privateKey, keyId);
}

async function withServer(fn, { roster = ROSTER } = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), 'federation-coordinator-'));
  const server = await startCoordinator({ dataDir, token: TOKEN, roster, port: 0 });
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    await fn({ base, dataDir });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function authed(token = TOKEN) {
  return { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
}

async function publish(base, envelope, headers = authed()) {
  return fetch(`${base}/tasks`, { method: 'POST', headers, body: jcs(envelope) });
}
async function claim(base, digest, body, headers = authed()) {
  return fetch(`${base}/tasks/${digest}/claim`, { method: 'POST', headers, body: JSON.stringify(body) });
}
async function submit(base, digest, body, headers = authed()) {
  return fetch(`${base}/tasks/${digest}/submit`, { method: 'POST', headers, body: JSON.stringify(body) });
}
async function get(base, digest) {
  return fetch(`${base}/tasks/${digest}`);
}

test('publish a validly-signed task -> 200 queued, persisted to disk', async () => {
  await withServer(async ({ base, dataDir }) => {
    const envelope = signTask();
    const res = await publish(base, envelope);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.status, 'queued');
    assert.match(body.task_digest, /^[0-9a-f]{64}$/);
    const onDisk = JSON.parse(await readFile(join(dataDir, `${body.task_digest}.json`), 'utf8'));
    assert.equal(onDisk.status, 'QUEUED');
    assert.equal(onDisk.claim_generation, 0);
  });
});

test('publish with a bad signature is rejected and never queued', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    envelope.payload = { ...envelope.payload, display_id: 'tampered' };
    const res = await publish(base, envelope);
    assert.equal(res.status, 400);
    // Claims key_id AUTHOR_KEY_ID but is actually signed with the executor's
    // private key: the roster resolves AUTHOR_KEY_ID to the author's PUBLIC
    // key, so verification against that specific key must fail. This proves
    // the coordinator checks the signature against the ONE key the claimed
    // key_id maps to, not "does it match any registered key".
    const wrongKeyEnvelope = signTask({ display_id: 'wrong-signer' }, { privateKey: executorPrivateKey, keyId: AUTHOR_KEY_ID });
    const res2 = await publish(base, wrongKeyEnvelope);
    assert.equal(res2.status, 400);
  });
});

test('publish with a key_id not in the roster is rejected before verification is even attempted', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask({}, { privateKey: strangerPrivateKey, keyId: 'stranger-not-registered' });
    const res = await publish(base, envelope);
    assert.equal(res.status, 401);
    const body = await res.json();
    assert.match(body.error, /unknown signer key_id/);
  });
});

test('submit with a key_id not in the roster is rejected, distinct from a bad-signature rejection', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    const resultEnv = signResult(digest, {}, { privateKey: strangerPrivateKey, keyId: 'stranger-not-registered' });
    const res = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token });
    assert.equal(res.status, 401);
    const body = await res.json();
    assert.match(body.error, /unknown signer key_id/);
  });
});

test('publish with non-canonical JSON is rejected', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const res = await fetch(`${base}/tasks`, { method: 'POST', headers: authed(), body: JSON.stringify(envelope, null, 2) });
    assert.equal(res.status, 400);
  });
});

test('publish with wrong schema payload is rejected', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    envelope.payload = { ...envelope.payload, schema: 'waspflow.federation.bogus.v0' };
    // Note: signature will now fail verification too (schema is part of the signed payload),
    // but this still exercises the "reject non-task schema" path end to end.
    const res = await publish(base, envelope);
    assert.equal(res.status, 400);
  });
});

test('publish without bearer token -> 401', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const res = await fetch(`${base}/tasks`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: jcs(envelope) });
    assert.equal(res.status, 401);
  });
});

test('publish with wrong bearer token -> 401', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const res = await publish(base, envelope, authed('nope'));
    assert.equal(res.status, 401);
  });
});

test('claim a queued task -> CLAIMED, generation 0 -> 1, returns original task envelope', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const { task_digest: digest } = await (await publish(base, envelope)).json();
    const res = await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.claim_generation, 1);
    assert.ok(body.lease_token);
    assert.ok(body.lease_expiry > Date.now());
    assert.deepEqual(body.task_envelope, envelope);

    const state = await (await get(base, digest)).json();
    assert.equal(state.status, 'CLAIMED');
    assert.equal(state.claim_generation, 1);
    assert.equal(state.executor_key, 'ed25519:executor-1');
  });
});

test('claim an already-CLAIMED task with a live lease is rejected', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const { task_digest: digest } = await (await publish(base, envelope)).json();
    const first = await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 });
    assert.equal(first.status, 200);
    const second = await claim(base, digest, { executor_key: 'ed25519:executor-2', lease_seconds: 60 });
    assert.equal(second.status, 409);
  });
});

test('claim a CLAIMED task whose lease has expired supersedes the previous claim', async () => {
  await withServer(async ({ base }) => {
    const envelope = signTask();
    const { task_digest: digest } = await (await publish(base, envelope)).json();
    const first = await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 0.001 });
    assert.equal(first.status, 200);
    assert.equal((await first.json()).claim_generation, 1);

    await new Promise((resolve) => setTimeout(resolve, 30));

    // Two generation bumps happen here: the lazy-expiry sweep rolls
    // CLAIMED -> QUEUED (generation + 1), then the successful new claim
    // rolls QUEUED -> CLAIMED (generation + 1 again) — per the design doc's
    // `CLAIMED -> EXPIRED -> QUEUED(generation + 1)` followed by a normal
    // claim. So generation goes 1 -> 3, not 1 -> 2.
    const second = await claim(base, digest, { executor_key: 'ed25519:executor-2', lease_seconds: 60 });
    assert.equal(second.status, 200);
    const secondBody = await second.json();
    assert.equal(secondBody.claim_generation, 3);

    const state = await (await get(base, digest)).json();
    assert.equal(state.executor_key, 'ed25519:executor-2');
    assert.equal(state.claim_generation, 3);
  });
});

test('submit with a stale claim_generation is rejected', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    const resultEnv = signResult(digest);
    const res = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation - 1, lease_token: claimBody.lease_token });
    assert.equal(res.status, 409);
  });
});

test('submit with an expired lease is rejected', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 0.001 })).json();
    await new Promise((resolve) => setTimeout(resolve, 30));
    const resultEnv = signResult(digest);
    const res = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token });
    assert.equal(res.status, 409);
  });
});

test('submit with a mismatched lease_token is rejected', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    const resultEnv = signResult(digest);
    const res = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: 'wrong-token' });
    assert.equal(res.status, 403);
  });
});

test('submit a result whose task_digest does not match the task being submitted to is rejected', async () => {
  await withServer(async ({ base }) => {
    const taskEnvA = signTask({ display_id: 'task-a' });
    const taskEnvB = signTask({ display_id: 'task-b' });
    const { task_digest: digestA } = await (await publish(base, taskEnvA)).json();
    const { task_digest: digestB } = await (await publish(base, taskEnvB)).json();
    const claimBody = await (await claim(base, digestA, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    // Result is validly signed and correctly bound to task B's digest, but we submit it against task A's claim.
    const resultEnv = signResult(digestB);
    const res = await submit(base, digestA, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token });
    assert.equal(res.status, 400);
  });
});

test('GET on an unknown task digest -> 404, not a crash', async () => {
  await withServer(async ({ base }) => {
    const res = await get(base, 'f'.repeat(64));
    assert.equal(res.status, 404);
    const body = await res.json();
    assert.ok(body.error);
  });
});

test('full round trip: publish -> claim -> submit -> GET shows settled with result envelope attached', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const publishBody = await (await publish(base, taskEnv)).json();
    const digest = publishBody.task_digest;

    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    assert.equal(claimBody.claim_generation, 1);

    const resultEnv = signResult(digest);
    const submitRes = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token });
    assert.equal(submitRes.status, 200);
    const submitBody = await submitRes.json();
    assert.equal(submitBody.status, 'settled');
    assert.match(submitBody.result_address, /^result:sha256:[0-9a-f]{64}$/);

    const finalState = await (await get(base, digest)).json();
    assert.equal(finalState.status, 'SETTLED');
    assert.deepEqual(finalState.result_envelope, resultEnv);
  });
});

test('claim requires bearer token', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const res = await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 }, { 'content-type': 'application/json' });
    assert.equal(res.status, 401);
  });
});

test('submit requires bearer token', async () => {
  await withServer(async ({ base }) => {
    const taskEnv = signTask();
    const { task_digest: digest } = await (await publish(base, taskEnv)).json();
    const claimBody = await (await claim(base, digest, { executor_key: 'ed25519:executor-1', lease_seconds: 60 })).json();
    const resultEnv = signResult(digest);
    const res = await submit(base, digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token }, { 'content-type': 'application/json' });
    assert.equal(res.status, 401);
  });
});

// --- GET /tasks/next: task discovery for the guided contributor flow -----

async function next(base, headers = authed()) {
  return fetch(`${base}/tasks/next`, { headers });
}

test('GET /tasks/next returns null when no task is queued', async () => {
  await withServer(async ({ base }) => {
    const res = await next(base);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { task_digest: null });
  });
});

test('GET /tasks/next requires the bearer token — unlike GET /tasks/:digest, this is a discovery surface across all tasks', async () => {
  await withServer(async ({ base }) => {
    const res = await next(base, {});
    assert.equal(res.status, 401);
  });
});

test('GET /tasks/next returns the oldest QUEUED task, skips CLAIMED/SETTLED ones', async () => {
  await withServer(async ({ base }) => {
    const first = await (await publish(base, signTask({ display_id: 'first' }))).json();
    // A tiny real delay so published_at timestamps are genuinely ordered,
    // not just equal-and-coincidentally-sorted.
    await new Promise((resolve) => setTimeout(resolve, 5));
    const second = await (await publish(base, signTask({ display_id: 'second' }))).json();

    // First one is claimed (no longer eligible) — next should skip it.
    await claim(base, first.task_digest, { executor_key: 'ed25519:executor-1', lease_seconds: 3600 });

    const res = await next(base);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.task_digest, second.task_digest, 'must return the still-QUEUED task, not the CLAIMED one');
  });
});

test('GET /tasks/next returns a task again once its claim lease expires (lazy requeue applies here too)', async () => {
  await withServer(async ({ base }) => {
    const published = await (await publish(base, signTask())).json();
    await claim(base, published.task_digest, { executor_key: 'ed25519:executor-1', lease_seconds: 0.001 });
    await new Promise((resolve) => setTimeout(resolve, 30));

    const res = await next(base);
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.task_digest, published.task_digest, 'an expired-lease task must become claimable (and discoverable) again');
  });
});

test('GET /tasks/next never returns a SETTLED task', async () => {
  await withServer(async ({ base }) => {
    const published = await (await publish(base, signTask())).json();
    const claimBody = await (await claim(base, published.task_digest, { executor_key: 'ed25519:executor-1', lease_seconds: 3600 })).json();
    const resultEnv = signResult(published.task_digest);
    await submit(base, published.task_digest, { envelope: resultEnv, claim_generation: claimBody.claim_generation, lease_token: claimBody.lease_token });

    const res = await next(base);
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { task_digest: null });
  });
});
