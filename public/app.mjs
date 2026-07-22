const POLL_INTERVAL_MS = 1500;
const navigation = [
  ['contribute', 'Contribute'], ['requests', 'Requests'], ['activity', 'Activity'],
  ['settings', 'Settings'], ['help', 'Help'],
];
const lifecycleSteps = ['queued', 'claimed', 'running', 'settled'];

export function routeFromHash(hash = '') {
  const route = String(hash).replace(/^#\/?/, '').split('/')[0].toLowerCase();
  return navigation.some(([name]) => name === route) ? route : 'contribute';
}

export function viewForStatus(status) {
  if (!status) return { name: 'loading' };
  if (status.state === 'not_joined') return { name: 'join' };
  if (status.state === 'pending_approval') return { name: 'pending' };
  if (status.state === 'action_needed') return { name: 'action', action: status.action || {} };
  if (status.state === 'setup_required') return { name: 'setup', checks: status.action?.checks || [] };
  const names = { contributing: 'Contributing', paused: 'Paused', idle: 'Ready when you are' };
  return { name: 'status', title: names[status.state] || 'Checking status', control: status.state === 'contributing' ? 'pause' : 'start' };
}

export function lifecycleStage(taskStatus) {
  const state = String(taskStatus || '').toLowerCase();
  if (state === 'settled') return 'settled';
  if (['claimed'].includes(state)) return 'claimed';
  if (['submitted', 'evaluating', 'running'].includes(state)) return 'running';
  return 'queued';
}

export function taskTimeline(task = {}) {
  const current = lifecycleSteps.indexOf(lifecycleStage(task.status));
  return lifecycleSteps.map((name, index) => ({
    name,
    complete: index < current,
    current: index === current,
    timestamp: task[`${name}_at`] || (name === 'queued' ? task.published_at : null),
  }));
}

function providerAccounts(identity) {
  const accounts = identity?.accounts || identity?.providers || [];
  return Array.isArray(accounts) ? accounts : [];
}

export function capacityKind(account = {}) {
  return account.capacity_kind || account.capacity?.kind || account.kind || account.auth_kind || account.capacity_type || 'not reported';
}

function readableCapacityKind(value) {
  return String(value || 'not reported').replace(/[_-]+/g, ' ').replace(/\b\w/g, (character) => character.toUpperCase());
}

export function providerCapacitySubject(identity) {
  const account = providerAccounts(identity)[0];
  if (!account) return 'your configured provider account';
  const provider = account.provider || account.service || account.name || 'provider';
  const kind = String(capacityKind(account)).toLowerCase();
  if (kind.includes('local')) return `the ${provider} local model`;
  if (kind.includes('api')) return `your ${provider} API key`;
  return `your ${provider} account`;
}

function element(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value === null || value === undefined || value === false) continue;
    if (name === 'className') node.className = value;
    else if (name === 'text') node.textContent = value;
    else if (name.startsWith('on')) node.addEventListener(name.slice(2).toLowerCase(), value);
    else if (name === 'checked') node.checked = Boolean(value);
    else node.setAttribute(name, value === true ? '' : value);
  }
  node.append(...children.flat().filter(Boolean));
  return node;
}

function button(label, onClick, className = '', attributes = {}) {
  return element('button', { type: 'button', className, onClick, ...attributes, text: label });
}

function panel(title, lead, ...children) {
  return element('section', { className: 'panel' },
    element('div', { className: 'panel-heading' }, element('h2', { text: title }), lead ? element('p', { className: 'muted', text: lead }) : null),
    ...children,
  );
}

function formatDate(value) {
  const date = new Date(value || '');
  return Number.isFinite(date.getTime()) ? new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(date) : 'Not recorded';
}

function labeledDate(label, value) {
  return value ? `${label} ${formatDate(value)}` : `${label} not recorded`;
}

function formatDuration(value) {
  if (typeof value === 'number' && Number.isFinite(value)) return `${Math.max(0, Math.round(value / 1000))} seconds`;
  return value || 'Not recorded';
}

