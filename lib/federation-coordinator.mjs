/**
 * Federation v0 coordinator: an owner-hosted HTTP service that lets an
 * author publish a signed task envelope, an executor claim and submit
 * against it, and a requester poll for the settled result.
 *
 * Scope discipline (read before extending):
 *  - This module knows the claim/lease/generation STATE MACHINE SHAPE from
 *    docs/design/FEDERATION_DESIGN_V2.md B.5.2, and nothing else from B.5.
 *    No escrow, balances, ledger, fees, disputes, or redundant execution.
 *    `settlement` and friends stay hard-null through federation-envelope's
 *    own validation — this module never reads or writes them.
 *  - "Collective membership" here is a single shared bearer token (env
 *    WASPFLOW_FEDERATION_COLLECTIVE_TOKEN), not the aspirational "public
 *    keys, revocation" membership model. The token answers "are you in the
 *    collective at all"; the ed25519 envelope signature (verified via
 *    lib/federation-envelope.mjs, against the specific key the roster says
 *    owns the envelope's claimed `key_id`) answers "which specific
 *    author/executor key signed this specific payload". They are
 *    deliberately independent checks — a valid token with a bad signature
 *    is still rejected, and vice versa.
 *  - Roster, not a single shared key: the coordinator's real scenario has
 *    an author (Tim) and an executor (Ocean) signing with genuinely
 *    different ed25519 keypairs, so `deps.roster` maps `key_id ->
 *    publicKeyPem` for every registered collective member. A flat, single
 *    roster (not separate author-roster/executor-roster maps) is the
 *    deliberate v0 choice: the initial use case has Tim always authoring
 *    and Ocean always executing, but nothing in the trust model actually
 *    requires that split — a friends-and-family collective member who
 *    sometimes authors and sometimes executes is the common case as the
 *    roster grows past two people, and a role-split roster would force an
 *    operator to duplicate an entry (or add role-change ceremony) the
 *    moment that happens. Any registered key_id may sign either a task or
 *    a result; the bearer token remains the actual "is this participant
 *    allowed to talk to the coordinator at all" gate, and the envelope
 *    schema/domain-separation (task vs result signing domains in
 *    federation-envelope.mjs) already stops a task signature from being
 *    replayed as a result signature or vice versa. Revisit only if a real
 *    incident shows author-only or executor-only keys are needed.
 *  - Artifact bytes: out of scope for the claim/lease/settlement state
 *    machine above, but slice 3 (full loop, 2026-07-20) added a minimal
 *    content-addressed blob store (`PUT`/`GET /artifacts/:digest`) so a
 *    requester and executor on different machines can actually exchange
 *    source/prompt/candidate bytes through the one service Tim hosts,
 *    instead of standing up a second file server. This deliberately stays
 *    dumb: no multipart, no streaming resume, no per-artifact ACLs beyond
 *    the same collective bearer token every other endpoint already
 *    requires. Content-addressing (the URL digest must equal the uploaded
 *    bytes' sha256) makes corruption/mismatch a hard 400 at upload time,
 *    not silent bad data discovered later by an executor.
 */
import { createHash, randomUUID } from 'node:crypto';
import { mkdir, readFile, readdir, rename, writeFile, unlink } from 'node:fs/promises';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { verifyEnvelope, parseCanonicalEnvelope, EnvelopeError, LIMITS } from './federation-envelope.mjs';

export class CoordinatorError extends Error {
  constructor(message, status = 400) { super(message); this.name = 'CoordinatorError'; this.status = status; }
}
const fail = (message, status = 400) => { throw new CoordinatorError(message, status); };

const DIGEST = /^[0-9a-f]{64}$/;

// Looks up the envelope's claimed signer in the roster BEFORE verification:
// verifyEnvelope needs one concrete PEM to check the signature against, and
// an unregistered key_id has none to offer. This also means we never try
// "does it match any roster key" — only the specific key_id the envelope
// itself claims, so a valid signature from key A can never be accepted as
// if it were key B's.
function resolveSigner(envelope, roster) {
  const keyId = envelope && envelope.signature && envelope.signature.key_id;
  if (typeof keyId !== 'string' || !keyId || !roster.has(keyId)) {
    fail(`unknown signer key_id: ${keyId} — not a registered collective member`, 401);
  }
  return roster.get(keyId);
}

