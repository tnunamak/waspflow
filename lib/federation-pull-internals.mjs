/**
 * Federation v0 executor-side ("pull") internals: everything bin/waspflow-
 * federation-pull needs that is worth unit-testing directly, kept out of the
 * bin script's CommonJS top level so tests can `import` these functions
 * without shelling out.
 *
 * Deliberately thin: HTTP calls to the coordinator, ValidatedJobSpec
 * construction, and the prepare->start->collect->destroy run sequence over
 * DockerSbxBackend. No claim/lease/signature logic lives here that isn't
 * already owned by lib/federation-coordinator.mjs or lib/federation-
 * envelope.mjs — this module is glue, not a second copy of either.
 */
import { createHash, randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { validateJobSpec } from './federation-runtime.mjs';
import { DockerSbxBackend } from './federation-docker-backend.mjs';
import {
  CODEX_HARNESS,
  CLAUDE_CODE_SUBSCRIPTION_HARNESS,
  CLAUDE_CODE_API_KEY_HARNESS,
  GH_CLI_HARNESS,
} from './federation-harnesses.mjs';

// image = the sbx built-in agent template name (federation-runtime.mjs's
// ValidatedJobSpec doc: "For DockerSbxBackend in v0 this is a built-in sbx
// agent template name"). HarnessSpec.install already carries exactly that
// value for every harness in lib/federation-harnesses.mjs.
const HARNESSES = {
  'claude-code-subscription': { spec: CLAUDE_CODE_SUBSCRIPTION_HARNESS, image: CLAUDE_CODE_SUBSCRIPTION_HARNESS.install },
  'claude-code-api-key': { spec: CLAUDE_CODE_API_KEY_HARNESS, image: CLAUDE_CODE_API_KEY_HARNESS.install },
  'codex': { spec: CODEX_HARNESS, image: CODEX_HARNESS.install },
  'gh-cli': { spec: GH_CLI_HARNESS, image: GH_CLI_HARNESS.install },
};

// federation-envelope.mjs's RFC3339 pattern is second-precision, no
// milliseconds (^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$) — `Date.toISOString()`
// includes milliseconds and would fail validatePayload/signEnvelope. Every
// timestamp this module writes into a signed payload must go through this.
export function rfc3339Now() {
  return new Date().toISOString().replace(/\.\d{3}Z$/, 'Z');
}

export function resolveHarness(name) {
  const entry = HARNESSES[name];
  if (!entry) throw new Error(`unknown --harness "${name}" — must be one of: ${Object.keys(HARNESSES).join(', ')}`);
  return { ...entry.spec, image: entry.image };
}

// --- coordinator HTTP client ------------------------------------------------

export async function claimTask({ coordinatorUrl, token, taskDigest, executorKey, leaseSeconds }) {
  const res = await fetch(`${coordinatorUrl}/tasks/${taskDigest}/claim`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ executor_key: executorKey, lease_seconds: leaseSeconds }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`claim failed: ${res.status} ${body.error || JSON.stringify(body)}`);
  return body;
}

