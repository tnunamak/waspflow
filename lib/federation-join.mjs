import fs from 'node:fs';
import { collectiveId, loadConfig, normalizeConfig, saveConfig, generateAndStoreKeypair } from './federation-config.mjs';
import { createApprovalRequest } from './federation-approval-request.mjs';
import { parseJoinInvite } from './federation-invite.mjs';
import { coordinatorHome, readCoordinatorStatus } from './federation-host.mjs';

export class FederationJoinError extends Error {
  constructor(message) { super(message); this.name = 'FederationJoinError'; }
}

async function verifyInviteToken(coordinatorUrl, inviteToken, fetchImpl) {
  let probe;
  try { probe = await fetchImpl(`${coordinatorUrl}/tasks/next`, { headers: { authorization: `Bearer ${inviteToken}` } }); }
  catch { throw new FederationJoinError(`Waspflow could not reach ${coordinatorUrl}. Check the invite and try again.`); }
  if (probe.status === 401) throw new FederationJoinError('That invite is no longer accepted. Ask for a new one.');
  if (!probe.ok) throw new FederationJoinError(`Waspflow could not join this collective (${probe.status}). Try again later.`);
}

export async function refreshRosterCache(config, { fetchImpl = fetch } = {}) {
  let response;
  try { response = await fetchImpl(`${config.coordinator_url}/roster`, { headers: { authorization: `Bearer ${config.collective_token}` } }); }
  catch { return config; }
  if (!response.ok) return config;
  const body = await response.json().catch(() => null);
  if (!Array.isArray(body?.roster)) return config;
  const roster = { ...(config.roster || {}) };
  for (const entry of body.roster) {
    if (typeof entry?.key_id === 'string' && typeof entry?.public_key_pem === 'string') roster[entry.key_id] = entry.public_key_pem;
  }
  const collectiveName = typeof body.collective_name === 'string' && body.collective_name.trim();
  const next = { ...config, roster, last_seen: new Date().toISOString(), ...(collectiveName ? { collective_name: collectiveName } : {}) };
  saveConfig(next);
  return next;
}

function sameOrigin(left, right) {
  try { return new URL(left).origin === new URL(right).origin; } catch { return false; }
}

function localHostStateFor(coordinatorUrl, hostHome) {
  const hostFile = `${hostHome}/host.json`;
  if (!fs.existsSync(hostFile)) return null;
  try {
    const host = JSON.parse(fs.readFileSync(hostFile, 'utf8'));
    const status = readCoordinatorStatus(host);
    const reachableUrls = [status?.public_url, host.reachability?.publicUrl, `http://127.0.0.1:${host.port}`, `http://localhost:${host.port}`].filter(Boolean);
    return reachableUrls.some((url) => sameOrigin(url, coordinatorUrl)) ? host : null;
  } catch { return null; }
}

function approveLocally(host, keyId, publicKeyPem) {
  const roster = JSON.parse(fs.readFileSync(host.roster_path, 'utf8'));
  roster[keyId] = publicKeyPem;
  fs.writeFileSync(host.roster_path, JSON.stringify(roster, null, 2));
}

/** The one join operation shared by the web UI and terminal fallback. */
export async function joinFederation({ invite, keyId, collectiveName, fetchImpl = fetch, hostHome = coordinatorHome() } = {}) {
  const existing = loadConfig();
  const parsed = parseJoinInvite(invite, existing?.coordinator_url || process.env.WASPFLOW_FEDERATION_COORDINATOR_URL);
  const name = collectiveName || parsed.collectiveName;
  const known = existing?.collectives?.find((collective) => collective.coordinator_url === parsed.coordinatorUrl);
  if (known) {
    if (known.collective_token !== parsed.token) {
      await verifyInviteToken(parsed.coordinatorUrl, parsed.token, fetchImpl);
      const updated = normalizeConfig({ ...existing, ...known, collective_token: parsed.token, ...(name ? { collective_name: name } : {}), active_collective_id: known.id });
      saveConfig(updated);
      return { status: 'rejoined', keyId: updated.key_id, coordinatorUrl: updated.coordinator_url, autoApproved: false };
    }
    if (name && known.collective_name !== name) saveConfig(normalizeConfig({ ...existing, ...known, collective_name: name, active_collective_id: known.id }));
    else if (existing.active_collective_id !== known.id) saveConfig(normalizeConfig({ ...existing, ...known, active_collective_id: known.id }));
    return { status: 'already_joined', keyId: known.key_id, coordinatorUrl: known.coordinator_url, autoApproved: false };
  }
  await verifyInviteToken(parsed.coordinatorUrl, parsed.token, fetchImpl);
  const memberKeyId = keyId || process.env.USER || 'member';
  const storageKeyId = existing ? `${memberKeyId}-${Date.now().toString(36)}` : memberKeyId;
  const { privateKeyPath, publicKeyPem } = generateAndStoreKeypair(storageKeyId);
  const approvalRequest = createApprovalRequest({ keyId: memberKeyId, publicKeyPem });
  const joinedAt = new Date().toISOString();
  let config = normalizeConfig({
    ...(existing || {}), coordinator_url: parsed.coordinatorUrl, collective_token: parsed.token, key_id: memberKeyId,
    private_key_path: privateKeyPath, approval_request: approvalRequest, ...(name ? { collective_name: name } : {}),
    collectives: [...(existing?.collectives || []), { id: collectiveId(parsed.coordinatorUrl), coordinator_url: parsed.coordinatorUrl, collective_token: parsed.token, key_id: memberKeyId, private_key_path: privateKeyPath, approval_request: approvalRequest, ...(name ? { collective_name: name } : {}), joined_at: joinedAt, last_seen: joinedAt }],
    active_collective_id: collectiveId(parsed.coordinatorUrl),
  });
  saveConfig(config);
  config = await refreshRosterCache(config, { fetchImpl });
  const localHost = localHostStateFor(parsed.coordinatorUrl, hostHome);
  if (localHost) approveLocally(localHost, memberKeyId, publicKeyPem);
  return {
    status: 'joined', keyId: memberKeyId, coordinatorUrl: parsed.coordinatorUrl,
    peersAutoFetched: Object.keys(config.roster || {}).length,
    rosterSnippet: { [memberKeyId]: publicKeyPem },
    nextStep: localHost
      ? 'This computer is approved and ready to contribute.'
      : 'Send approval_request to the collective operator.',
    autoApproved: Boolean(localHost),
    ...(localHost ? {} : { approvalRequest }),
  };
}