function taskAge(publishedAt) {
  const time = Date.parse(publishedAt || '');
  if (!Number.isFinite(time)) return 'Recently submitted';
  const minutes = Math.max(0, Math.round((Date.now() - time) / 60000));
  return minutes < 1 ? 'Submitted just now' : minutes < 60 ? `Submitted ${minutes}m ago` : `Submitted ${Math.round(minutes / 60)}h ago`;
}

function copyText(value) {
  if (value) void navigator.clipboard?.writeText(value);
}

function statusChip(status) {
  const label = String(status || 'queued').toLowerCase().replace(/_/g, ' ');
  return element('span', { className: `chip chip-${label.replace(/\s+/g, '-')}`, text: label });
}

function header(active) {
  const nav = element('nav', { className: 'primary-nav', 'aria-label': 'Federation sections' }, ...navigation.map(([route, label]) => {
    const link = element('a', { href: `#/${route}`, text: label, 'aria-current': active === route ? 'page' : null });
    return link;
  }));
  return element('header', { className: 'app-header' },
    element('a', { className: 'brand', href: '#/contribute' }, element('span', { className: 'brand-mark', text: 'W' }), element('span', { text: 'Waspflow Federation' })), nav,
  );
}

function banner(message) {
  return message ? element('div', { className: 'notice', role: 'alert', text: message }) : null;
}

function authOrJoinView(view, status, control) {
  if (view.name === 'loading') return panel('Checking Federation status', 'Loading your local Federation state before showing a setup or contribution action.');
  if (view.name === 'join') {
    const invite = element('textarea', { id: 'invite', placeholder: 'Paste an invite link, join command, or token', required: true });
    return panel('Join your collective', 'One paste is all it takes to get set up.',
      element('p', { text: 'Federation recognizes the invite link, join command, or token you were sent.' }),
      element('label', { for: 'invite', text: 'Invite' }), invite,
      element('div', { className: 'actions' }, button('Join Federation', () => control('/join', { invite: invite.value }))),
      element('p', { className: 'quiet-note', text: 'Tasks run in an isolated Docker sandbox. They cannot read your other files, reach your home network, or see other tasks.' }),
    );
  }
  if (view.name === 'pending') return panel('Waiting for approval', 'Your collective owner needs to approve this machine.',
    status?.collective_name ? element('p', { text: `You’re joining ${status.collective_name}.` }) : null,
    element('p', { className: 'muted', text: status?.detail || 'You can close this page. Waspflow will be ready after approval.' }),
  );
  if (view.name === 'setup') return panel('Your sandbox needs attention', 'Complete this once, then come back to contribute.',
    element('ol', { className: 'manual-steps' }, ...(view.checks.length ? view.checks.map((check) => element('li', { text: `${check.detail || check.name}. ${check.fix || ''}` })) : [element('li', { text: 'Run waspflow federation doctor for the exact repair.' })])),
    element('p', { className: 'detail', text: status?.detail || '' }),
  );
  const browserAction = view.action?.kind === 'awaiting_browser';
  return panel(browserAction ? 'Sign in to continue' : 'One-time sign-in step', 'Waspflow will keep this page current while you finish.',
    element('p', { text: browserAction ? 'Complete the sign-in in your browser. Contribution will resume automatically.' : 'Complete the listed step inside your agent, then start contributing again.' }),
    browserAction ? button(view.action?.code ? 'Sign in to Docker' : 'Open sign-in', () => window.open(view.action?.url, '_blank', 'noopener')) : element('pre', { className: 'instruction', text: view.action?.instruction || 'Follow the sign-in instruction shown by your agent.' }),
    view.action?.code ? element('p', { className: 'detail', text: `Confirmation code: ${view.action.code}` }) : null,
  );
}

