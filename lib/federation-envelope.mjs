/**
 * Federation v0's portable trust boundary.  This deliberately knows nothing
 * about runners, coordinators, settlement, or evaluation: it only makes an
 * author/executor handoff inspectable and cryptographically bound.
 */
import { createHash, createPrivateKey, createPublicKey, sign, verify } from 'node:crypto';

export const LIMITS = Object.freeze({
  envelopeBytes: 256 * 1024,
  payloadBytes: 192 * 1024,
  stringBytes: 16 * 1024,
  artifactBytes: 2 ** 40,
  maxDepth: 12,
});

const TASK_SCHEMA = 'waspflow.federation.task.v0';
const RESULT_SCHEMA = 'waspflow.federation.result.v0';
const CAPACITY_KINDS = new Set(['subscription', 'api_key', 'local', 'gateway']);
const SHA256 = /^[0-9a-f]{64}$/;
const DIGEST = /^sha256:[0-9a-f]{64}$/;
const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;
const FORBIDDEN = new Set([
  'devcontainer', 'devcontainer_json', 'container', 'container_image', 'docker',
  'vm', 'vm_image', 'mount', 'mounts', 'host_mount', 'privileged', 'devices',
  'lifecycle_hook', 'lifecycle_hooks', 'prepare_command', 'network_rule',
  'network_rules', 'network_destination', 'network_allowlist', 'raw_network',
]);

export class EnvelopeError extends Error {
  constructor(message) { super(message); this.name = 'EnvelopeError'; }
}
const fail = (message) => { throw new EnvelopeError(message); };
const bytes = (value) => Buffer.byteLength(value, 'utf8');

// RFC 8785 delegates primitive serialization to ECMAScript's JSON serializer.
// The recursive ordering here is the JCS object-member rule.
export function jcs(value) {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number') {
    if (!Number.isFinite(value)) fail('JCS value contains a non-finite number');
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) return `[${value.map(jcs).join(',')}]`;
  if (typeof value !== 'object') fail(`JCS cannot encode ${typeof value}`);
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${jcs(value[key])}`).join(',')}}`;
}

export function sha256(value) {
  return createHash('sha256').update(value).digest('hex');
}
export function payloadDigest(payload) { return sha256(jcs(payload)); }
export function address(kind, digest) { return `${kind}:sha256:${digest}`; }
function domain(kind, digest) { return Buffer.concat([Buffer.from(`waspflow-federation/${kind}/v0\0`), Buffer.from(digest, 'hex')]); }

function own(object, key) { return Object.prototype.hasOwnProperty.call(object, key); }
function expectObject(value, name) {
  if (!value || Array.isArray(value) || typeof value !== 'object') fail(`${name} must be an object`);
}
function keys(value, allowed, name) {
  expectObject(value, name);
  for (const key of Object.keys(value)) if (!allowed.includes(key)) fail(`${name} has unknown field ${key}`);
}
function text(value, name, { optional = false, pattern } = {}) {
  if (value === undefined && optional) return;
  if (typeof value !== 'string' || !value || bytes(value) > LIMITS.stringBytes || (pattern && !pattern.test(value))) fail(`${name} is invalid`);
}
function uint(value, name, max = Number.MAX_SAFE_INTEGER) {
  if (!Number.isSafeInteger(value) || value < 0 || value > max) fail(`${name} must be a bounded unsigned integer`);
}
function nullableText(value, name) {
  if (value === null) return;
  text(value, name);
}
function artifact(value, name) {
  keys(value, ['sha256', 'bytes', 'media_type'], name);
  text(value.sha256, `${name}.sha256`, { pattern: SHA256 });
  uint(value.bytes, `${name}.bytes`, LIMITS.artifactBytes);
  text(value.media_type, `${name}.media_type`);
}
function reserved(payload) {
  for (const key of ['oracle_ref', 'result_verdict', 'settlement']) {
    if (!own(payload, key) || payload[key] !== null) fail(`${key} is reserved and must be null in v0`);
  }
}
function forbidden(value, path = 'payload', depth = 0) {
  if (depth > LIMITS.maxDepth) fail('payload exceeds nesting limit');
  if (Array.isArray(value)) return value.forEach((part, index) => forbidden(part, `${path}[${index}]`, depth + 1));
  if (!value || typeof value !== 'object') return;
  for (const [key, part] of Object.entries(value)) {
    if (FORBIDDEN.has(key) || /(?:^|_)(?:mount|privileged|devcontainer|container|docker|vm|network_rule)(?:_|$)/.test(key)) {
      fail(`${path}.${key} is forbidden in a task envelope`);
    }
    forbidden(part, `${path}.${key}`, depth + 1);
  }
}

