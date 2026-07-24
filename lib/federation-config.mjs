/**
 * Managed local config for the guided Federation v0 CLI verbs (`waspflow
 * federation join|contribute|submit|status`).
 *
 * Prior to this module, every federation CLI (bin/waspflow-federation-
 * {submit,pull,coordinator}) required the operator to hand-manage an ed25519
 * keypair, a collective bearer token, a coordinator URL, and a roster file,
 * re-passing all of it as flags on every invocation. That is exactly the
 * "PEM keypairs, rosters, digests, 8-flag invocations" surface the owner
 * rejected as unusable by a non-technical contributor (Ocean).
 *
 * This module is the single place that reads/writes the managed config dir
 * (~/.waspflow/federation/, override via WASPFLOW_FEDERATION_HOME) so
 * `waspflow federation join` can write it once and `contribute`/`submit`/
 * `status` can read it silently — the guided verbs never re-ask for a URL,
 * token, or key path the way the raw bins still do (kept working, unchanged,
 * for power users).
 *
 * Deliberately NOT a network client: this module only touches the local
 * filesystem. It does not talk to the coordinator — `join` prints a roster
 * snippet for the human to send, because the coordinator's roster is (by
 * design, see lib/federation-coordinator.mjs's own comment) a hand-edited
 * file with no network-reachable registration endpoint. Adding one would be
 * a real security-surface change this task is explicitly scoped to avoid.
 */
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, generateKeyPairSync } from 'node:crypto';

export class FederationConfigError extends Error {
  constructor(message) { super(message); this.name = 'FederationConfigError'; }
}

export function configHome() {
  return process.env.WASPFLOW_FEDERATION_HOME || path.join(os.homedir(), '.waspflow', 'federation');
}

export function configPath() {
  return path.join(configHome(), 'config.json');
}

const MEMBERSHIP_FIELDS = ['coordinator_url', 'collective_name', 'collective_token', 'key_id', 'private_key_path', 'approval_request', 'roster', 'joined_at', 'last_seen'];

export function collectiveId(coordinatorUrl) {
  return `collective_${createHash('sha256').update(coordinatorUrl).digest('hex').slice(0, 16)}`;
}

function membershipFrom(config) {
  return Object.fromEntries(MEMBERSHIP_FIELDS.flatMap((field) => config[field] === undefined ? [] : [[field, config[field]]]));
}

/** Keep legacy active fields as the daemon's scalar interface while storing memberships separately. */
export function normalizeConfig(config, now = new Date().toISOString()) {
  if (!config || typeof config !== 'object') return config;
  const collectives = Array.isArray(config.collectives) ? config.collectives.filter((entry) => entry?.coordinator_url) : [];
  if (!collectives.length && config.coordinator_url) {
    const membership = membershipFrom(config);
    collectives.push({ ...membership, id: collectiveId(membership.coordinator_url), joined_at: now, last_seen: now });
  }
  if (!collectives.length) return null;
  const activeCollectiveId = collectives.some((entry) => entry.id === config.active_collective_id)
    ? config.active_collective_id
    : collectives[0].id || collectiveId(collectives[0].coordinator_url);
  const normalizedCollectives = collectives.map((entry) => {
    const id = entry.id || collectiveId(entry.coordinator_url);
    const active = id === activeCollectiveId;
    // Root fields may have been changed by existing callers (for example roster refresh).
    const membership = active ? { ...entry, ...membershipFrom(config) } : entry;
    return { ...membership, id, joined_at: entry.joined_at || now, last_seen: entry.last_seen || entry.joined_at || now };
  });
  const active = normalizedCollectives.find((entry) => entry.id === activeCollectiveId);
  const { collectives: _collectives, active_collective_id: _activeCollectiveId, ...rest } = config;
  return { ...rest, ...membershipFrom(active), collectives: normalizedCollectives, active_collective_id: activeCollectiveId };
}

/**
 * Writes a small piece of Federation state atomically with an explicit file
 * mode. Host setup uses the same durable, private-file primitive as member
 * configuration, but keeps its operator credentials in its own directory.
 */