function contributionStatus(status, view, control, settings) {
  const isContributing = view.control === 'pause';
  const controlLabel = isContributing ? 'Pause contributing' : status?.state === 'paused' ? 'Resume contributing' : 'Start contributing';
  const count = status?.ledger_summary?.count_7d || 0;
  const collectiveName = settings?.collective_name || status?.collective_name || 'your collective';
  const activeTask = status?.contribution?.display_id;
  const requester = status?.contribution?.requester || status?.contribution?.author;
  const completion = status?.last_completed?.display_id;
  const detail = isContributing && activeTask
    ? `Working on '${activeTask}'${requester ? ` for ${requester}` : ''}`
    : status?.detail || 'Waspflow checks for a safe next task.';
  return panel('Your contribution', null,
    element('p', { className: 'collective-line', text: `Collective: ${collectiveName}` }),
    element('div', { className: 'contribution-state' },
      element('div', { className: 'status-dot', 'data-state': status?.state || 'idle' }),
      element('div', {}, element('p', { className: 'status-label', text: view.title }), element('p', { className: 'detail', text: detail })),
    ),
    element('div', { className: 'actions' }, button(controlLabel, () => control(isContributing ? '/contribute/stop' : '/contribute/start'), isContributing ? 'secondary' : '')),
    completion ? element('a', { className: 'ledger-link', href: '#/activity', text: `Finished '${completion}' · View activity` }) : element('a', { className: 'ledger-link', href: '#/activity', text: `${count} completed this week · View activity` }),
    element('div', { className: 'guard' }, element('strong', { text: 'Waspflow only helps out with capacity you’re not using. Pause anytime.' })),
  );
}

function taskChoices(tasks, contribute) {
  const choices = Array.isArray(tasks) ? tasks : [];
  return panel('Choose a task', 'Pick a request that suits your capacity.',
    element('div', { className: 'actions' }, button('Contribute next available', () => contribute(), 'secondary', { disabled: choices.length === 0, 'aria-disabled': choices.length === 0 })),
    choices.length ? element('ul', { className: 'task-list', 'aria-label': 'Available tasks' }, ...choices.map((task) => element('li', { className: 'task-row' },
      element('div', { className: 'task-main' },
        element('div', { className: 'task-title' }, element('strong', { text: task.display_id || 'Untitled task' }), task.author ? element('span', { className: 'muted', text: `by ${task.author}` }) : null),
        element('p', { className: 'muted', text: taskAge(task.published_at) }),
        task.prompt ? element('p', { className: 'prompt-preview', text: task.prompt }) : null,
        task.network !== undefined ? element('p', { className: 'network', text: `Network: ${task.network ? 'on' : 'off'}` }) : null,
      ),
      button('Contribute this', () => contribute(task.task_digest), 'secondary'),
    ))) : element('div', { className: 'empty-state' }, element('strong', { text: 'Nothing is waiting right now.' }), element('p', { text: 'Keep contributing on and Waspflow will pick up the next trusted request.' })),
  );
}

function contributeView(status, tasks, view, control, settings) {
  if (view.name !== 'status') return authOrJoinView(view, status, control);
  return element('div', { className: 'view-stack' }, contributionStatus(status, view, control, settings), status?.state === 'idle' ? taskChoices(tasks, (digest) => control('/contribute/start', digest ? { task_digest: digest } : null)) : null);
}

function timeline(task) {
  const steps = taskTimeline(task);
  return element('ol', { className: 'timeline', 'aria-label': 'Task lifecycle' }, ...steps.map((step) => element('li', { className: step.complete ? 'complete' : step.current ? 'current' : '' },
    element('strong', { text: step.name }), element('span', { text: step.timestamp ? formatDate(step.timestamp) : step.current ? 'In progress' : 'Waiting' }),
  )));
}

function receipt(task) {
  const metadata = task.execution_metadata || task.receipt || {};
  const fields = [
    ['Harness', metadata.harness_id], ['Model', task.model || metadata.model], ['Tokens', task.tokens || metadata.tokens || tokenUsage(metadata)],
    ['Duration', formatDuration(task.duration || metadata.duration || metadata.duration_ms)], ['Sandbox', task.sandbox_id || metadata.sandbox_id],
  ].filter(([, value]) => value);
  return fields.length ? element('dl', { className: 'receipt' }, ...fields.flatMap(([label, value]) => [element('dt', { text: label }), element('dd', { text: String(value) })])) : element('p', { className: 'muted', text: 'Execution receipt will appear here when the task settles.' });
}

