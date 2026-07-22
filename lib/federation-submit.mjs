/**
 * Federation v0 requester-side client library: "Tim submits a task and
 * receives the result branch" (slice 3 of the full loop, 2026-07-20).
 *
 * This module holds every piece of `bin/waspflow-federation-submit` that
 * benefits from being unit-testable without a subprocess: building/signing
 * the task envelope, packaging local directories/text into artifacts,
 * talking to the coordinator's `/tasks` and `/artifacts` endpoints, polling
 * for settlement, and materializing the settled candidate artifact back to
 * disk. The bin/ wrapper stays a thin arg-parsing shell around these calls,
 * matching how bin/waspflow-federation-coordinator wraps
 * lib/federation-coordinator.mjs.
 *
 * CONTRACT DECISIONS (see also the coordinator's own top-of-file comment):
 *  - Artifact transport: the coordinator gained `PUT /artifacts/:digest`
 *    (content-addressed upload, digest-verified) and `GET /artifacts/:digest`
 *    (download), both gated by the same collective bearer token as every
 *    other endpoint. One service, not a second file server. See
 *    lib/federation-coordinator.mjs's updated top comment. CONFIRMED
 *    compatible with the executor slice (bin/waspflow-federation-pull /
 *    lib/federation-pull-internals.mjs), which was independently built
 *    against this exact same endpoint shape (found already present in this
 *    working tree while building this slice — see final report).
 *  - media_type for the packaged source bundle: "application/x-tar" — NOT
 *    a custom vnd.waspflow string. This was corrected after discovering the
 *    executor slice's materializeSourceArtifact() decides whether to
 *    extract-as-tar via `/tar/.test(media_type)`; a custom
 *    "application/vnd.waspflow.source-bundle.v1" string does not match
 *    that regex and would silently make the executor treat a real tar as
 *    an opaque single file. Always an uncompressed tar (via `git archive
 *    HEAD` when --source is a git repo, otherwise a plain `tar` of the
 *    directory tree) — never gzipped, so isGzip's `/gzip|gz/` check on the
 *    executor side correctly stays false for this media type.
 *  - media_type for the prompt artifact: "text/markdown" (a plain UTF-8
 *    text blob; --prompt/--prompt-file content is used verbatim, no
 *    templating). Not load-bearing on the executor side (it just does
 *    `promptBytes.toString('utf8')` regardless of media_type), so this
 *    stays descriptive rather than matching their test fixtures' generic
 *    "text/plain".
 *  - media_type for the candidate result artifact this script downloads
 *    and extracts: "application/gzip" is what the executor slice actually
 *    produces (a gzip-compressed tar of the full resulting working tree,
 *    written by `tar czf`, NOT a git patch/diff). This module's own
 *    CANDIDATE_MEDIA_TYPE constant documents that expectation but does NOT
 *    gate extraction on it — materializeCandidate() always runs `tar -xf`,
 *    which auto-detects gzip vs. plain tar, so it transparently handles
 *    both the executor's actual gzip output and a hypothetical future
 *    plain-tar producer without a media_type branch of its own.
 */
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { jcs, sha256, signEnvelope, validatePayload, verifyEnvelope, parseCanonicalJson, EnvelopeError } from './federation-envelope.mjs';

const execFileAsync = promisify(execFile);

export class SubmitError extends Error {
  constructor(message) { super(message); this.name = 'SubmitError'; }
}
const fail = (message) => { throw new SubmitError(message); };

export const SOURCE_MEDIA_TYPE = 'application/x-tar';
export const PROMPT_MEDIA_TYPE = 'text/markdown';
// Documents what the executor slice (bin/waspflow-federation-pull) actually
// sends for candidate.artifact.media_type. Not read/branched-on by this
// module — see the module doc comment above.
export const CANDIDATE_MEDIA_TYPE = 'application/gzip';

// --- artifact packaging ----------------------------------------------------

function digestOf(buffer) {
  return { sha256: createHash('sha256').update(buffer).digest('hex'), bytes: buffer.length };
}

async function isGitRepo(dir) {
  try {
    const { stdout } = await execFileAsync('git', ['-C', dir, 'rev-parse', '--is-inside-work-tree'], { maxBuffer: 1024 * 1024 });
    return stdout.trim() === 'true';
  } catch {
    return false;
  }
}

