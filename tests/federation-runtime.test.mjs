import test from 'node:test';
import assert from 'node:assert/strict';
import { validateJobSpec, ValidationError, SandboxBackend, FORBIDDEN_FIELDS } from '../lib/federation-runtime.mjs';

const validSpec = () => ({
  job_id: 'job-1',
  image: 'wf-federation-guest:v0',
  entrypoint: 'wf-guest-entrypoint',
  resources: { cpu: 2, memory_mib: 4096, storage_mib: 2048, wall_seconds: 3600, output_bytes: 10485760, network_bytes: 104857600, max_processes: 256 },
  inputs: [{ artifact_id: 'sha256:' + 'a'.repeat(64), dest: 'work/source.tar' }],
  output_manifest: ['work/result.patch'],
  egress_policy_id: 'wf-relay-v0',
  capability_token: 'wf-job-1-token',
});

test('accepts a well-formed ValidatedJobSpec', () => {
  assert.deepEqual(validateJobSpec(validSpec()), validSpec());
});

test('rejects unknown top-level fields', () => {
  const spec = { ...validSpec(), host_cwd: '/home/user/project' };
  assert.throws(() => validateJobSpec(spec), ValidationError);
});

for (const field of FORBIDDEN_FIELDS) {
  test(`rejects forbidden field: ${field}`, () => {
    const spec = { ...validSpec(), extra: { [field]: 'x' } };
    assert.throws(() => validateJobSpec(spec), ValidationError);
  });
}

test('rejects path traversal in output_manifest', () => {
  const spec = validSpec();
  spec.output_manifest = ['../../etc/passwd'];
  assert.throws(() => validateJobSpec(spec), /safe relative path/);
});

test('rejects absolute paths in input dest', () => {
  const spec = validSpec();
  spec.inputs = [{ artifact_id: 'sha256:' + 'a'.repeat(64), dest: '/etc/passwd' }];
  assert.throws(() => validateJobSpec(spec), /safe relative path/);
});

test('rejects non-positive resource limits', () => {
  const spec = validSpec();
  spec.resources.wall_seconds = 0;
  assert.throws(() => validateJobSpec(spec), /resources.wall_seconds/);
});

test('rejects missing capability_token', () => {
  const spec = validSpec();
  delete spec.capability_token;
  assert.throws(() => validateJobSpec(spec), ValidationError);
});

test('SandboxBackend base methods throw NotImplementedError, never silently no-op', async () => {
  const backend = new SandboxBackend();
  await assert.rejects(() => backend.probeCapabilities(), /NotImplementedError|probeCapabilities/);
  await assert.rejects(() => backend.prepare({}), /prepare/);
  await assert.rejects(() => backend.start({}), /start/);
  await assert.rejects(() => backend.collectDeclaredOutputs({}, []), /collectDeclaredOutputs/);
  await assert.rejects(() => backend.cancel({}), /cancel/);
  await assert.rejects(() => backend.destroy({}), /destroy/);
  await assert.rejects(() => backend.inspect({}), /inspect/);
});
