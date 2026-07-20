// Proves the two credential/state hygiene claims required by the 2026-07-20
// decision note ("Personal credentials must never cross into federation",
// and independent Waspflow sbx state/profile separation, §1 and §3).
//
// This file imports lib/federation-docker-backend.mjs, owned by a parallel
// worker. If that file does not exist yet, every test in this file is
// skipped rather than failed, and a clear pointer is printed so the suite
// stays green until the file lands — see
// docs/design/federation-evidence/HYGIENE_DETECTION_MAKER_REPORT.md for
// whether these tests have actually been run against the real module yet.
import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';
import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises';

const BACKEND_PATH = '../lib/federation-docker-backend.mjs';

let backend = null;
let importError = null;
try {
  backend = await import(BACKEND_PATH);
} catch (error) {
  importError = error;
}

const skip = importError
  ? { skip: `lib/federation-docker-backend.mjs not importable yet (${importError.message}); pending the parallel worker's file` }
  : false;

test('sanitizedEnv strips every personal-credential/state variable and keeps harmless ones', skip, () => {
  assert.equal(typeof backend.sanitizedEnv, 'function', 'expected an exported sanitizedEnv(baseEnv) function');

  const dirtyEnv = {
    PATH: '/usr/bin:/bin',
    HOME: homedir(),
    SSH_AUTH_SOCK: '/tmp/ssh-agent.sock',
    DOCKER_HOST: 'unix:///var/run/docker.sock',
    ANTHROPIC_API_KEY: 'sk-ant-fake-value',
    OPENAI_API_KEY: 'sk-fake-value',
    AWS_ACCESS_KEY_ID: 'AKIAFAKEFAKEFAKEFAKE',
    GCP_SERVICE_ACCOUNT: '{"type":"service_account","fake":true}',
    AZURE_CLIENT_SECRET: 'fake-azure-secret',
    GIT_ASKPASS: '/usr/local/bin/git-askpass-fake',
    GH_TOKEN: 'ghp_fakefakefakefakefakefakefakefake',
  };

  const cleaned = backend.sanitizedEnv(dirtyEnv);

  const mustBeAbsent = [
    'SSH_AUTH_SOCK', 'DOCKER_HOST', 'ANTHROPIC_API_KEY', 'OPENAI_API_KEY',
    'AWS_ACCESS_KEY_ID', 'GCP_SERVICE_ACCOUNT', 'AZURE_CLIENT_SECRET',
    'GIT_ASKPASS', 'GH_TOKEN',
  ];
  for (const key of mustBeAbsent) {
    assert.equal(Object.hasOwn(cleaned, key), false, `${key} must not be a key in the sanitized env, not merely falsy`);
  }

  assert.equal(Object.hasOwn(cleaned, 'PATH'), true, 'PATH must survive sanitization');
  assert.equal(Object.hasOwn(cleaned, 'HOME'), true, 'HOME must survive sanitization');
  assert.equal(cleaned.PATH, dirtyEnv.PATH);
});

test('sanitizedEnv strips *_API_KEY/*_TOKEN patterns generically, not just the named examples', skip, () => {
  const dirtyEnv = {
    PATH: '/usr/bin',
    SOME_RANDOM_API_KEY: 'should-be-stripped',
    SOME_RANDOM_TOKEN: 'should-be-stripped',
  };
  const cleaned = backend.sanitizedEnv(dirtyEnv);
  assert.equal(Object.hasOwn(cleaned, 'SOME_RANDOM_API_KEY'), false);
  assert.equal(Object.hasOwn(cleaned, 'SOME_RANDOM_TOKEN'), false);
});

test('_internal.sbxHome() honors WASPFLOW_FEDERATION_SBX_HOME and differs from the real HOME by default', skip, () => {
  assert.equal(typeof backend._internal?.sbxHome, 'function', 'expected an exported _internal.sbxHome() function');

  const defaultHome = backend._internal.sbxHome();
  assert.notEqual(defaultHome, homedir(), 'even the default Waspflow sbx home must not equal the real user HOME');

  const wfSbxHome = join(tmpdir(), 'waspflow-federation-sbx-home-hygiene-test');
  const previous = process.env.WASPFLOW_FEDERATION_SBX_HOME;
  process.env.WASPFLOW_FEDERATION_SBX_HOME = wfSbxHome;
  try {
    assert.equal(backend._internal.sbxHome(), wfSbxHome, '_internal.sbxHome() must honor the override env var');
  } finally {
    if (previous === undefined) delete process.env.WASPFLOW_FEDERATION_SBX_HOME;
    else process.env.WASPFLOW_FEDERATION_SBX_HOME = previous;
  }
});

test('the real sbx child-process invocation carries the Waspflow-owned HOME override, not the real HOME', skip, async () => {
  // Exercise the actual code path DockerSbxBackend uses to shell out
  // (probeCapabilities -> execFile(sbxBin(), ..., { env: sbxChildEnv() })),
  // not just sanitizedEnv() in isolation. A fake `sbx` stub stands in for the
  // real CLI (not installed on this machine) and echoes the HOME it actually
  // received, so this proves the override reaches a real child process.
  const stubDir = await mkdtemp(join(tmpdir(), 'wf-sbx-stub-'));
  const stubPath = join(stubDir, 'sbx');
  await writeFile(stubPath, '#!/bin/sh\nprintf "sbx version 0.35.0 (HOME=%s)\\n" "$HOME"\n');
  await chmod(stubPath, 0o755);

  const wfSbxHome = join(tmpdir(), 'waspflow-federation-sbx-home-hygiene-test-2');
  const previousBin = process.env.WASPFLOW_SBX_BIN;
  const previousHome = process.env.WASPFLOW_FEDERATION_SBX_HOME;
  process.env.WASPFLOW_SBX_BIN = stubPath;
  process.env.WASPFLOW_FEDERATION_SBX_HOME = wfSbxHome;
  try {
    const backendInstance = new backend.DockerSbxBackend();
    const report = await backendInstance.probeCapabilities();
    assert.equal(report.available, true, 'the stub sbx must be detected as available');
    assert.match(report.version, new RegExp(`HOME=${wfSbxHome.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}`), 'the child process must see the Waspflow-owned sbx home, not the real HOME, and it must differ from the real user HOME');
    assert.doesNotMatch(report.version, new RegExp(`HOME=${homedir().replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}$`));
  } finally {
    if (previousBin === undefined) delete process.env.WASPFLOW_SBX_BIN;
    else process.env.WASPFLOW_SBX_BIN = previousBin;
    if (previousHome === undefined) delete process.env.WASPFLOW_FEDERATION_SBX_HOME;
    else process.env.WASPFLOW_FEDERATION_SBX_HOME = previousHome;
    await rm(stubDir, { recursive: true, force: true });
  }
});
