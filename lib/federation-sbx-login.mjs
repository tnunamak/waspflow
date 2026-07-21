/** Structured Docker device-login flow for the Federation sbx identity. */
import { spawn as spawnChild } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { probeSbxPreflight, sbxChildEnv } from './federation-docker-backend.mjs';

export class SbxLoginError extends Error {
  constructor(message) { super(message); this.name = 'SbxLoginError'; }
}

function sbxBin() {
  return process.env.WASPFLOW_SBX_BIN || 'sbx';
}

function stop(child) {
  try { child.kill('SIGTERM'); } catch { /* already exited */ }
  const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* already exited */ } }, 1_000);
  child.once('exit', () => clearTimeout(timer));
}

/**
 * Runs `sbx login` in Waspflow's profile and returns its browser handoff.
 * Completion is proven by a fresh preflight, not by a browser click or text.
 */
export async function startSbxDockerLogin({
  spawnProcess = spawnChild,
  probe = probeSbxPreflight,
  platformName = process.platform,
  env = sbxChildEnv(),
  loginBin = sbxBin(),
  urlTimeoutMs = 15_000,
  completionTimeoutMs = 5 * 60_000,
  pollIntervalMs = 500,
} = {}) {
  const child = spawnProcess(loginBin, ['login'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let output = '';
  let exited = false;
  let exitCode = null;
  child.stdout?.on('data', (chunk) => { output += chunk.toString('utf8'); });
  child.once('exit', (code) => { exited = true; exitCode = code; });

  const deadline = Date.now() + urlTimeoutMs;
  let url;
  let code;
  while (Date.now() < deadline) {
    url = /https?:\/\/[^\s]+/.exec(output)?.[0];
    code = /one-time device confirmation code is:\s*([A-Z0-9-]+)/i.exec(output)?.[1];
    if (url) break;
    if (exited) throw new SbxLoginError(`Docker sign-in ended before showing a browser link${exitCode === 0 ? '.' : ` (exit ${exitCode ?? 'unknown'}).`}`);
    await delay(25);
  }
  if (!url) {
    stop(child);
    throw new SbxLoginError('Docker sign-in did not provide a browser link.');
  }

  return {
    url,
    ...(code ? { code } : {}),
    cancel: () => stop(child),
    waitForCompletion: async () => {
      const completionDeadline = Date.now() + completionTimeoutMs;
      while (Date.now() < completionDeadline) {
        const preflight = await probe({ platformName });
        if (preflight.checks.find((item) => item.name === 'docker_login')?.ok) {
          stop(child);
          return { status: 'complete', detail: 'Docker sign-in was confirmed.' };
        }
        if (exited && exitCode !== 0) return { status: 'failed', detail: 'Docker sign-in stopped before it was confirmed.' };
        await delay(pollIntervalMs);
      }
      stop(child);
      return { status: 'failed', detail: 'Docker sign-in timed out before it was confirmed.' };
    },
  };
}
