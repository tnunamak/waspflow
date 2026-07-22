export class FederationInviteError extends Error {
  constructor(message) { super(message); this.name = 'FederationInviteError'; }
}

function coordinatorUrl(value) {
  try {
    const parsed = new URL(value);
    if (!['http:', 'https:'].includes(parsed.protocol)) throw new Error('not HTTP');
    return parsed.toString().replace(/\/$/, '');
  } catch {
    throw new FederationInviteError('The invite needs a web address.');
  }
}

function commandParts(value) {
  const match = /^\s*waspflow\s+federation\s+join\s+(?:"([^"]+)"|'([^']+)'|(\S+))(?:\s+(\S+))?\s*$/.exec(value);
  return match ? { coordinator: match[1] || match[2] || match[3], token: match[4] } : null;
}

/** Normalize the invite forms accepted by the app and terminal fallback. */
export function parseJoinInvite(invite, fallbackCoordinatorUrl) {
  if (typeof invite !== 'string' || !invite.trim()) throw new FederationInviteError('Paste an invite link or code.');
  const value = invite.trim();
  if (value.startsWith('waspflow://')) {
    let link;
    try { link = new URL(value); } catch { throw new FederationInviteError('That invite link is not valid.'); }
    if (link.hostname !== 'join') throw new FederationInviteError('That invite link is not valid.');
    const coordinator = link.searchParams.get('coordinator') || link.searchParams.get('coordinator_url');
    const token = link.searchParams.get('token');
    if (!coordinator || !token) throw new FederationInviteError('That invite link is missing information.');
    const collectiveName = link.searchParams.get('name');
    return { coordinatorUrl: coordinatorUrl(coordinator), token, ...(collectiveName?.trim() ? { collectiveName: collectiveName.trim() } : {}) };
  }
  const coordinatorAndToken = /^(\S+)\s+(\S+)$/.exec(value);
  if (coordinatorAndToken && /^https?:\/\//i.test(coordinatorAndToken[1])) {
    return { coordinatorUrl: coordinatorUrl(coordinatorAndToken[1]), token: coordinatorAndToken[2] };
  }
  if (/^https?:\/\//i.test(value)) {
    let link;
    try { link = new URL(value); } catch { throw new FederationInviteError('That invite link is not valid.'); }
    if (link.pathname !== '/join' || !link.hash.slice(1)) throw new FederationInviteError('That invite link is missing information.');
    let token;
    try { token = decodeURIComponent(link.hash.slice(1)); } catch { throw new FederationInviteError('That invite link is not valid.'); }
    return { coordinatorUrl: coordinatorUrl(link.origin), token };
  }
  const command = commandParts(value);
  if (command) return command.token
    ? { coordinatorUrl: coordinatorUrl(command.coordinator), token: command.token }
    : parseJoinInvite(command.coordinator, fallbackCoordinatorUrl);
  if (/\s/.test(value)) throw new FederationInviteError('Paste an invite link or code.');
  if (!fallbackCoordinatorUrl) throw new FederationInviteError('Paste the complete invite link.');
  return { coordinatorUrl: coordinatorUrl(fallbackCoordinatorUrl), token: value };
}
