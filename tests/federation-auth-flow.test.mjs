import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startAuthFlow, isProviderSecretSet, describeAuthRequirement, AuthFlowError } from '../lib/federation-auth-flow.mjs';
import { CODEX_HARNESS, CLAUDE_CODE_HARNESS } from '../lib/federation-harnesses.mjs';

// All tests here use a STUB sbx binary — never invoke real `--oauth` (hits
// the real OpenAI OAuth endpoint, opens a real local callback listener, and
// leaves real host state). This mirrors the live-probe lesson: a real
// `sbx secret set -g openai --oauth` run must always be killed cleanly, and
// this suite proves the wrapper does that without ever risking the real call.

async function stubSbx(script) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-authflow-'));
  const path = join(dir, 'sbx');
  await writeFile(path, `#!/bin/sh\n${script}\n`);
  await chmod(path, 0o755);
  return path;
}

test('describeAuthRequirement: Codex (host-url-flow) is drivable', () => {
  const desc = describeAuthRequirement(CODEX_HARNESS);
  assert.equal(desc.drivable, true);
  assert.equal(desc.flow_shape, 'host-url-flow');
});

test('describeAuthRequirement: Claude Code (interactive-session-flow) is honestly NOT drivable — no forced {url} shape', () => {
  const desc = describeAuthRequirement(CLAUDE_CODE_HARNESS);
  assert.equal(desc.drivable, false);
  assert.equal(desc.flow_shape, 'interactive-session-flow');
  assert.match(desc.instruction, /sbx run claude/);
  assert.match(desc.instruction, /cannot drive this host-side/);
});

test('startAuthFlow refuses a non-docker-native-oauth harness', () => {
  const fakeSpec = { ...CODEX_HARNESS, auth_strategy: 'host-env-proxy' };
  assert.throws(() => startAuthFlow(fakeSpec), AuthFlowError);
});

test('startAuthFlow refuses interactive-session-flow (Claude) rather than faking a URL', () => {
  assert.throws(() => startAuthFlow(CLAUDE_CODE_HARNESS), AuthFlowError);
});

test('isProviderSecretSet: detect-first correctly reads "not set" from a stub matching real sbx v0.35.0 empty-result text', async () => {
  const sbxBin = await stubSbx(`
    if [ "$1" = "secret" ] && [ "$2" = "ls" ]; then
      echo 'No secrets found for scope "(global)" and service "openai".'
      exit 0
    fi
  `);
  const result = await isProviderSecretSet(CODEX_HARNESS, { sbxBin });
  assert.equal(result.alreadySet, false);
});

test('isProviderSecretSet: detect-first correctly reads "already set" from a nonempty secret listing', async () => {
  const sbxBin = await stubSbx(`
    if [ "$1" = "secret" ] && [ "$2" = "ls" ]; then
      echo "openai  oauth  (global)"
      exit 0
    fi
  `);
  const result = await isProviderSecretSet(CODEX_HARNESS, { sbxBin });
  assert.equal(result.alreadySet, true);
});

test('startAuthFlow: waspflow drives the command itself and surfaces ONLY the parsed URL, never the raw command to the caller', async () => {
  const sbxBin = await stubSbx(`
    echo "Open this URL to sign in to Codex OAuth:"
    echo "https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz"
    sleep 0.2
    exit 0
  `);
  const handle = startAuthFlow(CODEX_HARNESS, { sbxBin, completionTimeoutMs: 2000 });
  const result = await handle.waitForCompletion();
  assert.equal(result.status, 'complete');
  assert.equal(handle.url, 'https://auth.openai.com/oauth/authorize?client_id=abc&state=xyz');
  assert.equal(handle.status, 'complete');
});

test('startAuthFlow: a failed flow (nonzero exit) is reported as failed, not silently swallowed', async () => {
  const sbxBin = await stubSbx(`
    echo "some error" >&2
    exit 1
  `);
  const handle = startAuthFlow(CODEX_HARNESS, { sbxBin, urlTimeoutMs: 500, completionTimeoutMs: 2000 });
  const result = await handle.waitForCompletion();
  assert.equal(result.status, 'failed');
  assert.match(result.detail, /some error/);
});

test('startAuthFlow: a spawn failure (binary does not exist) is reported as failed, not an uncaught ReferenceError', async () => {
  const handle = startAuthFlow(CODEX_HARNESS, { sbxBin: '/nonexistent/path/to/sbx-binary-xyz', urlTimeoutMs: 2000 });
  const result = await handle.waitForCompletion();
  assert.equal(result.status, 'failed');
  assert.match(result.detail, /failed to spawn/);
  assert.match(result.detail, /sbx-binary-xyz/);
});

test('startAuthFlow: cancel() actually kills the OS process, even if it ignores SIGTERM — no leaked listener (the exact live-probe lesson)', async () => {
  // A live probe against real sbx found that SIGTERM is not reliably
  // delivered/handled in every environment — a trap-holding child survived
  // both `child.kill('SIGTERM')` and a plain shell `kill -TERM` run
  // completely outside Node. This stub deliberately IGNORES SIGTERM
  // (`trap '' TERM`) to force the SIGKILL fallback path. Asserting the
  // process is ACTUALLY DEAD (not just that our JS-side status flipped) is
  // the honest test here, since trusting a cooperative signal handler is
  // exactly what proved unreliable.
  const sbxBin = await stubSbx(`
    echo "Open this URL to sign in to Codex OAuth:"
    echo "https://auth.openai.com/oauth/authorize?client_id=abc"
    trap '' TERM
    sleep 30
  `);
  const handle = startAuthFlow(CODEX_HARNESS, { sbxBin, completionTimeoutMs: 10_000 });
  await new Promise((resolve) => {
    const check = setInterval(() => {
      if (handle.url) { clearInterval(check); resolve(); }
    }, 20);
  });
  handle.cancel();
  const result = await handle.waitForCompletion();
  assert.equal(result.status, 'failed');
  assert.equal(handle.status, 'cancelled');
  // The SIGKILL fallback fires ~1000ms after SIGTERM if still alive; give
  // it a margin past that before checking. sbxBin's path is unique per test
  // (mkdtemp), but `pgrep -f <path>` run via execSync('sh -c ...') matches
  // its OWN command line too (the path string appears in argv of the pgrep
  // invocation itself) — filter those self-matches out by process name,
  // keeping only a real /bin/sh child running the stub script.
  await new Promise((r) => setTimeout(r, 1500));
  const { execSync } = await import('node:child_process');
  let stillRunning = false;
  try {
    const out = execSync(`pgrep -af ${sbxBin}`, { stdio: 'pipe' }).toString();
    stillRunning = out.split('\n').some((line) => line.trim() && !/pgrep|sh -c/.test(line));
  } catch {
    stillRunning = false; // pgrep exits nonzero when no process matches — it's gone
  }
  assert.equal(stillRunning, false, 'child process ignoring SIGTERM should have been SIGKILLed by the cancel() fallback');
});

test('startAuthFlow: times out and cancels if no URL ever appears', async () => {
  const sbxBin = await stubSbx(`
    sleep 10
  `);
  const handle = startAuthFlow(CODEX_HARNESS, { sbxBin, urlTimeoutMs: 200 });
  const result = await handle.waitForCompletion();
  assert.equal(result.status, 'failed');
  assert.match(result.detail, /timed out.*login URL/);
  assert.equal(handle.status, 'cancelled');
});
