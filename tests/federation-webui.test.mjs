import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { lifecycleStage, viewForStatus } from '../public/app.mjs';

test('web UI document loads its browser module', async () => {
  const index = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(index, /<main id="app"/);
  assert.match(index, /app\.src = `\/app\.mjs\?token=/);
});

test('idle contributor UI offers both task choice and the one-click next-task path', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /Choose a task/);
  assert.match(app, /Contribute this/);
  assert.match(app, /Contribute next available/);
  assert.match(app, /request\('\/tasks'\)/);
});

test('web UI maps daemon states to the join, status, and auth views', () => {
  assert.deepEqual(viewForStatus({ state: 'not_joined' }), { name: 'join' });
  assert.deepEqual(viewForStatus({ state: 'contributing' }), { name: 'status', title: 'Contributing', control: 'pause' });
  assert.deepEqual(viewForStatus({ state: 'paused' }), { name: 'status', title: 'Paused', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Idle', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'pending_approval' }), { name: 'pending' });
  assert.deepEqual(
    viewForStatus({ state: 'action_needed', action: { kind: 'awaiting_browser', url: 'https://auth.example' } }),
    { name: 'action', action: { kind: 'awaiting_browser', url: 'https://auth.example' } },
  );
  assert.deepEqual(
    viewForStatus({ state: 'action_needed', action: { kind: 'awaiting_browser', url: 'https://login.docker.com/activate?user_code=XQZN-BWCH', code: 'XQZN-BWCH' } }),
    { name: 'action', action: { kind: 'awaiting_browser', url: 'https://login.docker.com/activate?user_code=XQZN-BWCH', code: 'XQZN-BWCH' } },
  );
  assert.deepEqual(
    viewForStatus({ state: 'setup_required', action: { kind: 'sandbox_preflight', checks: [{ name: 'docker_login', ok: false }] } }),
    { name: 'setup', checks: [{ name: 'docker_login', ok: false }] },
  );
});

test('web UI renders approval waiting, collective-name personalization, and contribution thanks', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /Waiting for approval/);
  assert.match(app, /You're helping:/);
  assert.match(app, /Tasks come only from/);
  assert.match(app, /You've completed/);
  assert.match(app, /Sign in to Docker/);
  assert.match(app, /Confirmation code/);
});

test('web UI maps the coordinator lifecycle to the complete requester stepper', () => {
  assert.equal(lifecycleStage('QUEUED'), 'queued');
  assert.equal(lifecycleStage('CLAIMED'), 'running');
  assert.equal(lifecycleStage('SUBMITTED'), 'running');
  assert.equal(lifecycleStage('EVALUATING'), 'running');
  assert.equal(lifecycleStage('SETTLED'), 'settled');
});
