/**
 * Waspflow-driven auth flow (auth UX reframe, 2026-07-20).
 *
 * Prior shape: HarnessSpec.credential_discovery.login_command was presented
 * to the OPERATOR as an instruction ("run this yourself"). The owner
 * corrected this model on three points:
 *
 *   (a) Waspflow RUNS the sbx auth command itself; the user does ONLY the
 *       browser part. Never "go type this in your shell."
 *   (b) Detect-first: check the prepared job sandbox's harness-defined
 *       status probe before triggering anything. Only start a login flow
 *       when a job actually needs a provider that isn't authed yet. Never
 *       re-prompt once set.
 *   (c) Not terminal-bound: the packaging target is an installed app
 *       (clawmeter-style), not a forced terminal. The auth step must emit a
 *       structured event {url, waitForCompletion} that a future non-terminal
 *       UI can render — never architected AS a terminal command, even though
 *       v0's own test harness happens to run in one.
 *
 * This module is the structured interface. `startAuthFlow()` returns an
 * AuthFlowHandle whose shape is stable regardless of what eventually
 * consumes it (a v0 terminal script today; a tray/GUI notification later).
 * It does NOT print anything itself — callers decide how to render
 * `handle.url`. See scripts/federation-harness-auth-proof-live-run.sh for
 * the v0 terminal rendering of this same interface.
 *
 * A host-url-flow command may be host-side (Codex's sbx secret command) or
 * guest-side (Claude's CLI command). Guest-side commands run through `sbx
 * exec` in the prepared job sandbox; success is always proved by the
 * harness-defined status probe, never inferred from a browser click.
 */
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';
import { sanitizedEnv, sbxChildEnv, suppressChildBrowserLaunch } from './federation-docker-backend.mjs';

// A freshly-created Docker secret can take substantially longer than a normal
// browser handoff before it prints its URL.  Fifteen seconds made the UI turn
// a slow-but-valid first run into a false failure and left the underlying
// listener alive long enough to make the next attempt conflict.
export const DEFAULT_LOGIN_URL_TIMEOUT_MS = 75_000;

export class AuthFlowError extends Error {
  constructor(message) { super(message); this.name = 'AuthFlowError'; }
}

/**
 * @typedef {object} AuthFlowHandle
 * @property {string} harness_id
 * @property {'pending'|'awaiting-browser'|'complete'|'failed'|'cancelled'} status
 * @property {string} [url]            present once parsed from the command's output
 * @property {() => Promise<{status: 'complete'|'failed', detail: string}>} waitForCompletion
 * @property {() => void} cancel       kills the underlying process and any listener it opened
 */

/**
 * Checks whether a harness's provider secret is already set in the
 * Waspflow-scoped sbx profile, WITHOUT triggering any login flow. This
 * remains useful to callers that can decide before creating a job;
 * startAuthFlow() also performs the authoritative per-job status probe.
 *
 * @param {import('./federation-harness-spec.mjs').HarnessSpec} harnessSpec
 * @param {{sbxBin?: string, env?: NodeJS.ProcessEnv, timeoutMs?: number}} [opts]
 * @returns {Promise<{alreadySet: boolean, raw: string}>}
 */
export async function isProviderSecretSet(harnessSpec, opts = {}) {
  const sbxBin = opts.sbxBin || process.env.WASPFLOW_SBX_BIN || 'sbx';
  const env = sandboxEnv(opts.env || process.env);
  const args = ['secret', 'ls', '-g', '--service', harnessSpec.provider_service_id];
  const raw = await runAndCapture(sbxBin, args, { env, timeoutMs: opts.timeoutMs ?? 10_000 });
  // `sbx secret ls` has no --json output as of v0.35.0 (confirmed against a
  // real install); "No secrets found for scope ... and service ..." is the
  // documented empty-result text. Absence of that exact phrase, combined
  // with non-empty output, means a secret line was printed.
  const alreadySet = raw.trim().length > 0 && !/No secrets found/i.test(raw);
  return { alreadySet, raw };
}

