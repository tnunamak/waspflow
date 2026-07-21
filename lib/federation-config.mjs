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
import { generateKeyPairSync } from 'node:crypto';

export class FederationConfigError extends Error {
  constructor(message) { super(message); this.name = 'FederationConfigError'; }
}

export function configHome() {
  return process.env.WASPFLOW_FEDERATION_HOME || path.join(os.homedir(), '.waspflow', 'federation');
}

export function configPath() {
  return path.join(configHome(), 'config.json');
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
  return parsed;
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
  const dir = configHome();
  // POSIX modes document the intended privacy boundary. Windows uses ACLs;
  // installer repair owns any Windows-specific permission remediation.
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = configPath();
  const tmp = path.join(dir, `.config.json.${process.pid}.tmp`);
  fs.writeFileSync(tmp, JSON.stringify(config, null, 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}

/**
 * Generates a fresh ed25519 keypair and writes it under the managed config
 * dir as `<keyId>.pem` (private, mode 0600) / `<keyId>.pub.pem` (public).
 * Returns the paths and PEM strings so the caller can both persist the path
 * in config.json and print the public key for the roster snippet.
 */
export function generateAndStoreKeypair(keyId) {
  const dir = configHome();
  // See saveConfig: these modes are ACL no-ops on Windows.
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const { privateKey, publicKey } = generateKeyPairSync('ed25519');
  const privateKeyPem = privateKey.export({ type: 'pkcs8', format: 'pem' });
  const publicKeyPem = publicKey.export({ type: 'spki', format: 'pem' });

  const privateKeyPath = path.join(dir, `${keyId}.pem`);
  const publicKeyPath = path.join(dir, `${keyId}.pub.pem`);
  fs.writeFileSync(privateKeyPath, privateKeyPem, { mode: 0o600 });
  fs.writeFileSync(publicKeyPath, publicKeyPem, { mode: 0o644 });

  return { privateKeyPath, publicKeyPath, privateKeyPem, publicKeyPem };
}