// Packages a local directory as the base_artifact tar. Prefers `git archive
// HEAD` when `dir` is a git repo — it naturally excludes .git/ and
// gitignored/untracked cruft and produces a reproducible tree without a
// manual exclude list. Falls back to a plain `tar` of the directory
// (excluding .git if present) when it isn't a git repo, or when HEAD has no
// commits yet (a fresh repo).
export async function packageSourceDirectory(dir) {
  const dirStat = await stat(dir).catch(() => null);
  if (!dirStat || !dirStat.isDirectory()) fail(`--source is not a directory: ${dir}`);

  if (await isGitRepo(dir)) {
    try {
      const { stdout } = await execFileAsync('git', ['-C', dir, 'archive', '--format=tar', 'HEAD'], { maxBuffer: 1024 * 1024 * 1024, encoding: 'buffer' });
      return { buffer: stdout, ...digestOf(stdout), media_type: SOURCE_MEDIA_TYPE, method: 'git-archive' };
    } catch (error) {
      // HEAD may not exist yet (no commits) — fall through to plain tar
      // rather than failing the whole submission over an empty repo.
      if (!/unknown revision|ambiguous argument|fatal: bad revision/i.test(String(error.stderr || error.message))) throw error;
    }
  }

  const { stdout } = await execFileAsync('tar', ['-cf', '-', '--exclude=.git', '-C', dir, '.'], { maxBuffer: 1024 * 1024 * 1024, encoding: 'buffer' });
  return { buffer: stdout, ...digestOf(stdout), media_type: SOURCE_MEDIA_TYPE, method: 'tar' };
}

export function packagePromptText(text) {
  if (typeof text !== 'string' || !text.trim()) fail('prompt text is empty');
  const buffer = Buffer.from(text, 'utf8');
  return { buffer, ...digestOf(buffer), media_type: PROMPT_MEDIA_TYPE };
}

// --- task payload / envelope -----------------------------------------------

export function buildTaskPayload({ collective, displayId, authorKeyId, source, prompt, gitSource, network = 'disabled', createdAt = new Date(), expiresInSeconds = 3600 }) {
  if (!['enabled', 'disabled'].includes(network)) fail('network must be "enabled" or "disabled"');
  const created = new Date(createdAt);
  const expires = new Date(created.getTime() + Math.max(1, Math.floor(expiresInSeconds)) * 1000);
  const iso = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');
  const payload = {
    schema: 'waspflow.federation.task.v0',
    collective,
    display_id: displayId,
    author_key: authorKeyId,
    created_at: iso(created),
    expires_at: iso(expires),
    source: { base_artifact: { sha256: source.sha256, bytes: source.bytes, media_type: source.media_type } },
    ...(gitSource ? { git_source: {
      url: gitSource.url,
      ...(gitSource.ref ? { ref: gitSource.ref } : {}),
      ...(gitSource.authenticationRequired ? { authentication_required: true } : {}),
    } } : {}),
    prompt: { artifact: { sha256: prompt.sha256, bytes: prompt.bytes, media_type: prompt.media_type } },
    // Cloning a repository is the one task-source operation that needs
    // network access before task code starts. Enforce this at the shared
    // envelope builder so CLI, daemon, and future callers cannot diverge.
    network: gitSource ? 'enabled' : network,
    oracle_ref: null,
    result_verdict: null,
    settlement: null,
  };
  validatePayload(payload); // fail fast with the same schema the coordinator will enforce
  return payload;
}

export function signTaskEnvelope(payload, privateKeyPem, keyId) {
  return signEnvelope(payload, privateKeyPem, keyId);
}

// --- coordinator HTTP client ------------------------------------------------

function authHeaders(token, extra = {}) {
  return { authorization: `Bearer ${token}`, ...extra };
}

async function readJsonOrFail(response, context) {
  let body;
  const text = await response.text();
  try { body = JSON.parse(text); } catch { body = { error: text.slice(0, 500) }; }
  if (!response.ok) fail(`${context} failed (HTTP ${response.status}): ${body.error || text.slice(0, 500)}`);
  return body;
}

// Uploads a single artifact's bytes if the coordinator does not already have
// them. Always attempts the PUT (the coordinator's PUT handler is itself
// idempotent for identical bytes), keeping this function simple rather than
// adding a HEAD-first optimization v0 doesn't need.
export async function uploadArtifact(coordinatorUrl, token, artifact) {
  const response = await fetch(`${coordinatorUrl}/artifacts/${artifact.sha256}`, {
    method: 'PUT',
    headers: authHeaders(token),
    body: artifact.buffer,
  });
  return readJsonOrFail(response, `uploading artifact ${artifact.sha256}`);
}

export async function downloadArtifact(coordinatorUrl, token, digest) {
  const response = await fetch(`${coordinatorUrl}/artifacts/${digest}`, {
    headers: token ? authHeaders(token) : {},
  });
  if (!response.ok) fail(`downloading artifact ${digest} failed (HTTP ${response.status})`);
  const buffer = Buffer.from(await response.arrayBuffer());
  const actual = createHash('sha256').update(buffer).digest('hex');
  if (actual !== digest) fail(`downloaded artifact ${digest} does not match its digest (got ${actual}) — refusing to trust it`);
  return buffer;
}

