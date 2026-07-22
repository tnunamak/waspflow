/**
 * GitHub device login for task access. Unlike provider capacity sign-in, this
 * creates a static GitHub token and stores it only in Federation's sbx secret
 * store. The task receives a proxy-managed GH_TOKEN sentinel through the
 * wf-gh-cli kit; it never receives the real token or the user's gh config.
 */
import { spawn } from 'node:child_process';
import { rm } from 'node:fs/promises';
import path from 'node:path';
import { sanitizedEnv, sbxChildEnv } from './federation-docker-backend.mjs';

export class GitHubAuthError extends Error {}

function githubEnv(baseEnv = process.env, federationHome = sbxChildEnv().HOME) {
  const env = sanitizedEnv(baseEnv);
  env.HOME = federationHome;
  // gh honors GH_CONFIG_DIR. Keeping it below Federation's sbx identity makes
  // the isolation explicit and prevents any read of ~/.config/gh.
  env.GH_CONFIG_DIR = path.join(federationHome, '.gh-task-access');
  return env;
}

function spawnCapture(command, args, { env, input } = {}) {
  const child = spawn(command, args, { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  const done = new Promise((resolve, reject) => {
    child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8'); });
    child.stderr.on('data', (chunk) => { stderr += chunk.toString('utf8'); });
    child.once('error', reject);
    child.once('exit', (code) => resolve({ code, stdout, stderr }));
  });
  if (input !== undefined) child.stdin.end(input);
  else child.stdin.end();
  return { child, done, output: () => `${stdout}\n${stderr}` };
}

/** Starts the real default gh device flow and returns its capturable code/URL. */
export async function startGitHubAuthFlow({ ghBin = 'gh', sbxBin = process.env.WASPFLOW_SBX_BIN || 'sbx', env = process.env, federationHome = sbxChildEnv().HOME, urlTimeoutMs = 75_000, onHandle } = {}) {
  const childEnv = githubEnv(env, federationHome);
  // Avoid the OS credential keychain: gh's default keychain namespace is
  // user-wide, while this flow must never read or write the personal gh
  // account. The short-lived file is immediately deleted after its token is
  // moved into Federation's sbx secret store.
  const login = spawnCapture(ghBin, ['auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--skip-ssh-key', '--insecure-storage'], { env: childEnv });
  const cleanConfig = () => rm(childEnv.GH_CONFIG_DIR, { recursive: true, force: true }).catch(() => {});
  const handle = {
    harness_id: 'gh-cli',
    status: 'pending',
    url: undefined,
    code: undefined,
    cancel() {
      handle.status = 'cancelled';
      try { login.child.kill('SIGTERM'); } catch {}
      // The CLI may still be flushing its insecure on-disk config when it
      // receives SIGTERM, so defer removal until it has actually exited.
      void login.done.finally(cleanConfig);
    },
    waitForCompletion: undefined,
  };
  onHandle?.(handle);

  const device = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new GitHubAuthError(`timed out after ${urlTimeoutMs}ms waiting for GitHub's device code`)), urlTimeoutMs);
    const inspect = () => {
      const output = login.output();
      const url = /(https:\/\/github\.com\/login\/device)/.exec(output)?.[1];
      const code = /one-time code:\s*([A-Z0-9-]+)/i.exec(output)?.[1];
      if (url && code) { clearTimeout(timer); resolve({ url, code }); }
    };
    login.child.stdout.on('data', inspect);
    login.child.stderr.on('data', inspect);
    inspect();
    login.done.then((result) => {
      inspect();
      if (!handle.url && result.code !== 0) { clearTimeout(timer); reject(new GitHubAuthError(`GitHub sign-in exited ${result.code}: ${(result.stderr || result.stdout).trim()}`)); }
    }).catch(reject);
  }).catch(async (error) => {
    handle.cancel();
    await login.done.catch(() => {});
    await cleanConfig();
    throw error;
  });

  handle.url = device.url;
  handle.code = device.code;
  handle.status = 'awaiting-browser';
  handle.waitForCompletion = async () => {
    const result = await login.done;
    try {
      if (handle.status === 'cancelled') return { status: 'failed', detail: 'cancelled before completion' };
      if (result.code !== 0) return { status: 'failed', detail: `GitHub sign-in exited ${result.code}: ${(result.stderr || result.stdout).trim()}` };
      const tokenRead = spawnCapture(ghBin, ['auth', 'token', '--hostname', 'github.com'], { env: childEnv });
      const token = await tokenRead.done;
      if (token.code !== 0 || !token.stdout.trim()) return { status: 'failed', detail: 'GitHub sign-in completed, but Federation could not securely store task access.' };
      // Token flows only from gh stdout into sbx stdin. Do not put it in argv,
      // environment, a log, or this returned object.
      const store = spawnCapture(sbxBin, ['secret', 'set', '-g', 'github', '--force'], { env: { ...childEnv, HOME: sbxChildEnv().HOME }, input: token.stdout.trim() });
      const stored = await store.done;
      if (stored.code !== 0) return { status: 'failed', detail: `Federation could not store GitHub task access: ${(stored.stderr || stored.stdout).trim()}` };
      handle.status = 'complete';
      return { status: 'complete', detail: 'GitHub task access is ready.' };
    } finally {
      await cleanConfig();
    }
  };
  return handle;
}
