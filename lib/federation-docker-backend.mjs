/**
 * DockerSbxBackend: SandboxBackend implementation over Docker Sandboxes'
 * `sbx` CLI (Runtime Decision, 2026-07-20 — inbox/2026-07-20-chatgpt-sandbox.md).
 *
 * Status: Federation Preview backend only. This module implements the
 * MECHANISM (interface, error handling, safety boundary around workspace and
 * credentials). It does NOT itself prove the graduation gates A-I from the
 * decision note — that is a separate adversarial conformance suite run
 * against a real `sbx` install. See DOCKER_ADAPTER_MAKER_REPORT.md for the
 * honest list of what remains unverified pending real sbx.
 *
 * prepare()/start()/destroy()'s `sbx` argv shapes were corrected and directly
 * proven against a real, authenticated sbx v0.35.0 install (2026-07-21):
 * `sbx run` needs the agent BEFORE the workspace path (not after, as this
 * file originally guessed) plus `--detached`; `start()` must drive the
 * entrypoint through `sbx exec SANDBOX -- sh -c ENTRYPOINT` since entrypoint
 * is a multi-word HarnessSpec command string, not a single guest binary name;
 * `sbx rm` needs `--force` non-interactively. A full prepare->start->destroy
 * cycle against a real deny-all-policy sandbox produced the exact expected
 * stdout and an independently-verified clean removal. See
 * docs/design/FEDERATION_V0_UAT_REPORT.md "Autonomous fix loop".
 */

import { execFile as execFileCb } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, rm, stat, lstat, readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { SandboxBackend } from './federation-runtime.mjs';

const execFile = promisify(execFileCb);

export const BACKEND_ID = 'docker-sbx';
export const SBX_PREFLIGHT_SCHEMA_VERSION = 1;
const INSTALL_HINT = 'https://docs.docker.com/ai/sandboxes/get-started/';
const UBUNTU_INSTALL_FIX = 'curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-sbx';
export const SBX_SOCKET_PATH_LIMIT = 104;
const SBX_CONTAINERD_SOCKET_RELATIVE_PATH = '.local/state/sandboxes/sandboxes/sandboxd/containerd/containerd.sock.ttrpc';
let warnedAboutLongLegacySbxHome = false;

// Read at call time (not module load) so tests can point WASPFLOW_SBX_BIN at
// a stub executable per-test without re-importing the module.
function sbxBin() {
  return process.env.WASPFLOW_SBX_BIN || 'sbx';
}

// Env var name patterns that must never reach an `sbx` child process. Matches
// the note's §3 list: SSH agent forwarding, DOCKER_HOST, provider/model
// secrets, cloud CLI credentials, Git credential helpers, personal OAuth state.
const STRIP_EXACT = new Set(['SSH_AUTH_SOCK', 'DOCKER_HOST']);
const STRIP_PATTERNS = [
  /_API_KEY$/i,
  /_TOKEN$/i,
  /^AWS_/i,
  /^GCP_/i,
  /^GOOGLE_/i,
  /^AZURE_/i,
  /^GIT_/i,
  /^GH_/i,
  /^GITHUB_/i,
  /^DOCKER_/i,
  /^NPM_/i,
  /^OPENAI_/i,
  /^ANTHROPIC_/i,
];

/**
 * Returns a copy of baseEnv with credential/identity-bearing variables
 * stripped. Exported by exact name for an independent hygiene test.
 * @param {NodeJS.ProcessEnv} baseEnv
 * @returns {NodeJS.ProcessEnv}
 */
export function sanitizedEnv(baseEnv) {
  const out = {};
  for (const [key, value] of Object.entries(baseEnv || {})) {
    if (STRIP_EXACT.has(key)) continue;
    if (STRIP_PATTERNS.some((pattern) => pattern.test(key))) continue;
    out[key] = value;
  }
  return out;
}

/**
 * Waspflow-owned sbx state directory, distinct from the developer's personal
 * sbx config. `sbx` has no documented --config-dir flag as of this writing
 * (Runtime Decision §1: "I did not find a documented, cross-platform named
 * local-profile mechanism"). This is the LAST-RESORT option from that
 * numbered list: a distinct OS-level identity via a Waspflow-owned HOME,
 * pending Docker confirming a supported profile mechanism (graduation gate A,
 * decision-note item 12).
 */
export function containerdSocketPathForSbxHome(home) {
  return path.join(home, SBX_CONTAINERD_SOCKET_RELATIVE_PATH);
}

