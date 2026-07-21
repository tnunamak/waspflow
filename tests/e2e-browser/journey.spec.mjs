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
const favicon401 = /favicon\.ico.*(?:401|Unauthorized)|(?:401|Unauthorized).*favicon\.ico/i;
const browserFavicon401 = 'Failed to load resource: the server responded with a status of 401 (Unauthorized)';
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
    await check('Page loads with the Federation heading', async () => {
      const response = await page.goto(targetUrl.toString(), { waitUntil: 'networkidle', timeout: 15_000 });
      assert.ok(response?.ok(), `navigation returned ${response?.status()}`);
      await assertText(page.locator('h1'), 'Waspflow Federation');
      await page.screenshot({ path: path.join(artifactDir, 'initial.png'), fullPage: true });
    });

    await check('Idle contributor view and ledger copy', async () => {
      await assertSelectorVisible(page, '[data-state="idle"]');
      await assertText(page, 'Ready to contribute.');
      await assertText(page, 'Coordinator: trusted');
      await assertText(page, "You're helping:");
      await assertText(page, "You've completed 0 tasks this week.");
      await page.screenshot({ path: path.join(artifactDir, 'idle.png'), fullPage: true });
    });

    await check('Task choice card has a next-available button and selectable tasks', async () => {
      await assertText(page.locator('h2'), 'Choose a task');
      const next = page.getByRole('button', { name: 'Contribute next available' });
      await assertEnabled(next);
      const taskButtons = page.getByRole('button', { name: 'Contribute this' });
      assert.ok(await taskButtons.count() >= 1, 'expected at least one Contribute this button');
      await assertEnabled(taskButtons.first());
    });

    await check('Safety accordion stays expanded across two poll cycles', async () => {
      const safety = page.locator('details').filter({ has: page.getByText('How this works / Is this safe?', { exact: true }) });
      await safety.locator('summary').click();
      await assertText(safety, 'Everything else is blocked');
      await page.waitForTimeout(4_000);
      assert.equal(await safety.evaluate((element) => element.open), true, 'safety accordion collapsed during polling');
      await page.screenshot({ path: path.join(artifactDir, 'safety-expanded.png'), fullPage: true });
    });

    await check('Advanced-submit accordion stays expanded across two poll cycles', async () => {
      const submit = page.locator('details').filter({ has: page.getByText('Submit a task (advanced)', { exact: true }) });
      await submit.locator('summary').click();
      await assertSelectorVisible(submit, '#source');
      await assertSelectorVisible(submit, '#prompt');
      await assertSelectorVisible(submit, '#display-id');
      await page.waitForTimeout(4_000);
      assert.equal(await submit.evaluate((element) => element.open), true, 'advanced-submit accordion collapsed during polling');
      await page.screenshot({ path: path.join(artifactDir, 'advanced-submit-expanded.png'), fullPage: true });
    });

    await check('Contribution controls are present and enabled without mutating the rig', async () => {
      await assertEnabled(page.getByRole('button', { name: 'Start contributing' }));
      await assertEnabled(page.getByRole('button', { name: 'Contribute next available' }));
      assert.ok(await page.getByRole('button', { name: 'Contribute this' }).count() >= 1);
    });

    await check('No console errors other than the known favicon 401', () => {
      assert.deepEqual(filteredConsoleErrors(), []);
    });
  } finally {
    await writeFile(path.join(artifactDir, 'sweep-results.json'), `${JSON.stringify({
      targetUrl: targetUrl.toString(),
      consoleErrors: filteredConsoleErrors(),
      ignoredConsoleErrors: rawConsoleErrors.filter((message) => !filteredConsoleErrors().includes(message)),
      results,
    }, null, 2)}\n`);
    await browser.close();
  }

  console.table(results);
  console.log(`Console errors (excluding favicon 401): ${JSON.stringify(filteredConsoleErrors())}`);
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

function filteredConsoleErrors() {
  return rawConsoleErrors.filter((message) => !favicon401.test(message) && message !== browserFavicon401);
}

await main();
