import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { join } from 'node:path';
import { _internal, DockerSbxBackend, probeSbxPreflight } from '../lib/federation-docker-backend.mjs';

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

function identityCommandStub({ daemonReady = true, policyReady = true, dockerLogin = true } = {}) {
  const calls = [];
  const state = { daemonReady, policyReady, dockerLogin };
  const runCommand = async (command, args, options) => {
    calls.push({ args, env: options.env });
    if (args[0] === 'version') return result({ stdout: 'sbx version: v0.35.0 abc123' });
    if (args[0] === 'diagnose') {
      if (!state.daemonReady) return result({ code: 1, stderr: 'daemon connection refused' });
      return state.dockerLogin
        ? result({ stdout: 'Daemon healthy\nDocker authentication healthy' })
        : result({ code: 1, stdout: 'Daemon healthy', stderr: 'user is not authenticated to Docker' });
    }
    if (args[0] === 'policy' && args[1] === 'ls') {
      return state.policyReady
        ? result({ stdout: 'Policy rules' })
        : result({ code: 1, stderr: 'global network policy has not been initialized' });
    }
    if (args[0] === 'daemon' && args[1] === 'start' && args[2] === '--detach') {
      state.daemonReady = true;
      return result({ stdout: 'daemon started' });
    }
    if (args[0] === 'policy' && args[1] === 'init' && args[2] === 'balanced') {
      state.policyReady = true;
      return result({ stdout: 'policy initialized' });
    }
    if (command === 'dpkg-query') return result({ stdout: 'docker-sbx\tinstalled\t0.35.0\ndocker-ce\tinstalled\t28.0.0\ncontainerd.io\tinstalled\t2.1.0\n' });
    if (command === 'docker') return result({ stdout: '28.0.0' });
    if (command === 'containerd') return result({ stdout: 'containerd github.com/containerd/containerd v2.1.0' });
    if (command === 'test') return result();
    throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
  };
  return { calls, runCommand, state };
}

test('preflight classifies a fully ready Ubuntu sbx installation', () => {
  const checks = byName(healthyInputs());
  assert.equal(Object.keys(checks).length, 6);
  assert.ok(Object.values(checks).every((item) => item.ok));
  assert.ok(Object.values(checks).every((item) => typeof item.detail === 'string' && typeof item.fix === 'string'));
});