/**
 * Selects Federation's isolated sbx HOME without moving existing state.
 * `sbx` appends 75 characters here (a slash plus its containerd socket path),
 * so the home path must be at most 29 characters for Unix's 104-char limit.
 */
export function selectSbxHome({ home = os.homedir(), override = process.env.WASPFLOW_FEDERATION_SBX_HOME, pathExists = existsSync } = {}) {
  if (override) return { home: override, migration: null };

  const defaultHome = path.join(home, '.wfsbx');
  const legacyHome = path.join(home, '.waspflow', 'sbx-home');
  if (!pathExists(legacyHome) || pathExists(defaultHome)) return { home: defaultHome, migration: null };

  if (containerdSocketPathForSbxHome(legacyHome).length <= SBX_SOCKET_PATH_LIMIT) {
    return { home: legacyHome, migration: 'using_legacy_home' };
  }
  return { home: defaultHome, migration: 'legacy_home_too_long' };
}

function sbxHome() {
  const selection = selectSbxHome();
  if (selection.migration === 'legacy_home_too_long' && !warnedAboutLongLegacySbxHome) {
    warnedAboutLongLegacySbxHome = true;
    process.stderr.write('Waspflow is using a new sandbox home because the previous sandbox path is too long; no files were moved.\n');
  }
  return selection.home;
}

function scratchRoot() {
  return process.env.WASPFLOW_FEDERATION_SCRATCH_ROOT || os.tmpdir();
}

function sandboxNameFor(jobId) {
  const digest = createHash('sha256').update(jobId).digest('hex').slice(0, 16);
  return `wf-${digest}`;
}

/** Builds the sanitized, profile-isolated env every `sbx` child process gets. */
export function sbxChildEnv() {
  const env = sanitizedEnv(process.env);
  env.HOME = sbxHome();
  return env;
}

async function runSbx(args) {
  try {
    const { stdout, stderr } = await execFile(sbxBin(), args, {
      env: sbxChildEnv(),
      maxBuffer: 16 * 1024 * 1024,
    });
    return { code: 0, stdout, stderr };
  } catch (error) {
    if (error && error.code === 'ENOENT') throw error;
    return { code: typeof error.code === 'number' ? error.code : 1, stdout: error.stdout || '', stderr: error.stderr || String(error.message || error) };
  }
}

function outputOf(result) {
  // sbx diagnose uses ANSI styling in an interactive-capable terminal. The
  // readiness facts must not depend on whether its output was colorized.
  return `${result?.stdout || ''}\n${result?.stderr || ''}`.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, '').trim();
}

function diagnosticsOf(result) {
  return `${result?.stdout || ''}${result?.stderr ? `\n${result.stderr}` : ''}`.trim();
}

function commandWorked(result) {
  return result && result.code === 0;
}

function packageIsInstalled(result, packageName) {
  return commandWorked(result) && new RegExp(`^${packageName}\\tinstalled\\t`, 'm').test(result.stdout || '');
}

function containerdIsV2(result) {
  return commandWorked(result) && /(?:^|\s)v?2\./.test(outputOf(result));
}

function hasDiagnostic(text, pattern) {
  return pattern.test(text || '');
}

function check(name, ok, detail, fix, diagnostics = '') {
  return { name, ok, detail, fix, diagnostics };
}

export function socketPathLengthCheck(home = sbxHome()) {
  const socketPath = containerdSocketPathForSbxHome(home);
  const ok = socketPath.length <= SBX_SOCKET_PATH_LIMIT;
  return check(
    'socket_path_length',
    ok,
    ok ? `The sandbox files are at a path that is ${socketPath.length} characters long.` : 'The sandbox files live at a path that is too long for the system.',
    ok ? '' : 'Set WASPFLOW_FEDERATION_SBX_HOME to a shorter directory.',
    `Sandbox path length: ${socketPath.length} characters.`,
  );
}

