import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { lifecycleStage, viewForStatus } from '../public/app.mjs';

test('web UI document loads its browser module', async () => {
  const index = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(index, /<main id="app"/);
  assert.match(index, /app\.src = `\/app\.mjs\?token=/);
});

test('web UI maps daemon states to the join, status, and auth views', () => {
  assert.deepEqual(viewForStatus({ state: 'not_joined' }), { name: 'join' });
  assert.deepEqual(viewForStatus({ state: 'contributing' }), { name: 'status', title: 'Contributing', control: 'pause' });
  assert.deepEqual(viewForStatus({ state: 'paused' }), { name: 'status', title: 'Paused', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Idle', control: 'start' });
  assert.deepEqual(
    viewForStatus({ state: 'action_needed', action: { kind: 'awaiting_browser', url: 'https://auth.example' } }),
    { name: 'action', action: { kind: 'awaiting_browser', url: 'https://auth.example' } },
  );
  assert.deepEqual(
    viewForStatus({ state: 'setup_required', action: { kind: 'sandbox_preflight', checks: [{ name: 'docker_login', ok: false }] } }),
    { name: 'setup', checks: [{ name: 'docker_login', ok: false }] },
  );
});

test('web UI maps the coordinator lifecycle to the complete requester stepper', () => {
  assert.equal(lifecycleStage('QUEUED'), 'queued');
  assert.equal(lifecycleStage('CLAIMED'), 'running');
  assert.equal(lifecycleStage('SUBMITTED'), 'running');
  assert.equal(lifecycleStage('EVALUATING'), 'running');
  assert.equal(lifecycleStage('SETTLED'), 'settled');
});