function task(payload) {
  keys(payload, ['schema', 'collective', 'display_id', 'author_key', 'created_at', 'expires_at', 'source', 'prompt', 'network', 'oracle_ref', 'result_verdict', 'settlement'], 'task payload');
  if (payload.schema !== TASK_SCHEMA) fail('unknown task schema');
  text(payload.collective, 'collective'); text(payload.display_id, 'display_id'); text(payload.author_key, 'author_key');
  text(payload.created_at, 'created_at', { pattern: RFC3339 }); text(payload.expires_at, 'expires_at', { pattern: RFC3339 });
  const createdAt = Date.parse(payload.created_at); const expiresAt = Date.parse(payload.expires_at);
  if (!Number.isFinite(createdAt) || !Number.isFinite(expiresAt) || expiresAt <= createdAt) fail('expires_at must follow a valid created_at');
  keys(payload.source, ['base_artifact', 'base_revision'], 'source'); artifact(payload.source.base_artifact, 'source.base_artifact');
  text(payload.source.base_revision, 'source.base_revision', { optional: true });
  keys(payload.prompt, ['artifact'], 'prompt'); artifact(payload.prompt.artifact, 'prompt.artifact');
  if (!['enabled', 'disabled'].includes(payload.network)) fail('network must be enabled or disabled');
  reserved(payload); forbidden(payload);
}
function result(payload) {
  keys(payload, ['schema', 'task_digest', 'executor_key', 'submitted_at', 'candidate', 'execution_metadata', 'oracle_ref', 'result_verdict', 'settlement'], 'result payload');
  if (payload.schema !== RESULT_SCHEMA) fail('unknown result schema');
  text(payload.task_digest, 'task_digest', { pattern: DIGEST }); text(payload.executor_key, 'executor_key');
  text(payload.submitted_at, 'submitted_at', { pattern: RFC3339 });
  keys(payload.candidate, ['artifact', 'tree_digest'], 'candidate'); artifact(payload.candidate.artifact, 'candidate.artifact');
  text(payload.candidate.tree_digest, 'candidate.tree_digest', { pattern: DIGEST }); reserved(payload);
  if (own(payload, 'execution_metadata')) executionMetadata(payload.execution_metadata);
}

// Additive optional result metadata intentionally stays in the existing v0
// result schema. Old signed results remain valid because the field is absent;
// new results are signed over it. Account identities are structurally absent
// from this public envelope and therefore cannot leak to requesters.
function executionMetadata(value) {
  keys(value, ['harness_id', 'capacity_kind', 'model', 'usage', 'duration_ms'], 'execution_metadata');
  text(value.harness_id, 'execution_metadata.harness_id');
  if (!CAPACITY_KINDS.has(value.capacity_kind)) fail('execution_metadata.capacity_kind is invalid');
  nullableText(value.model, 'execution_metadata.model');
  if (value.usage !== null) {
    keys(value.usage, ['input_tokens', 'output_tokens'], 'execution_metadata.usage');
    uint(value.usage.input_tokens, 'execution_metadata.usage.input_tokens');
    uint(value.usage.output_tokens, 'execution_metadata.usage.output_tokens');
  }
  uint(value.duration_ms, 'execution_metadata.duration_ms');
}
export function validatePayload(payload) {
  expectObject(payload, 'payload');
  if (payload.schema === TASK_SCHEMA) task(payload);
  else if (payload.schema === RESULT_SCHEMA) result(payload);
  else fail('unknown envelope schema');
  if (bytes(jcs(payload)) > LIMITS.payloadBytes) fail('payload exceeds byte limit');
  return payload.schema === TASK_SCHEMA ? 'task' : 'result';
}