function preflightChecks({ platformName, version, packages, dockerVersion, containerdVersion, diagnose, policy, kvmReadable, kvmWritable, hypervisorPlatform, sbxHome: activeSbxHome = sbxHome() }) {
  if (platformName === 'win32') return [...windowsPreflightChecks({ version, diagnose, hypervisorPlatform }), socketPathLengthCheck(activeSbxHome)];
  const diagnostics = outputOf(diagnose);
  const diagnoseDiagnostics = diagnosticsOf(diagnose);
  const policyOutput = outputOf(policy);
  const policyDiagnostics = diagnosticsOf(policy);
  const sbxPresent = version?.errorCode !== 'ENOENT';
  const sbxInstallOk = sbxPresent && commandWorked(version)
    && (platformName !== 'linux' || packageIsInstalled(packages, 'docker-sbx'));
  const sbxInstallDetail = !sbxPresent
    ? 'sbx was not found on PATH.'
    : !commandWorked(version)
      ? 'Docker Sandboxes could not be verified.'
      : platformName === 'linux' && !packageIsInstalled(packages, 'docker-sbx')
        ? 'sbx is present, but docker-sbx is not installed as an apt package; a copied binary skips required dependencies.'
        : 'Docker Sandboxes is installed.';
  const sbxInstallFix = platformName === 'darwin'
    ? 'brew trust docker/tap && brew install docker/tap/sbx'
    : platformName === 'win32'
      ? 'winget install -h Docker.sbx'
      : UBUNTU_INSTALL_FIX;

  const transferPluginFailure = hasDiagnostic(diagnostics, /io\.containerd\.transfer\.v1:\s*no plugins registered/i);
  const dockerRuntimeOk = platformName !== 'linux' || (
    packageIsInstalled(packages, 'docker-ce')
    && packageIsInstalled(packages, 'containerd.io')
    && commandWorked(dockerVersion)
    && containerdIsV2(containerdVersion)
    && !transferPluginFailure
  );
  const dockerRuntimeDetail = platformName !== 'linux'
    ? 'not checked on this platform (Docker Sandboxes manages the runtime outside Ubuntu apt).'
    : transferPluginFailure
      ? 'sbx reported io.containerd.transfer.v1: no plugins registered; this is the Ubuntu docker.io/containerd mismatch.'
      : !packageIsInstalled(packages, 'docker-ce') || !packageIsInstalled(packages, 'containerd.io')
        ? 'Docker CE and containerd.io must be installed from download.docker.com; Ubuntu docker.io is not sufficient.'
        : !commandWorked(dockerVersion) || !containerdIsV2(containerdVersion)
          ? 'Docker CE and containerd v2 could not be verified.'
          : 'Docker CE and containerd v2 are ready.';

  // `sbx diagnose` exits non-zero when a different check (for example Docker
  // login) fails. Its explicit daemon line is still authoritative for this
  // separate prerequisite, so do not misdiagnose a healthy daemon as broken.
  const daemonOk = hasDiagnostic(diagnostics, /daemon\b[^\n]{0,30}\bhealthy/i);
  const daemonDetail = daemonOk
    ? 'sbx diagnose reports Daemon healthy.'
    : 'The sandbox service is not running yet.';

  const policyMissing = hasDiagnostic(policyOutput, /global network policy has not been initialized/i);
  const policyOk = commandWorked(policy) && !policyMissing;
  const policyDetail = policyOk
    ? 'global network policy is initialized and readable.'
    : policyMissing
      ? 'global network policy has not been initialized.'
      : 'The sandbox network policy could not be verified.';

  const kvmDiagnosticFailure = hasDiagnostic(diagnostics, /KVM error:\s*Permission denied/i);
  const kvmOk = platformName !== 'linux' || (commandWorked(kvmReadable) && commandWorked(kvmWritable) && !kvmDiagnosticFailure);
  const kvmDetail = platformName !== 'linux'
    ? 'not applicable on this platform.'
    : kvmDiagnosticFailure
      ? 'sbx reported KVM error: Permission denied (os error 13).'
      : !commandWorked(kvmReadable) || !commandWorked(kvmWritable)
        ? '/dev/kvm is not readable and writable by this user.'
        : '/dev/kvm is readable and writable by this user.';

  const loginMissing = hasDiagnostic(diagnostics, /(?:user is not authenticated to Docker|you are not authenticated to Docker|not authenticated to Docker|authentication (?:failed|required)|authentication.*not signed in|not signed in|please (?:log in|sign in)|run sbx login)/i);
  const loginOk = commandWorked(diagnose) && !loginMissing;
  const loginDetail = loginOk
    ? 'sbx diagnose did not report a Docker authentication problem.'
    : loginMissing
      ? "The sandbox service isn't signed in to Docker yet."
      : 'Docker sign-in could not be verified.';

  return [
    check('sbx_install', sbxInstallOk, sbxInstallDetail, sbxInstallOk ? '' : sbxInstallFix, diagnosticsOf(version)),
    check('docker_runtime', dockerRuntimeOk, dockerRuntimeDetail, dockerRuntimeOk ? '' : UBUNTU_INSTALL_FIX, `${diagnosticsOf(packages)}\n${diagnosticsOf(dockerVersion)}\n${diagnosticsOf(containerdVersion)}\n${diagnoseDiagnostics}`.trim()),
    check('sbx_daemon', daemonOk, daemonDetail, daemonOk ? '' : 'sbx daemon stop && sbx daemon start --detach && sbx diagnose', diagnoseDiagnostics),
    check('network_policy', policyOk, policyDetail, policyOk ? '' : 'sbx policy init balanced (or run: waspflow federation doctor --fix-policy)', policyDiagnostics),
    check('kvm_access', kvmOk, kvmDetail, kvmOk ? '' : 'sudo usermod -aG kvm $USER && newgrp kvm (on a VM, also enable nested virtualization)', diagnoseDiagnostics),
    check('docker_login', loginOk, loginDetail, loginOk ? '' : 'sbx login', diagnoseDiagnostics),
    socketPathLengthCheck(activeSbxHome),
  ];
}

