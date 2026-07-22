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
      await assertText(page, 'Collective:');
      await assertText(page, 'completed this week');
      await page.screenshot({ path: path.join(artifactDir, 'idle.png'), fullPage: true });
    });

    await check('Task choice card has a next-available button and selectable tasks', async () => {
      await assertText(page.locator('h2'), 'Choose a task');
      const next = page.getByRole('button', { name: 'Contribute next available' });
      const taskButtons = page.getByRole('button', { name: 'Contribute this' });
      if (await taskButtons.count()) {
        await assertEnabled(next);
        await assertEnabled(taskButtons.first());
      } else {
        assert.equal(await next.isDisabled(), true, 'next-available must be disabled when the queue is empty');
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

    await check('Contribution controls are present and enabled without mutating the rig', async () => {
      await page.getByRole('link', { name: 'Contribute' }).click();
      await assertEnabled(page.getByRole('button', { name: 'Start contributing' }));
      const next = page.getByRole('button', { name: 'Contribute next available' });
      if (await page.getByRole('button', { name: 'Contribute this' }).count()) await assertEnabled(next);
      else assert.equal(await next.isDisabled(), true);
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
