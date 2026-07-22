import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startAuthFlow, isProviderSecretSet, describeAuthRequirement, AuthFlowError } from '../lib/federation-auth-flow.mjs';
import { CODEX_HARNESS, CLAUDE_CODE_HARNESS } from '../lib/federation-harnesses.mjs';

async function stubSbx(script) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-authflow-'));
  const path = join(dir, 'sbx');
  await writeFile(path, `#!/bin/sh\n${script}\n`);
  await chmod(path, 0o755);
  return path;
}

test('Claude Code subscription is a validated, drivable host-url-flow', () => {
  assert.equal(describeAuthRequirement(CLAUDE_CODE_HARNESS).drivable, true);
  assert.equal(CLAUDE_CODE_HARNESS.credential_discovery.login_command, 'claude auth login --claudeai');
  assert.equal(CLAUDE_CODE_HARNESS.credential_discovery.url_prompt_pattern, 'visit:');
  assert.deepEqual(CLAUDE_CODE_HARNESS.login_status_probe.success, { loggedIn: true });
});

test('startAuthFlow rejects a non-docker-native-oauth harness', async () => {
  const fakeSpec = { ...CODEX_HARNESS, auth_strategy: 'host-env-proxy' };
  await assert.rejects(startAuthFlow(fakeSpec, { sandboxId: 'job' }), AuthFlowError);
});

test('isProviderSecretSet detects an absent or present Docker secret', async () => {
  const absent = await stubSbx(`echo 'No secrets found for scope "(global)" and service "openai".'`);
  assert.equal((await isProviderSecretSet(CODEX_HARNESS, { sbxBin: absent })).alreadySet, false);
  const present = await stubSbx('echo "openai  oauth  (global)"');
  assert.equal((await isProviderSecretSet(CODEX_HARNESS, { sbxBin: present })).alreadySet, true);
});

test('startAuthFlow scrapes Codex host OAuth URL and proves completion through the sandbox status probe', async () => {
  const state = join(await mkdtemp(join(tmpdir(), 'wf-auth-state-')), 'ready');
  const sbxBin = await stubSbx(`
    if [ "$1" = exec ]; then
      if [ -f '${state}' ]; then echo 'SBX_CRED_OPENAI_MODE=oauth'; else echo 'SBX_CRED_OPENAI_MODE=none'; fi
      exit 0
    fi
    echo 'Open this URL to sign in to Codex OAuth:'
    echo 'https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz'
    touch '${state}'
  `);
  const flow = await startAuthFlow(CODEX_HARNESS, { sbxBin, sandboxId: 'codex-job', completionTimeoutMs: 2_000 });
  assert.equal(flow.url, 'https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz');
  assert.equal((await flow.waitForCompletion()).status, 'complete');
});

test('startAuthFlow accepts a provider URL emitted on stderr', async () => {
  const state = join(await mkdtemp(join(tmpdir(), 'wf-auth-state-')), 'ready');
  const sbxBin = await stubSbx(`
    if [ "$1" = exec ]; then
      if [ -f '${state}' ]; then echo 'SBX_CRED_OPENAI_MODE=oauth'; else echo 'SBX_CRED_OPENAI_MODE=none'; fi
      exit 0
    fi
    echo 'Open this URL to sign in to Codex OAuth:' >&2
    echo 'https://auth.openai.com/oauth/authorize?client_id=stderr&state=xyz' >&2
    touch '${state}'
  `);
  const flow = await startAuthFlow(CODEX_HARNESS, { sbxBin, sandboxId: 'codex-job', completionTimeoutMs: 2_000 });
  assert.equal(flow.url, 'https://auth.openai.com/oauth/authorize?client_id=stderr&state=xyz');
  assert.equal((await flow.waitForCompletion()).status, 'complete');
});

test('startAuthFlow gives a clear error instead of waiting on an existing OAuth overwrite prompt', async () => {
  const sbxBin = await stubSbx(`
    if [ "$1" = exec ]; then echo 'SBX_CRED_OPENAI_MODE=none'; exit 0; fi
    echo 'OPENAI OAuth token already exists. Overwrite? (y/N): Cancelled'
  `);
  await assert.rejects(
    startAuthFlow(CODEX_HARNESS, { sbxBin, sandboxId: 'codex-job' }),
    /existing OpenAI OAuth credential needs attention/,
  );
});

test('startAuthFlow publishes a cancellable handle before a slow URL is available', async () => {
  const sbxBin = await stubSbx(`
    if [ "$1" = exec ]; then echo 'SBX_CRED_OPENAI_MODE=none'; exit 0; fi
    sleep 10
  `);
  let handle;
  const starting = startAuthFlow(CODEX_HARNESS, { sbxBin, sandboxId: 'codex-job', urlTimeoutMs: 20_000, onHandle: (value) => { handle = value; } });
  while (!handle) await new Promise((resolve) => setTimeout(resolve, 5));
  handle.cancel();
  await assert.rejects(starting, /exited|login URL|cancelled/);
});

test('startAuthFlow runs Claude login inside the job sandbox, scrapes visit: URL, and waits for loggedIn:true', async () => {
  const stateDir = await mkdtemp(join(tmpdir(), 'wf-auth-state-'));
  const state = join(stateDir, 'ready');
  const sandboxRecord = join(stateDir, 'sandbox');
  const sbxBin = await stubSbx(`
    if [ "$1" = exec ] && [ "$4" = sh ]; then
      if [ -f '${state}' ]; then echo '{"loggedIn":true}'; else echo '{"loggedIn":false}'; fi
      exit 0
    fi
    if [ "$1" = exec ] && [ "$4" = claude ]; then
      printf '%s' "$2" > '${sandboxRecord}'
      echo "Opening browser to sign in… If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?state=abc"
      touch '${state}'
      exit 0
    fi
    exit 1
  `);
  const flow = await startAuthFlow(CLAUDE_CODE_HARNESS, { sbxBin, sandboxId: 'claude-job', completionTimeoutMs: 2_000 });
  assert.equal(flow.url, 'https://claude.com/cai/oauth/authorize?state=abc');
  assert.equal(await readFile(sandboxRecord, 'utf8'), 'claude-job');
  assert.equal((await flow.waitForCompletion()).status, 'complete');
});

test('startAuthFlow requires a job sandbox for guest status probes', async () => {
  await assert.rejects(startAuthFlow(CLAUDE_CODE_HARNESS), /requires the prepared job sandbox/);
});