function windowsPreflightChecks({ version, diagnose, hypervisorPlatform }) {
  const diagnostics = outputOf(diagnose);
  const sbxInstallOk = commandWorked(version);
  const hypervisorEnabled = commandWorked(hypervisorPlatform) && /\benabled\b/i.test(outputOf(hypervisorPlatform));
  const loginMissing = hasDiagnostic(diagnostics, /(?:user is not authenticated to Docker|you are not authenticated to Docker|not authenticated to Docker|authentication (?:failed|required)|authentication.*not signed in|not signed in|please (?:log in|sign in)|run sbx login)/i);
  const loginOk = commandWorked(diagnose) && !loginMissing;

  return [
    check('sbx_install', sbxInstallOk,
      sbxInstallOk ? 'Docker Sandboxes is installed.' : 'Docker Sandboxes is not installed on this computer.',
      sbxInstallOk ? '' : 'Run the Federation installer\'s Repair action. If repair is unavailable, this device cannot contribute yet.', diagnosticsOf(version)),
    check('hypervisor_platform', hypervisorEnabled,
      hypervisorEnabled ? 'Windows Hypervisor Platform is enabled.' : 'Windows Hypervisor Platform is not enabled.',
      hypervisorEnabled ? '' : 'Reinstall or run the Federation installer\'s Repair action. Last resort for an administrator: Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart', diagnosticsOf(hypervisorPlatform)),
    check('docker_login', loginOk,
      loginOk ? 'Docker sign-in is ready.' : loginMissing
        ? "The sandbox service isn't signed in to Docker yet."
        : 'Docker sign-in could not be verified.',
      loginOk ? '' : 'Open Federation and select Sign in to Docker. If that action is unavailable, this device cannot contribute yet.', diagnosticsOf(diagnose)),
    check('windows_file_permissions', true,
      'Windows file permissions are managed by the Federation installer.',
      '', ''),
  ];
}

async function runPreflightCommand(command, args, { env = sbxChildEnv() } = {}) {
  try {
    const { stdout, stderr } = await execFile(command, args, { env, maxBuffer: 16 * 1024 * 1024 });
    return { code: 0, stdout, stderr };
  } catch (error) {
    return {
      code: typeof error?.code === 'number' ? error.code : 1,
      stdout: error?.stdout || '',
      stderr: error?.stderr || String(error?.message || error),
      errorCode: error?.code,
    };
  }
}

/**
 * Read-only install preflight for the exact `sbx` profile Federation uses.
 * The optional command runner makes every classification independently testable
 * without a live Docker installation.
 */