function tokenUsage(metadata = {}) {
  const usage = metadata.usage || metadata;
  const input = usage.input_tokens ?? usage.tokens_in;
  const output = usage.output_tokens ?? usage.tokens_out;
  return input !== undefined || output !== undefined ? `${input || 0} tokens in · ${output || 0} tokens out` : '';
}

function taskDetail(task, selectedDigest, resultHref) {
  if (!selectedDigest || !/^sha256:[a-f0-9]{64}$/i.test(selectedDigest)) return null;
  const detail = task || { task_digest: selectedDigest, status: 'queued' };
  const result = detail.result_address || detail.result_ref || detail.status?.toLowerCase?.() === 'settled';
  return element('div', { className: 'view-stack' },
    panel(detail.display_id || 'Task detail', detail.author ? `Requested by ${detail.author}` : 'Request lifecycle and receipt.',
      timeline(detail),
      element('p', { className: 'detail', text: labeledDate('Started', detail.started_at || detail.running_at || detail.claimed_at) }),
      element('p', { className: 'detail', text: labeledDate('Finished', detail.finished_at || detail.settled_at) }),
      element('p', { className: 'detail', text: `Duration: ${formatDuration(detail.duration || detail.execution_metadata?.duration_ms)}` }),
      element('h3', { text: 'What should be done' }), element('p', { className: 'prompt-detail', text: detail.prompt || detail.description || 'Task details are loading from the coordinator.' }),
      detail.source ? element('p', { className: 'detail', text: `Source: ${typeof detail.source === 'string' ? detail.source : detail.source.name || 'Task source'}` }) : null,
    ),
    panel('Execution receipt', 'Shared execution metadata never includes the contributor’s account identities.', receipt(detail)),
    result ? panel('Result', 'The task has settled.',
      element('div', { className: 'actions' }, element('a', { className: 'button-link', href: resultHref, text: 'Download result' }), button('Copy reference', () => copyText(detail.result_address || `result:${selectedDigest}`), 'secondary')),
    ) : null,
  );
}

function requestList(requests, selectedDigest, select) {
  return panel('My requests', 'Tasks you have asked the collective to complete.',
    requests.length ? element('ul', { className: 'request-list' }, ...requests.map((task) => element('li', { className: task.task_digest === selectedDigest ? 'selected' : '' },
      element('button', { type: 'button', className: 'request-select', onclick: () => select(task.task_digest) }, element('span', { text: task.display_id || 'Untitled task' }), statusChip(task.status), element('small', { text: task.published_at ? formatDate(task.published_at) : 'Recently submitted' })),
    ))) : element('div', { className: 'empty-state' }, element('strong', { text: 'No requests yet.' }), element('p', { text: 'Submit a task and its status, result, and receipt will stay here.' })),
  );
}

function submitForm(submit, formState) {
  let feedback;
  const edited = () => { formState.error = ''; if (feedback) feedback.textContent = ''; };
  const name = element('input', { id: 'task-name', required: true, value: formState.display_id, placeholder: 'e.g. repair-login-test', oninput: (event) => { formState.display_id = event.target.value; edited(); } });
  const prompt = element('textarea', { id: 'task-prompt', required: true, placeholder: 'Describe the outcome you need.', oninput: (event) => { formState.prompt = event.target.value; edited(); } }, formState.prompt);
  const folder = element('input', { id: 'task-folder', value: formState.source, placeholder: '/path/to/project (optional)', oninput: (event) => { formState.source = event.target.value; edited(); } });
  feedback = element('p', { className: 'form-feedback', role: 'alert', text: formState.error });
  const form = element('form', { className: 'submit-form', onsubmit: async (event) => {
    event.preventDefault();
    formState.error = '';
    if (!formState.display_id.trim() || !formState.prompt.trim()) {
      formState.error = 'Please enter a task name and what should be done.';
      feedback.textContent = formState.error;
      return;
    }
    try { await submit({ display_id: formState.display_id, prompt: formState.prompt, source: formState.source }); }
    catch (error) { formState.error = error.message; feedback.textContent = formState.error; }
  } },
    element('label', { for: 'task-name', text: 'Task name' }), name,
    element('label', { for: 'task-prompt', text: 'What should be done' }), prompt,
    element('label', { for: 'task-folder', text: 'Folder on this computer (optional)' }), folder,
    element('p', { className: 'field-help', text: 'Without a folder, the task starts in an empty workspace.' }), feedback,
    element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Submit task' })),
  );
  return panel('Submit a request', 'Describe the outcome for your collective.', form);
}

