import test from 'node:test';
import assert from 'node:assert/strict';
import { generateKeyPairSync, createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { signEnvelope, verifyEnvelope, validatePayload } from '../lib/federation-envelope.mjs';
import { startCoordinator } from '../lib/federation-coordinator.mjs';
import {
  SOURCE_MEDIA_TYPE,
  PROMPT_MEDIA_TYPE,
  CANDIDATE_MEDIA_TYPE,
  packageSourceDirectory,
  packagePromptText,
  buildTaskPayload,
  signTaskEnvelope,
  uploadArtifact,
  downloadArtifact,
  publishTask,
  getTaskStatus,
  pollUntilSettled,
  materializeCandidate,
  SubmitError,
} from '../lib/federation-submit.mjs';

const execFileAsync = promisify(execFile);

const authorKeys = generateKeyPairSync('ed25519');
const authorPrivateKey = authorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const authorPublicKey = authorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const AUTHOR_KEY_ID = 'tim-author';

const executorKeys = generateKeyPairSync('ed25519');
const executorPrivateKey = executorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const executorPublicKey = executorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const EXECUTOR_KEY_ID = 'ocean-executor';

const ROSTER = new Map([
  [AUTHOR_KEY_ID, authorPublicKey],
  [EXECUTOR_KEY_ID, executorPublicKey],
]);
const TOKEN = 'test-collective-token';

async function withServer(fn) {
  const dataDir = await mkdtemp(join(tmpdir(), 'federation-submit-coordinator-'));
  const server = await startCoordinator({ dataDir, token: TOKEN, roster: ROSTER, port: 0 });
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    await fn({ base, dataDir });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function makeGitRepo() {
  const dir = await mkdtemp(join(tmpdir(), 'federation-submit-src-'));
  await execFileAsync('git', ['-C', dir, 'init', '-q']);
  await execFileAsync('git', ['-C', dir, 'config', 'user.email', 'test@example.com']);
  await execFileAsync('git', ['-C', dir, 'config', 'user.name', 'Test']);
  await writeFile(join(dir, 'hello.txt'), 'hello world\n');
  await writeFile(join(dir, '.gitignore'), 'ignored.txt\n');
  await writeFile(join(dir, 'ignored.txt'), 'should not appear in archive\n');
  await execFileAsync('git', ['-C', dir, 'add', 'hello.txt', '.gitignore']);
  await execFileAsync('git', ['-C', dir, 'commit', '-q', '-m', 'initial']);
  return dir;
}

// Simulates what an executor would do against the coordinator: claim the
// queued task, then submit a signed result envelope whose candidate
// artifact is a tar of a fabricated result tree. Used to drive the
// submit-side polling loop through to SETTLED without needing a real
// executor process.
async function simulateExecutorSettle(base, taskDigest, { resultFiles = { 'result.txt': 'result content\n' } } = {}) {
  const claimRes = await fetch(`${base}/tasks/${taskDigest}/claim`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ executor_key: 'ed25519:executor-1', lease_seconds: 60 }),
  });
  assert.equal(claimRes.status, 200);
  const claim = await claimRes.json();

  const treeDir = await mkdtemp(join(tmpdir(), 'federation-submit-candidate-'));
  for (const [name, content] of Object.entries(resultFiles)) {
    await writeFile(join(treeDir, name), content);
  }
  // gzip-compressed, matching what the real executor slice
  // (bin/waspflow-federation-pull) actually produces (`tar czf`), so this
  // simulation exercises materializeCandidate's real auto-detect path
  // rather than only the easier uncompressed case.
  const { stdout: tarBuffer } = await execFileAsync('tar', ['-czf', '-', '-C', treeDir, '.'], { encoding: 'buffer', maxBuffer: 1024 * 1024 * 64 });
  const candidateDigest = createHash('sha256').update(tarBuffer).digest('hex');

  const uploadRes = await fetch(`${base}/artifacts/${candidateDigest}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${TOKEN}` },
    body: tarBuffer,
  });
  assert.equal(uploadRes.status, 200);

  const resultPayload = {
    schema: 'waspflow.federation.result.v0',
    task_digest: `sha256:${taskDigest}`,
    executor_key: 'ed25519:executor',
    submitted_at: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
    candidate: {
      artifact: { sha256: candidateDigest, bytes: tarBuffer.length, media_type: CANDIDATE_MEDIA_TYPE },
      tree_digest: `sha256:${'d'.repeat(64)}`,
    },
    oracle_ref: null,
    result_verdict: null,
    settlement: null,
  };
  const resultEnvelope = signEnvelope(resultPayload, executorPrivateKey, EXECUTOR_KEY_ID);

  const submitRes = await fetch(`${base}/tasks/${taskDigest}/submit`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: JSON.stringify({ envelope: resultEnvelope, claim_generation: claim.claim_generation, lease_token: claim.lease_token }),
  });
  assert.equal(submitRes.status, 200);
  return { candidateDigest, tarBuffer, treeDir };
}