export async function probeSbxPreflight({ runCommand = runPreflightCommand, platformName = process.platform } = {}) {
  const run = (command, args) => runCommand(command, args, { env: sbxChildEnv() });
  const windows = platformName === 'win32';
  const version = await run(windows ? 'where' : sbxBin(), windows ? ['sbx'] : ['version']);
  const linux = platformName === 'linux';
  const sbxAvailable = commandWorked(version);
  const [packages, dockerVersion, containerdVersion, diagnose, policy, kvmReadable, kvmWritable, hypervisorPlatform] = await Promise.all([
    linux ? run('dpkg-query', ['-W', '-f=${binary:Package}\\t${db:Status-Status}\\t${Version}\\n', 'docker-sbx', 'docker-ce', 'containerd.io']) : Promise.resolve({ code: 0, stdout: '' }),
    linux ? run('docker', ['version', '--format', '{{.Server.Version}}']) : Promise.resolve({ code: 0, stdout: '' }),
    linux ? run('containerd', ['--version']) : Promise.resolve({ code: 0, stdout: '' }),
    sbxAvailable ? run(sbxBin(), ['diagnose']) : Promise.resolve({ code: 1, stderr: 'sbx is not installed' }),
    sbxAvailable && !windows ? run(sbxBin(), ['policy', 'ls']) : Promise.resolve({ code: 0, stdout: '' }),
    linux ? run('test', ['-r', '/dev/kvm']) : Promise.resolve({ code: 0, stdout: '' }),
    linux ? run('test', ['-w', '/dev/kvm']) : Promise.resolve({ code: 0, stdout: '' }),
    windows ? run('powershell.exe', ['-NoProfile', '-Command', '(Get-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform).State']) : Promise.resolve({ code: 0, stdout: '' }),
  ]);
  const checks = preflightChecks({ platformName, version, packages, dockerVersion, containerdVersion, diagnose, policy, kvmReadable, kvmWritable, hypervisorPlatform });
  return {
    schema_version: SBX_PREFLIGHT_SCHEMA_VERSION,
    backend_id: BACKEND_ID,
    ok: checks.every((entry) => entry.ok),
    checks,
    version: commandWorked(version) ? outputOf(version) : undefined,
  };
}

function namedCheck(preflight, name) {
  return preflight.checks.find((entry) => entry.name === name);
}

// A missing "Daemon healthy" line can also result from unrelated failures.
// Only start the daemon for the concrete stopped/unreachable shape; starting
// it cannot repair a broken install or a Docker login failure.
function daemonNeedsStart(check) {
  return !check?.ok && /(?:daemon.*(?:connection refused|not running|stopped|unavailable)|connection refused)/i.test(check.diagnostics || '');
}

function policyNeedsInitialization(check) {
  return !check?.ok && /global network policy has not been initialized/i.test(check.diagnostics || '');
}

/** Safe, profile-isolated repair for a stopped Federation sbx daemon. */
export async function startSbxDaemon({ runCommand = runPreflightCommand } = {}) {
  return runCommand(sbxBin(), ['daemon', 'start', '--detach'], { env: sbxChildEnv() });
}

/** Safe, profile-isolated default policy initialization. */
export async function initializeDefaultSbxPolicy({ runCommand = runPreflightCommand } = {}) {
  return runCommand(sbxBin(), ['policy', 'init', 'balanced'], { env: sbxChildEnv() });
}

/**
 * Makes the Waspflow-owned sbx identity ready for a contribution without
 * widening the user-facing setup surface. Every repair is followed by a
 * fresh probe, so unrelated installation, KVM, and login failures remain
 * explicit rather than being hidden behind a repair attempt.
 */
async function ensureSbxIdentity({ runCommand = runPreflightCommand, platformName = process.platform } = {}) {
  let preflight = await probeSbxPreflight({ runCommand, platformName });
  const repairs = [];

  const daemon = namedCheck(preflight, 'sbx_daemon');
  if (daemonNeedsStart(daemon)) {
    const result = await startSbxDaemon({ runCommand });
    repairs.push({ name: 'sbx_daemon', ok: result.code === 0, detail: result.code === 0 ? 'The sandbox service started.' : 'The sandbox service could not be started.', diagnostics: diagnosticsOf(result) });
    if (result.code === 0) preflight = await probeSbxPreflight({ runCommand, platformName });
  }

  const policy = namedCheck(preflight, 'network_policy');
  if (policyNeedsInitialization(policy)) {
    const result = await initializeDefaultSbxPolicy({ runCommand });
    repairs.push({ name: 'network_policy', ok: result.code === 0, detail: result.code === 0 ? 'The sandbox network policy was initialized.' : 'The sandbox network policy could not be initialized.', diagnostics: diagnosticsOf(result) });
    if (result.code === 0) preflight = await probeSbxPreflight({ runCommand, platformName });
  }

  return { preflight, repairs };
}

function isSafeRelativeOutputPath(candidate) {
  if (typeof candidate !== 'string' || candidate.length === 0) return false;
  if (candidate.startsWith('/') || candidate.includes('\0')) return false;
  const parts = candidate.split('/');
  return parts.every((part) => part !== '..' && part !== '.' && part.length > 0);
}

async function assertNotSymlink(fullPath) {
  let info;
  try {
    info = await lstat(fullPath);
  } catch (error) {
    if (error && error.code === 'ENOENT') return null;
    throw error;
  }
  if (info.isSymbolicLink()) throw new Error(`refusing to collect symlinked output: ${fullPath}`);
  return info;
}