export function saveJsonFile(file, value, { mode = 0o600 } = {}) {
  const dir = path.dirname(file);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(value, null, 2), { mode });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, mode);
}

/**
 * Reads the managed config, or null if `join` has never been run. Never
 * throws on absence — callers decide whether that's fatal for their verb.
 */
export function loadConfig() {
  const file = configPath();
  if (!fs.existsSync(file)) return null;
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (error) {
    throw new FederationConfigError(`could not read ${file}: ${error.message}`);
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (error) {
    throw new FederationConfigError(`${file} is not valid JSON: ${error.message}`);
  }
  if (!parsed || typeof parsed !== 'object') throw new FederationConfigError(`${file} must contain a JSON object`);
  const config = normalizeConfig(parsed);
  if (!config) return null;
  if (JSON.stringify(config) !== JSON.stringify(parsed)) saveJsonFile(file, config);
  return config;
}

/**
 * Requires an existing config, with a clear "run join first" message rather
 * than a generic "config is null" crash — this is the message a non-technical
 * user actually sees when they skip straight to `contribute`.
 */
export function requireConfig() {
  const config = loadConfig();
  if (!config) {
    throw new FederationConfigError(
      `no Federation config found at ${configPath()}. Run 'waspflow federation join <coordinator-url> <invite-token>' first.`
    );
  }
  return config;
}

// Same tmp-then-rename atomic-write pattern used elsewhere in this repo
// (lib/core.sh, lib/federation-coordinator.mjs's saveTask) — a crash mid-write
// must never leave config.json truncated or half-written, since every guided
// verb depends on it being readable.
export function saveConfig(config) {
  saveJsonFile(configPath(), normalizeConfig(config));
}

export function switchCollective(id) {
  const config = requireConfig();
  const collective = config.collectives.find((entry) => entry.id === id);
  if (!collective) throw new FederationConfigError(`no known collective has id '${id}'`);
  const next = normalizeConfig({ ...config, ...membershipFrom(collective), active_collective_id: id });
  saveConfig(next);
  return next;
}

export function leaveCollective(id) {
  const config = requireConfig();
  const collectives = config.collectives.filter((entry) => entry.id !== id);
  if (collectives.length === config.collectives.length) throw new FederationConfigError(`no known collective has id '${id}'`);
  if (!collectives.length) {
    fs.unlinkSync(configPath());
    return null;
  }
  const active = config.active_collective_id === id ? collectives[0] : collectives.find((entry) => entry.id === config.active_collective_id);
  const next = normalizeConfig({ ...config, ...membershipFrom(active), collectives, active_collective_id: active.id });
  saveConfig(next);
  return next;
}

/**
 * Generates a fresh ed25519 keypair and writes it under the managed config
 * dir as `<keyId>.pem` (private, mode 0600) / `<keyId>.pub.pem` (public).
 * Returns the paths and PEM strings so the caller can both persist the path
 * in config.json and print the public key for the roster snippet.
 */
export function generateAndStoreKeypair(keyId) {
  return generateAndStoreKeypairAt(configHome(), keyId);
}

/**
 * The host coordinator has a different lifetime and access boundary than a
 * joining member, so it stores its keypair under federation-coordinator/
 * rather than reusing the member config directory. The key format and file
 * discipline remain identical.
 */
export function generateAndStoreKeypairAt(dir, keyId) {
  // See saveConfig: these modes are ACL no-ops on Windows.
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });

  const privateKeyPath = path.join(dir, `${keyId}.pem`);
  const publicKeyPath = path.join(dir, `${keyId}.pub.pem`);
  fs.writeFileSync(privateKeyPath, privateKeyPem, { mode: 0o600 });
  fs.writeFileSync(publicKeyPath, publicKeyPem, { mode: 0o644 });
  fs.chmodSync(privateKeyPath, 0o600);

  return { privateKeyPath, publicKeyPath, privateKeyPem, publicKeyPem };
}