// --- artifact packaging ------------------------------------------------

test('packageSourceDirectory uses git archive for a git repo and excludes gitignored files', async () => {
  const dir = await makeGitRepo();
  const artifact = await packageSourceDirectory(dir);
  assert.equal(artifact.method, 'git-archive');
  assert.equal(artifact.media_type, SOURCE_MEDIA_TYPE);
  assert.match(artifact.sha256, /^[0-9a-f]{64}$/);
  assert.equal(createHash('sha256').update(artifact.buffer).digest('hex'), artifact.sha256);
  assert.equal(artifact.bytes, artifact.buffer.length);

  // Verify contents via a fresh tar listing over the produced buffer.
  const tmp = await mkdtemp(join(tmpdir(), 'federation-submit-listing-'));
  const tarPath = join(tmp, 'archive.tar');
  await writeFile(tarPath, artifact.buffer);
  const { stdout } = await execFileAsync('tar', ['-tf', tarPath]);
  assert.match(stdout, /hello\.txt/);
  assert.doesNotMatch(stdout, /ignored\.txt/);
  assert.doesNotMatch(stdout, /\.git\//);

  await rm(dir, { recursive: true, force: true });
  await rm(tmp, { recursive: true, force: true });
});

test('packageSourceDirectory falls back to plain tar for a non-git directory', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'federation-submit-plain-'));
  await writeFile(join(dir, 'plain.txt'), 'plain content\n');
  const artifact = await packageSourceDirectory(dir);
  assert.equal(artifact.method, 'tar');
  assert.equal(createHash('sha256').update(artifact.buffer).digest('hex'), artifact.sha256);
  await rm(dir, { recursive: true, force: true });
});

test('packageSourceDirectory rejects a non-directory path', async () => {
  await assert.rejects(() => packageSourceDirectory('/definitely/does/not/exist'), SubmitError);
});

test('packagePromptText produces a correct real sha256/bytes for the prompt blob', () => {
  const artifact = packagePromptText('do the thing\n');
  assert.equal(artifact.media_type, PROMPT_MEDIA_TYPE);
  assert.equal(createHash('sha256').update('do the thing\n', 'utf8').digest('hex'), artifact.sha256);
  assert.equal(artifact.bytes, Buffer.byteLength('do the thing\n', 'utf8'));
});

test('packagePromptText rejects empty/blank prompt text', () => {
  assert.throws(() => packagePromptText(''), SubmitError);
  assert.throws(() => packagePromptText('   \n'), SubmitError);
});

// --- task envelope building ------------------------------------------------

test('buildTaskPayload + signTaskEnvelope produce an envelope that passes validatePayload and verifyEnvelope', () => {
  const source = { sha256: 'a'.repeat(64), bytes: 100, media_type: SOURCE_MEDIA_TYPE };
  const prompt = { sha256: 'b'.repeat(64), bytes: 20, media_type: PROMPT_MEDIA_TYPE };
  const payload = buildTaskPayload({
    collective: 'test-collective',
    displayId: 'my-task',
    authorKeyId: AUTHOR_KEY_ID,
    source,
    prompt,
    network: 'disabled',
    expiresInSeconds: 3600,
  });
  assert.equal(validatePayload(payload), 'task');
  assert.equal(payload.network, 'disabled');
  assert.equal(payload.author_key, AUTHOR_KEY_ID);

  const envelope = signTaskEnvelope(payload, authorPrivateKey, AUTHOR_KEY_ID);
  const verification = verifyEnvelope(envelope, authorPublicKey);
  assert.equal(verification.kind, 'task');
});

test('buildTaskPayload defaults network to disabled (the safer posture)', () => {
  const payload = buildTaskPayload({
    collective: 'c', displayId: 'd', authorKeyId: AUTHOR_KEY_ID,
    source: { sha256: 'a'.repeat(64), bytes: 1, media_type: SOURCE_MEDIA_TYPE },
    prompt: { sha256: 'b'.repeat(64), bytes: 1, media_type: PROMPT_MEDIA_TYPE },
  });
  assert.equal(payload.network, 'disabled');
});