export class DockerSbxBackend extends SandboxBackend {
  /** @returns {Promise<import('./federation-runtime.mjs').CapabilityReport>} */
  async probeCapabilities(options) {
    const { preflight, repairs } = await ensureSbxIdentity(options);
    const sbxCheck = preflight.checks.find((entry) => entry.name === 'sbx_install');
    if (!sbxCheck?.ok) {
      return {
        available: false,
        backend_id: BACKEND_ID,
        missing_prerequisites: [sbxCheck?.detail || 'sbx CLI (Docker Sandboxes) not found on PATH'],
        install_hint: INSTALL_HINT,
        preflight,
        identity_repairs: repairs,
      };
    }
    if (!preflight.ok) {
      return {
        available: false,
        backend_id: BACKEND_ID,
        missing_prerequisites: preflight.checks.filter((entry) => !entry.ok).map((entry) => `${entry.name}: ${entry.detail}`),
        install_hint: INSTALL_HINT,
        preflight,
        identity_repairs: repairs,
      };
    }
    return { available: true, backend_id: BACKEND_ID, version: preflight.version, preflight, identity_repairs: repairs };
  }

  /**
   * @param {object} validatedJob
   * @returns {Promise<import('./federation-runtime.mjs').SandboxHandle>}
   */
  async prepare(validatedJob) {
    const jobId = validatedJob.job_id;
    const sandboxId = sandboxNameFor(jobId);

    await mkdir(scratchRoot(), { recursive: true });
    const scratchDir = await mkdtemp(path.join(scratchRoot(), `wf-job-${sandboxId}-`));

    const handle = {
      backend_id: BACKEND_ID,
      job_id: jobId,
      sandbox_id: sandboxId,
      scratch_dir: scratchDir,
      _image: validatedJob.image,
      _entrypoint: validatedJob.entrypoint,
      _inputs: validatedJob.inputs,
    };

    // `sbx run [flags] AGENT PATH... [-- AGENT_ARGS...]` — the agent positional
    // comes BEFORE the workspace path (confirmed against a real sbx v0.35.0
    // install; see docs/design/FEDERATION_V0_UAT_REPORT.md "Owner UAT findings
    // and fixes"). `--detached` so prepare() only creates the sandbox; start()
    // separately drives the actual task via `sbx exec` — `sbx run --detached`
    // launches the image's OWN default session, it does not execute a task by
    // itself (also confirmed live: a bare `sbx run --detached -- <args>` left
    // the sandbox idle with no such process running).
    const runResult = await runSbx(['run', '--name', sandboxId, validatedJob.image, scratchDir, '--detached']);
    if (runResult.code !== 0) {
      throw new Error(`sbx run failed for sandbox ${sandboxId}: ${runResult.stderr || `exit ${runResult.code}`}`);
    }

    // `sbx run --detached` returns before the sandbox is actually exec-able
    // (image layer builds + microVM boot happen asynchronously — on slow or
    // nested-virtualized hosts that window is many seconds, and a failed boot
    // otherwise surfaces NOWHERE). Found live: the very next `sbx exec` (the
    // auth preflight) failed "no sandbox named <id>" against a sandbox whose
    // creation had just 'succeeded'. Wait for real readiness — a trivial
    // exec — before returning the handle, so every later exec (auth probe,
    // task entrypoint, output collection) can trust the sandbox is booted.
    const readyDeadline = Date.now() + (Number(process.env.WASPFLOW_FEDERATION_SANDBOX_READY_TIMEOUT_MS) || 180_000);
    for (;;) {
      const probe = await runSbx(['exec', sandboxId, '--', 'true']);
      if (probe.code === 0) break;
      if (Date.now() > readyDeadline) {
        throw new Error(`sandbox ${sandboxId} never became ready after sbx run (boot may have failed): ${probe.stderr || `exit ${probe.code}`}`);
      }
      await new Promise((resolve) => setTimeout(resolve, 2_000));
    }

    // Copy declared inputs into the sandbox's private storage via the
    // backend's copy mechanism — never assume the guest can see scratchDir
    // contents implicitly beyond what `sbx run`'s workspace mount provides.
    for (const input of validatedJob.inputs || []) {
      await this._copyIn(handle, input);
    }

    return handle;
  }

