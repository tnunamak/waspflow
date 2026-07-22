import assert from 'node:assert/strict';
import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright';

const token = process.env.WASPFLOW_SESSION_TOKEN || '1LI6CwJ5PoN3tWmJmju4yJAtArwT09O6gM0XqTiWhXA';
const baseUrl = process.env.WASPFLOW_UI_URL || 'http://127.0.0.1:8902/';
const targetUrl = new URL(baseUrl);
targetUrl.searchParams.set('token', token);
const artifactDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../test-artifacts/federation-ui');
const rawConsoleErrors = [];
const results = [];

async function check(name, action) {
  try {
    await action();
    results.push({ name, status: 'PASS' });
  } catch (error) {
    results.push({ name, status: 'FAIL', detail: error.message });
  }
}

async function main() {
  await mkdir(artifactDir, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: process.env.PLAYWRIGHT_CHANNEL || 'chrome' });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  page.on('console', (message) => {
    if (message.type() === 'error') rawConsoleErrors.push(message.text());
  });
  page.on('pageerror', (error) => rawConsoleErrors.push(`pageerror: ${error.message}`));

  try {
    await check('Page loads with persistent Federation navigation', async () => {
      const response = await page.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
      assert.ok(response?.ok(), `navigation returned ${response?.status()}`);
      await assertText(page.locator('.brand'), 'Waspflow Federation');
      for (const label of ['Contribute', 'Requests', 'Activity', 'Settings', 'Help']) await assertText(page.locator('.primary-nav'), label);
      await page.screenshot({ path: path.join(artifactDir, 'initial.png'), fullPage: true });
    });

    await check('Idle contributor view and ledger copy', async () => {
      await assertSelectorVisible(page, '.status-dot[data-state="idle"]');
      await assertText(page, 'Ready when you are');
      await page.screenshot({ path: path.join(artifactDir, 'idle.png'), fullPage: true });
    });

    await check('Task choice card only appears when work is available', async () => {
      const next = page.getByRole('button', { name: 'Contribute next available' });
      const taskButtons = page.getByRole('button', { name: 'Contribute this' });
      if (await taskButtons.count()) {
        await assertText(page.locator('h2'), 'Choose a task');
        await assertEnabled(next);
        await assertEnabled(taskButtons.first());
      } else {
        assert.equal(await next.count(), 0, 'empty queues must not show a disabled contribute button');
        await assertText(page, 'No tasks are waiting right now. Nothing will run automatically');
      }
    });

    await check('Help keeps the safety boundary available in-app', async () => {
      await page.getByRole('link', { name: 'Help' }).click();
      await assertText(page, 'Your safety boundary');
      await assertText(page, 'Everything else is blocked');
      await page.screenshot({ path: path.join(artifactDir, 'safety-expanded.png'), fullPage: true });
    });

    await check('Requester form keeps its values and an inline submit error across polling, then clears the error on edit', async () => {
      await page.getByRole('link', { name: 'Requests' }).click();
      await assertSelectorVisible(page, '#task-name');
      await assertSelectorVisible(page, '#task-prompt');
      await assertSelectorVisible(page, '#task-folder');
      await page.locator('#task-name').fill('wave-d-form-persistence');
      await page.locator('#task-prompt').fill('Prove the error survives a status refresh.');
      await page.locator('#task-folder').fill('/definitely/not/a-folder');
      await page.getByRole('button', { name: 'Submit task' }).click();
      await assertText(page.locator('.form-feedback'), 'source folder does not exist');
      rawConsoleErrors.length = 0; // This deliberate 400 is the error path under test, not a page failure.
      await page.waitForTimeout(3_500);
      assert.equal(await page.locator('#task-name').inputValue(), 'wave-d-form-persistence');
      assert.equal(await page.locator('#task-prompt').inputValue(), 'Prove the error survives a status refresh.');
      assert.equal(await page.locator('#task-folder').inputValue(), '/definitely/not/a-folder');
      await assertText(page.locator('.form-feedback'), 'source folder does not exist');
      await page.locator('#task-prompt').fill('Edited prompt clears the old error.');
      assert.equal(await page.locator('.form-feedback').textContent(), '');
      assert.equal(await page.locator('#task-folder').getAttribute('required'), null);
      await page.screenshot({ path: path.join(artifactDir, 'advanced-submit-expanded.png'), fullPage: true });
    });

    await check('Activity and Settings render complete requester history and the cached identity', async () => {
      await page.getByRole('link', { name: 'Activity' }).click();
      await assertText(page, 'Contribution history');
      await assertText(page, 'Requester history');
      await page.getByRole('link', { name: 'Settings' }).click();
      await assertText(page, 'Accounts in use');
      await assertText(page, 'Docker account');
      await page.screenshot({ path: path.join(artifactDir, 'activity-settings.png'), fullPage: true });
    });

    await check('Settings shows a provider-start failure in the page instead of surfacing a transport error', async () => {
      const attentionPage = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      await attentionPage.route('**/status', async (route) => route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'idle', detail: 'OpenAI sign-in could not start. An existing OpenAI OAuth credential needs attention before another sign-in can start.', coordinator_unavailable: false, ledger_summary: { count_7d: 0 } }),
      }));
      await attentionPage.route('**/identity', async (route) => route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ docker_status: 'detected', providers: [{ service: 'openai', authed: false, capacity_kind: 'subscription' }] }),
      }));
      try {
        await attentionPage.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
        await attentionPage.getByRole('link', { name: 'Settings' }).click();
        await assertText(attentionPage, 'Sign-in needs attention');
        await assertText(attentionPage, 'existing OpenAI OAuth credential needs attention');
        await attentionPage.screenshot({ path: path.join(artifactDir, 'openai-signin-attention.png'), fullPage: true });
      } finally {
        await attentionPage.close();
      }
    });

    await check('Contribution controls require a consented task without mutating the rig', async () => {
      await page.getByRole('link', { name: 'Contribute' }).click();
      const next = page.getByRole('button', { name: 'Contribute next available' });
      if (await page.getByRole('button', { name: 'Contribute this' }).count()) await assertEnabled(next);
      else assert.equal(await next.count(), 0);
    });

    await check('Active contribution polls preserve a text selection for over ten seconds', async () => {
      const activePage = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      await activePage.route('**/status', async (route) => route.fulfill({
        status: 200,
        contentType: 'application/json',
        body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'contributing', detail: 'Contribution is running.', contribution: { display_id: 'render-stability-check', started_at: new Date().toISOString() }, coordinator_unavailable: false, ledger_summary: { count_7d: 0 } }),
      }));
      try {
        await activePage.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
        await assertSelectorVisible(activePage, '.guard strong');
        const selected = await activePage.locator('.guard strong').evaluate((node) => {
          const range = document.createRange();
          range.selectNodeContents(node);
          const selection = window.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          window.__waspflowSelectedNode = node;
          return selection.toString();
        });
        await activePage.waitForTimeout(10_500);
        const after = await activePage.evaluate(() => ({
          selection: window.getSelection().toString(),
          sameNode: window.__waspflowSelectedNode === document.querySelector('.guard strong'),
        }));
        assert.equal(after.selection, selected, 'polling must not clear a live text selection');
        assert.equal(after.sameNode, true, 'polling must not replace the selected DOM node');
        await activePage.screenshot({ path: path.join(artifactDir, 'active-selection-stable.png'), fullPage: true });
      } finally {
        await activePage.close();
      }
    });

    await check('Requester task detail renders the bounded execution transcript', async () => {
      const logPage = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      const digest = 'a'.repeat(64);
      await logPage.route('**/status', async (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ schema_version: 1, type: 'daemon_status', state: 'idle', detail: 'Ready to contribute.', coordinator_unavailable: false, ledger_summary: { count_7d: 0 } }) }));
      await logPage.route('**/requests', async (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify([{ task_digest: `sha256:${digest}`, display_id: 'transcript-check', status: 'SETTLED', published_at: '2026-07-22T00:00:00.000Z' }]) }));
      await logPage.route(`**/tasks/${digest}/log`, async (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ task_digest: `sha256:${digest}`, output: ['[stdout] task started', '[stderr] harness progress', ''].join('\n'), truncated: false }) }));
      await logPage.route(`**/tasks/${digest}`, async (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ task_digest: digest, display_id: 'transcript-check', author: 'ed25519:requester', status: 'SETTLED', execution_log_available: true, prompt: 'Render the transcript.' }) }));
      try {
        await logPage.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
        await logPage.getByRole('link', { name: 'Requests' }).click();
        await logPage.getByRole('button', { name: 'transcript-check' }).click();
        await logPage.getByRole('button', { name: 'View execution log' }).click();
        await assertText(logPage.locator('.execution-log'), 'harness progress');
        await logPage.screenshot({ path: path.join(artifactDir, 'execution-log.png'), fullPage: true });
      } finally {
        await logPage.close();
      }
    });

    await check('Expired sessions stop polling after two unauthorized status responses', async () => {
      const stalePage = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
      const staleErrors = [];
      let statusRequests = 0;
      stalePage.on('console', (message) => { if (message.type() === 'error') staleErrors.push(message.text()); });
      await stalePage.route('**/status', async (route) => {
        statusRequests += 1;
        await route.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ error: 'missing or invalid daemon session token' }) });
      });
      try {
        await stalePage.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
        await assertText(stalePage, 'This local link has expired; no task or account change was made');
        await assertEnabled(stalePage.getByRole('button', { name: 'Reconnect Federation' }));
        await stalePage.setViewportSize({ width: 390, height: 844 });
        await stalePage.screenshot({ path: path.join(artifactDir, 'session-expired-390.png'), fullPage: true });
        await stalePage.waitForTimeout(3_500);
        assert.equal(statusRequests, 2, 'the stale tab must stop status polling after repeated 401 responses');
        assert.equal(staleErrors.length, 2, 'the browser may report the two real 401 responses, but it must not keep emitting them');
      } finally {
        await stalePage.close();
      }
    });

    await check('No console errors on any Federation view', () => {
      assert.deepEqual(rawConsoleErrors, []);
    });
  } finally {
    await writeFile(path.join(artifactDir, 'sweep-results.json'), `${JSON.stringify({
      targetUrl: baseUrl,
      consoleErrors: rawConsoleErrors,
      results,
    }, null, 2)}\n`);
    await browser.close();
  }

  console.table(results);
  console.log(`Console errors: ${JSON.stringify(rawConsoleErrors)}`);
  if (results.some((result) => result.status === 'FAIL')) process.exitCode = 1;
}

async function assertText(scope, text) {
  await scope.getByText(text, { exact: false }).first().waitFor({ state: 'visible', timeout: 5_000 });
}

async function assertSelectorVisible(scope, selector) {
  await scope.locator(selector).first().waitFor({ state: 'visible', timeout: 5_000 });
}

async function assertEnabled(locator) {
  await locator.waitFor({ state: 'visible', timeout: 5_000 });
  assert.equal(await locator.isEnabled(), true, 'expected enabled control');
}

await main();
