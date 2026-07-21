/**
 * Golden/contract test for the `--json` event contract emitted by
 * `bin/waspflow-federation` (SLICE 0 — event-contract versioning). This is
 * the drift backstop: it runs the REAL CLI as a subprocess against a real,
 * ephemeral coordinator (same pattern as tests/waspflow-federation-cli.
 * test.mjs) for a few canned scenarios, and asserts every emitted --json
 * line (a) parses as JSON, (b) has schema_version === 1, and (c) validates
 * against the source-of-truth schema in lib/federation-events.mjs (has the
 * `type` discriminator plus every required field for that type).
 *
 * Deliberately does NOT re-prove the federation loop itself (claim/verify/
 * run/submit already covered by tests/federation-{coordinator,submit,pull}.
 * test.mjs and tests/waspflow-federation-cli.test.mjs) — only that the
 * CLI's OWN event shape stays in sync with lib/federation-events.mjs.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPairSync } from 'node:crypto';
import { startCoordinator } from '../lib/federation-coordinator.mjs';
import { signEnvelope, jcs } from '../lib/federation-envelope.mjs';
import { buildTaskPayload } from '../lib/federation-submit.mjs';
import { SCHEMA_VERSION, validateEvent } from '../lib/federation-events.mjs';

const execFileAsync = promisify(execFile);
const CLI = join(process.cwd(), 'bin', 'waspflow-federation');

// A real, already-approved author identity — the coordinator's roster (see
// withCoordinator below) already has this key_id, so a task signed with it
// publishes cleanly without any of this file's tests needing to drive a
// `trust`/roster-fetch flow (irrelevant to the events-contract question).
const authorKeys = generateKeyPairSync('ed25519');
const authorPrivateKeyPem = authorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const authorPublicKeyPem = authorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const AUTHOR_KEY_ID = 'contract-test-author';

async function withCoordinator(fn) {
  const dataDir = await mkdtemp(join(tmpdir(), 'wf-fed-events-coordinator-'));
  const roster = new Map([[AUTHOR_KEY_ID, authorPublicKeyPem]]);
  const server = await startCoordinator({ dataDir, token: 'test-invite-token', roster, port: 0 });
  const { port } = server.address();
  try {
    await fn(`http://127.0.0.1:${port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function publishSignedTask(coordinatorUrl) {
  const artifact = (hex) => ({ sha256: hex.repeat(64), bytes: 1, media_type: 'text/plain' });
  const payload = buildTaskPayload({
    collective: 'test',
    displayId: 'events-contract-test',
    authorKeyId: AUTHOR_KEY_ID,
    source: artifact('a'),
    prompt: artifact('b'),
  });
  const envelope = signEnvelope(payload, authorPrivateKeyPem, AUTHOR_KEY_ID);
  const res = await fetch(`${coordinatorUrl}/tasks`, {
    method: 'POST',
    headers: { authorization: 'Bearer test-invite-token', 'content-type': 'application/json' },
    body: jcs(envelope),
  });
  if (!res.ok) throw new Error(`publishSignedTask failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function withMemberHome(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-fed-events-member-'));
  try {
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function runCli(args, { home } = {}) {
  return execFileAsync(process.execPath, [CLI, ...args], {
    env: { ...process.env, WASPFLOW_FEDERATION_HOME: home },
  });
}

// Asserts the line parses as JSON, carries schema_version === 1, and
// validates against lib/federation-events.mjs's required-field list for its
// `type` — the three things a future GUI consumer must be able to rely on.
function assertValidEvent(stdout, expectedType) {
  const event = JSON.parse(stdout);
  assert.equal(event.schema_version, SCHEMA_VERSION, `expected schema_version ${SCHEMA_VERSION}, got ${JSON.stringify(event)}`);
  assert.equal(event.type, expectedType, `expected type '${expectedType}', got ${JSON.stringify(event)}`);
  const errors = validateEvent(event);
  assert.deepEqual(errors, [], `event failed schema validation: ${errors.join('; ')}\nevent: ${JSON.stringify(event)}`);
  return event;
}

test('not_joined: status --json before join validates against the schema', async () => {
  await withMemberHome(async (home) => {
    const { stdout } = await runCli(['status', '--json'], { home });
    assertValidEvent(stdout, 'not_joined');
  });
});

test('joined: join --json validates against the schema', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      const { stdout } = await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author', '--json'], { home });
      assertValidEvent(stdout, 'joined');
    });
  });
});

test('already_joined: joining twice --json validates against the schema', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      const { stdout } = await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author', '--json'], { home });
      assertValidEvent(stdout, 'already_joined');
    });
  });
});

test('member_status: status --json after join validates against the schema', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      const { stdout } = await runCli(['status', '--json'], { home });
      assertValidEvent(stdout, 'member_status');
    });
  });
});

test('trusted: trust --json validates against the schema', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });
      const pubkeyPem = '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZkcNBVMeGBosN5XTHB2/gz/H0yDxMeNRbhV+R7+ZCG0=\n-----END PUBLIC KEY-----\n';
      const { stdout } = await runCli(['trust', 'tim-author', pubkeyPem, '--json'], { home });
      assertValidEvent(stdout, 'trusted');
    });
  });
});

test('no_task_available: contribute --json with an empty queue validates against the schema', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });

      // Stub sbx reporting "already authenticated" so the harness-auth
      // preflight is skipped — this scenario is about task discovery
      // returning nothing, not auth (same stub pattern as
      // tests/waspflow-federation-cli.test.mjs).
      const stubHome = await mkdtemp('/tmp/x');
      const stubBinDir = await mkdtemp(join(tmpdir(), 'wf-fed-events-stubbin-'));
      const stubPath = join(stubBinDir, 'sbx');
      await writeFile(stubPath, `#!/bin/sh
case "$1 $2" in
  "version ") echo "sbx version: v0.35.0 abc123" ;;
  "diagnose ") printf 'Daemon healthy\\nDocker authentication healthy\\n' ;;
  "policy ls") echo "Policy rules" ;;
  "secret ls") echo "openai  oauth  (global)" ;;
  *) exit 1 ;;
esac
`);
      await writeFile(join(stubBinDir, 'dpkg-query'), '#!/bin/sh\nprintf "docker-sbx\\tinstalled\\t0.35.0\\ndocker-ce\\tinstalled\\t28.0.0\\ncontainerd.io\\tinstalled\\t2.1.0\\n"\n');
      await writeFile(join(stubBinDir, 'docker'), '#!/bin/sh\necho "28.0.0"\n');
      await writeFile(join(stubBinDir, 'containerd'), '#!/bin/sh\necho "containerd github.com/containerd/containerd v2.1.0"\n');
      await writeFile(join(stubBinDir, 'test'), '#!/bin/sh\nexit 0\n');
      await Promise.all(['sbx', 'dpkg-query', 'docker', 'containerd', 'test'].map((name) => chmod(join(stubBinDir, name), 0o755)));

      try {
        const { stdout } = await execFileAsync(process.execPath, [CLI, 'contribute', '--json'], {
          env: {
            ...process.env,
            WASPFLOW_FEDERATION_HOME: home,
            WASPFLOW_FEDERATION_SBX_HOME: stubHome,
            WASPFLOW_SBX_BIN: stubPath,
            PATH: `${stubBinDir}:${process.env.PATH}`,
          },
        });
        assertValidEvent(stdout, 'no_task_available');
      } finally {
        await rm(stubHome, { recursive: true, force: true });
        await rm(stubBinDir, { recursive: true, force: true });
      }
    });
  });
});

test('task_status: status --task-digest --json validates against the schema, with `type` immune to the coordinator record\'s own `status` field', async () => {
  await withCoordinator(async (coordinatorUrl) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });

      const { task_digest } = await publishSignedTask(coordinatorUrl);

      const { stdout } = await runCli(['status', '--task-digest', task_digest, '--json'], { home });
      const event = assertValidEvent(stdout, 'task_status');
      // The coordinator's own record status ('QUEUED') is real domain data
      // carried on `status` — proving `type` (not `status`) is what a
      // consumer must switch on, exactly the ambiguity this contract exists
      // to resolve.
      assert.equal(event.status, 'QUEUED');
    });
  });
});