function requestsView(requests, selectedDigest, selectedTask, submit, select, resultHref, formState) {
  return element('div', { className: 'view-stack' }, submitForm(submit, formState), requestList(requests, selectedDigest, select), taskDetail(selectedTask, selectedDigest, resultHref));
}

function activityDetail(entry) {
  if (!entry) return null;
  const receipt = entry.receipt || entry;
  return panel(entry.display_id || entry.task_name || 'Contribution detail', 'Usage as reported by the agent (Claude Code).',
    element('p', { className: 'detail', text: labeledDate('Started', entry.started_at || receipt.started_at) }),
    element('p', { className: 'detail', text: labeledDate('Finished', entry.finished_at || entry.settled_at || receipt.finished_at) }),
    element('p', { className: 'detail', text: `Duration: ${formatDuration(entry.duration || receipt.duration || receipt.duration_ms)}` }),
    element('p', { className: 'detail', text: `Models (combined): ${entry.model || receipt.model || 'Not reported'}` }),
    element('p', { className: 'detail', text: `Usage (combined): ${entry.tokens || tokenUsage(receipt) || 'Not reported'}` }),
    element('p', { className: 'detail', text: `Requester: ${entry.requester || entry.author || entry.author_key || 'Not reported'}` }),
    element('p', { className: 'detail', text: `Task: ${entry.display_id || entry.task_name || 'Federation task'}` }),
  );
}

function activityView(ledger, requests, select, selectedContribution, selectContribution) {
  const contributionRows = ledger.filter((entry) => entry.role !== 'requester' && entry.author !== 'me');
  const contributionList = contributionRows.length
    ? element('ul', { className: 'history-list' }, ...contributionRows.map((entry) => element('li', {},
      element('button', { type: 'button', className: 'history-select', onclick: () => selectContribution(entry) },
        element('strong', { text: entry.display_id || entry.task_name || 'Federation task' }),
        element('span', { className: 'muted', text: labeledDate('Finished', entry.finished_at || entry.settled_at) }),
        element('span', { className: 'history-meta', text: [entry.duration, entry.model || entry.receipt?.model, entry.tokens || tokenUsage(entry.receipt || entry)].filter(Boolean).join(' · ') || 'Receipt pending' }),
      ),
    )))
    : element('div', { className: 'empty-state' }, element('strong', { text: 'Your contribution history will appear here.' }));
  return element('div', { className: 'view-stack' },
    panel('Contribution history', 'Private receipts for completed work.', contributionList),
    activityDetail(selectedContribution),
    panel('Requester history', 'Requests and results.', requests.length ? element('ul', { className: 'history-list' }, ...requests.map((entry) => element('li', {}, element('button', { type: 'button', className: 'text-button', onclick: () => select(entry.task_digest), text: entry.display_id || 'Untitled task' }), statusChip(entry.status)))) : element('div', { className: 'empty-state' }, element('strong', { text: 'No requester activity yet.' }))),
  );
}

function providerSignInCard(status) {
  const action = status?.action;
  if (status?.state !== 'action_needed' || action?.kind !== 'awaiting_browser' || !action.service) return null;
  return panel(`Sign in to ${action.service}`, 'Finish this step in your browser.',
    button(action.code ? 'Open sign-in' : 'Open sign-in', () => window.open(action.url, '_blank', 'noopener')),
    action.code ? element('p', { className: 'detail', text: `Confirmation code: ${action.code}` }) : null,
  );
}