// --- storage -----------------------------------------------------------
//
// One JSON file per task, named by its payload digest, under `dataDir`.
// Writes go to a same-directory ".tmp" sibling then get renamed into place,
// matching the mktemp+rename atomic-write pattern used elsewhere in this
// repo's bash libs (lib/core.sh) — a crash or concurrent read never
// observes a partially-written task file.
function taskPath(dataDir, digest) { return join(dataDir, `${digest}.json`); }

// Content-addressed artifact blobs live in their own sibling directory (not
// mixed in with the per-task JSON files) so a `readdir(dataDir)` for tasks
// never has to filter blob entries out, and so the two stores could be
// pointed at different disks later without a migration.
function artifactsDir(dataDir) { return join(dataDir, 'artifacts'); }
function artifactPath(dataDir, digest) { return join(artifactsDir(dataDir), digest); }

async function loadTask(dataDir, digest) {
  if (!DIGEST.test(digest)) return null;
  try {
    return JSON.parse(await readFile(taskPath(dataDir, digest), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

async function saveTask(dataDir, digest, record) {
  const target = taskPath(dataDir, digest);
  const tmp = join(dataDir, `.${digest}.${randomUUID()}.tmp`);
  await writeFile(tmp, JSON.stringify(record));
  await rename(tmp, target);
}

// --- lease/generation state machine ------------------------------------
//
// PUBLISHED -> QUEUED -> CLAIMED(generation, executor, lease_expiry)
//   -> SUBMITTED -> EVALUATING -> SETTLED
//   CLAIMED -> EXPIRED -> QUEUED(generation + 1)      [lease timeout]
//
// v0 does not implement ABANDONED (no explicit executor give-up endpoint)
// or CANCELLED (no publish-time author cancel endpoint) — neither was asked
// for in this slice's endpoint list, and adding them would be scope creep
// beyond "publish / claim / submit / get". EXPIRED->QUEUED is the only
// requeue path v0 supports, and it happens lazily (see below), not off a
// timer.
//
// Lazy expiry: there is no background sweep. A CLAIMED task whose lease has
// passed is only discovered and rolled forward to QUEUED (bumping
// claim_generation) the next time it is read via GET or a claim attempt.
// This is a deliberate v0 simplification — correct because every access
// path funnels through `settleExpiry`, not an oversight. A production
// coordinator serving many idle tasks would likely still want a periodic
// sweep so stale claims free up promptly even without a reader, but v0 has
// no worker/timer infrastructure to hang that off of.
function settleExpiry(record, now) {
  if (record.status === 'CLAIMED' && record.lease_expiry !== null && record.lease_expiry <= now) {
    record.status = 'QUEUED';
    record.claim_generation += 1;
    record.executor_key = null;
    record.lease_token = null;
    record.lease_expiry = null;
  }
  return record;
}

function publicView(record) {
  return {
    task_digest: record.task_digest,
    status: record.status,
    claim_generation: record.claim_generation,
    executor_key: record.executor_key,
    result_envelope: record.status === 'SETTLED' ? record.result_envelope : null,
  };
}

// --- request handling ----------------------------------------------------

async function readBody(request, maxBytes) {
  const chunks = [];
  let total = 0;
  for await (const chunk of request) {
    total += chunk.length;
    if (total > maxBytes) fail('request body exceeds byte limit', 413);
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

function requireToken(request, token) {
  const header = request.headers.authorization || '';
  const match = /^Bearer (.+)$/.exec(header);
  if (!match || match[1] !== token) fail('missing or invalid collective bearer token', 401);
}

async function handlePublish({ request, respond, body, deps }) {
  requireToken(request, deps.token);
  let envelope;
  try {
    envelope = parseCanonicalEnvelope(body);
  } catch (error) {
    fail(error instanceof EnvelopeError ? error.message : 'invalid task envelope', 400);
  }
  const signerKey = resolveSigner(envelope, deps.roster);
  let verification;
  try {
    verification = verifyEnvelope(envelope, signerKey);
  } catch (error) {
    fail(error instanceof EnvelopeError ? error.message : 'envelope verification failed', 400);
  }
  if (verification.kind !== 'task') fail('envelope is not a task payload', 400);

  const digest = verification.digest;
  const existing = await loadTask(deps.dataDir, digest);
  if (existing) {
    // Publishing the same task envelope twice is idempotent (same digest,
    // same signature) rather than an error — the caller likely retried.
    return respond(200, { task_digest: digest, address: verification.address, status: existing.status.toLowerCase() });
  }

  const record = {
    task_digest: digest,
    task_envelope: envelope,
    status: 'QUEUED', // v0 has no separate publish-review step: PUBLISHED -> QUEUED happens in this same request.
    claim_generation: 0,
    executor_key: null,
    lease_token: null,
    lease_expiry: null,
    result_envelope: null,
    published_at: new Date().toISOString(),
  };
  await saveTask(deps.dataDir, digest, record);
  respond(200, { task_digest: digest, address: verification.address, status: 'queued' });
}

async function handleClaim({ request, respond, body, deps, digest }) {
  requireToken(request, deps.token);
  if (!DIGEST.test(digest)) fail('malformed task digest', 400);

  let payload;
  try { payload = JSON.parse(body.toString('utf8')); } catch { fail('claim body must be JSON', 400); }
  if (typeof payload.executor_key !== 'string' || !payload.executor_key) fail('executor_key is required', 400);
  if (!Number.isFinite(payload.lease_seconds) || payload.lease_seconds <= 0) fail('lease_seconds must be a positive number', 400);

  let record = await loadTask(deps.dataDir, digest);
  if (!record) fail('unknown task', 404);
  const now = Date.now();
  record = settleExpiry(record, now);
  if (record.status !== 'QUEUED') fail(`task is not claimable (status: ${record.status})`, 409);

  record.status = 'CLAIMED';
  record.claim_generation += 1;
  record.executor_key = payload.executor_key;
  // v0 stores the plaintext lease token, not a digest of it. The design
  // doc's "store only its digest" guidance is written for a stranger-facing
  // marketplace where the coordinator operator is a threat to defend
  // against. v0's collective is friends-and-family behind one shared bearer
  // token already, so the coordinator operator (Tim, hosting this himself)
  // is already fully trusted with task/result contents; hashing the lease
  // token would add code without adding real defense against anyone who
  // matters in this threat model. Revisit if/when v0 grows into a
  // multi-operator or stranger-facing coordinator.
  record.lease_token = randomUUID();
  record.lease_expiry = now + Math.floor(payload.lease_seconds * 1000);
  await saveTask(deps.dataDir, digest, record);

  respond(200, {
    task_digest: digest,
    claim_generation: record.claim_generation,
    lease_token: record.lease_token,
    lease_expiry: record.lease_expiry,
    task_envelope: record.task_envelope,
  });
}

async function handleSubmit({ request, respond, body, deps, digest }) {
  requireToken(request, deps.token);
  if (!DIGEST.test(digest)) fail('malformed task digest', 400);

  let payload;
  try { payload = JSON.parse(body.toString('utf8')); } catch { fail('submit body must be JSON', 400); }
  if (!payload || typeof payload !== 'object') fail('submit body must be an object', 400);
  const { envelope, claim_generation: claimGeneration, lease_token: leaseToken } = payload;
  if (!Number.isSafeInteger(claimGeneration)) fail('claim_generation is required', 400);
  if (typeof leaseToken !== 'string' || !leaseToken) fail('lease_token is required', 400);
  if (!envelope || typeof envelope !== 'object') fail('envelope is required', 400);

  let record = await loadTask(deps.dataDir, digest);
  if (!record) fail('unknown task', 404);
  const now = Date.now();
  record = settleExpiry(record, now);

  if (record.status !== 'CLAIMED') fail(`task is not awaiting submission (status: ${record.status})`, 409);
  if (record.claim_generation !== claimGeneration) fail('stale claim_generation', 409);
  if (record.lease_expiry === null || record.lease_expiry <= now) fail('lease has expired', 409);
  if (record.lease_token !== leaseToken) fail('lease_token does not match', 403);

  const signerKey = resolveSigner(envelope, deps.roster);
  let verification;
  try {
    verification = verifyEnvelope(envelope, signerKey, { allowExpired: true });
  } catch (error) {
    fail(error instanceof EnvelopeError ? error.message : 'envelope verification failed', 400);
  }
  if (verification.kind !== 'result') fail('envelope is not a result payload', 400);
  if (envelope.payload.task_digest !== `sha256:${digest}`) fail('result task_digest does not match this task', 400);

  // v0 has no separate evaluation step: SUBMITTED -> EVALUATING -> SETTLED
  // all happen synchronously in this same request, since settlement/escrow
  // logic is explicitly deferred. "SETTLED" here only means "a validly
  // signed, correctly-bound result has been recorded" — it carries no
  // economic effect and no pass/fail verdict (result_verdict stays null,
  // enforced by federation-envelope's schema validation).
  record.status = 'SETTLED';
  record.result_envelope = envelope;
  record.settled_at = new Date().toISOString();
  await saveTask(deps.dataDir, digest, record);

  respond(200, { task_digest: digest, status: 'settled', result_address: verification.address });
}

// Deliberately unauthenticated, unlike every other endpoint: a requester
// polling for a settled result needs a simple, shareable status URL, and
// the digest itself (an unguessable 64-hex-char sha256, never enumerable)
// is already the access-control token here — matching the same reasoning
// GET /artifacts/:digest below relies on. Anyone who has the digest already
// received it from a collective member who signed/claimed it; this is not
// a wider disclosure than the collective already has.
async function handleGet({ respond, deps, digest }) {
  if (!DIGEST.test(digest)) fail('malformed task digest', 400);
  let record = await loadTask(deps.dataDir, digest);
  if (!record) fail('unknown task', 404);
  record = settleExpiry(record, Date.now());
  await saveTask(deps.dataDir, digest, record);
  respond(200, publicView(record));
}

// GET /tasks/next — "give me a claimable task", for the guided contributor
// flow (waspflow federation contribute) so a non-technical executor never
// has to be told a digest out-of-band. Authenticated (unlike GET
// /tasks/:digest): this is a discovery surface across ALL tasks, not a
// single unguessable-digest-gated lookup, so it needs the same collective
// bearer-token gate as claim/submit/publish. Deliberately dumb for v0: a
// linear scan of every on-disk task record, oldest-published-first, for
// the first one that's actually claimable right now (QUEUED, or CLAIMED
// with an expired lease — resolved the same lazy way every other read
// path resolves expiry). No queue index, no pagination, no filtering by
// resource requirements or harness compatibility — a real collective
// beyond a handful of concurrent tasks would need those; v0's collective
// is friends-and-family scale, where "read every file in the data dir"
// is a fine answer, not a fine answer forever.
async function handleNext({ request, respond, deps }) {
  requireToken(request, deps.token);
  let entries;
  try {
    entries = await readdir(deps.dataDir, { withFileTypes: true });
  } catch (error) {
    if (error.code === 'ENOENT') return respond(200, { task_digest: null });
    throw error;
  }
  const digests = entries
    .filter((entry) => entry.isFile() && entry.name.endsWith('.json') && DIGEST.test(entry.name.slice(0, -'.json'.length)))
    .map((entry) => entry.name.slice(0, -'.json'.length));

  const now = Date.now();
  const candidates = [];
  for (const digest of digests) {
    let record = await loadTask(deps.dataDir, digest);
    if (!record) continue;
    const before = record.status;
    record = settleExpiry(record, now);
    if (record.status !== before) await saveTask(deps.dataDir, digest, record);
    if (record.status === 'QUEUED') candidates.push(record);
  }
  if (candidates.length === 0) return respond(200, { task_digest: null });
  candidates.sort((a, b) => (a.published_at < b.published_at ? -1 : a.published_at > b.published_at ? 1 : 0));
  respond(200, { task_digest: candidates[0].task_digest });
}

// --- artifact blob store -------------------------------------------------
//
// PUT/GET /artifacts/:digest. Gated by the same bearer token as every other
// endpoint (no separate artifact-token concept in v0). Bytes are capped at
// federation-envelope's LIMITS.artifactBytes so this can't be used to fill
// the operator's disk with something the envelope schema would never have
// admitted a digest for anyway.
async function handlePutArtifact({ request, respond, deps, digest }) {
  requireToken(request, deps.token);
  if (!DIGEST.test(digest)) fail('malformed artifact digest', 400);

  const dir = artifactsDir(deps.dataDir);
  await mkdir(dir, { recursive: true });
  const target = artifactPath(deps.dataDir, digest);

  // Same digest, same bytes: uploading an already-stored artifact again is
  // idempotent, matching handlePublish's idempotent-republish behavior.
  try {
    const existing = await readFile(target);
    if (createHash('sha256').update(existing).digest('hex') === digest) {
      return respond(200, { digest, bytes: existing.length, status: 'stored' });
    }
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }

  const body = await readBody(request, LIMITS.artifactBytes);
  const actual = createHash('sha256').update(body).digest('hex');
  if (actual !== digest) fail(`uploaded bytes do not hash to the URL digest (got ${actual})`, 400);

  const tmp = join(dir, `.${digest}.${randomUUID()}.tmp`);
  await writeFile(tmp, body);
  await rename(tmp, target);
  respond(200, { digest, bytes: body.length, status: 'stored' });
}

// Deliberately unauthenticated, matching GET /tasks/:digest above: the
// sha256 digest itself is the access-control token, and executors need a
// simple fetch-by-digest URL to materialize task artifacts. See handleGet's
// comment for the full reasoning.
async function handleGetArtifact({ respond, response, deps, digest }) {
  if (!DIGEST.test(digest)) fail('malformed artifact digest', 400);
  let body;
  try {
    body = await readFile(artifactPath(deps.dataDir, digest));
  } catch (error) {
    if (error.code === 'ENOENT') fail('unknown artifact', 404);
    throw error;
  }
  response.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': body.length });
  response.end(body);
}

// --- HTTP wiring ---------------------------------------------------------

const MAX_REQUEST_BYTES = 256 * 1024; // matches federation-envelope's LIMITS.envelopeBytes

function route(request) {
  const url = new URL(request.url, 'http://coordinator.internal');
  const parts = url.pathname.split('/').filter(Boolean);
  if (request.method === 'POST' && parts.length === 1 && parts[0] === 'tasks') return { name: 'publish' };
  if (request.method === 'GET' && parts.length === 2 && parts[0] === 'tasks' && parts[1] === 'next') return { name: 'next' };
  if (request.method === 'POST' && parts.length === 3 && parts[0] === 'tasks' && parts[2] === 'claim') return { name: 'claim', digest: parts[1] };
  if (request.method === 'POST' && parts.length === 3 && parts[0] === 'tasks' && parts[2] === 'submit') return { name: 'submit', digest: parts[1] };
  if (request.method === 'GET' && parts.length === 2 && parts[0] === 'tasks') return { name: 'get', digest: parts[1] };
  if (request.method === 'PUT' && parts.length === 2 && parts[0] === 'artifacts') return { name: 'putArtifact', digest: parts[1] };
  if (request.method === 'GET' && parts.length === 2 && parts[0] === 'artifacts') return { name: 'getArtifact', digest: parts[1] };
  return null;
}

/**
 * Creates (but does not start listening on) the coordinator's node:http
 * server. `deps.dataDir` must already exist (see `startCoordinator`).
 */
export function createCoordinatorServer(deps) {
  if (!deps || typeof deps.dataDir !== 'string' || !deps.dataDir) fail('dataDir is required', 500);
  if (typeof deps.token !== 'string' || !deps.token) fail('collective token is required', 500);
  if (!(deps.roster instanceof Map) || deps.roster.size === 0) fail('roster (key_id -> publicKeyPem, at least one entry) is required', 500);

  return createServer((request, response) => {
    const respond = (status, body) => {
      const json = JSON.stringify(body);
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(json);
    };

    (async () => {
      try {
        const matched = route(request);
        if (!matched) return fail('not found', 404);
        // putArtifact reads its own body (larger limit, streamed after the
        // digest check) rather than being pre-read here like the small
        // JSON-body endpoints.
        const body = ['publish', 'claim', 'submit'].includes(matched.name)
          ? await readBody(request, MAX_REQUEST_BYTES)
          : Buffer.alloc(0);
        const ctx = { request, response, respond, body, deps, digest: matched.digest };
        if (matched.name === 'publish') await handlePublish(ctx);
        else if (matched.name === 'next') await handleNext(ctx);
        else if (matched.name === 'claim') await handleClaim(ctx);
        else if (matched.name === 'submit') await handleSubmit(ctx);
        else if (matched.name === 'get') await handleGet(ctx);
        else if (matched.name === 'putArtifact') await handlePutArtifact(ctx);
        else await handleGetArtifact(ctx);
      } catch (error) {
        if (error instanceof CoordinatorError) return respond(error.status, { error: error.message });
        respond(500, { error: 'internal coordinator error' });
      }
    })();
  });
}

/**
 * Convenience entrypoint used by the CLI (and tests): ensures the data dir
 * exists, builds the server, and starts listening. Returns the listening
 * `http.Server` so callers can read back the bound port (useful for `port:
 * 0` ephemeral binding in tests) and close it later.
 */
export async function startCoordinator({ dataDir, token, roster, port = 0, host = '127.0.0.1' }) {
  await mkdir(dataDir, { recursive: true });
  const server = createCoordinatorServer({ dataDir, token, roster });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, host, () => resolve());
  });
  return server;
}

// Exported for tests that want to poke at persistence directly without
// going through HTTP.
export const _internal = { loadTask, saveTask, taskPath, readdir, unlink };