export async function publishTask(coordinatorUrl, token, envelope) {
  const response = await fetch(`${coordinatorUrl}/tasks`, {
    method: 'POST',
    headers: authHeaders(token, { 'content-type': 'application/json' }),
    body: jcs(envelope), // MUST be RFC 8785 canonical JSON — the coordinator rejects plain JSON.stringify output
  });
  return readJsonOrFail(response, 'publishing task');
}

export async function getTaskStatus(coordinatorUrl, digest) {
  const response = await fetch(`${coordinatorUrl}/tasks/${digest}`);
  return readJsonOrFail(response, `fetching task status for ${digest}`);
}

// --- polling -----------------------------------------------------------

/**
 * Polls GET /tasks/:digest until status === 'SETTLED', or throws SubmitError
 * on timeout or an unreachable coordinator. `onTick` (optional) is called
 * with each poll's status body, useful for CLI progress printing.
 */
export async function pollUntilSettled(coordinatorUrl, digest, { intervalMs = 5000, timeoutMs = 3600_000, onTick, now = Date.now, sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)) } = {}) {
  const deadline = now() + timeoutMs;
  for (;;) {
    let status;
    try {
      status = await getTaskStatus(coordinatorUrl, digest);
    } catch (error) {
      fail(`polling failed: ${error.message}`);
    }
    if (onTick) onTick(status);
    if (status.status === 'SETTLED') return status;
    if (now() >= deadline) fail(`timed out after ${timeoutMs}ms waiting for task ${digest} to settle (last status: ${status.status})`);
    await sleep(intervalMs);
  }
}

// --- result materialization -----------------------------------------------

/**
 * Given a SETTLED task status body (from pollUntilSettled/getTaskStatus),
 * downloads and verifies the candidate artifact and extracts it as a tar of
 * the resulting working tree into `outputDir` (see CANDIDATE_MEDIA_TYPE
 * above for why tar-of-tree, not a patch). Returns the candidate artifact's
 * digest/bytes for the caller to print/verify against.
 */
export async function materializeCandidate(coordinatorUrl, token, status, outputDir, { roster } = {}) {
  if (status.status !== 'SETTLED' || !status.result_envelope) fail('task is not settled; nothing to materialize');
  let resultVerification;
  try {
    resultVerification = validatePayload(status.result_envelope.payload);
  } catch (error) {
    fail(error instanceof EnvelopeError ? `result envelope failed schema validation: ${error.message}` : String(error));
  }
  if (resultVerification !== 'result') fail('settled envelope is not a result payload');

  // Independent signature re-verification (defense in depth — mirrors the
  // executor slice's own re-verification of the TASK envelope). The
  // coordinator already checked this at submit time, but this requester is
  // about to extract executor-produced bytes onto local disk; it should not
  // simply trust "the coordinator said so" any more than the executor
  // trusts an unverified task. `roster` is optional so existing callers
  // (and tests) that only need schema validation keep working, but every
  // real bin/waspflow-federation-submit invocation supplies one.
  if (roster) {
    const signerKeyId = status.result_envelope.signature && status.result_envelope.signature.key_id;
    const signerPem = signerKeyId && roster[signerKeyId];
    if (!signerPem) fail(`settled result_envelope's signer key_id "${signerKeyId}" is not in the roster — refusing to trust unverifiable executor output`);
    try {
      verifyEnvelope(status.result_envelope, signerPem);
    } catch (error) {
      fail(error instanceof EnvelopeError ? `result envelope signature verification failed: ${error.message}` : String(error));
    }
  }

  const candidate = status.result_envelope.payload.candidate.artifact;
  const buffer = await downloadArtifact(coordinatorUrl, token, candidate.sha256);
  if (buffer.length !== candidate.bytes) fail(`downloaded candidate artifact size mismatch: expected ${candidate.bytes} bytes, got ${buffer.length}`);

  await execFileAsync('mkdir', ['-p', outputDir]);
  const tmpTar = join(await mkdtemp(join(tmpdir(), 'wf-federation-candidate-')), 'candidate.tar');
  await writeFile(tmpTar, buffer);
  try {
    await execFileAsync('tar', ['-xf', tmpTar, '-C', outputDir]);
  } finally {
    await rm(tmpTar, { force: true }).catch(() => {});
  }
  return { sha256: candidate.sha256, bytes: candidate.bytes, media_type: candidate.media_type };
}

// Exported for tests that want to read a canonical envelope file directly
// (mirrors parseCanonicalJson's role in federation-envelope.mjs).
export async function readEnvelopeFile(path) {
  return parseCanonicalJson(await readFile(path, 'utf8'));
}

export { verifyEnvelope };
