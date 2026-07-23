import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  capacityKind, lifecycleStage, providerCapacitySubject, providerDisplayName,
  routeFromHash, statusRole, taskTimeline, viewForStatus,
} from '../public/app.mjs';

test('served document retains the token-bearing static asset contract', async () => {
  const index = await readFile(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.match(index, /<main id="app"/);
  assert.match(index, /app\.src = `\/app\.mjs\?token=/);
  assert.doesNotMatch(index, /app\.css/);
});

test('hash routing implements the structural proposal routes safely', () => {
  assert.deepEqual(routeFromHash(''), { name: 'contribute', parts: [] });
  assert.deepEqual(routeFromHash('#/tasks/sha256%3Aabc'), { name: 'tasks', parts: ['sha256%3Aabc'] });
  assert.deepEqual(routeFromHash('#/settings/device'), { name: 'settings', parts: ['device'] });
  assert.deepEqual(routeFromHash('#/settings/collective'), { name: 'settings', parts: ['collective'] });
  assert.equal(routeFromHash('#/unknown').name, 'contribute');
});

test('daemon state mappings preserve join, approval, contribution, and recovery contracts', () => {
  assert.deepEqual(viewForStatus(null), { name: 'loading' });
  assert.deepEqual(viewForStatus({ state: 'not_joined' }), { name: 'join' });
  assert.deepEqual(viewForStatus({ state: 'pending_approval' }), { name: 'pending' });
  assert.deepEqual(viewForStatus({ state: 'approval_revoked' }), { name: 'approval_revoked' });
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Ready when you are', control: 'start' });
  assert.deepEqual(viewForStatus({ state: 'contributing' }), { name: 'status', title: 'Contributing', control: 'pause' });
});

test('timeline and status tokens preserve protocol semantics', () => {
  assert.equal(lifecycleStage('CLAIMED'), 'claimed');
  assert.equal(lifecycleStage('SETTLED'), 'settled');
  assert.equal(lifecycleStage('FAILED'), 'failed');
  assert.equal(taskTimeline({ status: 'FAILED' }).at(-1).name, 'failed');
  assert.equal(statusRole('contributing'), 'active');
  assert.equal(statusRole('paused'), 'attention');
  assert.equal(statusRole('settled'), 'ready');
  assert.equal(statusRole('failed'), 'problem');
});

test('source is Preact/Vite, preserves API paths, and removes manual DOM churn machinery', async () => {
  const [source, packageJson, config] = await Promise.all([
    readFile(new URL('../ui/src/main.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../ui/package.json', import.meta.url), 'utf8'),
    readFile(new URL('../ui/vite.config.mjs', import.meta.url), 'utf8'),
  ]);
  assert.match(source, /from 'preact'/);
  assert.match(source, /useState/);
  assert.match(source, /#\/tasks/);
  assert.match(source, /Device & accounts/);
  assert.match(source, /What I did/);
  assert.match(source, /Accept and run/);
  assert.match(source, /\/identity\/signin/);
  assert.match(source, /Join a different collective/);
  assert.match(source, /switch-invite/);
  assert.match(source, /Finish the current work before switching collectives/);
  assert.match(source, /disabled=\{switchingBlocked\}/);
  assert.match(source, /join=\{\(invite\) => control\('\/join'/);
  assert.doesNotMatch(source, /replaceChildren|lastLayoutSignature|updateLiveBindings/);
  assert.match(packageJson, /"vite"/);
  assert.match(config, /outDir/);
});

test('identity wording remains capacity-source aware', () => {
  assert.equal(capacityKind({ capacity_kind: 'managed_plan' }), 'managed_plan');
  assert.equal(providerDisplayName('anthropic'), 'Anthropic (Claude)');
  assert.equal(providerCapacitySubject({ providers: [{ service: 'openai', capacity_kind: 'api_key' }] }), 'your OpenAI API key');
});