function settingsView(identity, settings, roster, saveSettings, signIn, status) {
  const schedule = settings?.schedule || {};
  const collectiveName = element('input', { id: 'collective-name', value: settings?.collective_name || identity?.collective_name || '', placeholder: 'Your collective' });
  const enabled = element('input', { id: 'schedule-enabled', type: 'checkbox', checked: Boolean(schedule.enabled) });
  const start = element('input', { id: 'schedule-start', type: 'time', value: schedule.start || '' });
  const end = element('input', { id: 'schedule-end', type: 'time', value: schedule.end || '' });
  const days = element('input', { id: 'schedule-days', placeholder: 'Every day', value: schedule.days || '' });
  const feedback = element('p', { className: 'form-feedback', role: 'alert' });
  const scheduleForm = element('form', { onsubmit: async (event) => { event.preventDefault(); feedback.textContent = ''; try { await saveSettings({ collective_name: collectiveName.value, schedule: { enabled: enabled.checked, start: start.value, end: end.value, days: days.value } }); } catch (error) { feedback.textContent = error.message; } } },
    element('label', { for: 'collective-name', text: 'Collective name' }), collectiveName,
    element('p', { className: 'field-help', text: 'Shown only on this machine.' }),
    element('label', { className: 'check-label', for: 'schedule-enabled' }, enabled, document.createTextNode(' Use a contribution schedule')),
    element('div', { className: 'schedule-grid' }, element('div', {}, element('label', { for: 'schedule-start', text: 'Start' }), start), element('div', {}, element('label', { for: 'schedule-end', text: 'End' }), end), element('div', {}, element('label', { for: 'schedule-days', text: 'Days' }), days)),
    feedback, element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Save schedule' })),
  );
  const accounts = providerAccounts(identity);
  const providerRows = accounts.flatMap((account) => {
    const service = account.provider || account.service || account.name || 'Provider';
    const unauthenticated = (account.authenticated ?? account.authed) === false;
    return [
      element('dt', { text: service }),
      element('dd', {},
        element('span', { text: [account.email || account.account_email, account.tier, unauthenticated ? 'needs sign-in' : 'signed in'].filter(Boolean).join(' · ') }),
        unauthenticated ? button('Sign in', () => signIn(account.service || account.provider), 'secondary') : String(service).toLowerCase().includes('anthropic') ? element('p', { className: 'field-help', text: 'Managed automatically by Waspflow.' }) : null,
      ),
      element('dt', { text: 'Capacity source' }),
      element('dd', { text: readableCapacityKind(capacityKind(account)) }),
    ];
  });
  return element('div', { className: 'view-stack' },
    providerSignInCard(status),
    panel('Accounts in use', 'The identities this machine uses.',
      element('dl', { className: 'identity-list' },
        element('dt', { text: 'Docker account' }), element('dd', {}, element('span', { text: identity?.docker?.email || identity?.docker_account || 'Not reported yet' }), element('p', { className: 'field-help', text: 'Used to run isolated task sandboxes.' })),
        element('dt', { text: 'Member ID' }), element('dd', {}, element('span', { text: identity?.key_id || 'Not reported yet' }), element('p', { className: 'field-help', text: 'How the collective recognizes your machine.' })),
        identity?.coordinator_url ? [element('dt', { text: 'Connection address' }), element('dd', {}, element('span', { text: identity.coordinator_url }), element('p', { className: 'field-help', text: 'Where this machine checks for collective work.' }))] : null,
        ...providerRows,
      ),
    ),
    panel('Limit to certain hours (optional)', 'Pause is always available immediately.', scheduleForm),
    panel('Collective roster', 'Approved members.', roster?.length ? element('ul', { className: 'roster-list' }, ...roster.map((member) => element('li', {}, element('strong', { text: member.name || member.key_id || 'Member' }), element('code', { text: member.key_id || member.public_key_pem || '' })))) : element('div', { className: 'empty-state' }, element('strong', { text: 'Roster unavailable.' }))),
  );
}