test('every preflight detail is one plain sentence while raw command output stays in diagnostics', () => {
  const hostile = '\u001b[32m✓\u001b[0m Daemon healthy\n╰─ detailed terminal output';
  const linux = Object.values(byName(healthyInputs({ diagnose: result({ stdout: hostile }) })));
  const windows = Object.values(byName(healthyInputs({
    platformName: 'win32',
    version: result({ stdout: hostile }),
    hypervisorPlatform: result({ stdout: hostile }),
    diagnose: result({ stdout: hostile }),
  })));
  for (const item of [...linux, ...windows]) {
    assert.doesNotMatch(item.detail, /[\r\n\x1b\u2500-\u257f]/, `${item.name} detail leaked terminal formatting`);
    assert.equal(item.detail.split(/[.!?]/).filter(Boolean).length, 1, `${item.name} detail must be one sentence`);
    assert.equal(typeof item.diagnostics, 'string');
  }
  assert.match(linux.find((item) => item.name === 'docker_login').diagnostics, /Daemon healthy/);
  assert.match(windows.find((item) => item.name === 'sbx_install').diagnostics, /\x1b\[32m/);
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

test('probeCapabilities starts a stopped daemon under the isolated Federation sbx identity, then passes', async () => {
  const stub = identityCommandStub({ daemonReady: false });
  const report = await new DockerSbxBackend().probeCapabilities({ runCommand: stub.runCommand, platformName: 'linux' });
  assert.equal(report.available, true);
  assert.deepEqual(report.identity_repairs.map((item) => item.name), ['sbx_daemon']);
  const start = stub.calls.find((call) => call.args.join(' ') === 'daemon start --detach');
  assert.ok(start, 'expected the stopped daemon to be started');
  assert.equal(start.env.HOME, _internal.sbxHome());
});

test('probeCapabilities initializes an uninitialized balanced policy under the isolated Federation sbx identity, then passes', async () => {
  const stub = identityCommandStub({ policyReady: false });
  const report = await new DockerSbxBackend().probeCapabilities({ runCommand: stub.runCommand, platformName: 'linux' });
  assert.equal(report.available, true);
  assert.deepEqual(report.identity_repairs.map((item) => item.name), ['network_policy']);
  const initialize = stub.calls.find((call) => call.args.join(' ') === 'policy init balanced');
  assert.ok(initialize, 'expected the missing policy to be initialized');
  assert.equal(initialize.env.HOME, _internal.sbxHome());
});

test('probeCapabilities leaves Docker login as the only manual preflight failure after identity setup is ready', async () => {
  const stub = identityCommandStub({ dockerLogin: false });
  const report = await new DockerSbxBackend().probeCapabilities({ runCommand: stub.runCommand, platformName: 'linux' });
  assert.equal(report.available, false);
  assert.deepEqual(report.preflight.checks.filter((item) => !item.ok).map((item) => item.name), ['docker_login']);
  assert.deepEqual(report.identity_repairs, []);
  assert.equal(stub.calls.some((call) => call.args[0] === 'daemon' || (call.args[0] === 'policy' && call.args[1] === 'init')), false);
});

test('after Docker sign-in is confirmed, the existing daemon and policy repairs lead directly to a ready contribution preflight', async () => {
  const stub = identityCommandStub({ daemonReady: false, policyReady: false, dockerLogin: false });
  const blocked = await new DockerSbxBackend().probeCapabilities({ runCommand: stub.runCommand, platformName: 'linux' });
  assert.equal(blocked.available, false);
  assert.deepEqual(blocked.identity_repairs.map((item) => item.name), ['sbx_daemon', 'network_policy']);
  assert.deepEqual(blocked.preflight.checks.filter((item) => !item.ok).map((item) => item.name), ['docker_login']);

  stub.state.dockerLogin = true;
  const ready = await new DockerSbxBackend().probeCapabilities({ runCommand: stub.runCommand, platformName: 'linux' });
  assert.equal(ready.available, true);
  assert.equal(ready.preflight.ok, true);
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

test('Windows preflight uses where, checks HypervisorPlatform, and skips Linux-only checks', async () => {
  const calls = [];
  const report = await probeSbxPreflight({
    platformName: 'win32',
    runCommand: async (command, args) => {
      calls.push([command, args]);
      if (command === 'where' && args[0] === 'sbx') return result({ stdout: 'C:\\Program Files\\Docker\\sbx.exe' });
      if (command === 'powershell.exe') return result({ stdout: 'Enabled' });
      if (args[0] === 'diagnose') return result({ stdout: 'Daemon healthy\nDocker authentication healthy' });
      throw new Error(`unexpected command: ${command} ${args.join(' ')}`);
    },
  });
  assert.equal(report.ok, true);
  assert.deepEqual(report.checks.map((item) => item.name), ['sbx_install', 'hypervisor_platform', 'docker_login', 'windows_file_permissions']);
  assert.ok(calls.some(([command, args]) => command === 'where' && args[0] === 'sbx'));
  assert.ok(calls.some(([command, args]) => command === 'powershell.exe' && args.some((arg) => arg.includes('Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform'))));
  assert.ok(!calls.some(([command]) => ['dpkg-query', 'docker', 'containerd', 'test'].includes(command)));
});

test('Windows preflight routes HypervisorPlatform recovery through installer repair before an administrator fallback', () => {
  const checks = byName(healthyInputs({
    platformName: 'win32',
    version: result({ stdout: 'C:\\Program Files\\Docker\\sbx.exe' }),
    hypervisorPlatform: result({ stdout: 'Disabled' }),
  }));
  assert.equal(checks.hypervisor_platform.ok, false);
  assert.match(checks.hypervisor_platform.fix, /^Reinstall or run the Federation installer's Repair action\./);
  assert.match(checks.hypervisor_platform.fix, /Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart$/);
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
