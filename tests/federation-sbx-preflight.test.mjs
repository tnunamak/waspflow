import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { _internal, probeSbxPreflight } from '../lib/federation-docker-backend.mjs';

const execFileAsync = promisify(execFile);
const CLI = join(process.cwd(), 'bin', 'waspflow-federation');

function result(overrides = {}) {
  return { code: 0, stdout: '', stderr: '', ...overrides };
}

function healthyInputs(overrides = {}) {
  return {
    platformName: 'linux',
    version: result({ stdout: 'sbx version: v0.35.0 abc123' }),
    packages: result({ stdout: 'docker-sbx\tinstalled\t0.35.0\ndocker-ce\tinstalled\t28.0.0\ncontainerd.io\tinstalled\t2.1.0\n' }),
    dockerVersion: result({ stdout: '28.0.0' }),
    containerdVersion: result({ stdout: 'containerd github.com/containerd/containerd v2.1.0' }),
    diagnose: result({ stdout: 'Daemon healthy\nDocker authentication healthy' }),
    policy: result({ stdout: 'Policy rules' }),
    kvmReadable: result(),
    kvmWritable: result(),
    ...overrides,
  };
}

function byName(inputs) {
  return Object.fromEntries(_internal.preflightChecks(inputs).map((item) => [item.name, item]));
}

test('preflight classifies a fully ready Ubuntu sbx installation', () => {
  const checks = byName(healthyInputs());
  assert.equal(Object.keys(checks).length, 6);
  assert.ok(Object.values(checks).every((item) => item.ok));
  assert.ok(Object.values(checks).every((item) => typeof item.detail === 'string' && typeof item.fix === 'string'));
});

test('preflight rejects a bare sbx binary that was not installed as docker-sbx', () => {
  const checks = byName(healthyInputs({ packages: result({ stdout: 'docker-ce\tinstalled\t28.0.0\ncontainerd.io\tinstalled\t2.1.0\n' }) }));
  assert.equal(checks.sbx_install.ok, false);
  assert.match(checks.sbx_install.detail, /copied binary/i);
  assert.match(checks.sbx_install.fix, /docker-sbx/);
});

test('preflight rejects the exact transfer.v1 containerd failure', () => {
  const checks = byName(healthyInputs({ diagnose: result({ stdout: 'Daemon healthy\nio.containerd.transfer.v1: no plugins registered' }) }));
  assert.equal(checks.docker_runtime.ok, false);
  assert.match(checks.docker_runtime.detail, /transfer\.v1/);
  assert.match(checks.docker_runtime.fix, /docker-ce/);
});

test('preflight rejects an unhealthy sbx daemon diagnostic', () => {
  const checks = byName(healthyInputs({ diagnose: result({ code: 1, stderr: 'daemon connection refused' }) }));
  assert.equal(checks.sbx_daemon.ok, false);
  assert.match(checks.sbx_daemon.fix, /sbx daemon stop/);
});

test('preflight rejects the exact uninitialized policy diagnostic and offers the safe fix', () => {
  const checks = byName(healthyInputs({ policy: result({ code: 1, stderr: 'global network policy has not been initialized' }) }));
  assert.equal(checks.network_policy.ok, false);
  assert.match(checks.network_policy.detail, /has not been initialized/);
  assert.match(checks.network_policy.fix, /doctor --fix-policy/);
});

test('preflight rejects the exact KVM permission diagnostic', () => {
  const checks = byName(healthyInputs({ diagnose: result({ stdout: 'Daemon healthy\nKVM error: Permission denied (os error 13)' }) }));
  assert.equal(checks.kvm_access.ok, false);
  assert.match(checks.kvm_access.fix, /usermod -aG kvm/);
});

test('preflight rejects the exact Docker authentication diagnostic', () => {
  const checks = byName(healthyInputs({ diagnose: result({ stdout: 'Daemon healthy\nuser is not authenticated to Docker' }) }));
  assert.equal(checks.docker_login.ok, false);
  assert.match(checks.docker_login.fix, /^sbx login$/);
});

test('probeSbxPreflight builds its JSON-ready report from stubbed command output', async () => {
  const report = await probeSbxPreflight({
    platformName: 'darwin',
    runCommand: async (_command, args) => {
      if (args[0] === 'version') return result({ stdout: 'sbx version: v0.35.0' });
      if (args[0] === 'diagnose') return result({ stdout: 'Daemon healthy\nDocker authentication healthy' });
      if (args[0] === 'policy') return result({ stdout: 'Policy rules' });
      throw new Error(`unexpected command: ${args.join(' ')}`);
    },
  });
  assert.equal(report.schema_version, 1);
  assert.equal(report.ok, true);
  assert.equal(report.checks.length, 6);
});

test('doctor --json returns a structured setup_required event, never a stack trace', async () => {
  await assert.rejects(execFileAsync(process.execPath, [CLI, 'doctor', '--json'], {
    env: { ...process.env, WASPFLOW_SBX_BIN: '/definitely/missing/sbx' },
  }), (error) => {
    const event = JSON.parse(error.stdout);
    assert.equal(event.schema_version, 1);
    assert.equal(event.type, 'sandbox_preflight');
    assert.equal(event.status, 'setup_required');
    assert.ok(event.checks.some((item) => item.name === 'sbx_install' && item.ok === false));
    assert.doesNotMatch(error.stderr, /\.mjs:\d+:\d+|\bat \w+ \(/);
    return true;
  });
});