function helpView(identity) {
  const capacitySubject = providerCapacitySubject(identity);
  return element('div', { className: 'view-stack' },
    panel('How Federation works', 'A trusted collective shares spare capacity without sharing your computer.', element('ol', { className: 'manual-steps' }, element('li', { text: 'A requester packages one chosen folder and describes the work.' }), element('li', { text: 'A contributor accepts a task only when contributing is on.' }), element('li', { text: 'The task runs in an isolated Docker sandbox and returns a receipt and result.' }))),
    panel('Your safety boundary', 'Three things to know before you contribute.', element('div', { className: 'safety-copy' }, element('p', { text: `Tasks run inside an isolated Docker sandbox on your machine. The sandbox can use ${capacitySubject} to do the work, but it cannot see anything else on your computer.` }), element('p', { text: 'Shared in: only the task folder and instructions you choose. Not touched: your other projects, accounts, or personal files.' }), element('p', { text: 'Everything else is blocked: the sandbox cannot read your other files, cannot reach your home network, and cannot see other tasks.' }))),
    panel('Questions people ask', null, element('div', { className: 'faq' }, element('details', { open: true }, element('summary', { text: 'What runs where?' }), element('p', { text: 'The selected task runs in a Docker sandbox on the contributor’s machine. The requester gets the result and shared execution metadata.' })), element('details', {}, element('summary', { text: 'Whose account is used?' }), element('p', { text: `${capacitySubject} is used only inside the contributor’s isolated Federation environment. Account identities are private to that contributor.` })), element('details', {}, element('summary', { text: 'How do I stop?' }), element('p', { text: 'Use Pause contributing at any time. Nothing new starts while paused.' })), element('details', {}, element('summary', { text: 'What can a task see?' }), element('p', { text: 'Only the folder and instructions the requester deliberately supplied. It cannot see other files, your home network, or other tasks.' })))),
  );
}

