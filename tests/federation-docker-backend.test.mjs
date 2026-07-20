import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, writeFile, rm, chmod, symlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  DockerSbxBackend,
  sanitizedEnv,
  BACKEND_ID,
  _internal,
} from '../lib/federation-docker-backend.mjs';

const execFile = promisify(execFileCb);

const validJob = (overrides = {}) => ({
  job_id: 'job-docker-1',
  image: 'wf-federation-guest:v0',
  entrypoint: 'wf-guest-entrypoint',
  resources: { cpu: 2, memory_mib: 4096, storage_mib: 2048, wall_seconds: 3600, output_bytes: 10485760, network_bytes: 104857600, max_processes: 256 },
  inputs: [],
  output_manifest: [],
  egress_policy_id: 'wf-relay-v0',
  capability_token: 'wf-job-1-token',
  ...overrides,
});

// --- sanitizedEnv: no sbx binary required -----------------------------------

test('sanitizedEnv strips SSH agent and DOCKER_HOST exactly', () => {
  const out = sanitizedEnv({ SSH_AUTH_SOCK: '/tmp/agent.sock', DOCKER_HOST: 'tcp://1.2.3.4:2375', KEEP_ME: 'yes' });
  assert.equal(out.SSH_AUTH_SOCK, undefined);
  assert.equal(out.DOCKER_HOST, undefined);
  assert.equal(out.KEEP_ME, 'yes');
});

test('sanitizedEnv strips *_API_KEY and *_TOKEN patterns', () => {
  const out = sanitizedEnv({
    OPENAI_API_KEY: 'sk-x',
    ANTHROPIC_API_KEY: 'sk-y',
    GITHUB_TOKEN: 'ghp_x',
    RANDOM_TOKEN: 'z',
    PATH: '/usr/bin',
  });
  assert.equal(out.OPENAI_API_KEY, undefined);
  assert.equal(out.ANTHROPIC_API_KEY, undefined);
  assert.equal(out.GITHUB_TOKEN, undefined);
  assert.equal(out.RANDOM_TOKEN, undefined);
  assert.equal(out.PATH, '/usr/bin');
});

test('sanitizedEnv strips cloud provider and git credential-helper vars', () => {
  const out = sanitizedEnv({
    AWS_SECRET_ACCESS_KEY: 'a',
    AWS_ACCESS_KEY_ID: 'b',
    GCP_PROJECT: 'c',
    GOOGLE_APPLICATION_CREDENTIALS: 'd',
    AZURE_CLIENT_SECRET: 'e',
    GIT_ASKPASS: 'f',
    GIT_SSH_COMMAND: 'g',
    GH_TOKEN: 'h',
    NPM_TOKEN: 'i',
    DOCKER_CONFIG: 'j',
    HOME: '/home/dev',
  });
  for (const key of ['AWS_SECRET_ACCESS_KEY', 'AWS_ACCESS_KEY_ID', 'GCP_PROJECT', 'GOOGLE_APPLICATION_CREDENTIALS', 'AZURE_CLIENT_SECRET', 'GIT_ASKPASS', 'GIT_SSH_COMMAND', 'GH_TOKEN', 'NPM_TOKEN', 'DOCKER_CONFIG']) {
    assert.equal(out[key], undefined, `${key} should have been stripped`);
  }
  assert.equal(out.HOME, '/home/dev');
});

test('sanitizedEnv is non-mutating and tolerates empty/undefined input', () => {
  const base = { SSH_AUTH_SOCK: '/x' };
  const out = sanitizedEnv(base);
  assert.equal(base.SSH_AUTH_SOCK, '/x', 'must not mutate the input object');
  assert.deepEqual(sanitizedEnv(undefined), {});
  assert.deepEqual(sanitizedEnv({}), {});
});

// --- scratch directory / sandbox naming -------------------------------------

test('scratch directory creation produces a unique, disposable directory per job', async () => {
  const scratchRoot = await mkdtemp(path.join(os.tmpdir(), 'wf-scratch-test-'));
  process.env.WASPFLOW_FEDERATION_SCRATCH_ROOT = scratchRoot;
  try {
    const backend = new DockerSbxBackend();
    const previousBin = process.env.WASPFLOW_SBX_BIN;
    // prepare() calls `sbx run`; point at a stub that always succeeds so we
    // can isolate scratch-dir behavior without a real sbx install.
    const stubDir = await writeStub('run-ok', 'exit 0');
    process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
    try {
      const handleA = await backend.prepare(validJob({ job_id: 'job-a' }));
      const handleB = await backend.prepare(validJob({ job_id: 'job-b' }));
      assert.notEqual(handleA.scratch_dir, handleB.scratch_dir);
      assert.ok(handleA.scratch_dir.startsWith(scratchRoot));
      assert.match(handleA.scratch_dir, /wf-job-/);
      const stat = await import('node:fs/promises').then((m) => m.stat(handleA.scratch_dir));
      assert.ok(stat.isDirectory());
      await rm(handleA.scratch_dir, { recursive: true, force: true });
      await rm(handleB.scratch_dir, { recursive: true, force: true });
    } finally {
      if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
      else process.env.WASPFLOW_SBX_BIN = previousBin;
      await rm(stubDir, { recursive: true, force: true });
    }
  } finally {
    delete process.env.WASPFLOW_FEDERATION_SCRATCH_ROOT;
    await rm(scratchRoot, { recursive: true, force: true });
  }
});

