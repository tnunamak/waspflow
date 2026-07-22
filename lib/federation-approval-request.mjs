export class FederationApprovalRequestError extends Error {
  constructor(message) { super(message); this.name = 'FederationApprovalRequestError'; }
}

export function createApprovalRequest({ keyId, publicKeyPem }) {
  return `wfapr1.${Buffer.from(JSON.stringify({ key_id: keyId, public_key_pem: publicKeyPem })).toString('base64url')}`;
}

export function parseApprovalRequest(value) {
  if (typeof value !== 'string' || !value.startsWith('wfapr1.')) throw new FederationApprovalRequestError('That approval request is not valid.');
  let parsed;
  try { parsed = JSON.parse(Buffer.from(value.slice('wfapr1.'.length), 'base64url').toString('utf8')); } catch { throw new FederationApprovalRequestError('That approval request is not valid.'); }
  if (!parsed || typeof parsed.key_id !== 'string' || !parsed.key_id || typeof parsed.public_key_pem !== 'string' || !parsed.public_key_pem.includes('BEGIN PUBLIC KEY')) {
    throw new FederationApprovalRequestError('That approval request is not valid.');
  }
  return { keyId: parsed.key_id, publicKeyPem: parsed.public_key_pem };
}