test('buildTaskPayload rejects an invalid network value', () => {
  assert.throws(() => buildTaskPayload({
    collective: 'c', displayId: 'd', authorKeyId: AUTHOR_KEY_ID,
    source: { sha256: 'a'.repeat(64), bytes: 1, media_type: SOURCE_MEDIA_TYPE },
    prompt: { sha256: 'b'.repeat(64), bytes: 1, media_type: PROMPT_MEDIA_TYPE },
    network: 'maybe',
  }), SubmitError);
});

// --- full round trip against a real coordinator ----------------------------

test('full round trip: package, upload artifacts, publish, simulate executor settle, poll detects SETTLED, materialize candidate', async () => {
  await withServer(async ({ base }) => {
    const repoDir = await makeGitRepo();
    const source = await packageSourceDirectory(repoDir);
    const prompt = packagePromptText('please fix the flaky test\n');

    const payload = buildTaskPayload({
      collective: 'test-collective',
      displayId: 'round-trip-task',
      authorKeyId: AUTHOR_KEY_ID,
      source,
      prompt,
      network: 'disabled',
      expiresInSeconds: 3600,
    });
    const envelope = signTaskEnvelope(payload, authorPrivateKey, AUTHOR_KEY_ID);

    const sourceUpload = await uploadArtifact(base, TOKEN, source);
    assert.equal(sourceUpload.status, 'stored');
    const promptUpload = await uploadArtifact(base, TOKEN, prompt);
    assert.equal(promptUpload.status, 'stored');

    // An independent fetch-by-digest gets back byte-identical content.
    const roundTrippedSource = await downloadArtifact(base, TOKEN, source.sha256);
    assert.ok(roundTrippedSource.equals(source.buffer));

    const published = await publishTask(base, TOKEN, envelope);
    assert.equal(published.status, 'queued');
    assert.match(published.task_digest, /^[0-9a-f]{64}$/);

    // Not settled yet: a short-timeout poll should time out cleanly.
    await assert.rejects(
      () => pollUntilSettled(base, published.task_digest, { intervalMs: 5, timeoutMs: 20 }),
      /timed out/,
    );

    // Simulate the executor side (claim + submit) directly over HTTP.
    const { tarBuffer, candidateDigest } = await simulateExecutorSettle(base, published.task_digest);

    const settled = await pollUntilSettled(base, published.task_digest, { intervalMs: 5, timeoutMs: 5000 });
    assert.equal(settled.status, 'SETTLED');
    assert.equal(settled.result_envelope.payload.candidate.artifact.sha256, candidateDigest);

    const outputDir = await mkdtemp(join(tmpdir(), 'federation-submit-output-'));
    const materialized = await materializeCandidate(base, TOKEN, settled, outputDir);
    assert.equal(materialized.sha256, candidateDigest);
    assert.equal(materialized.bytes, tarBuffer.length);

    const extracted = await readFile(join(outputDir, 'result.txt'), 'utf8');
    assert.equal(extracted, 'result content\n');

    await rm(repoDir, { recursive: true, force: true });
    await rm(outputDir, { recursive: true, force: true });
  });
});