test('sandbox names are deterministic per job_id and distinct across jobs', () => {
  const a1 = _internal.sandboxNameFor('job-a');
  const a2 = _internal.sandboxNameFor('job-a');
  const b = _internal.sandboxNameFor('job-b');
  assert.equal(a1, a2);
  assert.notEqual(a1, b);
  assert.match(a1, /^wf-[0-9a-f]{16}$/);
});

// --- output_manifest path safety --------------------------------------------

test('isSafeRelativeOutputPath rejects traversal, absolute paths, and NUL bytes', () => {
  assert.equal(_internal.isSafeRelativeOutputPath('work/result.patch'), true);
  assert.equal(_internal.isSafeRelativeOutputPath('../../etc/passwd'), false);
  assert.equal(_internal.isSafeRelativeOutputPath('/etc/passwd'), false);
  assert.equal(_internal.isSafeRelativeOutputPath('work/../../escape'), false);
  assert.equal(_internal.isSafeRelativeOutputPath('work/./x'), false);
  assert.equal(_internal.isSafeRelativeOutputPath('a\0b'), false);
  assert.equal(_internal.isSafeRelativeOutputPath(''), false);
  assert.equal(_internal.isSafeRelativeOutputPath(undefined), false);
});

test('collectDeclaredOutputs rejects an unsafe manifest path before touching sbx', async () => {
  const backend = new DockerSbxBackend();
  const scratchDir = await mkdtemp(path.join(os.tmpdir(), 'wf-collect-test-'));
  const handle = { backend_id: BACKEND_ID, job_id: 'job-x', sandbox_id: 'wf-deadbeef', scratch_dir: scratchDir };
  try {
    await assert.rejects(
      () => backend.collectDeclaredOutputs(handle, ['../../etc/passwd']),
      /unsafe output path/,
    );
    await assert.rejects(
      () => backend.collectDeclaredOutputs(handle, ['/etc/passwd']),
      /unsafe output path/,
    );
  } finally {
    await rm(scratchDir, { recursive: true, force: true });
  }
});

test('collectDeclaredOutputs rejects a copied-out symlink instead of following it', async () => {
  const scratchDir = await mkdtemp(path.join(os.tmpdir(), 'wf-collect-symlink-'));
  const outDir = path.join(scratchDir, '.wf-outputs');
  await mkdir(outDir, { recursive: true });
  const target = path.join(scratchDir, 'real-secret.txt');
  await writeFile(target, 'secret');
  const linkPath = path.join(outDir, 'result.patch');
  await symlink(target, linkPath);

  // Stub `sbx cp` to a no-op success so collectDeclaredOutputs proceeds to the
  // post-copy symlink check against the (pre-seeded) local path.
  const stubDir = await writeStub('cp-noop', 'exit 0');
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
  try {
    const backend = new DockerSbxBackend();
    const handle = { backend_id: BACKEND_ID, job_id: 'job-y', sandbox_id: 'wf-cafebabe', scratch_dir: scratchDir };
    await assert.rejects(
      () => backend.collectDeclaredOutputs(handle, ['result.patch']),
      /symlink/,
    );
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    await rm(stubDir, { recursive: true, force: true });
    await rm(scratchDir, { recursive: true, force: true });
  }
});

// --- live-sbx-dependent behavior: stub executable or skip -------------------

async function sbxOnPath() {
  try {
    await execFile('sbx', ['--version']);
    return true;
  } catch (error) {
    return error && error.code !== 'ENOENT';
  }
}

async function writeStub(name, body) {
  const dir = await mkdtemp(path.join(os.tmpdir(), `wf-sbx-stub-${name}-`));
  const scriptPath = path.join(dir, 'sbx');
  await writeFile(scriptPath, `#!/usr/bin/env bash\nset -euo pipefail\n${body}\n`);
  await chmod(scriptPath, 0o755);
  return dir;
}

