import test from 'node:test';
import assert from 'node:assert/strict';
import { lifecycleStage, providerCapacitySubject, routeFromHash, statusRole, taskTimeline, viewForStatus } from './helpers.js';

test('routes retain dedicated task and settings paths', () => {
  assert.deepEqual(routeFromHash('#/tasks/sha256:abc'), { name: 'tasks', parts: ['sha256:abc'] });
  assert.deepEqual(routeFromHash('#/settings/collective'), { name: 'settings', parts: ['collective'] });
  assert.equal(routeFromHash('#/unknown').name, 'contribute');
});
test('daemon status and timeline stay compatible', () => {
  assert.deepEqual(viewForStatus({ state: 'idle' }), { name: 'status', title: 'Ready when you are', control: 'start' });
  assert.equal(lifecycleStage('CLAIMED'), 'claimed');
  assert.equal(taskTimeline({ status: 'FAILED' }).at(-1).name, 'failed');
  assert.equal(statusRole('contributing'), 'active');
  assert.equal(providerCapacitySubject({ providers: [{ service: 'openai', capacity_kind: 'api_key' }] }), 'your OpenAI API key');
});