export function signEnvelope(payload, privateKeyPem, keyId) {
  const kind = validatePayload(payload); text(keyId, 'key_id');
  const digest = payloadDigest(payload);
  const signature = sign(null, domain(kind, digest), createPrivateKey(privateKeyPem)).toString('base64url');
  return { payload, signature: { algorithm: 'ed25519', key_id: keyId, value: signature } };
}
export function verifyEnvelope(envelope, publicKeyPem, { now = new Date(), allowExpired = false } = {}) {
  keys(envelope, ['payload', 'signature'], 'envelope');
  const kind = validatePayload(envelope.payload);
  keys(envelope.signature, ['algorithm', 'key_id', 'value'], 'signature');
  if (envelope.signature.algorithm !== 'ed25519') fail('unsupported signature algorithm');
  text(envelope.signature.key_id, 'signature.key_id'); text(envelope.signature.value, 'signature.value');
  const digest = payloadDigest(envelope.payload);
  let signature;
  try { signature = Buffer.from(envelope.signature.value, 'base64url'); } catch { fail('signature is not base64url'); }
  if (signature.length !== 64 || !verify(null, domain(kind, digest), createPublicKey(publicKeyPem), signature)) fail('invalid signature');
  if (kind === 'task' && !allowExpired && Date.parse(envelope.payload.expires_at) <= now.getTime()) fail('task has expired');
  return { kind, digest, address: address(kind, digest) };
}

// JSON.parse accepts duplicate keys. This scanner catches them before parsing;
// canonical-byte comparison then rejects alternate JSON encodings at this boundary.
function duplicateKeys(json) {
  let i = 0;
  const ws = () => { while (/\s/.test(json[i] || '')) i++; };
  const string = () => { const start = i++; let escaped = false; while (i < json.length) { const c = json[i++]; if (escaped) escaped = false; else if (c === '\\') escaped = true; else if (c === '"') return json.slice(start, i); } fail('unterminated JSON string'); };
  const value = () => { ws(); if (json[i] === '{') { object(); return; } if (json[i] === '[') { i++; ws(); if (json[i] === ']') return i++; while (true) { value(); ws(); if (json[i] === ']') return i++; if (json[i++] !== ',') fail('malformed JSON array'); } } if (json[i] === '"') return void string(); while (i < json.length && !/[\s,\]\}]/.test(json[i])) i++; };
  const object = () => { i++; ws(); const seen = new Set(); if (json[i] === '}') return i++; while (true) { ws(); if (json[i] !== '"') fail('malformed JSON object'); const raw = string(); let key; try { key = JSON.parse(raw); } catch { fail('invalid JSON string'); } if (seen.has(key)) fail(`duplicate JSON key ${key}`); seen.add(key); ws(); if (json[i++] !== ':') fail('malformed JSON object'); value(); ws(); if (json[i] === '}') return i++; if (json[i++] !== ',') fail('malformed JSON object'); } };
  value(); ws(); if (i !== json.length) fail('trailing JSON data');
}
export function parseCanonicalJson(input) {
  const raw = Buffer.isBuffer(input) ? new TextDecoder('utf-8', { fatal: true }).decode(input) : input;
  if (typeof raw !== 'string' || bytes(raw) > LIMITS.envelopeBytes) fail('JSON input exceeds byte limit');
  duplicateKeys(raw);
  let value; try { value = JSON.parse(raw); } catch { fail('invalid JSON'); }
  if (raw !== jcs(value)) fail('JSON is not RFC 8785 canonical');
  return value;
}
export function parseCanonicalEnvelope(input) {
  const envelope = parseCanonicalJson(input);
  keys(envelope, ['payload', 'signature'], 'envelope');
  return envelope;
}