test('probeCapabilities reports unavailable (never throws) when sbx is missing', async () => {
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = '/nonexistent/path/to/sbx-that-does-not-exist';
  try {
    const backend = new DockerSbxBackend();
    const report = await backend.probeCapabilities();
    assert.equal(report.available, false);
    assert.equal(report.backend_id, BACKEND_ID);
    assert.ok(Array.isArray(report.missing_prerequisites) && report.missing_prerequisites.length > 0);
    assert.match(report.install_hint, /^https:\/\//);
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
  }
});

test('probeCapabilities reports available:true and forwards version via a stub sbx', async () => {
  const stubDir = await writeStub('version', 'echo "sbx version 0.35.0"');
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
  try {
    const backend = new DockerSbxBackend();
    const report = await backend.probeCapabilities();
    assert.equal(report.available, true);
    assert.equal(report.backend_id, BACKEND_ID);
    assert.match(report.version, /0\.35\.0/);
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    await rm(stubDir, { recursive: true, force: true });
  }
});

test('prepare() invokes `sbx run` with the scratch dir as workspace, never a real repo path', async () => {
  const stubDir = await writeStub('run-record', `
    echo "$@" >"$WF_STUB_LOG"
    exit 0
  `);
  const logPath = path.join(stubDir, 'invocation.log');
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
  process.env.WF_STUB_LOG = logPath;
  try {
    const backend = new DockerSbxBackend();
    const handle = await backend.prepare(validJob({ job_id: 'job-record' }));
    const invocation = await import('node:fs/promises').then((m) => m.readFile(logPath, 'utf8'));
    assert.match(invocation, /^run --name wf-[0-9a-f]{16} /);
    assert.ok(invocation.includes(handle.scratch_dir), 'sbx run must receive the disposable scratch dir as workspace');
    assert.ok(!invocation.includes(process.cwd()), 'sbx run must never receive the repo checkout as workspace');
    await rm(handle.scratch_dir, { recursive: true, force: true });
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    delete process.env.WF_STUB_LOG;
    await rm(stubDir, { recursive: true, force: true });
  }
});

test('destroy() independently verifies removal via `sbx ls` rather than trusting `sbx rm` exit code', async () => {
  // Stub: `rm` always exits 0, but `ls` keeps reporting the sandbox present
  // for the first call and absent afterward, exercising the retry-once path.
  const stubDir = await writeStub('destroy-retry', `
    state_file="$(dirname "$0")/state"
    case "$1" in
      rm)
        exit 0
        ;;
      ls)
        if [ ! -f "$state_file" ]; then
          touch "$state_file"
          echo "wf-target  running"
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
  `);
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
  try {
    const backend = new DockerSbxBackend();
    const scratchDir = await mkdtemp(path.join(os.tmpdir(), 'wf-destroy-test-'));
    const handle = { backend_id: BACKEND_ID, job_id: 'job-destroy', sandbox_id: 'wf-target', scratch_dir: scratchDir };
    const receipt = await backend.destroy(handle);
    assert.equal(receipt.removed, true);
    assert.equal(receipt.scratch_removed, true);
    assert.equal(receipt.job_id, 'job-destroy');
    assert.equal(receipt.sandbox_id, 'wf-target');
    assert.match(receipt.at, /^\d{4}-\d{2}-\d{2}T/);
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    await rm(stubDir, { recursive: true, force: true });
  }
});

test('destroy() honestly reports removed:false when `sbx ls` still shows the sandbox after retry', async () => {
  const stubDir = await writeStub('destroy-stuck', `
    case "$1" in
      rm) exit 0 ;;
      ls) echo "wf-stuck  running"; exit 0 ;;
      *) exit 0 ;;
    esac
  `);
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  process.env.WASPFLOW_SBX_BIN = path.join(stubDir, 'sbx');
  try {
    const backend = new DockerSbxBackend();
    const scratchDir = await mkdtemp(path.join(os.tmpdir(), 'wf-destroy-stuck-'));
    const handle = { backend_id: BACKEND_ID, job_id: 'job-stuck', sandbox_id: 'wf-stuck', scratch_dir: scratchDir };
    const receipt = await backend.destroy(handle);
    assert.equal(receipt.removed, false, 'must not lie about removal when sbx ls still shows the sandbox');
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    await rm(stubDir, { recursive: true, force: true });
  }
});

test('live sbx integration (real binary)', async (t) => {
  if (!(await sbxOnPath())) {
    console.log('SKIP: sbx not installed — skipping live sbx integration test');
    t.skip('sbx not installed');
    return;
  }
  const backend = new DockerSbxBackend();
  const report = await backend.probeCapabilities();
  assert.equal(report.available, true);
});
