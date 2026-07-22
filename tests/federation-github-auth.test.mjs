import test from 'node:test';
import assert from 'node:assert/strict';
import { access, chmod, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { startGitHubAuthFlow } from '../lib/federation-github-auth.mjs';

async function executable(name, body) {
  const dir = await mkdtemp(join(tmpdir(), 'wf-github-auth-'));
  const file = join(dir, name);
  await writeFile(file, `#!/bin/sh\n${body}\n`);
  await chmod(file, 0o755);
  return file;
}

test('GitHub device flow exposes the real UI shape and pipes its token only into the Federation sbx secret store', async () => {
  const record = join(await mkdtemp(join(tmpdir(), 'wf-github-auth-record-')), 'store-input');
  const federationHome = await mkdtemp(join(tmpdir(), 'wf-github-auth-home-'));
  const gh = await executable('gh', `
if [ "$1" = auth ] && [ "$2" = login ]; then
  echo 'First copy your one-time code: TEST-1234'
  echo 'Open this URL to continue in your web browser: https://github.com/login/device'
  exit 0
fi
if [ "$1" = auth ] && [ "$2" = token ]; then printf 'secret-token'; exit 0; fi
exit 1
`);
  const sbx = await executable('sbx', `cat > '${record}'`);
  const flow = await startGitHubAuthFlow({ ghBin: gh, sbxBin: sbx, env: { PATH: process.env.PATH, HOME: '/personal-gh-must-not-be-used' }, federationHome });
  assert.equal(flow.url, 'https://github.com/login/device');
  assert.equal(flow.code, 'TEST-1234');
  assert.deepEqual(await flow.waitForCompletion(), { status: 'complete', detail: 'GitHub task access is ready.' });
  assert.equal(await readFile(record, 'utf8'), 'secret-token');
});

test('cancelling GitHub device login removes its isolated insecure config', async () => {
  const record = join(await mkdtemp(join(tmpdir(), 'wf-github-auth-record-')), 'config-dir');
  const federationHome = await mkdtemp(join(tmpdir(), 'wf-github-auth-home-'));
  const gh = await executable('gh', `
if [ "$1" = auth ] && [ "$2" = login ]; then
  mkdir -p "$GH_CONFIG_DIR"
  printf token > "$GH_CONFIG_DIR/hosts.yml"
  printf '%s' "$GH_CONFIG_DIR" > '${record}'
  echo 'First copy your one-time code: TEST-5678'
  echo 'Open this URL to continue in your web browser: https://github.com/login/device'
  trap 'exit 0' TERM
  while true; do sleep 1; done
fi
exit 1
`);
  const flow = await startGitHubAuthFlow({ ghBin: gh, env: { PATH: process.env.PATH, HOME: '/personal-gh-must-not-be-used' }, federationHome });
  const configDir = await readFile(record, 'utf8');
  await access(configDir);
  flow.cancel();
  assert.deepEqual(await flow.waitForCompletion(), { status: 'failed', detail: 'cancelled before completion' });
  await assert.rejects(() => access(configDir));
});