/**
 * Starts a `docker-native-oauth` / `host-url-flow` login, driven entirely by
 * waspflow. The caller (a v0 terminal script, or eventually a tray/GUI) is
 * handed a structured handle — it never sees or types the raw `sbx` command.
 *
 * @param {import('./federation-harness-spec.mjs').HarnessSpec} harnessSpec
 * @param {{sandboxId: string, sbxBin?: string, env?: NodeJS.ProcessEnv, urlTimeoutMs?: number, completionTimeoutMs?: number, pollIntervalMs?: number, onHandle?: (handle: AuthFlowHandle) => void}} opts
 * @returns {Promise<AuthFlowHandle>}
 */
export async function startAuthFlow(harnessSpec, opts = {}) {
  if (harnessSpec.auth_strategy !== 'docker-native-oauth') {
    throw new AuthFlowError(`startAuthFlow only drives docker-native-oauth harnesses; '${harnessSpec.harness_id}' is '${harnessSpec.auth_strategy}'`);
  }
  if (harnessSpec.credential_discovery.flow_shape !== 'host-url-flow') {
    throw new AuthFlowError(
      `startAuthFlow only drives 'host-url-flow' — '${harnessSpec.harness_id}' is '${harnessSpec.credential_discovery.flow_shape}', which requires an ` +
      `interactive fallback (see describeAuthRequirement() for the honest description of that case).`
    );
  }
  if (typeof opts.sandboxId !== 'string' || !opts.sandboxId) {
    throw new AuthFlowError(`startAuthFlow requires the prepared job sandbox for '${harnessSpec.harness_id}'`);
  }

  const sbxBin = opts.sbxBin || process.env.WASPFLOW_SBX_BIN || 'sbx';
  const env = sandboxEnv(opts.env || process.env);
  const urlTimeoutMs = opts.urlTimeoutMs ?? DEFAULT_LOGIN_URL_TIMEOUT_MS;
  const completionTimeoutMs = opts.completionTimeoutMs ?? 5 * 60_000;
  const pollIntervalMs = opts.pollIntervalMs ?? 500;

  if (await probeReportsSuccess(harnessSpec, opts.sandboxId, { sbxBin, env, timeoutMs: 10_000 })) {
    return {
      harness_id: harnessSpec.harness_id,
      status: 'complete',
      waitForCompletion: async () => ({ status: 'complete', detail: 'already authenticated' }),
      cancel: () => {},
    };
  }

  const words = harnessSpec.credential_discovery.login_command.split(' ');
  const args = words[0] === 'sbx'
    ? words.slice(1)
    : ['exec', opts.sandboxId, '--', ...words];
  const child = spawn(sbxBin, args, { env });

  /** @type {AuthFlowHandle} */
  const handle = {
    harness_id: harnessSpec.harness_id,
    status: 'pending',
    url: undefined,
    waitForCompletion: undefined, // assigned below once we can build the promise
    cancel: () => {
      handle.status = 'cancelled';
      // SIGTERM first (lets the child's own trap/cleanup run if it has
      // one), then a SIGKILL fallback if it hasn't exited within a short
      // grace period. SIGTERM delivery/handling is not guaranteed — proven
      // directly in this environment, where a trap-holding child survived
      // both `child.kill('SIGTERM')` and a plain shell `kill -TERM` from
      // outside Node entirely. This is exactly the class of stray-listener
      // risk the live probe surfaced (a `sbx secret set --oauth` process
      // still holding localhost:1455): cancel() must not depend on
      // cooperative signal handling to guarantee cleanup.
      try { child.kill('SIGTERM'); } catch { /* already exited */ }
      const killTimer = setTimeout(() => {
        try { child.kill('SIGKILL'); } catch { /* already exited */ }
      }, 1000);
      child.once('exit', () => clearTimeout(killTimer));
    },
  };
  // The URL can be slow on a first Docker-secret setup. Publish cancellation
  // as soon as the child exists so a retry never has to wait for that URL
  // timeout before it can clean up the stale listener.
  opts.onHandle?.(handle);

  let stdoutBuf = '';
  let stderrBuf = '';
  const urlPattern = new RegExp(harnessSpec.credential_discovery.url_prompt_pattern, 'i');
  const urlLineExtract = /https?:\/\/\S+/;
  const existingCredentialPrompt = /OAuth token already exists\.\s*Overwrite\?/i;

  const urlReady = new Promise((resolve, reject) => {
    let settled = false;
    const finish = (fn, value) => { if (!settled) { settled = true; fn(value); } };
    const captureUrl = () => {
      // sbx and the underlying provider disagree on which stream carries
      // progress output. Treat the two streams as one human-facing transcript:
      // a valid URL on stderr is just as actionable as one on stdout.
      const output = `${stdoutBuf}\n${stderrBuf}`;
      if (existingCredentialPrompt.test(output)) {
        finish(reject, new AuthFlowError(
          'An existing OpenAI OAuth credential needs attention before another sign-in can start. It was not accepted by the sandbox status check; remove or refresh it, then try again.'
        ));
        return;
      }
      if (!handle.url && urlPattern.test(output)) {
        const match = urlLineExtract.exec(output);
        if (match) {
          handle.url = match[0];
          handle.status = 'awaiting-browser';
          finish(resolve, handle.url);
        }
      }
    };
    child.stdout.on('data', (chunk) => {
      stdoutBuf += chunk.toString('utf8');
      captureUrl();
    });
    child.stderr.on('data', (chunk) => {
      stderrBuf += chunk.toString('utf8');
      captureUrl();
    });
    child.once('error', (error) => finish(reject, new AuthFlowError(`failed to spawn '${sbxBin}': ${error.message}`)));
    child.once('exit', (code) => {
      if (!handle.url) finish(reject, new AuthFlowError(code === 0
        ? 'login command exited before producing a URL'
        : `exited ${code}: ${(stderrBuf || stdoutBuf).trim()}`));
    });
  });

  const completion = new Promise((resolve) => {
    let settled = false;
    const settle = (result) => { if (!settled) { settled = true; resolve(result); } };
    child.on('error', (error) => {
      handle.status = 'failed';
      settle({ status: 'failed', detail: `failed to spawn '${sbxBin}': ${error.message}` });
    });
    child.on('exit', (code) => {
      // A SIGKILLed child's stdio pipes can otherwise keep Node's event
      // loop alive indefinitely (observed directly: a killed child left the
      // process hanging until an external `timeout` intervened, even though
      // the 'exit' event itself fired correctly) — explicitly release them.
      child.stdout.destroy();
      child.stderr.destroy();
      if (handle.status === 'cancelled') {
        settle({ status: 'failed', detail: 'cancelled before completion' });
        return;
      }
      if (code !== 0) {
        handle.status = 'failed';
        settle({ status: 'failed', detail: `exited ${code}: ${(stderrBuf || stdoutBuf).trim()}` });
      }
    });
  });

  handle.waitForCompletion = async () => {
    // Use an AbortController so the losing side of the race is actually
    // cancelled — an uncleared node:timers/promises setTimeout keeps the
    // event loop alive for its full duration even after the other side
    // wins, which would otherwise make every caller's process hang.
    const timeoutController = new AbortController();
    const timeoutPromise = delay(completionTimeoutMs, undefined, { signal: timeoutController.signal })
      .then(() => {
        const reason = `timed out after ${completionTimeoutMs}ms waiting for the browser step to complete`;
        handle.cancel();
        return { status: 'failed', detail: reason };
      })
      .catch(() => null); // aborted — completion() won the race, ignore
    try {
      while (true) {
        const result = await Promise.race([
          completion,
          timeoutPromise,
          probeReportsSuccess(harnessSpec, opts.sandboxId, { sbxBin, env, timeoutMs: 10_000 })
            .then((success) => success ? { status: 'complete', detail: 'status probe reported authenticated' } : null),
        ]);
        if (result) {
          handle.status = result.status === 'complete' ? 'complete' : handle.status;
          return result;
        }
        await delay(pollIntervalMs);
      }
    } finally {
      timeoutController.abort();
    }
  };

  const urlTimeoutController = new AbortController();
  const urlTimeout = delay(urlTimeoutMs, undefined, { signal: urlTimeoutController.signal })
    .then(() => { throw new AuthFlowError(`timed out after ${urlTimeoutMs}ms waiting for a login URL to appear`); })
    .catch((error) => {
      if (error?.name === 'AbortError') return null;
      throw error;
    });
  try {
    const result = await Promise.race([urlReady, urlTimeout]);
    if (result === null) throw new AuthFlowError('login URL wait was cancelled');
  } catch (error) {
    handle.cancel();
    throw error;
  } finally {
    urlTimeoutController.abort();
  }
  return handle;
}