function createApplication(root) {
  const token = new URLSearchParams(window.location.search).get('token');
  let status = null; let availableTasks = []; let ledger = []; let requests = []; let identity = null; let settings = null; let roster = []; let selectedDigest = null; let selectedTask = null; let selectedContribution = null; let message = ''; let pollBusy = false; let lastRenderSignature = null;
  const requestForm = { display_id: '', prompt: '', source: '', error: '' };
  const failedRequests = new Map();

  async function request(path, options = {}) {
    if (!token) throw new Error('This link is missing its Waspflow session token. Open Federation again from Waspflow.');
    const response = await fetch(path, { ...options, headers: { 'x-waspflow-session-token': token, ...(options.body ? { 'content-type': 'application/json' } : {}) } });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error || 'Waspflow could not complete that request.');
    return body;
  }

  async function optionalRequest(path, fallback) {
    const failure = failedRequests.get(path);
    if (failure && Date.now() < failure.nextAttemptAt) return fallback;
    try {
      const result = await request(path);
      failedRequests.delete(path);
      return result;
    } catch {
      const attempts = (failure?.attempts || 0) + 1;
      failedRequests.set(path, { attempts, nextAttemptAt: Date.now() + Math.min(30_000, 1_500 * (2 ** attempts)) });
      return fallback;
    }
  }
  async function control(path, body) { message = ''; try { status = await request(path, { method: 'POST', body: body ? JSON.stringify(body) : undefined }); } catch (error) { message = error.message; } render(); }
  async function submit(body) { const result = await request('/submit', { method: 'POST', body: JSON.stringify(body) }); requestForm.display_id = ''; requestForm.prompt = ''; requestForm.source = ''; requestForm.error = ''; status = result; selectedDigest = /^sha256:[a-f0-9]{64}$/i.test(result.submission?.task_digest || '') ? result.submission.task_digest : selectedDigest; window.location.hash = '#/requests'; render(); }
  async function saveSettings(body) { settings = await request('/settings', { method: 'POST', body: JSON.stringify(body) }); render(); }
  async function signIn(service) { message = ''; try { status = await request('/identity/signin', { method: 'POST', body: JSON.stringify({ service }) }); } catch (error) { message = error.message; } render(); }
  function select(digest) { selectedDigest = digest; selectedTask = null; window.location.hash = '#/requests'; void refreshTask(); render(); }
  function selectContribution(entry) { selectedContribution = entry; render(); }
  async function refreshTask() { if (!selectedDigest || !/^sha256:[a-f0-9]{64}$/i.test(selectedDigest)) return; selectedTask = await optionalRequest(`/tasks/${encodeURIComponent(selectedDigest.replace(/^sha256:/, ''))}`, null) || await optionalRequest(`/submit/status?task_digest=${encodeURIComponent(selectedDigest)}`, null); render(); }
  function requesterEntries(entries, localIdentity) {
    return entries.filter((entry) => entry.author === 'me' || entry.role === 'requester' || entry.requester === true
      || (localIdentity && (entry.author_key === localIdentity || entry.author === localIdentity)));
  }
  async function refresh() {
    if (pollBusy) return; pollBusy = true;
    try {
      status = await request('/status');
      const coordinatorReady = ['idle', 'paused', 'contributing'].includes(status.state);
      const baseRequests = coordinatorReady ? await optionalRequest('/requests', null) : null;
      const data = await Promise.all([
        status.state === 'idle' ? optionalRequest('/tasks', []) : Promise.resolve([]), optionalRequest('/ledger', []), optionalRequest('/identity', null), optionalRequest('/settings', null), coordinatorReady ? optionalRequest('/roster', []) : Promise.resolve([]),
      ]);
      availableTasks = data[0]; ledger = Array.isArray(data[1]) ? data[1] : []; identity = data[2] || { key_id: status.key_id, coordinator_url: status.coordinator_url, collective_name: status.collective_name }; settings = data[3]; roster = Array.isArray(data[4]?.roster) ? data[4].roster : Array.isArray(data[4]) ? data[4] : [];
      requests = Array.isArray(baseRequests) ? baseRequests : requesterEntries(ledger, identity?.key_id);
      const submission = status.submission;
      if (submission?.task_digest && /^sha256:[a-f0-9]{64}$/i.test(submission.task_digest) && !selectedDigest) selectedDigest = submission.task_digest;
      if (selectedDigest) void refreshTask();
      message = '';
    } catch (error) { message = error.message === 'Failed to fetch' ? 'Waspflow is not running. Open Federation again from Waspflow.' : error.message; }
    finally { pollBusy = false; render(); }
  }
  function render() {
    const active = routeFromHash(window.location.hash); const view = viewForStatus(status);
    const content = [header(active), banner(message), element('section', { className: 'content' })]; const main = content.at(-1);
    if (active === 'contribute') main.append(contributeView(status, availableTasks, view, control, settings));
    else if (active === 'requests') {
      const resultHref = selectedDigest ? `/result/${encodeURIComponent(selectedDigest)}?token=${encodeURIComponent(token || '')}` : '#/requests';
      main.append(requestsView(requests, selectedDigest, selectedTask, submit, select, resultHref, requestForm));
    }
    else if (active === 'activity') main.append(activityView(ledger, requests, select, selectedContribution, selectContribution));
    else if (active === 'settings') main.append(settingsView(identity, settings, roster, saveSettings, signIn, status));
    else main.append(helpView(identity));
    const signature = JSON.stringify({ active, status, availableTasks, ledger, requests, identity, settings, roster, selectedDigest, selectedTask, message });
    if (signature === lastRenderSignature) return; lastRenderSignature = signature; root.replaceChildren(...content.filter(Boolean));
  }
  window.addEventListener('hashchange', render); render(); void refresh(); window.setInterval(refresh, POLL_INTERVAL_MS);
}

if (typeof document !== 'undefined') createApplication(document.getElementById('app'));
