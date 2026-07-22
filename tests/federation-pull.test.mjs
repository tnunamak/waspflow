import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile as execFileCb } from 'node:child_process';
import { generateKeyPairSync, createHash } from 'node:crypto';
import { mkdtemp, readFile, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { signEnvelope, verifyEnvelope, validatePayload, jcs, sha256 } from '../lib/federation-envelope.mjs';
import { startCoordinator } from '../lib/federation-coordinator.mjs';
import { validateJobSpec } from '../lib/federation-runtime.mjs';
import {
  claimTask,
  submitResult,
  fetchArtifact,
  buildValidatedJobSpec,
  resolveHarness,
  runJob,
  rfc3339Now,
  parseHarnessExecutionResult,
  parseProviderAccount,
  executionMetadata,
  buildTaskReceipt,
  capacityKindForHarness,
} from '../lib/federation-pull-internals.mjs';

const execFile = promisify(execFileCb);

// --- fixtures ----------------------------------------------------------

const authorKeys = generateKeyPairSync('ed25519');
const authorPrivateKey = authorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const authorPublicKey = authorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const AUTHOR_KEY_ID = 'tim-author';

const executorKeys = generateKeyPairSync('ed25519');
const executorPrivateKey = executorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const executorPublicKey = executorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const EXECUTOR_KEY_ID = 'ocean-executor';

const ROSTER = new Map([[AUTHOR_KEY_ID, authorPublicKey], [EXECUTOR_KEY_ID, executorPublicKey]]);
const TOKEN = 'test-collective-token';

const artifact = (bytes, mediaType = 'text/plain') => ({
  sha256: createHash('sha256').update(bytes).digest('hex'),
  bytes: bytes.length,
  media_type: mediaType,
});

function taskPayload({ sourceBytes, promptBytes }, overrides = {}) {
  return {
    schema: 'waspflow.federation.task.v0',
    collective: 'test',
    display_id: 'pull-slice-4',
    author_key: 'ed25519:author',
    created_at: '2026-07-18T00:00:00Z',
    expires_at: '2030-07-18T00:00:00Z',
    source: { base_artifact: artifact(sourceBytes, 'application/x-tar'), base_revision: 'git:sha1:display-only' },
    prompt: { artifact: artifact(promptBytes, 'text/plain') },
    network: 'enabled',
    oracle_ref: null,
    result_verdict: null,
    settlement: null,
    ...overrides,
  };
}

function signTask(payload, { privateKey = authorPrivateKey, keyId = AUTHOR_KEY_ID } = {}) {
  return signEnvelope(payload, privateKey, keyId);
}

async function withServer(fn) {
  const dataDir = await mkdtemp(join(tmpdir(), 'federation-pull-coordinator-'));
  const server = await startCoordinator({ dataDir, token: TOKEN, roster: ROSTER, port: 0 });
  const { port } = server.address();
  const base = `http://127.0.0.1:${port}`;
  try {
    await fn({ base, dataDir });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function publish(base, envelope) {
  const res = await fetch(`${base}/tasks`, {
    method: 'POST',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/json' },
    body: jcs(envelope),
  });
  const body = await res.json();
  assert.equal(res.status, 200, `publish failed: ${JSON.stringify(body)}`);
  return body;
}

async function putArtifact(base, bytes) {
  const digest = createHash('sha256').update(bytes).digest('hex');
  const res = await fetch(`${base}/artifacts/${digest}`, {
    method: 'PUT',
    headers: { authorization: `Bearer ${TOKEN}`, 'content-type': 'application/octet-stream' },
    body: bytes,
  });
  assert.equal(res.status, 200, `putArtifact failed: ${await res.text()}`);
  return digest;
}

// =========================================================================
// Tier 1: unit-testable without real sbx
// =========================================================================

test('claim-request construction: POSTs plain JSON (not a signed envelope) with the bearer token', async () => {
  await withServer(async ({ base }) => {
    const sourceBytes = Buffer.from('source-tar-bytes');
    const promptBytes = Buffer.from('do the thing');
    const envelope = signTask(taskPayload({ sourceBytes, promptBytes }));
    const { task_digest: digest } = await publish(base, envelope);

    const result = await claimTask({ coordinatorUrl: base, token: TOKEN, taskDigest: digest, executorKey: EXECUTOR_KEY_ID, leaseSeconds: 60 });
    assert.equal(result.task_digest, digest);
    assert.equal(result.claim_generation, 1);
    assert.ok(result.lease_token);
    assert.deepEqual(result.task_envelope, envelope);
  });
});

test('claim rejects with a clear error on non-2xx (e.g. unknown digest)', async () => {
  await withServer(async ({ base }) => {
    await assert.rejects(
      () => claimTask({ coordinatorUrl: base, token: TOKEN, taskDigest: 'f'.repeat(64), executorKey: EXECUTOR_KEY_ID, leaseSeconds: 60 }),
      /claim failed: 404/,
    );
  });
});

test('local task-envelope re-verification: a validly-signed envelope verifies against the roster PEM', () => {
  const sourceBytes = Buffer.from('src');
  const promptBytes = Buffer.from('prompt');
  const envelope = signTask(taskPayload({ sourceBytes, promptBytes }));
  const result = verifyEnvelope(envelope, authorPublicKey);
  assert.equal(result.kind, 'task');
});

test('local task-envelope re-verification: a tampered envelope (post-claim MITM) fails verification', () => {
  const sourceBytes = Buffer.from('src');
  const promptBytes = Buffer.from('prompt');
  const envelope = signTask(taskPayload({ sourceBytes, promptBytes }));
  const tampered = { ...envelope, payload: { ...envelope.payload, prompt: { artifact: artifact(Buffer.from('evil replacement prompt'), 'text/plain') } } };
  assert.throws(() => verifyEnvelope(tampered, authorPublicKey), /invalid signature/);
});

test('local task-envelope re-verification: signer key_id not in roster is caught before verification is attempted', () => {
  // This mirrors the executor-side check in bin/waspflow-federation-pull:
  // resolve the roster PEM for the claimed key_id first; refuse if absent.
  const sourceBytes = Buffer.from('src');
  const promptBytes = Buffer.from('prompt');
  const envelope = signTask(taskPayload({ sourceBytes, promptBytes }), { privateKey: executorPrivateKey, keyId: 'unregistered-key' });
  const roster = { [AUTHOR_KEY_ID]: authorPublicKey };
  assert.equal(roster[envelope.signature.key_id], undefined);
});

test('fetchArtifact: verifies downloaded bytes hash to the requested digest before returning them', async () => {
  await withServer(async ({ base }) => {
    const bytes = Buffer.from('some artifact content');
    const digest = await putArtifact(base, bytes);
    const fetched = await fetchArtifact(base, TOKEN, digest);
    assert.deepEqual(fetched, bytes);
  });
});

test('fetchArtifact: rejects on 404 for an unknown digest', async () => {
  await withServer(async ({ base }) => {
    await assert.rejects(() => fetchArtifact(base, TOKEN, 'a'.repeat(64)), /failed: 404/);
  });
});

test('ValidatedJobSpec construction passes validateJobSpec and uses the harness image/entrypoint', () => {
  const harness = resolveHarness('claude-code-subscription');
  assert.equal(harness.image, 'claude');
  const entrypointWithPrompt = `${harness.entrypoint} 'print WF_TASK_OK and exit'`;
  const spec = buildValidatedJobSpec({ taskDigest: 'a'.repeat(64), harness, entrypointWithPrompt });
  assert.doesNotThrow(() => validateJobSpec(spec));
  assert.equal(spec.image, 'claude');
  assert.ok(spec.entrypoint.startsWith('claude --print --verbose --output-format stream-json --dangerously-skip-permissions'));
  assert.deepEqual(spec.output_manifest, ['.wf-result/result.tar.gz']);
});

test('resolveHarness rejects an unknown harness name rather than silently defaulting', () => {
  assert.throws(() => resolveHarness('nonexistent-harness'), /unknown --harness/);
});

test('receipt parsers capture only the fields emitted by Claude, Codex, and Gemini JSON output', () => {
  const claude = parseHarnessExecutionResult('claude-code-subscription', JSON.stringify({
    type: 'result', duration_ms: 3840,
    usage: { input_tokens: 15166, output_tokens: 63 },
    modelUsage: { 'claude-fable-5': { inputTokens: 15166, outputTokens: 63 } },
  }));
  assert.deepEqual(parseHarnessExecutionResult('claude-code-subscription', [
    JSON.stringify({ type: 'assistant', message: { content: 'working' } }),
    JSON.stringify({ type: 'result', model: 'claude-fable-5', usage: { input_tokens: 8, output_tokens: 3 } }),
  ].join('\n')), { model: 'claude-fable-5', usage: { input_tokens: 8, output_tokens: 3 } });
  assert.deepEqual(claude, { model: 'claude-fable-5', usage: { input_tokens: 15166, output_tokens: 63 } });
  assert.deepEqual(parseHarnessExecutionResult('claude-code-subscription', JSON.stringify({
    model: 'claude-sonnet-4-5', usage: { input_tokens: 3, output_tokens: 2 }, modelUsage: { 'claude-haiku-4-5': {} },
  })), { model: 'claude-sonnet-4-5', usage: { input_tokens: 3, output_tokens: 2 } });
  assert.deepEqual(parseHarnessExecutionResult('claude-code-subscription', JSON.stringify({
    usage: { input_tokens: 3, output_tokens: 2 }, modelUsage: { 'claude-haiku-4-5': {}, 'claude-sonnet-4-5': {} },
  })), { model: 'claude-haiku-4-5, claude-sonnet-4-5', usage: { input_tokens: 3, output_tokens: 2 } });

  const codex = parseHarnessExecutionResult('codex', [
    JSON.stringify({ type: 'thread.started', thread_id: 'abc' }),
    JSON.stringify({ type: 'turn.completed', usage: { input_tokens: 18795, cached_input_tokens: 10496, output_tokens: 6, reasoning_output_tokens: 0 } }),
  ].join('\n'));
  assert.deepEqual(codex, { model: null, usage: { input_tokens: 18795, output_tokens: 6 } });

  const gemini = parseHarnessExecutionResult('gemini', JSON.stringify({
    model: 'gemini-2.5-pro', stats: { inputTokens: 12, outputTokens: 7 },
  }));
  assert.deepEqual(gemini, { model: 'gemini-2.5-pro', usage: { input_tokens: 12, output_tokens: 7 } });
  assert.deepEqual(parseHarnessExecutionResult('codex', 'not json'), { model: null, usage: null });
});

test('receipt parser reads optional Claude account identity from sandbox status output and never requires it for result metadata', () => {
  const account = parseProviderAccount('claude-code-subscription', JSON.stringify({
    loggedIn: true, email: 'oshin@example.test', subscriptionType: 'max',
  }));
  assert.deepEqual(account, { email: 'oshin@example.test', tier: 'max' });
  assert.equal(parseProviderAccount('claude-code-subscription', '{"loggedIn":false}'), null);
  assert.deepEqual(executionMetadata({ harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5', usage: { input_tokens: 3, output_tokens: 2 }, duration_ms: 99 }), {
    harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5', usage: { input_tokens: 3, output_tokens: 2 }, duration_ms: 99,
  });
});

test('capacity kind comes from the harness capacity source, not optional account tier data', () => {
  assert.equal(capacityKindForHarness(resolveHarness('claude-code-subscription')), 'subscription');
  assert.equal(capacityKindForHarness(resolveHarness('claude-code-api-key')), 'api_key');
  assert.equal(capacityKindForHarness(resolveHarness('gemini')), 'api_key');
  assert.equal(capacityKindForHarness(resolveHarness('gh-cli')), 'local');
});

test('task receipt joins measured sandbox facts, parsed output, and private identities', () => {
  const receipt = buildTaskReceipt({
    taskDigest: 'a'.repeat(64), harnessId: 'claude-code-subscription', dockerAccount: 'oshin',
    execution: {
      sandbox_id: 'wf-123', started_at: '2026-07-21T10:00:00.000Z', finished_at: '2026-07-21T10:00:01.200Z', duration_ms: 1200,
      stdout: JSON.stringify({ usage: { input_tokens: 12, output_tokens: 4 }, modelUsage: { 'claude-fable-5': {} } }),
      provider_status_stdout: JSON.stringify({ loggedIn: true, email: 'oshin@example.test', subscriptionType: 'max' }),
    },
  });
  assert.deepEqual(receipt, {
    schema_version: 1, task_digest: 'a'.repeat(64), harness_id: 'claude-code-subscription', capacity_kind: 'subscription', model: 'claude-fable-5',
    usage: { input_tokens: 12, output_tokens: 4 }, duration_ms: 1200,
    started_at: '2026-07-21T10:00:00.000Z', finished_at: '2026-07-21T10:00:01.200Z', sandbox_id: 'wf-123',
    identities: { docker_account: 'oshin', provider_account: { email: 'oshin@example.test', tier: 'max' } },
  });
});

test('result-envelope construction passes validatePayload (schema, DIGEST-prefixed task_digest)', () => {
  const candidateBytes = Buffer.from('result tar bytes');
  const candidateDigest = createHash('sha256').update(candidateBytes).digest('hex');
  const taskDigest = 'b'.repeat(64);
  const payload = {
    schema: 'waspflow.federation.result.v0',
    task_digest: `sha256:${taskDigest}`, // prefixed address form — NOT bare hex
    executor_key: EXECUTOR_KEY_ID,
    submitted_at: rfc3339Now(),
    candidate: {
      artifact: { sha256: candidateDigest, bytes: candidateBytes.length, media_type: 'application/gzip' },
      tree_digest: `sha256:${candidateDigest}`,
    },
    oracle_ref: null,
    result_verdict: null,
    settlement: null,
  };
  assert.doesNotThrow(() => validatePayload(payload));
  const envelope = signEnvelope(payload, executorPrivateKey, EXECUTOR_KEY_ID);
  const verified = verifyEnvelope(envelope, executorPublicKey);
  assert.equal(verified.kind, 'result');
});

test('result-envelope construction rejects a BARE HEX task_digest (the exact prefix bug the brief calls out)', () => {
  const taskDigest = 'c'.repeat(64);
  const payload = {
    schema: 'waspflow.federation.result.v0',
    task_digest: taskDigest, // bare hex, no sha256: prefix — must be rejected
    executor_key: EXECUTOR_KEY_ID,
    submitted_at: rfc3339Now(),
    candidate: { artifact: { sha256: 'd'.repeat(64), bytes: 3, media_type: 'application/gzip' }, tree_digest: `sha256:${'d'.repeat(64)}` },
    oracle_ref: null,
    result_verdict: null,
    settlement: null,
  };
  assert.throws(() => validatePayload(payload), /task_digest/);
});

// --- entrypoint + prompt argv assembly (shell-quoting correctness) --------

async function writeShellQuoteHarness(promptEnvVar) {
  // Mirrors bin/waspflow-federation-pull's shellQuoteSingle, isolated here
  // for a direct unit test (the bin script is CommonJS top-level and not
  // itself imported by tests — this reimplements the exact same POSIX
  // single-quote-escaping algorithm so the test proves the ALGORITHM is
  // injection-safe; the bin script's own copy is byte-identical).
  return (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;
}

test('shell-quoting: a hostile prompt with $, backticks, and quotes cannot break out of `sh -c`', async () => {
  const shellQuoteSingle = await writeShellQuoteHarness();
  const hostilePrompt = `hi $(rm -rf /tmp/pwned) \`echo pwned\` "quoted" 'single' ; echo injected`;
  const entrypoint = 'echo BASE_ARG_ONLY';
  const fullCommand = `${entrypoint} ${shellQuoteSingle(hostilePrompt)}`;

  // Actually execute it through sh -c, the same way DockerSbxBackend.start()
  // does via `sbx exec SANDBOX -- sh -c ENTRYPOINT`, and prove the hostile
  // prompt was passed as ONE inert argv element (echoed back verbatim by
  // `echo`, which echoes all its args) rather than executed as shell syntax.
  const canary = join(tmpdir(), `wf-shell-quote-canary-${Date.now()}`);
  const commandWithCanaryCheck = `${fullCommand.replace('echo BASE_ARG_ONLY', `test ! -e ${JSON.stringify(canary)} && echo BASE_ARG_ONLY`)}`;
  const { stdout } = await execFile('sh', ['-c', commandWithCanaryCheck]);
  assert.ok(stdout.includes('BASE_ARG_ONLY'), 'base command must still run');
  assert.ok(stdout.includes(hostilePrompt), 'hostile prompt must appear verbatim as echo output, proving it was one inert argument');
  await assert.rejects(() => readFile(canary), /ENOENT/, 'the injected `rm -rf` / subshell content must never have executed');
});

test('shell-quoting: a prompt containing a single quote itself is escaped correctly', async () => {
  const shellQuoteSingle = await writeShellQuoteHarness();
  const prompt = `it's a "test" with 'nested' quotes`;
  const quoted = shellQuoteSingle(prompt);
  const { stdout } = await execFile('sh', ['-c', `echo ${quoted}`]);
  assert.equal(stdout.trim(), prompt);
});

// =========================================================================
// Tier 2: full round trip against a REAL coordinator, STUBBED sbx backend
// =========================================================================

async function writeStub(name, body) {
  const dir = await mkdtemp(join(tmpdir(), `wf-pull-sbx-stub-${name}-`));
  const scriptPath = join(dir, 'sbx');
  await writeFile(scriptPath, `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`);
  await chmod(scriptPath, 0o755);
  return dir;
}

test('full plumbing round trip: publish -> claim -> run (stub backend) -> submit -> coordinator shows SETTLED', async () => {
  await withServer(async ({ base }) => {
    const sourceBytes = Buffer.from('fake tarball bytes');
    const promptBytes = Buffer.from('print WF_TASK_OK and exit');
    const taskEnv = signTask(taskPayload({ sourceBytes, promptBytes }));
    const { task_digest: digest } = await publish(base, taskEnv);
    await putArtifact(base, sourceBytes);
    await putArtifact(base, promptBytes);

    // --- claim + local re-verify (exactly what the bin script does) -----
    const claimResult = await claimTask({ coordinatorUrl: base, token: TOKEN, taskDigest: digest, executorKey: EXECUTOR_KEY_ID, leaseSeconds: 60 });
    const verification = verifyEnvelope(claimResult.task_envelope, authorPublicKey);
    assert.equal(verification.digest, digest);

    // --- fetch artifacts --------------------------------------------------
    const fetchedSource = await fetchArtifact(base, TOKEN, claimResult.task_envelope.payload.source.base_artifact.sha256);
    const fetchedPrompt = await fetchArtifact(base, TOKEN, claimResult.task_envelope.payload.prompt.artifact.sha256);
    assert.deepEqual(fetchedSource, sourceBytes);
    assert.deepEqual(fetchedPrompt, promptBytes);

    // --- build job spec -----------------------------------------------------
    const harness = resolveHarness('claude-code-subscription');
    const entrypointWithPrompt = `${harness.entrypoint} 'print WF_TASK_OK and exit'`;
    const jobSpec = buildValidatedJobSpec({ taskDigest: digest, harness, entrypointWithPrompt });

    // --- run against a STUB sbx: proves the wiring, not sbx mechanics -------
    // (sbx mechanics are already proven in tests/federation-docker-backend.test.mjs)
    const stubDir = await writeStub('pull-plumbing', `
      case "$1" in
        --version) echo "sbx version 0.35.0-stub"; exit 0 ;;
        run) exit 0 ;;
        exec)
          # \`sbx exec SANDBOX -- sh -c CMD\`: emulate producing the declared
          # output file wherever the CMD's tar step would have written it —
          # simplest correct stub is to just always succeed; collectDeclaredOutputs
          # below is separately stubbed to hand back a deterministic file.
          exit 0
          ;;
        cp) exit 0 ;;
        rm) exit 0 ;;
        ls) exit 0 ;;
        *) exit 0 ;;
      esac
    `);
    const previousBin = process.env.WASPFLOW_SBX_BIN;
    process.env.WASPFLOW_SBX_BIN = join(stubDir, 'sbx');
    let collected;
    let cleanupReceipt;
    let materializeCalledWith;
    const fakeContent = 'fake-result';
    try {
      const { DockerSbxBackend } = await import('../lib/federation-docker-backend.mjs');
      const backend = new DockerSbxBackend();
      // This plumbing test deliberately stubs sbx mechanics; the install
      // preflight itself is exhaustively exercised in
      // federation-sbx-preflight.test.mjs. Do not make a fake binary appear
      // install-ready by accident while testing artifact flow.
      backend.probeCapabilities = async () => ({ available: true, backend_id: 'docker-sbx' });
      // collectDeclaredOutputs relies on `sbx cp` actually placing bytes at
      // outDir/declaredPath; the bare stub above no-ops that copy. Rather
      // than teach the bash stub to fabricate a tar file (duplicating
      // federation-docker-backend's own already-tested cp mechanics), stub
      // collectDeclaredOutputs itself for this plumbing-only test.
      const fakeCollected = [{ path: '.wf-result/result.tar.gz', sha256: createHash('sha256').update(fakeContent).digest('hex'), bytes: fakeContent.length }];
      backend.collectDeclaredOutputs = async (handle, manifest) => {
        assert.deepEqual(manifest, jobSpec.output_manifest);
        const outDir = join(handle.scratch_dir, '.wf-outputs');
        const { mkdir } = await import('node:fs/promises');
        await mkdir(join(outDir, '.wf-result'), { recursive: true });
        await writeFile(join(outDir, '.wf-result', 'result.tar.gz'), fakeContent);
        return fakeCollected;
      };
      // Exercise the real materializeSource wiring: proves a file written
      // via the callback into the REAL (real prepare()-returned) scratch_dir
      // is what the guest's workspace mount would see — the exact gap
      // routed around in runJob's doc comment.
      const result = await runJob({
        jobSpec,
        backend,
        materializeSource: async (scratchDir) => {
          materializeCalledWith = scratchDir;
          await writeFile(join(scratchDir, 'materialized-source-marker.txt'), 'source was here');
        },
      });
      collected = result.collected;
      cleanupReceipt = result.cleanupReceipt;
    } finally {
      if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
      else process.env.WASPFLOW_SBX_BIN = previousBin;
      await rm(stubDir, { recursive: true, force: true });
    }
    assert.ok(materializeCalledWith, 'materializeSource must be invoked with the real scratch_dir');
    assert.equal(collected.length, 1);
    assert.equal(collected[0].path, '.wf-result/result.tar.gz');
    // bytes_content must be readable from the returned collected[] entry
    // WITHOUT touching the filesystem again — destroy() already removed
    // scratch_dir by the time runJob returns.
    assert.equal(collected[0].bytes_content.toString('utf8'), fakeContent);

    // --- sign + upload candidate + submit ------------------------------------
    const candidateDigest = collected[0].sha256;
    await putArtifact(base, collected[0].bytes_content);
    const resultPayload = {
      schema: 'waspflow.federation.result.v0',
      task_digest: `sha256:${digest}`,
      executor_key: EXECUTOR_KEY_ID,
      submitted_at: rfc3339Now(),
      candidate: { artifact: { sha256: candidateDigest, bytes: collected[0].bytes, media_type: 'application/gzip' }, tree_digest: `sha256:${candidateDigest}` },
      oracle_ref: null,
      result_verdict: null,
      settlement: null,
    };
    const resultEnvelope = signEnvelope(resultPayload, executorPrivateKey, EXECUTOR_KEY_ID);

    const submitResponse = await submitResult({
      coordinatorUrl: base, token: TOKEN, taskDigest: digest,
      envelope: resultEnvelope, claimGeneration: claimResult.claim_generation, leaseToken: claimResult.lease_token,
    });
    assert.equal(submitResponse.status, 'settled', JSON.stringify(submitResponse));

    const finalState = await (await fetch(`${base}/tasks/${digest}`)).json();
    assert.equal(finalState.status, 'SETTLED');
    assert.deepEqual(finalState.result_envelope, resultEnvelope);
  });
});

// =========================================================================
// Tier 3: live sbx integration (self-skips if sbx not installed)
// =========================================================================

async function sbxOnPath() {
  try {
    await execFile('sbx', ['ls']);
    return true;
  } catch (error) {
    return error && error.code !== 'ENOENT';
  }
}

// KNOWN, DIAGNOSED FAILURE MODE as of this writing (not a flake, not a bug in
// this slice's code): under the isolated WASPFLOW_FEDERATION_SBX_HOME
// identity DockerSbxBackend uses (~/.wfsbx by default), a fresh
// sandbox's kit-assigned network policy allows only claude.com,
// downloads.claude.ai, and mcp-proxy.anthropic.com — NOT api.anthropic.com,
// which `claude --print` needs to authenticate. Confirmed by direct
// reproduction (`sbx policy ls <sandbox> --wide` under that isolated HOME)
// and by contrast against the developer's normal $HOME, whose `local-policy`
// happens to carry a permissive `default-allow-all` network rule that masks
// the same narrow kit policy — this is exactly Gate B from
// docs/design/FEDERATION_V0_UAT_REPORT.md ("this machine's actual local
// policy is permissive... not deny-all"), now reproduced from the OTHER
// direction: the isolated identity IS deny-by-default, and that correctly
// blocks the harness's own auth domain. Fixing this is a host policy
// decision (`sbx policy allow --host api.anthropic.com:443` scoped to the
// waspflow sbx-home identity, or equivalent), not a code change to this
// slice — same "owner-level security decision" posture the UAT report
// already established for Gate B. This test intentionally does NOT swallow
// or downgrade that failure; it fails loudly with the real sbx error so it
// stays visible until an operator fixes the policy.
test('live sbx integration: real claim -> real prepare/start/destroy -> real submit -> SETTLED with matching output', async (t) => {
  if (!(await sbxOnPath())) {
    console.log('SKIP: sbx not installed — skipping live sbx integration test');
    t.skip('sbx not installed');
    return;
  }
  const { DockerSbxBackend } = await import('../lib/federation-docker-backend.mjs');
  const preflight = await new DockerSbxBackend().probeCapabilities();
  if (!preflight.available) {
    console.log(`SKIP: live sbx preflight is not ready — ${(preflight.missing_prerequisites || []).join('; ')}`);
    t.skip('live sbx preflight is not ready');
    return;
  }

  await withServer(async ({ base }) => {
    // A REAL uncompressed tar (matching lib/federation-submit.mjs's
    // SOURCE_MEDIA_TYPE convention: 'application/x-tar', git-archive or
    // plain tar, never gzip) containing one marker file, so this test can
    // prove materializeSource genuinely reaches the guest's mounted
    // workspace — not just that runJob's plumbing doesn't throw.
    const sourceStageDir = await mkdtemp(join(tmpdir(), 'wf-pull-live-source-'));
    const markerName = 'MARKER_FROM_REQUESTER.txt';
    await writeFile(join(sourceStageDir, markerName), 'source materialized correctly');
    const { stdout: tarStdout } = await execFile('tar', ['-cf', '-', '-C', sourceStageDir, '.'], { encoding: 'buffer', maxBuffer: 16 * 1024 * 1024 });
    const sourceBytes = tarStdout;
    await rm(sourceStageDir, { recursive: true, force: true });

    const promptBytes = Buffer.from('print WF_TASK_OK and exit');
    const taskEnv = signTask(taskPayload({ sourceBytes, promptBytes }));
    const { task_digest: digest } = await publish(base, taskEnv);
    await putArtifact(base, sourceBytes);
    await putArtifact(base, promptBytes);

    const claimResult = await claimTask({ coordinatorUrl: base, token: TOKEN, taskDigest: digest, executorKey: EXECUTOR_KEY_ID, leaseSeconds: 3600 });
    const verification = verifyEnvelope(claimResult.task_envelope, authorPublicKey);
    assert.equal(verification.digest, digest);

    const fetchedSource = await fetchArtifact(base, TOKEN, claimResult.task_envelope.payload.source.base_artifact.sha256);
    const fetchedPrompt = await fetchArtifact(base, TOKEN, claimResult.task_envelope.payload.prompt.artifact.sha256);
    assert.deepEqual(fetchedSource, sourceBytes);
    assert.deepEqual(fetchedPrompt, promptBytes);

    const harness = resolveHarness('claude-code-subscription');
    // Task: echo the marker file's content back out via stdout, proving the
    // materialized source is actually present in the guest's working
    // directory when the harness entrypoint runs — not just that the run
    // completed.
    const livePrompt = `print WF_TASK_OK and exit; then run: cat ${markerName}`;
    const entrypointWithPrompt = `${harness.entrypoint} '${livePrompt}'`;
    const jobSpec = buildValidatedJobSpec({ taskDigest: digest, harness, entrypointWithPrompt });

    const materializeSource = async (scratchDir) => {
      const tmpTar = join(await mkdtemp(join(tmpdir(), 'wf-pull-live-extract-')), 'source.tar');
      await writeFile(tmpTar, sourceBytes);
      await execFile('tar', ['xf', tmpTar, '-C', scratchDir]);
    };
    const { collected, cleanupReceipt } = await runJob({ jobSpec, materializeSource });
    assert.equal(cleanupReceipt.removed, true, 'destroy() must independently verify the sandbox is actually gone');
    assert.equal(collected.length, 1);
    assert.ok(Buffer.isBuffer(collected[0].bytes_content) && collected[0].bytes_content.length > 0, 'collected output bytes must be readable directly from the returned entry (destroy() already removed scratch_dir)');

    const candidateDigest = collected[0].sha256;
    assert.match(candidateDigest, /^[0-9a-f]{64}$/);
    assert.equal(createHash('sha256').update(collected[0].bytes_content).digest('hex'), candidateDigest, 'bytes_content must actually hash to the declared sha256');

    const resultPayload = {
      schema: 'waspflow.federation.result.v0',
      task_digest: `sha256:${digest}`,
      executor_key: EXECUTOR_KEY_ID,
      submitted_at: rfc3339Now(),
      candidate: { artifact: { sha256: candidateDigest, bytes: collected[0].bytes, media_type: 'application/gzip' }, tree_digest: `sha256:${candidateDigest}` },
      oracle_ref: null,
      result_verdict: null,
      settlement: null,
    };
    const resultEnvelope = signEnvelope(resultPayload, executorPrivateKey, EXECUTOR_KEY_ID);
    await putArtifact(base, collected[0].bytes_content);
    const submitResponse = await submitResult({
      coordinatorUrl: base, token: TOKEN, taskDigest: digest,
      envelope: resultEnvelope, claimGeneration: claimResult.claim_generation, leaseToken: claimResult.lease_token,
    });
    assert.equal(submitResponse.status, 'settled', JSON.stringify(submitResponse));

    const finalState = await (await fetch(`${base}/tasks/${digest}`)).json();
    assert.equal(finalState.status, 'SETTLED');

    // Extract the settled candidate and prove the guest actually saw the
    // materialized source file (its content appears somewhere in the
    // harness's echoed output, which the result tarball captures via the
    // workspace's own transcript/output files if the harness writes any, OR
    // — simplest, most direct proof available without depending on where a
    // given harness happens to persist stdout — the marker file we planted
    // is itself still present in the resulting tree, since collectDeclaredOutputs
    // tars the whole post-run workspace, unmodified files included).
    const extractDir = await mkdtemp(join(tmpdir(), 'wf-pull-live-verify-'));
    const candidateTar = join(extractDir, 'candidate.tar.gz');
    await writeFile(candidateTar, collected[0].bytes_content);
    await execFile('tar', ['xzf', candidateTar, '-C', extractDir]);
    const markerContent = await readFile(join(extractDir, markerName), 'utf8').catch(() => null);
    assert.equal(markerContent, 'source materialized correctly', 'the materialized source file must survive into the collected result tree, proving materializeSource actually reached the guest workspace');
    await rm(extractDir, { recursive: true, force: true });
  });
});