async function probeReportsSuccess(harnessSpec, sandboxId, { sbxBin, env, timeoutMs }) {
  const raw = await runAndCapture(sbxBin, ['exec', sandboxId, '--', 'sh', '-c', harnessSpec.login_status_probe.command], { env, timeoutMs })
    .catch(() => '');
  let values = {};
  try { values = JSON.parse(raw); } catch {
    for (const line of raw.split(/\r?\n/)) {
      const match = /^([^=]+)=(.*)$/.exec(line);
      if (match) values[match[1]] = match[2];
    }
  }
  return Object.entries(harnessSpec.login_status_probe.success).every(([key, value]) => values[key] === value);
}

/**
 * For flow_shapes startAuthFlow cannot drive (interactive-session-flow),
 * returns an honest structured description instead of forcing a false
 * {url, waitForCompletion} shape. A caller (terminal or future UI) uses this
 * to render "attach to a sandbox session and run /login" rather than a URL
 * prompt that doesn't exist for this harness.
 *
 * @param {import('./federation-harness-spec.mjs').HarnessSpec} harnessSpec
 * @returns {{drivable: boolean, flow_shape: string, instruction?: string}}
 */
export function describeAuthRequirement(harnessSpec) {
  const shape = harnessSpec.credential_discovery?.flow_shape;
  if (harnessSpec.auth_strategy === 'docker-native-oauth' && shape === 'host-url-flow') {
    return { drivable: true, flow_shape: shape };
  }
  if (harnessSpec.auth_strategy === 'docker-native-oauth' && shape === 'interactive-session-flow') {
    return {
      drivable: false,
      flow_shape: shape,
      instruction: `Attach an interactive sandbox session (sbx run ${harnessSpec.install}) and run '${harnessSpec.credential_discovery.login_command}' inside it. Waspflow cannot drive this host-side — there is no URL to capture.`,
    };
  }
  return { drivable: false, flow_shape: shape ?? 'n/a', instruction: `'${harnessSpec.harness_id}' does not use a docker-native-oauth login flow (strategy: ${harnessSpec.auth_strategy}).` };
}

