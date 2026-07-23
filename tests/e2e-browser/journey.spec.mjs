import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const token = process.env.WASPFLOW_SESSION_TOKEN || '1LI6CwJ5PoN3tWmJmju4yJAtArwT09O6gM0XqTiWhXA';
const baseUrl = process.env.WASPFLOW_UI_URL || 'http://127.0.0.1:8902/';
const targetUrl = new URL(baseUrl); targetUrl.searchParams.set('token', token);
const artifactDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../test-artifacts/federation-ui');
const rawConsoleErrors = []; const results = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function check(name, action) { try { await action(); results.push({ name, status: 'PASS' }); } catch (error) { results.push({ name, status: 'FAIL', detail: error.message }); } }
async function text(scope, value) { await scope.getByText(value, { exact: false }).first().waitFor({ state: 'visible', timeout: 5_000 }); }
async function visible(scope, selector) { await scope.locator(selector).first().waitFor({ state: 'visible', timeout: 5_000 }); }

async function main() {
  await mkdir(artifactDir, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  page.on('console', (message) => { if (message.type() === 'error') rawConsoleErrors.push(message.text()); });
  page.on('pageerror', (error) => rawConsoleErrors.push(`pageerror: ${error.message}`));
  try {
    await check('Mode-first navigation and settings gear load', async () => {
      const response = await page.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 }); assert.ok(response?.ok());
      await text(page.locator('.brand'), 'Waspflow Federation');
      for (const label of ['Contribute', 'Requests', 'Activity', 'Help']) await text(page.locator('.primary-nav'), label);
      await visible(page, '.gear[aria-label="Settings"]'); await page.screenshot({ path: path.join(artifactDir, 'initial.png'), fullPage: true });
    });
    await check('Idle contributor screen uses the ready status vocabulary', async () => {
      await visible(page, '.status-dot[data-status="ready"], .status-dot[data-status="active"]'); await text(page, 'You approve every task before it starts');
      await page.screenshot({ path: path.join(artifactDir, 'idle.png'), fullPage: true });
    });
    await check('Task review preserves explicit consent and empty queue safety', async () => {
      const review = page.getByRole('button', { name: 'Review the next task' });
      if (await review.count()) { await review.click(); await text(page, 'Review this task'); await text(page, 'Accept and run'); await text(page, 'Skip this one'); }
      else await text(page, 'No tasks are waiting');
    });
    await check('Help keeps the safety boundary available in-app', async () => {
      await page.getByRole('link', { name: 'Help' }).click(); await text(page, 'Your safety boundary'); await text(page, 'Everything else is blocked');
      await page.screenshot({ path: path.join(artifactDir, 'safety-expanded.png'), fullPage: true });
    });
    await check('Compose form keeps values and inline submit error across polling', async () => {
      await page.getByRole('link', { name: 'Requests' }).click(); await text(page, 'Requests'); await page.getByRole('link', { name: '+ New request' }).click();
      await visible(page, '#task-name'); await page.locator('#task-name').fill('wave-d-form-persistence'); await page.locator('#task-prompt').fill('Prove the error survives a status refresh.');
      await page.getByText('Advanced', { exact: true }).click(); await page.locator('#task-folder').fill('/definitely/not/a-folder'); await page.getByRole('button', { name: 'Submit task' }).click();
      await visible(page, '.form-feedback:not(:empty)'); rawConsoleErrors.length = 0; await sleep(3500);
      assert.equal(await page.locator('#task-name').inputValue(), 'wave-d-form-persistence'); assert.equal(await page.locator('#task-prompt').inputValue(), 'Prove the error survives a status refresh.'); assert.equal(await page.locator('#task-folder').inputValue(), '/definitely/not/a-folder');
      await page.locator('#task-prompt').fill('Edited prompt clears the old error.'); assert.equal(await page.locator('.form-feedback').textContent(), '');
      await page.screenshot({ path: path.join(artifactDir, 'advanced-submit-expanded.png'), fullPage: true });
    });
    await check('Activity lenses and split settings render', async () => {
      await page.getByRole('link', { name: 'Activity' }).click(); await text(page, 'What I did'); await text(page, 'What I asked for');
      await page.getByRole('link', { name: 'Settings' }).click(); await text(page, 'Device & accounts'); await text(page, 'Docker account');
      await page.goto(`${targetUrl.toString()}#/settings/collective`, { waitUntil: 'networkidle' }); await text(page, 'Collective'); await text(page, 'Technical details'); await text(page, 'Join a different collective'); await visible(page, '#switch-invite');
      await page.screenshot({ path: path.join(artifactDir, 'activity-settings.png'), fullPage: true });
    });
    await check('One shared task route renders live-watch details', async () => {
      const taskPage = await browser.newPage({ viewport: { width: 1440, height: 1100 } }); const digest = 'a'.repeat(64);
      await taskPage.route('**/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ state: 'idle', coordinator_unavailable: false }) }));
      await taskPage.route('**/tasks/**', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(route.request().url().includes('/log?') ? { output: 'assistant: checking the task' } : { task_digest: `sha256:${digest}`, display_id: 'shared-task-route', status: 'CLAIMED', prompt: 'Watch this task.' }) }));
      try { await taskPage.goto(`${targetUrl.toString()}#/tasks/sha256%3A${digest}`, { waitUntil: 'networkidle' }); await text(taskPage, 'shared-task-route'); await text(taskPage, 'Live transcript'); await text(taskPage, 'assistant: checking the task'); } finally { await taskPage.close(); }
    });
    await check('Provider sign-in failure remains a page recovery state', async () => {
      const attention = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      await attention.route('**/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'idle', detail: 'OpenAI sign-in could not start. An existing OpenAI OAuth credential needs attention before another sign-in can start.', coordinator_unavailable: false, ledger_summary: { count_7d: 0 } }) }));
      await attention.route('**/identity', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ docker_status: 'detected', providers: [{ service: 'openai', authed: false, capacity_kind: 'subscription' }] }) }));
      try { await attention.goto(`${targetUrl.toString()}#/settings/device`, { waitUntil: 'networkidle' }); await text(attention, 'Sign-in needs attention'); await text(attention, 'existing OpenAI OAuth credential needs attention'); await attention.screenshot({ path: path.join(artifactDir, 'openai-signin-attention.png'), fullPage: true }); } finally { await attention.close(); }
    });
    await check('GitHub device code is selectable and copyable', async () => {
      const github = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      await github.route('**/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'action_needed', detail: 'Finish github sign-in in your browser.', action: { kind: 'awaiting_browser', service: 'github', url: 'https://github.com/login/device', code: 'TEST-1234' }, coordinator_unavailable: false }) }));
      try { await github.goto(targetUrl.toString(), { waitUntil: 'networkidle' }); await text(github, 'Sign in to GitHub'); await text(github, 'Confirmation code:'); await text(github, 'TEST-1234'); await github.getByRole('button', { name: 'Copy code' }).click(); await github.screenshot({ path: path.join(artifactDir, 'github-device-flow.png'), fullPage: true }); } finally { await github.close(); }
    });
    await check('Contribute controls never start a task without review', async () => {
      await page.goto(targetUrl.toString(), { waitUntil: 'networkidle' }); const review = page.getByRole('button', { name: 'Review the next task' });
      if (await review.count()) await review.click(); else await text(page, 'No tasks are waiting');
      assert.equal(await page.getByRole('button', { name: 'Contribute next available' }).count(), 0);
    });
    await check('Active contribution polling preserves text selection', async () => {
      const active = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      await active.route('**/status', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'contributing', detail: 'Contribution is running.', contribution: { display_id: 'render-stability-check', started_at: new Date().toISOString() }, coordinator_unavailable: false, ledger_summary: { count_7d: 0 } }) }));
      try { await active.goto(targetUrl.toString(), { waitUntil: 'networkidle' }); const selected = await active.locator('.guard strong').evaluate((node) => { const range = document.createRange(); range.selectNodeContents(node); const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range); window.__waspflowSelectedNode = node; return selection.toString(); }); await sleep(10500); const after = await active.evaluate(() => ({ selection: window.getSelection().toString(), sameNode: window.__waspflowSelectedNode === document.querySelector('.guard strong') })); assert.equal(after.selection, selected); assert.equal(after.sameNode, true); } finally { await active.close(); }
    });
    await check('Session expiry stops polling and offers reconnect', async () => {
      const stale = await browser.newPage({ viewport: { width: 390, height: 844 } }); let statusRequests = 0; const errors = [];
      stale.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); }); await stale.route('**/status', (route) => { statusRequests += 1; return route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ error: 'expired' }) }); });
      try { await stale.goto(targetUrl.toString(), { waitUntil: 'networkidle' }); await text(stale, 'This local link has expired'); await stale.getByRole('button', { name: 'Reconnect Federation' }).isEnabled(); await stale.screenshot({ path: path.join(artifactDir, 'session-expired-390.png'), fullPage: true }); await sleep(3500); assert.ok(statusRequests <= 3, `stale tab made ${statusRequests} status requests`); } finally { await stale.close(); }
    });
    await check('No console errors on any Federation view', () => { assert.deepEqual(rawConsoleErrors, []); });
  } finally { await writeFile(path.join(artifactDir, 'sweep-results.json'), `${JSON.stringify({ targetUrl: baseUrl, consoleErrors: rawConsoleErrors, results }, null, 2)}\n`); await browser.close(); }
  console.table(results); if (results.some((result) => result.status === 'FAIL')) process.exitCode = 1;
}
await main();
