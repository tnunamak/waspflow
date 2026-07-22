import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { capacityKind, lifecycleStage, providerCapacitySubject, routeFromHash, taskTimeline, viewForStatus } from '../public/app.mjs';

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
  assert.match(app, /optionalRequest\('\/tasks', \[\]\)/);
});

test('web UI routes each persistent navigation destination and defaults safely to Contribute', () => {
  assert.equal(routeFromHash(''), 'contribute');
  assert.equal(routeFromHash('#/contribute'), 'contribute');
  assert.equal(routeFromHash('#/requests'), 'requests');
  assert.equal(routeFromHash('#/activity'), 'activity');
  assert.equal(routeFromHash('#/settings'), 'settings');
  assert.equal(routeFromHash('#/help'), 'help');
  assert.equal(routeFromHash('#/unknown'), 'contribute');
});

test('web UI maps daemon states to the join, status, and auth views', () => {
  assert.deepEqual(viewForStatus({ state: 'not_joined' }), { name: 'join' });
  assert.deepEqual(viewForStatus({ state: 'contributing' }), { name: 'status', title: 'Contributing', control: 'pause' });
  assert.deepEqual(viewForStatus({ state: 'paused' }), { name: 'status', title: 'Paused', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Ready when you are', control: 'start' });
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
  assert.match(app, /You’re joining/);
  assert.match(app, /Trusted coordinator/);
  assert.match(app, /completed this week/);
  assert.match(app, /Sign in to Docker/);
  assert.match(app, /Confirmation code/);
});

test('web UI maps the coordinator lifecycle to the complete requester stepper', () => {
  assert.equal(lifecycleStage('QUEUED'), 'queued');
  assert.equal(lifecycleStage('CLAIMED'), 'claimed');
  assert.equal(lifecycleStage('SUBMITTED'), 'running');
  assert.equal(lifecycleStage('EVALUATING'), 'running');
  assert.equal(lifecycleStage('SETTLED'), 'settled');
});

test('request lifecycle has no phantom selection and preserves all four task states once selected', () => {
  assert.equal(taskTimeline({}).filter((step) => step.current).length, 1);
  assert.deepEqual(
    taskTimeline({ status: 'SETTLED', queued_at: '2026-07-21T10:00:00Z' }).map((step) => [step.name, step.complete, step.current]),
    [['queued', true, false], ['claimed', true, false], ['running', true, false], ['settled', false, true]],
  );
});

test('product UI contains all five surfaces and the Wave A compatible task, result, identity, and schedule affordances', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  for (const label of ['Contribute', 'Requests', 'Activity', 'Settings', 'Help', 'Download result', 'Accounts in use', 'Pause schedule', 'Only spare capacity is used']) {
    assert.match(app, new RegExp(label));
  }
  assert.match(app, /optionalRequest\(`\/tasks\/\$\{encodeURIComponent\(selectedDigest\)\}`, null\)/);
  assert.match(app, /`\/result\/\$\{encodeURIComponent\(selectedDigest\)\}\?token=/);
  assert.match(app, /optionalRequest\('\/identity', null\)/);
  assert.match(app, /optionalRequest\('\/settings', null\)/);
});

test('identity capacity kind drives provider wording without assuming one capacity source', async () => {
  assert.equal(capacityKind({ capacity_kind: 'managed_plan' }), 'managed_plan');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'Claude', capacity_kind: 'managed_plan' }] }), 'your Claude account');
  assert.equal(providerCapacitySubject({ providers: [{ service: 'anthropic', capacity_kind: 'subscription' }] }), 'your anthropic account');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'OpenAI', capacity_kind: 'api_key' }] }), 'your OpenAI API key');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'Ollama', capacity_kind: 'local_model' }] }), 'the Ollama local model');
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(app, /subscript(?:ion)/i);
  assert.match(app, /Capacity kind/);
});
