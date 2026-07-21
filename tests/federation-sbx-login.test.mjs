import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { startSbxDockerLogin } from '../lib/federation-sbx-login.mjs';

test('sbx login output produces a browser URL and one-time code, then completion waits for authenticated preflight', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'wf-sbx-login-'));
  const sbx = join(dir, 'sbx');
  await writeFile(sbx, [
    '#!/bin/sh',
    "printf '%s\\n' 'Your one-time device confirmation code is: XQZN-BWCH'",
    "printf '%s\\n' 'Open this URL to sign in: https://login.docker.com/activate?user_code=XQZN-BWCH'",
    'while :; do sleep 1; done',
  ].join('\n'));
  await chmod(sbx, 0o755);
  let authenticated = false;
  const flow = await startSbxDockerLogin({
    loginBin: sbx,
    pollIntervalMs: 5,
    completionTimeoutMs: 500,
    probe: async () => ({ checks: [{ name: 'docker_login', ok: authenticated }] }),
  });
  assert.equal(flow.url, 'https://login.docker.com/activate?user_code=XQZN-BWCH');
  assert.equal(flow.code, 'XQZN-BWCH');
  authenticated = true;
  assert.deepEqual(await flow.waitForCompletion(), { status: 'complete', detail: 'Docker sign-in was confirmed.' });
});
