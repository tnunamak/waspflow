/**
 * Durable operator-side state and pure reachability choices for
 * `waspflow federation host`. Keeping this separate from the command lets
 * tests prove idempotency without starting a server, a service manager, or a
 * tunnel.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { generateAndStoreKeypairAt, saveJsonFile } from './federation-config.mjs';

export const HOST_SCHEMA_VERSION = 1;

export class FederationHostError extends Error {
  constructor(message) { super(message); this.name = 'FederationHostError'; }
}

export function coordinatorHome() {
  return process.env.WASPFLOW_FEDERATION_COORDINATOR_HOME
    || path.join(os.homedir(), '.waspflow', 'federation-coordinator');
}

export function hostPaths(home = coordinatorHome()) {
  return {
    home,
    config: path.join(home, 'host.json'),
    roster: path.join(home, 'roster.json'),
    token: path.join(home, 'collective-token'),
    ngrokToken: path.join(home, 'ngrok-token'),
    ngrokRuntime: path.join(home, 'ngrok-runtime'),
    status: path.join(home, 'status.json'),
    data: path.join(home, 'tasks'),
  };
}

function randomToken() {
  return randomBytes(32).toString('base64url');
}

function readJson(file, label) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (error) {
    throw new FederationHostError(`could not read ${label} at ${file}: ${error.message}`);
  }
}

function normalizeHttpsUrl(value) {
  let parsed;
  try { parsed = new URL(value); } catch { throw new FederationHostError(`tunnel URL must be a valid https address, got ${value}`); }
  if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new FederationHostError('tunnel URL must be an https origin such as https://collective.example');
  }
  return parsed.origin;
}

export function parseTunnel(value) {
  if (value === 'ngrok') return { kind: 'ngrok' };
  if (value === 'lan') return { kind: 'lan' };
  if (typeof value === 'string' && value.startsWith('url:')) return { kind: 'url', publicUrl: normalizeHttpsUrl(value.slice(4)) };
  throw new FederationHostError('--tunnel must be ngrok, lan, or url:<https://address>');
}

export function resolveLanUrl({ port, networkInterfaces = os.networkInterfaces() }) {
  for (const addresses of Object.values(networkInterfaces)) {
    for (const address of addresses || []) {
      if (address.family === 'IPv4' && !address.internal) return `http://${address.address}:${port}`;
    }
  }
  throw new FederationHostError('could not find a local-network IPv4 address; use --tunnel url:<https://address> instead');
}

/** Creates once, repairs the roster if needed, and never rotates credentials. */
export function ensureHostState({ home = coordinatorHome(), operatorKeyId = 'operator', port = 8787 } = {}) {
  const paths = hostPaths(home);
  fs.mkdirSync(home, { recursive: true, mode: 0o700 });
  fs.chmodSync(home, 0o700);

  let config;
  if (fs.existsSync(paths.config)) {
    config = readJson(paths.config, 'host configuration');
    if (config.schema_version !== HOST_SCHEMA_VERSION) throw new FederationHostError(`unsupported host configuration schema at ${paths.config}`);
  } else {
    const keypair = generateAndStoreKeypairAt(home, operatorKeyId);
    fs.writeFileSync(paths.token, randomToken(), { mode: 0o600 });
    fs.chmodSync(paths.token, 0o600);
    config = {
      schema_version: HOST_SCHEMA_VERSION,
      operator_key_id: operatorKeyId,
      operator_private_key_path: keypair.privateKeyPath,
      operator_public_key_path: keypair.publicKeyPath,
      collective_token_path: paths.token,
      roster_path: paths.roster,
      data_dir: paths.data,
      status_path: paths.status,
      port,
      reachability: null,
    };
    saveJsonFile(paths.config, config);
  }

  let roster = {};
  if (fs.existsSync(config.roster_path)) roster = readJson(config.roster_path, 'coordinator roster');
  if (!roster || typeof roster !== 'object' || Array.isArray(roster)) throw new FederationHostError(`coordinator roster at ${config.roster_path} must be a JSON object`);
  const operatorPublicKey = fs.readFileSync(config.operator_public_key_path, 'utf8');
  if (roster[config.operator_key_id] !== operatorPublicKey) {
    roster[config.operator_key_id] = operatorPublicKey;
    saveJsonFile(config.roster_path, roster);
  }
  fs.mkdirSync(config.data_dir, { recursive: true, mode: 0o700 });
  return { config, paths };
}

export function saveReachability(config, reachability) {
  const next = { ...config, reachability };
  saveJsonFile(path.join(path.dirname(config.roster_path), 'host.json'), next);
  return next;
}

export function createJoinInvite({ coordinatorUrl, collectiveToken }) {
  const invite = new URL('/join', normalizeCoordinatorUrl(coordinatorUrl));
  // Keep the bearer token out of request URLs, server logs, browser history
  // request metadata, and search indexing. OS scheme handlers are the future
  // path; retain their parsing in federation-daemon for backward compatibility.
  invite.hash = collectiveToken;
  return invite.toString();
}

function normalizeCoordinatorUrl(value) {
  let parsed;
  try { parsed = new URL(value); } catch { throw new FederationHostError(`coordinator URL is invalid: ${value}`); }
  if (!['http:', 'https:'].includes(parsed.protocol) || !parsed.hostname || parsed.username || parsed.password || parsed.pathname !== '/' || parsed.search || parsed.hash) {
    throw new FederationHostError(`coordinator URL must be an http(s) origin, got ${value}`);
  }
  return parsed.origin;
}

export function readCollectiveToken(config) {
  try { return fs.readFileSync(config.collective_token_path, 'utf8').trim(); } catch (error) {
    throw new FederationHostError(`could not read collective token: ${error.message}`);
  }
}

function writeTokenFile(config, token) {
  const file = config.collective_token_path;
  const directory = path.dirname(file);
  const tmp = path.join(directory, `.${path.basename(file)}.${process.pid}.tmp`);
  fs.writeFileSync(tmp, `${token}\n`, { mode: 0o600 });
  fs.renameSync(tmp, file);
  fs.chmodSync(file, 0o600);
}

/** Atomically replaces the bearer token without exposing a partial file. */
export function rotateCollectiveToken(config) {
  const token = randomToken();
  writeTokenFile(config, token);
  return token;
}

/** Restores a known token after a failed live-coordinator update. */
export function writeCollectiveToken(config, token) {
  writeTokenFile(config, token);
}

export function readCoordinatorStatus(config) {
  if (!fs.existsSync(config.status_path)) return null;
  return readJson(config.status_path, 'coordinator status');
}