test('materializeCandidate independently re-verifies the result envelope signature when a roster is given', async () => {
  await withServer(async ({ base }) => {
    const repoDir = await makeGitRepo();
    const source = await packageSourceDirectory(repoDir);
    const prompt = packagePromptText('please fix the flaky test\n');
    const payload = buildTaskPayload({ collective: 'test-collective', displayId: 'roster-check', authorKeyId: AUTHOR_KEY_ID, source, prompt });
    const envelope = signTaskEnvelope(payload, authorPrivateKey, AUTHOR_KEY_ID);
    await uploadArtifact(base, TOKEN, source);
    await uploadArtifact(base, TOKEN, prompt);
    const published = await publishTask(base, TOKEN, envelope);
    await simulateExecutorSettle(base, published.task_digest);
    const settled = await pollUntilSettled(base, published.task_digest, { intervalMs: 5, timeoutMs: 5000 });

    // A correct roster (key_id -> real executor PEM) verifies and extracts normally.
    const goodOutputDir = await mkdtemp(join(tmpdir(), 'federation-submit-roster-good-'));
    const roster = { [AUTHOR_KEY_ID]: authorPublicKey, [EXECUTOR_KEY_ID]: executorPublicKey };
    await materializeCandidate(base, TOKEN, settled, goodOutputDir, { roster });
    const extracted = await readFile(join(goodOutputDir, 'result.txt'), 'utf8');
    assert.equal(extracted, 'result content\n');

    // A roster missing the executor's key_id must refuse to extract, not
    // silently trust the coordinator's claim.
    const noExecutorRoster = { [AUTHOR_KEY_ID]: authorPublicKey };
    const missingKeyOutputDir = await mkdtemp(join(tmpdir(), 'federation-submit-roster-missing-'));
    await assert.rejects(
      () => materializeCandidate(base, TOKEN, settled, missingKeyOutputDir, { roster: noExecutorRoster }),
      /not in the roster/,
    );

    // A roster with the RIGHT key_id but the WRONG public key (e.g. the
    // author's key mistakenly registered under the executor's key_id) must
    // fail signature verification, not silently accept.
    const wrongKeyRoster = { [AUTHOR_KEY_ID]: authorPublicKey, [EXECUTOR_KEY_ID]: authorPublicKey };
    const wrongKeyOutputDir = await mkdtemp(join(tmpdir(), 'federation-submit-roster-wrongkey-'));
    await assert.rejects(
      () => materializeCandidate(base, TOKEN, settled, wrongKeyOutputDir, { roster: wrongKeyRoster }),
      /signature verification failed/,
    );

    await rm(repoDir, { recursive: true, force: true });
    await rm(goodOutputDir, { recursive: true, force: true });
    await rm(missingKeyOutputDir, { recursive: true, force: true });
    await rm(wrongKeyOutputDir, { recursive: true, force: true });
  });
});

// --- error handling ------------------------------------------------------

test('publishTask rejects clearly (not silently) when the coordinator is unreachable', async () => {
  const source = { sha256: 'a'.repeat(64), bytes: 1, media_type: SOURCE_MEDIA_TYPE };
  const prompt = { sha256: 'b'.repeat(64), bytes: 1, media_type: PROMPT_MEDIA_TYPE };
  const payload = buildTaskPayload({ collective: 'c', displayId: 'd', authorKeyId: AUTHOR_KEY_ID, source, prompt });
  const envelope = signTaskEnvelope(payload, authorPrivateKey, AUTHOR_KEY_ID);
  await assert.rejects(() => publishTask('http://127.0.0.1:1', 'tok', envelope));
});

test('pollUntilSettled throws (does not hang) when --timeout is exceeded without settlement', async () => {
  await withServer(async ({ base }) => {
    const source = { sha256: 'a'.repeat(64), bytes: 1, media_type: SOURCE_MEDIA_TYPE };
    const prompt = { sha256: 'b'.repeat(64), bytes: 1, media_type: PROMPT_MEDIA_TYPE };
    const payload = buildTaskPayload({ collective: 'test-collective', displayId: 'never-settles', authorKeyId: AUTHOR_KEY_ID, source, prompt });
    const envelope = signTaskEnvelope(payload, authorPrivateKey, AUTHOR_KEY_ID);
    const published = await publishTask(base, TOKEN, envelope);

    const start = Date.now();
    await assert.rejects(
      () => pollUntilSettled(base, published.task_digest, { intervalMs: 5, timeoutMs: 50 }),
      /timed out/,
    );
    assert.ok(Date.now() - start < 2000, 'poll must not hang well past its timeout');
  });
});

test('pollUntilSettled surfaces a clear error (not a hang) for an unknown task digest', async () => {
  await withServer(async ({ base }) => {
    await assert.rejects(
      () => pollUntilSettled(base, 'f'.repeat(64), { intervalMs: 5, timeoutMs: 200 }),
      /polling failed/,
    );
  });
});

test('downloadArtifact refuses content whose actual sha256 does not match the requested digest', async () => {
  await withServer(async ({ base, dataDir }) => {
    // Store bytes under one digest, then corrupt them on disk to simulate a
    // storage-layer corruption / mismatch and confirm the client-side digest
    // check (not just the coordinator's) catches it.
    const buffer = Buffer.from('original content');
    const digest = createHash('sha256').update(buffer).digest('hex');
    await uploadArtifact(base, TOKEN, { buffer, sha256: digest, bytes: buffer.length });

    const artifactPath = join(dataDir, 'artifacts', digest);
    await writeFile(artifactPath, 'corrupted content');

    await assert.rejects(() => downloadArtifact(base, TOKEN, digest), /does not match its digest/);
  });
});