function runAndCapture(command, args, { env, timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env });
    let out = '';
    let err = '';
    let killTimer;
    const timer = setTimeout(() => {
      child.kill('SIGTERM');
      // SIGTERM is not guaranteed to be honored (proven directly against a
      // real trap-holding process in this environment) — fall back to
      // SIGKILL rather than risk an indefinite hang on an unresponsive sbx.
      killTimer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* already exited */ } }, 1000);
      reject(new AuthFlowError(`'${command} ${args.join(' ')}' timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    child.stdout.on('data', (chunk) => { out += chunk.toString('utf8'); });
    child.stderr.on('data', (chunk) => { err += chunk.toString('utf8'); });
    child.on('error', (error) => { clearTimeout(timer); clearTimeout(killTimer); reject(error); });
    child.on('exit', () => {
      clearTimeout(timer);
      clearTimeout(killTimer);
      child.stdout.destroy();
      child.stderr.destroy();
      resolve(out || err);
    });
  });
}

function sandboxEnv(baseEnv) {
  // MUST resolve the sbx identity exactly like the backend that CREATED the
  // job sandbox (sbxChildEnv: the isolated Waspflow sbx home with the
  // short-path/legacy selection logic). A prior revision fell back to the
  // user's REAL HOME, so the login `sbx exec` talked to the PERSONAL sbx
  // daemon — which has never heard of the job's sandbox — failing
  // "no sandbox named <id>" on every fresh contribute (found live on both a
  // fresh VM and the host). One resolver, one identity.
  const env = sanitizedEnv(baseEnv);
  env.HOME = sbxChildEnv().HOME;
  // Same rationale as sbxChildEnv: login children must not pop the desktop
  // browser; their URLs surface in the Federation UI instead.
  return suppressChildBrowserLaunch(env);
}