  /**
   * `sbx cp SRC DST`, one side a `SANDBOX:PATH` — confirmed against a real
   * sbx v0.35.0 install's `sbx cp --help`, matching the shape used below.
   * `sbx cp` REQUIRES an absolute guest path ("container path must be
   * absolute (use SANDBOX:/path)") — confirmed live. The guest's absolute
   * workspace directory mirrors the host-side scratch_dir path passed as
   * `sbx run`'s PATH argument (confirmed live: `sbx exec <sandbox> -- pwd`
   * inside a freshly-created sandbox returns the exact host scratch_dir
   * path) — so a declared relative dest is resolved against handle.scratch_dir.
   */
  async _copyIn(handle, input) {
    const localPath = path.join(handle.scratch_dir, '.wf-inputs', input.artifact_id.replace(/[^A-Za-z0-9_.-]/g, '_'));
    await mkdir(path.dirname(localPath), { recursive: true });
    // The artifact-fetch-by-id step (resolving artifact_id to bytes on disk)
    // belongs to the caller/CAS layer, not this backend; this backend only
    // moves already-materialized local bytes into the guest.
    const remoteDest = `${handle.sandbox_id}:${path.posix.join(handle.scratch_dir, input.dest)}`;
    const result = await runSbx(['cp', localPath, remoteDest]);
    if (result.code !== 0) {
      throw new Error(`sbx cp (input ${input.artifact_id} -> ${input.dest}) failed: ${result.stderr || `exit ${result.code}`}`);
    }
  }

  /** @param {import('./federation-runtime.mjs').SandboxHandle} handle */
  async start(handle) {
    // `sbx exec SANDBOX COMMAND [ARG...]` mirrors `docker exec` (confirmed
    // against a real sbx v0.35.0 install) — the correct way to drive a task in
    // an already-`--detached`-running sandbox; `prepare()` only creates the
    // sandbox, it does not run anything. `entrypoint` is a HarnessSpec-shaped
    // command STRING (e.g. 'codex exec --dangerously-bypass-approvals-and-
    // sandbox'), not a single guest binary name, so it must be split into
    // argv words the same way the harness-proof script's proven
    // `sbx exec "$sandbox" -- $entrypoint "$TASK_PROMPT"` pattern does
    // (deliberately unquoted there for word-splitting) — passed here through
    // `sh -c` so the guest shell performs that same splitting, keeping this
    // backend's own argv construction free of a second, potentially
    // divergent tokenizer. See docs/design/FEDERATION_V0_UAT_REPORT.md
    // "Autonomous fix loop" for the live reproduction of the entrypoint-
    // never-driven bug this replaces.
    const result = await runSbx(['exec', handle.sandbox_id, '--', 'sh', '-c', handle._entrypoint]);
    if (result.code !== 0) {
      throw new Error(`sbx exec failed to start entrypoint in sandbox ${handle.sandbox_id}: ${result.stderr || `exit ${result.code}`}`);
    }
    handle._lastExecStdout = result.stdout;
    handle._lastExecStderr = result.stderr;
  }

  /**
   * @param {import('./federation-runtime.mjs').SandboxHandle} handle
   * @returns {AsyncGenerator<{stream: 'stdout'|'stderr', line: string}>}
   */
  async *streamLogs(handle) {
    const stdoutLines = (handle._lastExecStdout || '').split('\n').filter((line) => line.length > 0);
    const stderrLines = (handle._lastExecStderr || '').split('\n').filter((line) => line.length > 0);
    for (const line of stdoutLines) yield { stream: 'stdout', line };
    for (const line of stderrLines) yield { stream: 'stderr', line };
  }

  /**
   * @param {import('./federation-runtime.mjs').SandboxHandle} handle
   * @param {string[]} manifest
   * @returns {Promise<{path: string, sha256: string, bytes: number}[]>}
   */
  async collectDeclaredOutputs(handle, manifest) {
    const collected = [];
    const outDir = path.join(handle.scratch_dir, '.wf-outputs');
    await mkdir(outDir, { recursive: true });

    for (const declaredPath of manifest || []) {
      if (!isSafeRelativeOutputPath(declaredPath)) {
        throw new Error(`refusing to collect unsafe output path: ${declaredPath}`);
      }

      const localDest = path.join(outDir, declaredPath);
      await mkdir(path.dirname(localDest), { recursive: true });

      // Reverse-direction `sbx cp` — confirmed shape, same as _copyIn above
      // (including the absolute-guest-path requirement, resolved against
      // the workspace directory the guest mirrors from handle.scratch_dir).
      const remoteSrc = `${handle.sandbox_id}:${path.posix.join(handle.scratch_dir, declaredPath)}`;
      const result = await runSbx(['cp', remoteSrc, localDest]);
      if (result.code !== 0) {
        throw new Error(`sbx cp (output ${declaredPath}) failed: ${result.stderr || `exit ${result.code}`}`);
      }

      const info = await assertNotSymlink(localDest);
      if (!info) throw new Error(`declared output not present after copy-out: ${declaredPath}`);
      if (!info.isFile()) throw new Error(`declared output is not a regular file: ${declaredPath}`);

      const bytes = await hashFile(localDest);
      collected.push({ path: declaredPath, sha256: bytes.sha256, bytes: bytes.size });
    }

    return collected;
  }

