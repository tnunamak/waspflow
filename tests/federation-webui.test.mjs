import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { capacityKind, lifecycleStage, providerCapacitySubject, providerDisplayName, routeFromHash, taskTimeline, viewForStatus } from '../public/app.mjs';

test('web UI document loads its browser module', async () => {
  const index = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(index, /<main id="app"/);
  assert.match(index, /app\.src = `\/app\.mjs\?token=/);
});

test('idle contributor UI requires a task-specific consent decision and never auto-runs an empty queue', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /Choose a task/);
  assert.match(app, /Contribute this/);
  assert.match(app, /Contribute next available/);
  assert.match(app, /No tasks are waiting right now\. Nothing will run automatically/);
  assert.match(app, /Review next available task/);
  assert.match(app, /Prompt: \$\{promptFirstLine/);
  assert.match(app, /Run this/);
  assert.match(app, /Skip/);
  assert.doesNotMatch(app, /disabled: choices\.length === 0/);
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
  assert.deepEqual(viewForStatus(null), { name: 'loading' });
  assert.deepEqual(viewForStatus({ state: 'not_joined' }), { name: 'join' });
  assert.deepEqual(viewForStatus({ state: 'contributing' }), { name: 'status', title: 'Contributing', control: 'pause' });
  assert.deepEqual(viewForStatus({ state: 'paused' }), { name: 'status', title: 'Paused', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Ready when you are', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'pending_approval' }), { name: 'pending' });
  assert.deepEqual(viewForStatus({ state: 'approval_revoked' }), { name: 'approval_revoked' });
  assert.deepEqual(viewForStatus({ state: 'pausing' }), { name: 'status', title: 'Pausing after current task…', control: 'pause' });
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

test('web UI renders approval waiting, collective-first personalization, and contribution thanks', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /Waiting for approval/);
  assert.match(app, /You’re joining/);
  assert.match(app, /collectiveName \? element\('p', \{ className: 'collective-line'/);
  assert.match(app, /completed this week/);
  assert.match(app, /Sign in to \$\{provider\}/);
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

test('web UI keeps a neutral first-load screen, backs off failed optional fetches, and only renders a stepper for a real digest', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /Checking Federation status/);
  assert.match(app, /failedRequests/);
  assert.match(app, /nextAttemptAt/);
  assert.match(app, /\^sha256:\[a-f0-9\]\{64\}/);
});

test('product UI contains all five surfaces and the Wave A compatible task, result, identity, and schedule affordances', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  for (const label of ['Contribute', 'Requests', 'Activity', 'Settings', 'Help', 'Download result', 'Accounts in use', 'Limit to certain hours', 'Capacity guard']) {
    assert.match(app, new RegExp(label));
  }
  assert.match(app, /optionalRequest\(`\/tasks\/\$\{encodeURIComponent\(selectedDigest\.replace\(\/\^sha256:\/, ''\)\)\}`, null\)/);
  assert.match(app, /`\/result\/\$\{encodeURIComponent\(selectedDigest\)\}\?token=/);
  assert.match(app, /optionalRequest\('\/identity', null\)/);
  assert.match(app, /optionalRequest\('\/settings', null\)/);
});

test('identity capacity kind drives provider wording without assuming one capacity source', async () => {
  assert.equal(capacityKind({ capacity_kind: 'managed_plan' }), 'managed_plan');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'Claude', capacity_kind: 'managed_plan' }] }), 'your Anthropic (Claude) account');
  assert.equal(providerDisplayName('anthropic'), 'Anthropic (Claude)');
  assert.equal(providerCapacitySubject({ providers: [{ service: 'anthropic', capacity_kind: 'subscription' }] }), 'your Anthropic (Claude) account');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'OpenAI', capacity_kind: 'api_key' }] }), 'your OpenAI API key');
  assert.equal(providerCapacitySubject({ accounts: [{ provider: 'Ollama', capacity_kind: 'local_model' }] }), 'the Ollama local model');
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /provider-card/);
  assert.match(app, /Managed automatically/);
  assert.match(app, /API key/);
  assert.match(app, /Member ID/);
  assert.match(app, /identity\/signin/);
});

test('activity rows use a whole-row plain control and recovery states do not expose transport errors', async () => {
  const [app, index] = await Promise.all([
    readFile(new URL('../public/app.mjs', import.meta.url), 'utf8'),
    readFile(new URL('../public/index.html', import.meta.url), 'utf8'),
  ]);
  assert.match(app, /className: 'history-select'/);
  assert.match(app, /className: 'receipt-chip'/);
  assert.match(app, /SESSION_EXPIRED_MESSAGE/);
  assert.match(app, /unauthorizedPolls >= 2/);
  assert.match(app, /window\.clearInterval\(pollTimer\)/);
  assert.match(app, /Reconnect Federation/);
  assert.match(app, /Federation is not running on this computer/);
  assert.match(app, /Your collective is unreachable right now/);
  assert.match(app, /Stop now abandons the current task\. Waspflow records it as returned/);
  assert.match(app, /Sign in to \$\{displayName\}/);
  assert.match(app, /settingsDraft/);
  assert.match(app, /Schedule times are in/);
  assert.match(app, /Skip to content/);
  assert.doesNotMatch(index, /<main id="app" aria-live/);
  assert.match(app, /docker_status === 'failed'/);
  assert.match(app, /Checking…/);
  assert.match(index, /\.history-select \{[^}]*background: transparent/s);
  assert.match(index, /\.receipt-chip \{[^}]*color: #245139/s);
});

test('request form stores values and an inline error outside its recreated DOM subtree', async () => {
  const app = await readFile(new URL('../public/app.mjs', import.meta.url), 'utf8');
  assert.match(app, /const requestForm = \{ display_id: '', prompt: '', source: '', error: '' \}/);
  assert.match(app, /formState\.error = error\.message/);
  assert.match(app, /Folder on this computer \(optional\)/);
  assert.match(app, /Without a folder, the task starts in an empty workspace\./);
});
