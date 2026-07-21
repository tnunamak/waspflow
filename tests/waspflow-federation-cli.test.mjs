/**
 * Integration tests for the GUIDED Federation v0 CLI
 * (`bin/waspflow-federation` — `waspflow federation join|contribute|submit|
 * status|trust`). This is the consumable UX layer added on top of the
 * already-proven loop (lib/federation-coordinator.mjs et al, covered by
 * tests/federation-{coordinator,submit,pull}.test.mjs); these tests exist to
 * prove the WRAPPER itself — config persistence, flag-filling, the roster/
 * trust translation — actually drives that real loop end-to-end, not that
 * the loop is correct (already proven elsewhere).
 *
 * Runs the real CLI as a subprocess against a real, ephemeral coordinator
 * (same `startCoordinator({port: 0})` pattern as
 * tests/federation-coordinator.test.mjs) so these tests exercise the actual
 * process boundary a non-technical user hits, not an in-process stub.
 *
 * Deliberately does NOT exercise `contribute`'s sandboxed-run path (needs a
 * real `sbx` install + harness auth — covered manually, see
 * docs/design/FEDERATION_V0_UX_REPORT.md's independent-verification section)
 * — only the parts reachable without a real sandbox: config/keypair
 * lifecycle, task discovery returning "nothing available", and the
 * roster/trust error translation.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { generateKeyPairSync } from 'node:crypto';
import { mkdtemp, readFile, writeFile, chmod, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startCoordinator } from '../lib/federation-coordinator.mjs';
import { signEnvelope, jcs } from '../lib/federation-envelope.mjs';
import { buildTaskPayload } from '../lib/federation-submit.mjs';

const execFileAsync = promisify(execFile);
const CLI = join(process.cwd(), 'bin', 'waspflow-federation');

// A real, already-approved author identity — simulates the coordinator
// operator having already added this key_id to their roster file (the one
// remaining, deliberately-human membership decision) BEFORE a fresh
// contributor ever runs `join`. Used to prove GET /roster auto-fetch
// actually eliminates the `trust` step on the default path, not just that
// the endpoint returns 200.
const preRegisteredAuthorKeys = generateKeyPairSync('ed25519');
const preRegisteredAuthorPrivateKeyPem = preRegisteredAuthorKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
const preRegisteredAuthorPublicKeyPem = preRegisteredAuthorKeys.publicKey.export({ type: 'spki', format: 'pem' });
const PRE_REGISTERED_AUTHOR_KEY_ID = 'tim-author';

async function withCoordinator(fn, { roster } = {}) {
  const dataDir = await mkdtemp(join(tmpdir(), 'wf-fed-cli-coordinator-'));
  // Coordinator needs at least one roster entry to start; a throwaway one
  // works fine when a test doesn't care about roster contents. Tests that
  // DO care (the GET /roster auto-fetch tests) pass a real roster Map.
  const defaultRoster = new Map([['placeholder', '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n-----END PUBLIC KEY-----\n']]);
  const server = await startCoordinator({ dataDir, token: 'test-invite-token', roster: roster || defaultRoster, port: 0 });
  const { port } = server.address();
  try {
    await fn({ coordinatorUrl: `http://127.0.0.1:${port}`, dataDir });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

// Publishes a real, validly-signed task envelope directly against the
// coordinator's HTTP API (bypassing the submit CLI's git/tar packaging,
// which is irrelevant to what these roster-auto-fetch tests are proving).
async function publishRealTask(coordinatorUrl, { privateKeyPem, keyId }) {
  const artifact = (hex) => ({ sha256: hex.repeat(64), bytes: 1, media_type: 'text/plain' });
  const payload = buildTaskPayload({
    collective: 'test',
    displayId: 'roster-autofetch-test',
    authorKeyId: keyId,
    source: artifact('a'),
    prompt: artifact('b'),
  });
  const envelope = signEnvelope(payload, privateKeyPem, keyId);
  const res = await fetch(`${coordinatorUrl}/tasks`, {
    method: 'POST',
    headers: { authorization: 'Bearer test-invite-token', 'content-type': 'application/json' },
    body: jcs(envelope),
  });
  if (!res.ok) throw new Error(`publishRealTask failed: ${res.status} ${await res.text()}`);
  return res.json();
}

// A stub `sbx` that reports "already authed" for the harness-auth preflight
// (isProviderSecretSet) and, if invoked further (sbx run/exec), just exits
// nonzero — these tests only need to drive `waspflow-federation-pull` far
// enough to pass or fail its OWN independent roster/signature check, which
// happens BEFORE any real sandbox call; they are not exercising a real
// sandboxed run (that needs a real sbx install, covered manually per the UX
// report's independent-verification section).
async function stubSbx() {
  const stubBinDir = await mkdtemp(join(tmpdir(), 'wf-fed-cli-stubbin-'));
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
  return { stubBinDir, stubPath, commandPath: `${stubBinDir}:${process.env.PATH}` };
}

async function withMemberHome(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-fed-cli-member-'));
  try {
    await fn(dir);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}

function runCli(args, { home, cwd = process.cwd(), env = {} } = {}) {
  return execFileAsync(process.execPath, [CLI, ...args], {
    cwd,
    env: { ...process.env, WASPFLOW_FEDERATION_HOME: home, ...env },
  });
}

test('join: auto-generates a keypair and persists config with no PEM/roster/digest exposed to the human path', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      const { stdout } = await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      assert.match(stdout, /joined .* as 'tim-author'/);
      assert.match(stdout, /ONE MORE STEP/);
      // The printed snippet is a roster line, not a raw command the human
      // has to construct or a private key — the actual pain point being
      // fixed (see bin/waspflow-federation-submit's old --private-key-file
      // flag surface).
      assert.match(stdout, /"tim-author":"-----BEGIN PUBLIC KEY/);

      const config = JSON.parse(await readFile(join(home, 'config.json'), 'utf8'));
      assert.equal(config.coordinator_url, coordinatorUrl);
      assert.equal(config.collective_token, 'test-invite-token');
      assert.equal(config.key_id, 'tim-author');
      assert.ok(config.private_key_path.endsWith('tim-author.pem'));
    });
  });
});

test('join: running it twice against the same coordinator is idempotent, not a second keypair', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      const before = await readFile(join(home, 'config.json'), 'utf8');
      const { stdout } = await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      assert.match(stdout, /already joined/);
      const after = await readFile(join(home, 'config.json'), 'utf8');
      assert.equal(before, after);
    });
  });
});

test('approve: appends a member public key to the owner roster file without replacing existing JSON entries', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-fed-approve-'));
  const rosterFile = join(directory, 'roster.json');
  const publicKeyFile = join(directory, 'oshin.pub.pem');
  const existingPem = '-----BEGIN PUBLIC KEY-----\nexisting\n-----END PUBLIC KEY-----\n';
  const osHinPem = '-----BEGIN PUBLIC KEY-----\nnew-member\n-----END PUBLIC KEY-----\n';
  try {
    await writeFile(rosterFile, JSON.stringify({ 'tim-owner': existingPem }, null, 2));
    await writeFile(publicKeyFile, osHinPem);
    const { stdout } = await runCli(['approve', 'oshin', publicKeyFile, '--roster-file', rosterFile, '--json']);
    assert.deepEqual(JSON.parse(stdout), { status: 'approved', key_id: 'oshin', roster_file: rosterFile, schema_version: 1, type: 'approved' });
    assert.deepEqual(JSON.parse(await readFile(rosterFile, 'utf8')), { 'tim-owner': existingPem, oshin: osHinPem });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('approve: accepts the coordinator roster path from WASPFLOW_FEDERATION_COORDINATOR_ROSTER_FILE', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'wf-fed-approve-env-'));
  const rosterFile = join(directory, 'roster.json');
  const publicKeyFile = join(directory, 'member.pub.pem');
  const publicKeyPem = '-----BEGIN PUBLIC KEY-----\nfrom-env\n-----END PUBLIC KEY-----\n';
  try {
    await writeFile(rosterFile, JSON.stringify({ 'tim-owner': '-----BEGIN PUBLIC KEY-----\nowner\n-----END PUBLIC KEY-----\n' }));
    await writeFile(publicKeyFile, publicKeyPem);
    await runCli(['approve', 'oshin', publicKeyFile], { env: { WASPFLOW_FEDERATION_COORDINATOR_ROSTER_FILE: rosterFile } });
    assert.equal(JSON.parse(await readFile(rosterFile, 'utf8')).oshin, publicKeyPem);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test('status: reports "not joined" before join, and the joined identity after', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      const before = await runCli(['status', '--json'], { home });
      assert.deepEqual(JSON.parse(before.stdout), { status: 'not_joined', schema_version: 1, type: 'not_joined' });

      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'tim-author'], { home });
      const after = await runCli(['status', '--json'], { home });
      const parsed = JSON.parse(after.stdout);
      assert.equal(parsed.status, 'joined');
      assert.equal(parsed.key_id, 'tim-author');
      assert.equal(parsed.coordinator_url, coordinatorUrl);
    });
  });
});

test('contribute: without join, fails with a "run join first" message, not a raw stack trace', async () => {
  await withMemberHome(async (home) => {
    await assert.rejects(runCli(['contribute', '--task-digest', 'a'.repeat(64)], { home }), (error) => {
      assert.match(error.stderr, /Run 'waspflow federation join/);
      // The Oshin bar: a first-time contributor who runs `contribute` before
      // `join` must get the guided one-liner, NOT a raw stack trace. Asserting
      // the message alone is not enough — it was present inside the stack too,
      // so this must assert the stack is absent.
      assert.doesNotMatch(error.stderr, /\bat \w+ \(|\.mjs:\d+:\d+\)|FederationConfigError:/,
        `contribute-without-join leaked a stack trace instead of a guided message:\n${error.stderr}`);
      return true;
    });
  });
});

test('trust: adds a peer public key to the local roster cache, round-trips through config.json', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });
      const pubkeyPem = '-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAZkcNBVMeGBosN5XTHB2/gz/H0yDxMeNRbhV+R7+ZCG0=\n-----END PUBLIC KEY-----\n';
      const { stdout } = await runCli(['trust', 'tim-author', pubkeyPem, '--json'], { home });
      assert.deepEqual(JSON.parse(stdout), { status: 'trusted', key_id: 'tim-author', schema_version: 1, type: 'trusted' });

      const config = JSON.parse(await readFile(join(home, 'config.json'), 'utf8'));
      assert.equal(config.roster['tim-author'], pubkeyPem);
    });
  });
});

test('trust: rejects a value that is not PEM-shaped rather than silently caching garbage', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });
      await assert.rejects(runCli(['trust', 'tim-author', 'not-a-key'], { home }), (error) => {
        assert.match(error.stderr, /does not look like a PEM public key/);
        return true;
      });
    });
  });
});

test('contribute: no --task-digest and no queued task -> reports "no task available" rather than hanging or erroring', async () => {
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });
      // Skip the harness-auth preflight entirely by resolving it against an
      // isolated, empty HOME with a stub `sbx` reporting "already set" —
      // this test is about task-discovery-returns-nothing, not auth, and
      // must not depend on (or risk triggering) a real sbx install.
      const stubHome = await mkdtemp(join(tmpdir(), 'wf-fed-cli-sbxstub-'));
      const { stubBinDir, stubPath, commandPath } = await stubSbx();

      const { stdout } = await execFileAsync(process.execPath, [CLI, 'contribute', '--json'], {
        env: {
          ...process.env,
          WASPFLOW_FEDERATION_HOME: home,
          WASPFLOW_FEDERATION_SBX_HOME: stubHome,
          WASPFLOW_SBX_BIN: stubPath,
          PATH: commandPath,
        },
      });
      assert.deepEqual(JSON.parse(stdout), { status: 'no_task_available', schema_version: 1, type: 'no_task_available' });

      await rm(stubHome, { recursive: true, force: true });
      await rm(stubBinDir, { recursive: true, force: true });
    });
  });
});

// --- GET /roster auto-fetch (owner decision, 2026-07-21): the default path
// no longer requires `trust` -----------------------------------------------

test('join: auto-populates the local roster cache from the coordinator\'s GET /roster — no manual trust needed for an already-registered peer', async () => {
  const roster = new Map([[PRE_REGISTERED_AUTHOR_KEY_ID, preRegisteredAuthorPublicKeyPem]]);
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      const { stdout } = await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });
      // The human-relay snippet is still printed (membership approval stays
      // a real human step) but the report must be honest that a peer was
      // already auto-fetched — not silently claim zero peers known.
      assert.match(stdout, /1 existing collective member.*auto-fetched/);

      const config = JSON.parse(await readFile(join(home, 'config.json'), 'utf8'));
      assert.equal(config.roster[PRE_REGISTERED_AUTHOR_KEY_ID], preRegisteredAuthorPublicKeyPem);
    });
  }, { roster });
});

test('contribute: succeeds past the signature-verification step with ZERO manual trust, when the coordinator\'s roster already has the author\'s key', async () => {
  const roster = new Map([[PRE_REGISTERED_AUTHOR_KEY_ID, preRegisteredAuthorPublicKeyPem]]);
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      // Ocean joins fresh — never runs `trust` at any point in this test.
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });

      // Tim (already an approved roster member, per the coordinator's own
      // roster passed into withCoordinator above) publishes a real signed
      // task directly against the coordinator.
      const published = await publishRealTask(coordinatorUrl, { privateKeyPem: preRegisteredAuthorPrivateKeyPem, keyId: PRE_REGISTERED_AUTHOR_KEY_ID });
      assert.equal(published.status, 'queued');

      const { stubBinDir, stubPath, commandPath } = await stubSbx();
      const stubHome = await mkdtemp(join(tmpdir(), 'wf-fed-cli-sbxstub-'));
      try {
        // This will fail overall (the stub sbx can't actually run a
        // sandboxed job — that needs a real sbx install, out of scope for
        // this test per the file's own module doc). What matters is HOW it
        // fails: it must get PAST the roster/signature check inside
        // bin/waspflow-federation-pull, proving the auto-fetched roster
        // (not a manual `trust` call, which was never made) is what let
        // independent re-verification succeed.
        await assert.rejects(execFileAsync(process.execPath, [CLI, 'contribute'], {
          env: { ...process.env, WASPFLOW_FEDERATION_HOME: home, WASPFLOW_FEDERATION_SBX_HOME: stubHome, WASPFLOW_SBX_BIN: stubPath, PATH: commandPath },
        }), (error) => {
          assert.match(error.stderr, /independently re-verified task envelope signature/);
          assert.doesNotMatch(error.stderr, /is not in --roster-file/);
          assert.doesNotMatch(error.stderr, /haven't trusted/);
          return true;
        });
      } finally {
        await rm(stubHome, { recursive: true, force: true });
        await rm(stubBinDir, { recursive: true, force: true });
      }
    });
  }, { roster });
});

test('contribute: refuses a task from a signer this member has not trusted (locally) and the coordinator never served via GET /roster', async () => {
  // A DIFFERENT coordinator instance (its own roster, its own data dir) signs
  // and publishes the task with a key that is registered THERE — but Ocean's
  // home coordinator (the one she actually joined and fetched a roster from)
  // has never heard of that key at all. This is the direct, automatable
  // analogue of the manually-verified "untrusted signer claims but never
  // executes" scenario from the UX report's independent-verification
  // section: GET /roster auto-fetch must never manufacture trust for a
  // signer the member's OWN coordinator doesn't actually vouch for.
  const strangerKeys = generateKeyPairSync('ed25519');
  const strangerPrivateKeyPem = strangerKeys.privateKey.export({ type: 'pkcs8', format: 'pem' });
  const strangerPublicKeyPem = strangerKeys.publicKey.export({ type: 'spki', format: 'pem' });
  const STRANGER_KEY_ID = 'stranger-author';

  const roster = new Map([[PRE_REGISTERED_AUTHOR_KEY_ID, preRegisteredAuthorPublicKeyPem]]); // no stranger-author entry
  await withCoordinator(async ({ coordinatorUrl }) => {
    await withMemberHome(async (home) => {
      await runCli(['join', coordinatorUrl, 'test-invite-token', '--key-id', 'ocean-executor'], { home });

      // Confirm the auto-fetched cache really does hold the legitimate
      // author's key but NOT the stranger's — the setup this test depends on.
      const config = JSON.parse(await readFile(join(home, 'config.json'), 'utf8'));
      assert.equal(config.roster[PRE_REGISTERED_AUTHOR_KEY_ID], preRegisteredAuthorPublicKeyPem);
      assert.ok(!config.roster[STRANGER_KEY_ID]);

      // A separate coordinator (own roster containing the stranger key) is
      // what actually PUBLISHES this task — modeling "signed by a real key,
      // just not one Ocean's own coordinator/collective has ever vouched
      // for" without needing this test's single coordinator to somehow
      // register a key it also must not recognize.
      await withCoordinator(async ({ coordinatorUrl: strangerCoordinatorUrl }) => {
        const published = await publishRealTask(strangerCoordinatorUrl, { privateKeyPem: strangerPrivateKeyPem, keyId: STRANGER_KEY_ID });

        // Ocean's REAL config still points at her own (legitimate) coordinator,
        // which has never seen this digest — so claiming it there 404s. This
        // proves the negative end-to-end: a task Ocean's own coordinator
        // never published/vouched for cannot be contributed at all, whether
        // via absent digest or (per the manual E2E proof already in the UX
        // report) an untrusted signer on a task it HAS published.
        const { stubBinDir, stubPath, commandPath } = await stubSbx();
        const stubHome = await mkdtemp(join(tmpdir(), 'wf-fed-cli-sbxstub-'));
        try {
          await assert.rejects(runCli(['contribute', '--task-digest', published.task_digest], {
            home,
            env: { WASPFLOW_FEDERATION_SBX_HOME: stubHome, WASPFLOW_SBX_BIN: stubPath, PATH: commandPath },
          }), (error) => {
            assert.match(error.stderr, /unknown task|not in --roster-file|haven't trusted/);
            return true;
          });
        } finally {
          await rm(stubHome, { recursive: true, force: true });
          await rm(stubBinDir, { recursive: true, force: true });
        }
      }, { roster: new Map([[STRANGER_KEY_ID, strangerPublicKeyPem]]) });
    });
  }, { roster });
});