export async function submitResult({ coordinatorUrl, token, taskDigest, envelope, claimGeneration, leaseToken }) {
  const res = await fetch(`${coordinatorUrl}/tasks/${taskDigest}/submit`, {
    method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: JSON.stringify({ envelope, claim_generation: claimGeneration, lease_token: leaseToken }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) return { status: 'rejected', http_status: res.status, error: body.error || JSON.stringify(body) };
  return body;
}

// Content-addressed fetch: verifies the downloaded bytes' sha256 matches the
// requested digest before returning them — an executor about to run
// untrusted code/prompts derived from these bytes must never trust "the
// coordinator said so" for artifact integrity either, same defense-in-depth
// posture as the task-envelope re-verification.
export async function fetchArtifact(coordinatorUrl, token, digest) {
  const res = await fetch(`${coordinatorUrl}/artifacts/${digest}`, {
    headers: { authorization: `Bearer ${token}` },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`GET /artifacts/${digest} failed: ${res.status} ${body}`);
  }
  const bytes = Buffer.from(await res.arrayBuffer());
  const actual = createHash('sha256').update(bytes).digest('hex');
  if (actual !== digest) throw new Error(`fetched artifact bytes do not hash to the requested digest (expected ${digest}, got ${actual}) — refusing to trust`);
  return bytes;
}

// --- ValidatedJobSpec construction ------------------------------------------

const DEFAULT_RESOURCES = Object.freeze({
  cpu: 2,
  memory_mib: 4096,
  storage_mib: 4096,
  wall_seconds: 1800,
  output_bytes: 50 * 1024 * 1024,
  network_bytes: 100 * 1024 * 1024,
  max_processes: 256,
});

/**
 * @param {object} params
 * @param {string} params.taskDigest              bare-hex task digest, used to derive job_id
 * @param {object} params.harness                 resolved harness (from resolveHarness), carries `.image`
 * @param {string} params.entrypointWithPrompt     harness entrypoint + shell-quoted task prompt, already assembled
 * @returns {object} a validated ValidatedJobSpec (validateJobSpec has already run)
 */
export function buildValidatedJobSpec({ taskDigest, harness, entrypointWithPrompt, resources = DEFAULT_RESOURCES }) {
  const spec = {
    job_id: `wf-pull-${taskDigest.slice(0, 16)}-${randomUUID().slice(0, 8)}`,
    image: harness.image,
    entrypoint: entrypointWithPrompt,
    resources: { ...resources },
    inputs: [],
    // v0 output-collection convention: the whole post-run workspace is
    // tarred INSIDE the guest by one extra `sbx exec` after start()
    // completes, then collected as a single declared output file
    // (result.tar.gz). This is documented explicitly in runJob() below and
    // in the final report so the requester-side CLI (slice 3) can extract
    // the same format on the other end.
    output_manifest: ['.wf-result/result.tar.gz'],
    egress_policy_id: 'wf-federation-v0-default',
    capability_token: `wf-pull-${randomUUID()}`,
  };
  return validateJobSpec(spec);
}

// --- run orchestration -------------------------------------------------------

/**
 * Drives probeCapabilities -> prepare -> (materialize source into the now-
 * known scratch dir) -> start -> (tar the workspace) -> collectDeclaredOutputs
 * -> destroy, always destroying even on failure.
 *
 * Workspace materialization (real gap found + routed around, not silently
 * papered over — see final report): ValidatedJobSpec.inputs / prepare()'s
 * own `_copyIn` loop is currently unusable by any real caller —
 * `_copyIn(handle, input)` assumes bytes already exist at
 * `handle.scratch_dir/.wf-inputs/<artifact_id>` BEFORE it runs, but
 * `handle.scratch_dir` is only created inside that SAME prepare() call via
 * mkdtemp, so no caller can win that race (confirmed by direct
 * reproduction: `sbx cp` fails with "no such file" against a fresh
 * mkdtemp'd path every time). Routed around here instead of patched in
 * federation-docker-backend.mjs (shared, already-tested code from an
 * earlier slice) by using the OTHER thing prepare() already proves: the
 * returned handle.scratch_dir IS the guest's mounted workspace (`sbx run
 * ... IMAGE scratchDir` — confirmed live: a file written to scratch_dir
 * after prepare() returns is visible in the guest before start() runs).
 * So this job spec always declares `inputs: []` (see
 * buildValidatedJobSpec) and the caller instead passes `materializeSource`,
 * called with the real scratch_dir once prepare() has returned it.
 *
 * Output-collection convention (v0, chosen for simplicity + testability over
 * per-file manifest naming): after start() runs the harness entrypoint to
 * completion, one more `sbx exec` tars the ENTIRE post-run workspace
 * directory into .wf-result/result.tar.gz inside the guest; that single file
 * is then the one declared output_manifest entry collectDeclaredOutputs
 * copies out. Reusing the whole-tree-as-one-artifact shape keeps the
 * candidate's `tree_digest` claim honest without a second hashing pass (see
 * bin/waspflow-federation-pull's result-envelope construction).
 *
 * @param {object} params
 * @param {object} params.jobSpec      a ValidatedJobSpec from buildValidatedJobSpec
 * @param {(scratchDir: string) => Promise<void>} [params.materializeSource]
 *   called with the REAL scratch_dir once known (after prepare() returns,
 *   before start() runs the entrypoint) to extract/write the task's source
 *   artifact into the guest's mounted workspace. Optional so unit tests that
 *   don't care about workspace contents can omit it.
 * @param {object} [params.backend]    inject a stub backend for tests
 */
export async function runJob({ jobSpec, materializeSource, backend = new DockerSbxBackend() }) {
  const capabilities = await backend.probeCapabilities();
  if (!capabilities.available) {
    throw new Error(`sandbox backend unavailable: ${(capabilities.missing_prerequisites || []).join('; ')} (${capabilities.install_hint || ''})`);
  }

  const handle = await backend.prepare(jobSpec);
  try {
    if (materializeSource) await materializeSource(handle.scratch_dir);
    await backend.start(handle);

    // Tar the whole post-run workspace inside the guest so a single declared
    // output captures "the resulting tree" without a per-file manifest.
    const tarCommand = 'mkdir -p .wf-result && tar czf .wf-result/result.tar.gz --exclude=.wf-result -C . .';
    await execViaBackend(backend, handle, tarCommand);

    const collected = await backend.collectDeclaredOutputs(handle, jobSpec.output_manifest);
    // Read collected output bytes back BEFORE destroy() — destroy() removes
    // handle.scratch_dir (which is where collectDeclaredOutputs just wrote
    // .wf-outputs/<declaredPath>), so any caller reading the file path
    // AFTER runJob returns would find it already gone.
    const collectedWithBytes = await Promise.all(collected.map(async (file) => ({
      ...file,
      bytes_content: await readFile(join(handle.scratch_dir, '.wf-outputs', file.path)),
    })));
    return { collected: collectedWithBytes, cleanupReceipt: await backend.destroy(handle) };
  } catch (error) {
    await backend.destroy(handle).catch(() => {});
    throw error;
  }
}

// DockerSbxBackend has no public "run an arbitrary extra command" method —
// start() is the only driver, and it's already been used for the harness
// entrypoint. Re-invoke the same `sbx exec SANDBOX -- sh -c CMD` shape
// start() uses, via the backend's own handle fields, rather than adding a
// new public backend method for a single internal need. If a second caller
// ever needs this, promote it to a real SandboxBackend method instead of
// duplicating the shape a third time.
async function execViaBackend(backend, handle, shellCommand) {
  const tempHandle = { ...handle, _entrypoint: shellCommand };
  await backend.start(tempHandle);
}