  /** @param {import('./federation-runtime.mjs').SandboxHandle} handle */
  async cancel(handle) {
    // `sbx stop` preserves sandbox state (vs. `sbx rm`, which deletes it) —
    // appropriate for cancel, since destroy() is the caller's separate,
    // explicit teardown step.
    const result = await runSbx(['stop', handle.sandbox_id]);
    if (result.code !== 0) {
      throw new Error(`sbx stop failed for sandbox ${handle.sandbox_id}: ${result.stderr || `exit ${result.code}`}`);
    }
  }

  /**
   * @param {import('./federation-runtime.mjs').SandboxHandle} handle
   * @returns {Promise<import('./federation-runtime.mjs').CleanupReceipt>}
   */
  async destroy(handle) {
    let removed = await this._removeAndVerify(handle.sandbox_id);
    if (!removed) removed = await this._removeAndVerify(handle.sandbox_id);

    let scratchRemoved = false;
    try {
      await rm(handle.scratch_dir, { recursive: true, force: true });
      await stat(handle.scratch_dir).then(
        () => { scratchRemoved = false; },
        (error) => { scratchRemoved = error && error.code === 'ENOENT'; },
      );
    } catch {
      scratchRemoved = false;
    }

    return {
      job_id: handle.job_id,
      sandbox_id: handle.sandbox_id,
      removed,
      scratch_removed: scratchRemoved,
      at: new Date().toISOString(),
    };
  }

  async _removeAndVerify(sandboxId) {
    // `--force` is required: bare `sbx rm` refuses non-interactively
    // ("stdin is not a terminal; use --force to skip confirmation") and
    // silently no-ops, leaking the sandbox (confirmed live — see
    // docs/design/FEDERATION_V0_UAT_REPORT.md "Autonomous fix loop").
    await runSbx(['rm', '--force', sandboxId]);
    // Do NOT trust `sbx rm`'s exit code alone — independently verify via
    // `sbx ls` that the sandbox is actually gone, per the decision note.
    const stillPresent = await this._sandboxExists(sandboxId);
    return !stillPresent;
  }

  async _sandboxExists(sandboxId) {
    const result = await runSbx(['ls']);
    if (result.code !== 0) {
      // If we can't even list, we cannot honestly claim removal is verified.
      return true;
    }
    return result.stdout.split('\n').some((line) => line.trim().startsWith(sandboxId));
  }

  /** @param {import('./federation-runtime.mjs').SandboxHandle} handle */
  async inspect(handle) {
    const result = await runSbx(['ls']);
    if (result.code !== 0) {
      return { job_id: handle.job_id, status: 'unknown' };
    }
    const line = result.stdout.split('\n').find((entry) => entry.trim().startsWith(handle.sandbox_id));
    if (!line) return { job_id: handle.job_id, status: 'destroyed' };

    const lowered = line.toLowerCase();
    let status = 'unknown';
    if (lowered.includes('running')) status = 'running';
    else if (lowered.includes('stopped') || lowered.includes('exited')) status = 'exited';
    else if (lowered.includes('pending') || lowered.includes('creating')) status = 'pending';

    return { job_id: handle.job_id, status };
  }
}

async function hashFile(filePath) {
  const buffer = await readFile(filePath);
  return { sha256: createHash('sha256').update(buffer).digest('hex'), size: buffer.length };
}

// Re-exported so tests can exercise directory-listing helpers without
// duplicating fs plumbing.
export const _internal = { isSafeRelativeOutputPath, sandboxNameFor, sbxHome, scratchRoot, preflightChecks, packageIsInstalled, containerdIsV2, daemonNeedsStart, policyNeedsInitialization, selectSbxHome, containerdSocketPathForSbxHome, socketPathLengthCheck };
