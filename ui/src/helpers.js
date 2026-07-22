export const SESSION_EXPIRED_MESSAGE = 'This local link has expired; no task or account change was made.';

const routes = new Set(['contribute', 'requests', 'compose', 'activity', 'help', 'settings', 'tasks']);

export function routeFromHash(hash = '') {
  const parts = String(hash).replace(/^#\/?/, '').split('/').filter(Boolean);
  const route = parts[0]?.toLowerCase() || 'contribute';
  if (!routes.has(route)) return { name: 'contribute', parts: [] };
  return { name: route, parts: parts.slice(1) };
}

export function viewForStatus(status) {
  if (!status) return { name: 'loading' };
  if (status.state === 'not_joined') return { name: 'join' };
  if (status.state === 'pending_approval') return { name: 'pending' };
  if (status.state === 'approval_revoked') return { name: 'approval_revoked' };
  if (status.state === 'action_needed') return { name: 'action', action: status.action || {} };
  if (status.state === 'setup_required') return { name: 'setup', checks: status.action?.checks || [] };
  const names = { contributing: 'Contributing', pausing: 'Pausing after this task…', paused: 'Paused', idle: 'Ready when you are' };
  return { name: 'status', title: names[status.state] || 'Checking status', control: ['contributing', 'pausing'].includes(status.state) ? 'pause' : 'start' };
}

export function lifecycleStage(status) {
  const state = String(status || '').toLowerCase();
  if (['failed', 'error', 'returned'].includes(state)) return 'failed';
  if (state === 'settled') return 'settled';
  if (state === 'claimed') return 'claimed';
  return ['submitted', 'evaluating', 'running'].includes(state) ? 'running' : 'queued';
}

export function taskTimeline(task = {}) {
  const current = lifecycleStage(task?.status);
  const names = current === 'failed' ? ['queued', 'claimed', 'running', 'failed'] : ['queued', 'claimed', 'running', 'settled'];
  return names.map((name, index) => ({ name, complete: index < names.indexOf(current), current: name === current, timestamp: task?.[`${name}_at`] || (name === 'queued' ? task?.published_at : null) }));
}

export function providerDisplayName(value) {
  const names = { anthropic: 'Anthropic (Claude)', claude: 'Anthropic (Claude)', openai: 'OpenAI', github: 'GitHub', google: 'Google' };
  const provider = String(value || 'provider').trim();
  return names[provider.toLowerCase()] || provider;
}

export function capacityKind(account = {}) { return account.capacity_kind || account.capacity?.kind || account.kind || account.auth_kind || account.capacity_type || 'not captured'; }

export function providerCapacitySubject(identity) {
  const account = (identity?.accounts || identity?.providers || [])[0];
  if (!account) return 'your configured provider account';
  const provider = providerDisplayName(account.provider || account.service || account.name);
  const kind = String(capacityKind(account)).toLowerCase();
  if (kind.includes('local')) return `the ${provider} local model`;
  if (kind.includes('api')) return `your ${provider} API key`;
  return `your ${provider} account`;
}

export function statusRole(value) {
  const state = String(value || '').toLowerCase();
  if (['contributing', 'claimed', 'running', 'submitted', 'evaluating'].includes(state)) return 'active';
  if (['paused', 'action_needed', 'pending_approval', 'pausing'].includes(state)) return 'attention';
  if (['failed', 'error', 'approval_revoked', 'unreachable', 'session_expired'].includes(state)) return 'problem';
  return 'ready';
}

export function displayStatus(value) { return String(value || 'queued').replace(/[_-]+/g, ' ').replace(/\b\w/g, (letter) => letter.toUpperCase()); }
