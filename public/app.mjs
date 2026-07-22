const POLL_INTERVAL_MS = 1500;
const SESSION_EXPIRED_MESSAGE = 'This local link has expired; no task or account change was made.';
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
  if (status.state === 'approval_revoked') return { name: 'approval_revoked' };
  if (status.state === 'action_needed') return { name: 'action', action: status.action || {} };
  if (status.state === 'setup_required') return { name: 'setup', checks: status.action?.checks || [] };
  const names = { contributing: 'Contributing', pausing: 'Pausing after current task…', paused: 'Paused', idle: 'Ready when you are' };
  return { name: 'status', title: names[status.state] || 'Checking status', control: ['contributing', 'pausing'].includes(status.state) ? 'pause' : 'start' };
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
  const normalized = String(value || 'not reported').replace(/[_-]+/g, ' ').toLowerCase();
  if (normalized === 'api key') return 'API key';
  return normalized.replace(/\b\w/g, (character) => character.toUpperCase());
}

export function providerDisplayName(value) {
  const provider = String(value || 'provider').trim();
  const names = {
    anthropic: 'Anthropic (Claude)',
    claude: 'Anthropic (Claude)',
    openai: 'OpenAI',
    github: 'GitHub',
    google: 'Google',
  };
  return names[provider.toLowerCase()] || provider;
}

export function providerCapacitySubject(identity) {
  const account = providerAccounts(identity)[0];
  if (!account) return 'your configured provider account';
  const provider = providerDisplayName(account.provider || account.service || account.name);
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

function promptFirstLine(prompt) {
  const first = String(prompt || '').split(/\r?\n/).map((line) => line.trim()).find(Boolean);
  return first || 'Prompt preview is not available.';
}

function reconnectFederation() {
  window.location.href = 'waspflow://federation/reconnect';
}

function copyText(value) {
  if (value) void navigator.clipboard?.writeText(value);
}

function oneTimeCode(value) {
  const code = element('code', { className: 'one-time-code', text: value, tabindex: '0', onclick: () => {
    const range = document.createRange(); range.selectNodeContents(code);
    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    copyText(value);
  } });
  return element('span', { className: 'one-time-code-wrap' }, code, button('Copy code', () => { code.click(); }, 'secondary'));
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
  return [element('a', { className: 'skip-link', href: '#main-content', text: 'Skip to content' }), element('header', { className: 'app-header' },
    element('a', { className: 'brand', href: '#/contribute' }, element('span', { className: 'brand-mark', text: 'W' }), element('span', { text: 'Waspflow Federation' })), nav,
  )];
}

function banner(message) {
  return message ? element('div', { className: 'notice', role: 'alert', text: message }) : null;
}

function contributionDetail(status, view) {
  const activeTask = status?.contribution?.display_id;
  const requester = status?.contribution?.requester || status?.contribution?.author;
  const completion = status?.last_completed?.display_id;
  if (view.control === 'pause' && activeTask) return `Working on '${activeTask}'${requester ? ` for ${requester}` : ''}`;
  if (status?.state === 'idle' && completion) return `Last completed '${completion}'.`;
  return status?.state === 'idle' ? '' : status?.detail || 'Waspflow checks for a safe next task.';
}

function guardCopy(settings) {
  return `You approve every task before it runs. Pause anytime.${settings?.schedule?.enabled ? ' · Limited to your schedule.' : ''}`;
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
    status?.coordinator_unavailable ? element('p', { className: 'notice inline-notice', role: 'status', text: 'Your collective is unreachable right now — approval will refresh when it returns.' }) : null,
    status?.collective_name ? element('p', { text: `You’re joining ${status.collective_name}.` }) : null,
    element('p', { className: 'muted', text: status?.detail || 'No task can start until approval is granted.' }),
  );
  if (view.name === 'approval_revoked') return panel('Approval was revoked', 'No new work will start on this machine.',
    element('p', { className: 'detail', text: status?.detail || 'Your collective owner needs to approve this machine again.' }),
    button('Refresh approval', () => window.location.reload()),
  );
  if (view.name === 'setup') return panel('Your sandbox needs attention', 'Complete this once, then come back to contribute.',
    element('ol', { className: 'manual-steps' }, ...(view.checks.length ? view.checks.map((check) => element('li', { text: `${check.detail || check.name}. ${check.fix || ''}` })) : [element('li', { text: 'Run waspflow federation doctor for the exact repair.' })])),
    element('p', { className: 'detail', text: status?.detail || '' }),
  );
  const browserAction = view.action?.kind === 'awaiting_browser';
  const provider = providerDisplayName(view.action?.service || status?.contribution?.provider || 'your provider');
  const githubTaskAccess = String(view.action?.service || '').toLowerCase() === 'github';
  return panel(browserAction ? `Sign in to ${provider}` : 'Sign-in needs support', browserAction ? githubTaskAccess ? 'Connect GitHub task access under Federation’s isolated identity.' : 'Finish this one browser step, then return here to see whether the same task can resume.' : 'This provider cannot complete sign-in in Federation yet.',
    element('p', { text: browserAction ? githubTaskAccess ? 'This access is used only for private Git repository tasks. Waspflow will show the result here after you finish.' : `This affects ${status?.contribution?.display_id || 'your pending contribution'}. Waspflow will show the result here after you finish.` : 'No task will resume automatically. Use a provider with browser sign-in, or ask your collective owner to enable this account.' }),
    browserAction ? button(`Sign in to ${provider}`, () => window.open(view.action?.url, '_blank', 'noopener')) : null,
    view.action?.code ? element('p', { className: 'detail' }, document.createTextNode('Confirmation code: '), oneTimeCode(view.action.code)) : null,
  );
}

function contributionStatus(status, view, control, settings, coordinatorUnavailable, showStopNow, setShowStopNow, watchTask) {
  const isContributing = view.control === 'pause';
  const controlLabel = isContributing ? 'Pause after current task' : status?.state === 'paused' ? 'Choose a task to resume' : 'Choose a task below';
  const count = status?.ledger_summary?.count_7d || 0;
  const collectiveName = settings?.collective_name || status?.collective_name;
  const completion = status?.last_completed?.display_id;
  const detail = contributionDetail(status, view);
  return panel('Your contribution', null,
    collectiveName ? element('p', { className: 'collective-line', text: `Collective: ${collectiveName}` }) : null,
    element('div', { className: 'contribution-state' },
      element('div', { className: 'status-dot', 'data-live': 'contribution-dot', 'data-state': status?.state || 'idle' }),
      element('div', {}, element('p', { className: 'status-label', 'data-live': 'contribution-title', text: view.title }), element('p', { className: 'detail', 'data-live': 'contribution-detail', hidden: !detail, text: detail })),
    ),
    coordinatorUnavailable ? element('p', { className: 'notice inline-notice', role: 'status', text: 'Your collective is unreachable right now — tasks will resume when it returns.' }) : null,
    element('div', { className: 'actions' }, button(controlLabel, () => isContributing && control('/contribute/pause'), isContributing ? 'secondary' : '', { disabled: !isContributing })),
    isContributing && status?.contribution?.task_digest ? element('a', { className: 'button-link secondary', href: '#/requests', onclick: () => watchTask?.(status.contribution.task_digest), text: 'Watch live' }) : null,
    isContributing ? element('div', { className: 'stop-now' },
      showStopNow
        ? [element('p', { className: 'detail', text: 'Stop now abandons the current task. Waspflow records it as returned; requester confirmation is not available yet.' }), button('Stop now', () => control('/contribute/stop', { confirm: true }), 'secondary'), button('Keep working', () => setShowStopNow(false), 'secondary')]
        : button('Stop now', () => setShowStopNow(true), 'secondary'),
    ) : null,
    !isContributing && (completion ? element('a', { className: 'ledger-link', href: '#/activity', text: `Finished '${completion}' · View activity` }) : element('a', { className: 'ledger-link', href: '#/activity', text: `${count} completed this week · View activity` })),
    element('div', { className: 'guard' }, element('strong', { 'data-live': 'guard-copy', text: guardCopy(settings) })),
  );
}

function taskRequirementChips(task) {
  const chips = [];
  if (task?.github_access_required || task?.git_source?.authentication_required) chips.push(element('span', { className: 'receipt-chip', text: 'Needs: GitHub' }));
  if (task?.network === 'enabled' || task?.git_source) chips.push(element('span', { className: 'receipt-chip', text: 'Needs: internet' }));
  return chips.length ? element('div', { className: 'receipt-chips', 'aria-label': 'Task requirements' }, ...chips) : null;
}

function taskChoices(tasks, identity, contribute, setUpGitHub, pendingNext, setPendingNext) {
  const choices = Array.isArray(tasks) ? tasks : [];
  if (!choices.length) {
    return element('p', { className: 'task-queue-empty', text: 'No tasks are waiting right now. Nothing will run automatically.' });
  }
  const nextTask = pendingNext || choices[0];
  return panel('Choose a task', 'Pick a request that suits your capacity.',
    pendingNext ? panel('Review this task', 'Nothing runs until you approve.',
      element('p', { text: `Task: ${nextTask.display_id || 'Untitled task'}` }),
      element('p', { text: `From: ${nextTask.author || 'Unknown requester'}` }),
      element('p', { className: 'prompt-preview', text: `Prompt: ${promptFirstLine(nextTask.prompt_preview || nextTask.prompt)}` }),
      taskRequirementChips(nextTask),
      element('div', { className: 'actions' }, nextTask.git_source?.authentication_required && !identity?.providers?.some((provider) => provider.service === 'github' && provider.authed)
        ? button('Set up GitHub access', setUpGitHub)
        : button('Run this', () => contribute(nextTask.task_digest)), button('Skip', () => setPendingNext(null), 'secondary')),
    ) : element('div', { className: 'actions' }, button('Contribute next available', () => setPendingNext(nextTask), 'secondary')),
    element('ul', { className: 'task-list', 'aria-label': 'Available tasks' }, ...choices.map((task) => element('li', { className: 'task-row' },
      element('div', { className: 'task-main' },
        element('div', { className: 'task-title' }, element('strong', { text: task.display_id || 'Untitled task' }), task.author ? element('span', { className: 'muted', text: `by ${task.author}` }) : null),
        element('p', { className: 'muted', text: taskAge(task.published_at) }),
        element('p', { className: 'prompt-preview', text: `Prompt: ${promptFirstLine(task.prompt_preview || task.prompt)}` }),
        task.network !== undefined ? element('p', { className: 'network', text: `Internet access: ${task.network === 'enabled' ? 'on' : 'off'}` }) : null,
        taskRequirementChips(task),
      ),
      task.git_source?.authentication_required && !identity?.providers?.some((provider) => provider.service === 'github' && provider.authed)
        ? button('Set up GitHub access', setUpGitHub, 'secondary')
        : button('Contribute this', () => contribute(task.task_digest), 'secondary'),
    ))),
  );
}

function contributeView(status, tasks, identity, view, control, settings, coordinatorUnavailable, pendingNext, setPendingNext, showStopNow, setShowStopNow, watchTask, setUpGitHub) {
  if (view.name !== 'status') return authOrJoinView(view, status, control);
  return element('div', { className: 'view-stack' }, contributionStatus(status, view, control, settings, coordinatorUnavailable, showStopNow, setShowStopNow, watchTask), status?.state === 'idle' && !coordinatorUnavailable ? taskChoices(tasks, identity, (digest) => control('/contribute/start', { task_digest: digest }), setUpGitHub, pendingNext, setPendingNext) : null);
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

function executionLogPanel(log) {
  if (!log) return null;
  return panel('Execution log', log.truncated ? 'Earlier output was truncated to keep this local log bounded.' : 'Captured from the task harness on this machine.',
    element('pre', { className: 'execution-log', text: log.output || 'No output was captured.' }),
  );
}

function transcriptEntries(log) {
  return String(log?.output || '').split(/\r?\n/).filter(Boolean).map((raw) => {
    try {
      const event = JSON.parse(raw);
      const message = event.message?.content || event.message?.text || event.content || event.result || event.text;
      const tool = event.tool_name || event.name || event.tool_use?.name || event.tool?.name;
      const args = event.input || event.tool_use?.input || event.arguments;
      return { raw, role: event.type === 'assistant' || event.message?.role === 'assistant' ? 'Assistant' : tool ? 'Tool' : event.type || 'Event', message: typeof message === 'string' ? message : '', tool, args };
    } catch { return { raw, role: 'Output', message: raw }; }
  });
}

function transcriptPanel(log) {
  if (!log) return null;
  const raw = element('pre', { className: 'execution-log', text: log.output || 'No transcript events yet.' });
  raw.hidden = true;
  const entries = transcriptEntries(log);
  const readable = element('div', { className: 'transcript-list' }, ...entries.map((entry) => entry.tool
    ? element('details', { className: 'transcript-tool' }, element('summary', { text: `Tool · ${entry.tool}` }), element('pre', { className: 'execution-log', text: JSON.stringify(entry.args || entry.raw).slice(0, 1600) }))
    : element('article', { className: 'transcript-turn' }, element('strong', { className: 'transcript-role', text: entry.role }), element('p', { text: entry.message || 'Structured event' }))));
  const toggle = button('Raw JSON', () => { raw.hidden = !raw.hidden; readable.hidden = !readable.hidden; toggle.textContent = raw.hidden ? 'Raw JSON' : 'Readable transcript'; }, 'secondary');
  return panel('Transcript', log.truncated ? 'Transcript capture reached its 2 MB limit.' : 'Agent-native assistant turns and tool calls captured on this machine.', toggle, readable, raw);
}

function taskDetail(task, selectedDigest, resultHref, executionLog, loadExecutionLog) {
  if (!selectedDigest || !/^sha256:[a-f0-9]{64}$/i.test(selectedDigest)) return null;
  const detail = task || { task_digest: selectedDigest, status: 'queued' };
  const result = detail.result_address || detail.result_ref || detail.status?.toLowerCase?.() === 'settled';
  return element('div', { className: 'view-stack' },
    panel(detail.display_id || 'Task detail', detail.author ? `Requested by ${detail.author}` : 'Request lifecycle and receipt.',
      timeline(detail),
      taskRequirementChips(detail),
      element('p', { className: 'detail', text: labeledDate('Started', detail.started_at || detail.running_at || detail.claimed_at) }),
      element('p', { className: 'detail', text: labeledDate('Finished', detail.finished_at || detail.settled_at) }),
      element('p', { className: 'detail', text: `Duration: ${formatDuration(detail.duration || detail.execution_metadata?.duration_ms)}` }),
      element('h3', { text: 'What should be done' }), element('p', { className: 'prompt-detail', text: detail.prompt || detail.description || 'Task details are loading from the coordinator.' }),
      detail.source ? element('p', { className: 'detail', text: `Source: ${typeof detail.source === 'string' ? detail.source : detail.source.name || 'Task source'}` }) : null,
    ),
    panel('Execution receipt', 'Shared execution metadata never includes the contributor’s account identities.', receipt(detail)),
    panel('Execution transcript', 'This local daemon keeps the agent-native transcript for tasks it ran.',
      button('View execution log', () => loadExecutionLog(selectedDigest), 'secondary'),
      detail.execution_log_available === false ? element('p', { className: 'field-help', text: 'This task did not run on this machine, so its local execution log is unavailable here.' }) : null,
    ),
    transcriptPanel(executionLog),
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

function submitForm(submit, formState, probeGit, refreshForm) {
  let feedback;
  const edited = () => { formState.error = ''; if (feedback) feedback.textContent = ''; };
  const name = element('input', { id: 'task-name', required: true, value: formState.display_id, placeholder: 'Fix the login test', oninput: (event) => { formState.display_id = event.target.value; edited(); } });
  const prompt = element('textarea', { id: 'task-prompt', required: true, placeholder: 'Describe the outcome you need.', oninput: (event) => { formState.prompt = event.target.value; edited(); } }, formState.prompt);
  const folder = element('input', { id: 'task-folder', value: formState.source, placeholder: '/path/to/project (optional)', oninput: (event) => { formState.source = event.target.value; edited(); } });
  const gitUrl = element('input', { id: 'task-git-url', value: formState.git_url, placeholder: 'https://github.com/owner/repository.git', oninput: (event) => { formState.git_url = event.target.value; formState.git_probe = ''; edited(); }, onchange: async () => {
    if (!formState.git_url.trim()) return;
    try { const result = await probeGit(formState.git_url); formState.git_probe = result.visibility; formState.github_access_required = Boolean(result.github_access_required); refreshForm(); }
    catch (error) { formState.git_probe = 'private_or_unreachable'; formState.github_access_required = true; formState.error = error.message; refreshForm(); }
  } });
  const gitRef = element('input', { id: 'task-git-ref', value: formState.git_ref, placeholder: 'main (optional)', oninput: (event) => { formState.git_ref = event.target.value; edited(); } });
  const githubAccess = element('input', { id: 'task-github-access', type: 'checkbox', checked: Boolean(formState.github_access_required), onchange: (event) => { formState.github_access_required = event.target.checked; edited(); } });
  const addFiles = element('input', { id: 'task-files', type: 'file', multiple: true, onchange: (event) => { formState.files = [...formState.files, ...Array.from(event.target.files || [])]; edited(); refreshForm(); } });
  const addFolder = element('input', { id: 'task-folder-upload', type: 'file', multiple: true, webkitdirectory: true, onchange: (event) => { formState.files = [...formState.files, ...Array.from(event.target.files || [])]; edited(); refreshForm(); } });
  const dropZone = element('div', { className: 'drop-zone', tabindex: '0', text: 'Drag files or folders here', ondragover: (event) => event.preventDefault(), ondrop: (event) => { event.preventDefault(); formState.files = [...formState.files, ...Array.from(event.dataTransfer?.files || [])]; edited(); refreshForm(); } });
  const network = element('input', { id: 'task-network', type: 'checkbox', checked: Boolean(formState.git_url || formState.network), disabled: Boolean(formState.git_url), onchange: (event) => { formState.network = event.target.checked; edited(); } });
  feedback = element('p', { className: 'form-feedback', role: 'alert', text: formState.error });
  const form = element('form', { className: 'submit-form', onsubmit: async (event) => {
    event.preventDefault();
    formState.error = '';
    if (!formState.display_id.trim() || !formState.prompt.trim()) {
      formState.error = 'Please enter a task name and what should be done.';
      feedback.textContent = formState.error;
      return;
    }
    try {
      const attachments = await Promise.all((formState.files || []).map(async (file) => {
        const bytes = new Uint8Array(await file.arrayBuffer());
        let binary = '';
        for (let offset = 0; offset < bytes.length; offset += 0x8000) binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
        return { name: file.name, relative_path: file.webkitRelativePath || file.name, data_base64: btoa(binary) };
      }));
      const bytes = attachments.reduce((sum, file) => sum + Math.floor(file.data_base64.length * 3 / 4), 0);
      if (bytes > 20 * 1024 * 1024) throw new Error('Attachments are limited to 20 MB. Choose fewer or smaller files.');
      await submit({ display_id: formState.display_id, prompt: formState.prompt, source: formState.source, attachments, git_url: formState.git_url, git_ref: formState.git_ref, github_access_required: formState.github_access_required, network: formState.git_url ? 'enabled' : formState.network ? 'enabled' : 'disabled' });
    }
    catch (error) { formState.error = error.message; feedback.textContent = formState.error; }
  } },
    element('label', { for: 'task-name', text: 'Task name' }), name,
    element('label', { for: 'task-prompt', text: 'What should be done' }), prompt,
    element('label', { for: 'task-files', text: 'Add files (optional)' }), addFiles,
    element('label', { for: 'task-folder-upload', text: 'Add folder (optional)' }), addFolder, dropZone,
    formState.files.length ? element('ul', { className: 'attachment-list' }, ...formState.files.map((file, index) => element('li', {}, element('span', { text: `${file.webkitRelativePath || file.name} (${file.size.toLocaleString()} bytes)` }), button('Remove', () => { formState.files.splice(index, 1); refreshForm(); }, 'secondary')))) : null,
    element('p', { className: 'field-help', text: 'Attach the files the task should work on (optional — leave empty to start from scratch).' }),
    element('details', {}, element('summary', { text: 'Advanced' }), element('label', { for: 'task-folder', text: 'Local folder path' }), folder, element('p', { className: 'field-help', text: 'Use a folder already on this computer (where Waspflow runs) instead of uploading.' })),
    element('label', { for: 'task-git-url', text: 'Git repository (optional)' }), gitUrl,
    element('label', { for: 'task-git-ref', text: 'Branch or ref (optional)' }), gitRef,
    formState.git_probe === 'public' ? element('p', { className: 'field-help', text: 'Public repository — no GitHub sign-in is required.' }) : formState.git_probe === 'private_or_unreachable' ? element('p', { className: 'notice inline-notice', text: 'Private repository — GitHub sign-in will be used.' }) : null,
    element('label', { className: 'check-label', for: 'task-github-access' }, githubAccess, document.createTextNode(' Task needs GitHub access')),
    element('p', { className: 'field-help', text: 'Use this for GitHub organization or discovery work even when there is no repository source.' }),
    element('label', { className: 'check-label', for: 'task-network' }, network, document.createTextNode(' Allow internet access')),
    element('p', { className: 'field-help', text: formState.git_url ? 'Network access is required and locked on because Waspflow must clone the Git repository inside the contributor sandbox.' : 'When on, tasks can fetch public resources.' }),
    element('p', { className: 'quiet-note', text: 'GitHub access is task access, not contribution capacity. The credential stays behind the sandbox proxy.' }), feedback,
    element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Submit task' })),
  );
  return panel('Submit a request', 'Describe the outcome for your collective.', form);
}

function submissionStatus(submission, acknowledge) {
  if (!submission) return null;
  const label = submission.state === 'published' ? 'Published ✓' : String(submission.state || 'pending').replace(/_/g, ' ');
  return panel('Submission status', null, element('p', { className: submission.state === 'failed' ? 'notice inline-notice' : 'detail', text: `${label}: ${submission.reason || submission.detail}` }), button('Acknowledge', acknowledge, 'secondary'));
}

function requestsView(requests, selectedDigest, selectedTask, submit, select, resultHref, formState, executionLog, loadExecutionLog, submission, acknowledge, probeGit, refreshForm) {
  return element('div', { className: 'view-stack' }, submissionStatus(submission, acknowledge), submitForm(submit, formState, probeGit, refreshForm), requestList(requests, selectedDigest, select), taskDetail(selectedTask, selectedDigest, resultHref, executionLog, loadExecutionLog));
}

function activityDetail(entry, executionLog, loadExecutionLog) {
  if (!entry) return null;
  const receipt = entry.receipt || entry;
  const unavailable = (label, value) => value ? String(value) : `${label} unavailable for this legacy task.`;
  return panel(entry.display_id || entry.task_name || 'Contribution detail', 'Private execution receipt. Data comes from the local daemon and signed task result where available.',
    element('p', { className: 'detail', text: `Outcome: ${entry.status || (entry.outcome === 'returned' ? 'Returned' : 'Completed')}` }),
    element('p', { className: 'detail', text: labeledDate('Started', entry.started_at || receipt.started_at) }),
    element('p', { className: 'detail', text: labeledDate('Finished', entry.finished_at || entry.settled_at || receipt.finished_at) }),
    element('p', { className: 'detail', text: `Duration: ${formatDuration(entry.duration || receipt.duration || receipt.duration_ms)}` }),
    element('p', { className: 'detail', text: `Harness: ${unavailable('Harness', receipt.harness_id)}` }),
    element('p', { className: 'detail', text: `Capacity source: ${unavailable('Capacity source', receipt.capacity_kind)}` }),
    element('p', { className: 'detail', text: `Model: ${unavailable('Model', entry.model || receipt.model)}` }),
    element('p', { className: 'detail', text: `Usage: ${unavailable('Usage', entry.tokens || tokenUsage(receipt))}` }),
    element('p', { className: 'detail', text: `Sandbox: ${unavailable('Sandbox', receipt.sandbox_id)}` }),
    element('p', { className: 'detail', text: `Docker account: ${unavailable('Docker account', receipt.identities?.docker_account)}` }),
    element('p', { className: 'detail', text: `Provider account: ${unavailable('Provider account', receipt.identities?.provider_account?.email || receipt.identities?.provider_account?.tier)}` }),
    element('p', { className: 'detail', text: `Requester: ${unavailable('Requester', entry.requester || entry.author || entry.author_key)}` }),
    element('p', { className: 'detail', text: `Task: ${entry.display_id || entry.task_name || 'Federation task'}` }),
    element('p', { className: 'detail', text: `Task reference: ${unavailable('Task reference', entry.task_reference || entry.task_digest)}` }),
    element('p', { className: 'detail', text: `Prompt: ${unavailable('Prompt', entry.prompt)}` }),
    entry.source ? element('p', { className: 'detail', text: `Source: ${typeof entry.source === 'string' ? entry.source : entry.source.name || JSON.stringify(entry.source)}` }) : null,
    entry.reason ? element('p', { className: 'detail', text: `Reason: ${entry.reason}` }) : null,
    entry.requester_notice ? element('p', { className: 'detail', text: `Requester was told: ${entry.requester_notice}` }) : null,
    entry.task_digest ? button('View execution log', () => loadExecutionLog(entry.task_digest), 'secondary') : null,
    executionLogPanel(executionLog),
  );
}

function activityView(ledger, requests, collective, select, selectedContribution, selectContribution, executionLog, loadExecutionLog) {
  const contributionRows = ledger.filter((entry) => entry.role !== 'requester' && entry.author !== 'me');
  const contributionList = contributionRows.length
    ? element('ul', { className: 'history-list contribution-list' }, ...contributionRows.map((entry) => element('li', {},
      element('button', { type: 'button', className: 'history-select', onclick: () => selectContribution(entry) },
        element('span', { className: 'history-main' },
          element('strong', { text: entry.display_id || entry.task_name || 'Federation task' }),
          element('span', { className: 'history-date', text: `${entry.status || (entry.outcome === 'returned' ? 'Returned' : 'Completed')} · ${labeledDate('Finished', entry.finished_at || entry.settled_at)}` }),
          entry.reason ? element('span', { className: 'history-date', text: entry.reason }) : null,
        ),
        element('span', { className: 'receipt-chip', text: entry.outcome === 'returned' ? 'Returned' : [entry.duration, entry.model || entry.receipt?.model, entry.tokens || tokenUsage(entry.receipt || entry)].filter(Boolean).join(' · ') || 'Receipt data unavailable for this legacy task' }),
      ),
    )))
    : element('div', { className: 'empty-state' }, element('strong', { text: 'Your contribution history will appear here.' }));
  return element('div', { className: 'view-stack' },
    panel('Collective', 'Task-level activity shared with your collective. Private receipts stay private.', Array.isArray(collective) && collective.length
      ? element('ul', { className: 'history-list' }, ...collective.map((entry) => {
        const actor = entry.status === 'settled' ? entry.executor_key : entry.author;
        const verb = entry.status === 'settled' ? 'completed' : entry.status === 'claimed' ? 'claimed' : 'submitted';
        const at = entry.settled_at || entry.claimed_at || entry.published_at;
        return element('li', {}, element('span', { className: 'history-main' }, element('strong', { text: `${actor || 'A member'} ${verb} '${entry.display_id || 'a task'}'` }), element('span', { className: 'history-date', text: `${entry.author || 'unknown requester'} · ${taskAge(at)}` })), statusChip(entry.status));
      }))
      : element('div', { className: 'empty-state' }, element('strong', { text: 'No collective activity yet.' }))),
    panel('Contribution history', 'Private receipts for every completed or returned attempt.', contributionList),
    activityDetail(selectedContribution, executionLog, loadExecutionLog),
    panel('Requester history', 'Requests and results.', requests.length ? element('ul', { className: 'history-list' }, ...requests.map((entry) => element('li', {}, element('button', { type: 'button', className: 'text-button', onclick: () => select(entry.task_digest), text: entry.display_id || 'Untitled task' }), statusChip(entry.status)))) : element('div', { className: 'empty-state' }, element('strong', { text: 'No requester activity yet.' }))),
  );
}

function providerSignInCard(status) {
  if (status?.state === 'idle' && /sign-in could not start/i.test(status.detail || '')) {
    return panel('Sign-in needs attention', status.detail);
  }
  const action = status?.action;
  if (status?.state !== 'action_needed' || action?.kind !== 'awaiting_browser' || !action.service) return null;
  return panel(`Sign in to ${action.service}`, 'Finish this step in your browser.',
    button(action.code ? 'Open sign-in' : 'Open sign-in', () => window.open(action.url, '_blank', 'noopener')),
    action.code ? element('p', { className: 'detail' }, document.createTextNode('Confirmation code: '), oneTimeCode(action.code)) : null,
  );
}

function providerAccountCard(account, signIn) {
  const service = account.provider || account.service || account.name || 'Provider';
  const displayName = providerDisplayName(service);
  const unauthenticated = (account.authenticated ?? account.authed) === false;
  const managed = !unauthenticated && String(service).toLowerCase().includes('anthropic');
  const checking = Boolean(account.checking);
  const taskAccess = String(service).toLowerCase() === 'github';
  return element('li', { className: 'provider-card' },
    element('div', { className: 'provider-account-copy' },
      element('strong', { text: displayName }),
      element('span', { className: 'provider-account-meta', text: `${taskAccess ? 'Task access' : readableCapacityKind(capacityKind(account))} · ${checking ? 'Checking…' : unauthenticated ? 'Needs sign-in' : 'Signed in'}` }),
      account.account_email || account.email ? element('span', { className: 'field-help', text: account.account_email || account.email }) : null,
    ),
    unauthenticated && !checking
      ? button(`Sign in to ${displayName}`, () => signIn(String(account.service || account.provider || service).toLowerCase()), 'secondary')
      : managed ? element('span', { className: 'provider-managed', text: 'Managed automatically' }) : null,
  );
}

function dockerAccountLabel(identity) {
  const account = identity?.docker?.email || identity?.docker_account;
  if (account) return account;
  if (identity?.docker_status === 'failed') return "Couldn't detect — is Docker signed in?";
  if (identity?.docker_status === 'checking' || identity?.refreshing) return 'Checking…';
  return 'Not reported yet';
}

function settingsView(identity, settings, roster, saveSettings, signIn, status, draft) {
  const schedule = draft.value.schedule;
  const change = (field, value) => { draft.value = { ...draft.value, schedule: { ...draft.value.schedule, [field]: value } }; draft.dirty = true; };
  const collectiveName = element('input', { id: 'collective-name', name: 'collective-name', autocomplete: 'organization', value: draft.value.collective_name || identity?.collective_name || '', placeholder: 'Your collective', oninput: (event) => { draft.value = { ...draft.value, collective_name: event.target.value }; draft.dirty = true; } });
  const enabled = element('input', { id: 'schedule-enabled', name: 'schedule-enabled', type: 'checkbox', checked: Boolean(schedule.enabled), onchange: (event) => change('enabled', event.target.checked) });
  const start = element('input', { id: 'schedule-start', name: 'schedule-start', type: 'time', value: schedule.start || '', oninput: (event) => change('start', event.target.value) });
  const end = element('input', { id: 'schedule-end', name: 'schedule-end', type: 'time', value: schedule.end || '', oninput: (event) => change('end', event.target.value) });
  const days = element('select', { id: 'schedule-days', name: 'schedule-days', multiple: true, size: 4, onchange: (event) => change('days', Array.from(event.target.selectedOptions, (option) => option.value).join(',')) }, ...['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((day) => element('option', { value: day, selected: String(schedule.days || '').split(',').includes(day), text: day })));
  const timezone = element('input', { id: 'schedule-timezone', name: 'schedule-timezone', value: schedule.timezone || Intl.DateTimeFormat().resolvedOptions().timeZone, readonly: true });
  if (!schedule.timezone) draft.value.schedule.timezone = timezone.value;
  const feedback = element('p', { className: 'form-feedback', role: 'alert' });
  const scheduleForm = element('form', { onsubmit: async (event) => { event.preventDefault(); feedback.textContent = ''; if (enabled.checked && (!start.value || !end.value || !days.value)) { feedback.textContent = 'Choose a start, end, and at least one day.'; return; } try { await saveSettings(draft.value); draft.dirty = false; draft.saved = true; } catch (error) { feedback.textContent = error.message; } } },
    element('label', { className: 'check-label', for: 'schedule-enabled' }, enabled, document.createTextNode(' Use a contribution schedule')),
    element('div', { className: 'schedule-grid' }, element('div', {}, element('label', { for: 'schedule-start', text: 'Start' }), start), element('div', {}, element('label', { for: 'schedule-end', text: 'End' }), end), element('div', {}, element('label', { for: 'schedule-days', text: 'Days' }), days)),
    element('label', { for: 'schedule-timezone', text: 'Timezone' }), timezone,
    element('p', { className: 'field-help', text: `Schedule times are in ${timezone.value}. ${enabled.checked && start.value && end.value ? `Active ${days.value || 'selected days'} from ${start.value} to ${end.value}.` : 'Schedule is currently off.'}` }),
    draft.dirty ? element('p', { className: 'field-help', text: 'Unsaved changes' }) : draft.saved ? element('p', { className: 'field-help', text: 'Saved' }) : null, feedback, element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Save schedule' })),
  );
  const collectiveNameForm = element('form', { onsubmit: async (event) => { event.preventDefault(); try { await saveSettings(draft.value); draft.dirty = false; draft.saved = true; } catch (error) { feedback.textContent = error.message; } } },
    element('label', { for: 'collective-name', text: 'Collective name' }), collectiveName,
    element('p', { className: 'field-help', text: 'Shown only on this machine.' }),
    element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Save collective name' })),
  );
  const accounts = providerAccounts(identity);
  const owner = roster?.[0]?.name || roster?.[0]?.key_id || 'the collective operator';
  return element('div', { className: 'view-stack' },
    providerSignInCard(status),
    panel('This machine', 'Accounts, schedule, and the member ID for this device.',
      element('dl', { className: 'identity-list' },
        element('dt', { text: 'Docker account' }), element('dd', {}, element('span', { text: dockerAccountLabel(identity) }), element('p', { className: 'field-help', text: 'Used to run isolated task sandboxes.' })),
        element('dt', { text: 'Member ID' }), element('dd', {}, element('span', { text: identity?.key_id || 'Not reported yet' }), element('p', { className: 'field-help', text: 'How the collective recognizes your machine.' })),
      ),
      accounts.length ? element('ul', { className: 'provider-list', 'aria-label': 'Provider accounts' }, ...accounts.map((account) => providerAccountCard(account, signIn))) : null,
      panel('Limit to certain hours (optional)', 'Pause is always available immediately.', scheduleForm),
    ),
    panel('Your collective', `Run by ${owner}.`,
      collectiveNameForm,
      identity?.coordinator_url ? element('p', { className: 'detail', text: `Connection address: ${identity.coordinator_url}` }) : null,
      element('h3', { text: 'Collective roster' }), roster?.length ? element('ul', { className: 'roster-list' }, ...roster.map((member) => element('li', {}, element('strong', { text: member.name || member.key_id || 'Member' }), element('code', { text: member.key_id || member.public_key_pem || '' })))) : element('div', { className: 'empty-state' }, element('strong', { text: 'Roster unavailable.' })),
      element('p', { className: 'quiet-note', text: "Collective management (approvals, removal) happens on the operator's machine today." }),
    ),
  );
}

function helpView(identity) {
  const capacitySubject = providerCapacitySubject(identity);
  return element('div', { className: 'view-stack' },
    panel('How Federation works', 'A trusted collective shares spare capacity without sharing your computer.', element('ol', { className: 'manual-steps' }, element('li', { text: 'A requester packages one chosen folder and describes the work.' }), element('li', { text: 'A contributor accepts a task only when contributing is on.' }), element('li', { text: 'The task runs in an isolated Docker sandbox and returns a receipt and result.' }))),
    panel('Your safety boundary', 'Three things to know before you contribute.', element('div', { className: 'safety-copy' }, element('p', { text: `Tasks run inside an isolated Docker sandbox on your machine. The sandbox can use ${capacitySubject} to do the work, but it cannot see anything else on your computer.` }), element('p', { text: 'Shared in: only the task folder and instructions you choose. Not touched: your other projects, accounts, or personal files.' }), element('p', { text: 'Everything else is blocked: the sandbox cannot read your other files, cannot reach your home network, and cannot see other tasks.' }))),
    panel('Questions people ask', null, element('div', { className: 'faq' }, element('details', { open: true }, element('summary', { text: 'What runs where?' }), element('p', { text: 'The selected task runs in a Docker sandbox on the contributor’s machine. The requester gets the result and shared execution metadata.' })), element('details', {}, element('summary', { text: 'Whose account is used?' }), element('p', { text: `${capacitySubject} is used only inside the contributor’s isolated Federation environment. Account identities are private to that contributor.` })), element('details', {}, element('summary', { text: 'How do I stop?' }), element('p', { text: 'Pause finishes the current task and accepts no new tasks. Stop now abandons the current task; it is recorded as returned.' })), element('details', {}, element('summary', { text: 'What can a task see?' }), element('p', { text: 'Only the folder and instructions the requester deliberately supplied. It cannot see other files, your home network, or other tasks.' })))),
  );
}

function createApplication(root) {
  const token = new URLSearchParams(window.location.search).get('token');
  let status = null; let availableTasks = []; let ledger = []; let requests = []; let collective = []; let identity = null; let settings = null; let roster = []; let selectedDigest = null; let selectedTask = null; let selectedTaskRevision = 0; let selectedContribution = null; let selectedExecutionLog = null; let executionLogRevision = 0; let message = ''; let pollBusy = false; let lastLayoutSignature = null; let unauthorizedPolls = 0; let sessionExpired = false; let daemonUnavailable = false; let coordinatorUnavailable = false; let lastKnownAt = null; let pollTimer = null; let pendingNext = null; let showStopNow = false;
  const requestForm = { display_id: '', prompt: '', source: '', git_url: '', git_ref: '', git_probe: '', github_access_required: false, files: [], network: false, error: '' };
  const failedRequests = new Map();
  const settingsDraft = { value: { schedule: { enabled: false, start: '', end: '', days: '', timezone: Intl.DateTimeFormat().resolvedOptions().timeZone } }, dirty: false, saved: false };
  window.addEventListener('beforeunload', (event) => { if (settingsDraft.dirty) { event.preventDefault(); event.returnValue = ''; } });

  async function request(path, options = {}) {
    if (!token) {
      const error = new Error(SESSION_EXPIRED_MESSAGE);
      error.status = 401;
      throw error;
    }
    const response = await fetch(path, { ...options, headers: { 'x-waspflow-session-token': token, ...(options.body ? { 'content-type': 'application/json' } : {}) } });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) {
      const error = new Error(body.error || 'Waspflow could not complete that request.');
      error.status = response.status;
      throw error;
    }
    return body;
  }

  async function optionalRequest(path, fallback) {
    const failure = failedRequests.get(path);
    if (failure && Date.now() < failure.nextAttemptAt) return fallback;
    try {
      const result = await request(path);
      failedRequests.delete(path);
      return result;
    } catch (error) {
      const attempts = (failure?.attempts || 0) + 1;
      failedRequests.set(path, { attempts, nextAttemptAt: Date.now() + Math.min(30_000, 1_500 * (2 ** attempts)) });
      if (['/tasks', '/requests', '/roster'].includes(path) || path.startsWith('/tasks/')) coordinatorUnavailable = true;
      return fallback;
    }
  }
  async function control(path, body) { message = ''; try { status = await request(path, { method: 'POST', body: body ? JSON.stringify(body) : undefined }); pendingNext = null; showStopNow = false; } catch (error) { message = error.message; } render(); }
  async function submit(body) { const result = await request('/submit', { method: 'POST', body: JSON.stringify(body) }); requestForm.display_id = ''; requestForm.prompt = ''; requestForm.source = ''; requestForm.git_url = ''; requestForm.git_ref = ''; requestForm.git_probe = ''; requestForm.github_access_required = false; requestForm.files = []; requestForm.network = false; requestForm.error = ''; status = result; selectedDigest = /^sha256:[a-f0-9]{64}$/i.test(result.submission?.task_digest || '') ? result.submission.task_digest : selectedDigest; window.location.hash = '#/requests'; render(); }
  async function acknowledgeSubmission() { status = await request('/submit/ack', { method: 'POST' }); render(); }
  async function probeGit(gitUrl) { return request('/git/probe', { method: 'POST', body: JSON.stringify({ git_url: gitUrl }) }); }
  async function saveSettings(body) { settings = await request('/settings', { method: 'POST', body: JSON.stringify(body) }); settingsDraft.value = structuredClone(settings); render(); }
  async function signIn(service) { message = ''; try { status = await request('/identity/signin', { method: 'POST', body: JSON.stringify({ service }) }); } catch (error) { message = error.message; } render(); }
  function select(digest) { selectedDigest = digest; selectedTask = null; selectedTaskRevision += 1; selectedExecutionLog = null; executionLogRevision += 1; window.location.hash = '#/requests'; void refreshTask(); render(); }
  function selectContribution(entry) { selectedContribution = entry; selectedExecutionLog = null; executionLogRevision += 1; render(); }
  async function refreshTask() {
    if (!selectedDigest || !/^sha256:[a-f0-9]{64}$/i.test(selectedDigest)) return;
    const next = await optionalRequest(`/tasks/${encodeURIComponent(selectedDigest.replace(/^sha256:/, ''))}`, null) || await optionalRequest(`/submit/status?task_digest=${encodeURIComponent(selectedDigest)}`, null);
    if (JSON.stringify(next) !== JSON.stringify(selectedTask)) { selectedTask = next; selectedTaskRevision += 1; }
    render();
  }
  async function loadExecutionLog(digest, append = false) {
    const bareDigest = String(digest || '').replace(/^sha256:/, '');
    if (!/^[a-f0-9]{64}$/i.test(bareDigest)) return;
    try {
      const since = append ? selectedExecutionLog?.next_offset || 0 : 0;
      const next = await request(`/tasks/${encodeURIComponent(bareDigest)}/log?since=${since}`);
      selectedExecutionLog = append && selectedExecutionLog ? { ...next, output: `${selectedExecutionLog.output || ''}${next.output || ''}` } : next;
    }
    catch (error) { selectedExecutionLog = { output: error.message || 'The execution log is unavailable on this machine.', truncated: false }; }
    executionLogRevision += 1;
    render();
  }
  function requesterEntries(entries, localIdentity) {
    return entries.filter((entry) => entry.author === 'me' || entry.role === 'requester' || entry.requester === true
      || (localIdentity && (entry.author_key === localIdentity || entry.author === localIdentity)));
  }
  async function refresh() {
    if (pollBusy || sessionExpired) return; pollBusy = true;
    try {
      status = await request('/status');
      daemonUnavailable = false;
      lastKnownAt = new Date().toISOString();
      coordinatorUnavailable = Boolean(status.coordinator_unavailable);
      const coordinatorReady = ['idle', 'paused', 'contributing'].includes(status.state);
      const baseRequests = coordinatorReady ? await optionalRequest('/requests', null) : null;
      const data = await Promise.all([
        status.state === 'idle' ? optionalRequest('/tasks', []) : Promise.resolve([]), optionalRequest('/ledger', []), optionalRequest('/identity', null), optionalRequest('/settings', null), coordinatorReady ? optionalRequest('/roster', []) : Promise.resolve([]), coordinatorReady ? optionalRequest('/activity', []) : Promise.resolve([]),
      ]);
      availableTasks = data[0]; ledger = Array.isArray(data[1]) ? data[1] : []; identity = data[2] || { key_id: status.key_id, coordinator_url: status.coordinator_url, collective_name: status.collective_name }; settings = data[3]; if (settings && !settingsDraft.dirty) settingsDraft.value = structuredClone(settings); roster = Array.isArray(data[4]?.roster) ? data[4].roster : Array.isArray(data[4]) ? data[4] : []; collective = Array.isArray(data[5]) ? data[5] : [];
      requests = Array.isArray(baseRequests) ? baseRequests : requesterEntries(ledger, identity?.key_id);
      const submission = status.submission;
      if (submission?.task_digest && /^sha256:[a-f0-9]{64}$/i.test(submission.task_digest) && !selectedDigest) selectedDigest = submission.task_digest;
      if (selectedDigest) void refreshTask();
      if (selectedDigest && ['claimed', 'submitted', 'evaluating', 'running'].includes(String(selectedTask?.status || '').toLowerCase())) void loadExecutionLog(selectedDigest, true);
      message = '';
      unauthorizedPolls = 0;
      if (!failedRequests.size) coordinatorUnavailable = false;
    } catch (error) {
      if (error.status === 401) {
        unauthorizedPolls += 1;
        if (unauthorizedPolls >= 2) {
          sessionExpired = true;
          if (pollTimer) window.clearInterval(pollTimer);
          message = SESSION_EXPIRED_MESSAGE;
        }
      } else if (error.message === 'Failed to fetch') { daemonUnavailable = true; message = ''; }
      else message = error.message;
    }
    finally { pollBusy = false; render(); }
  }
  function updateText(selector, value) {
    const node = root.querySelector(selector);
    if (node && node.textContent !== value) node.textContent = value;
  }
  function updateLiveBindings(view) {
    const dot = root.querySelector('[data-live="contribution-dot"]');
    if (!dot) return;
    const detail = contributionDetail(status, view);
    updateText('[data-live="contribution-title"]', view.title || 'Checking status');
    updateText('[data-live="contribution-detail"]', detail);
    const detailNode = root.querySelector('[data-live="contribution-detail"]');
    if (detailNode) detailNode.hidden = !detail;
    if (dot.getAttribute('data-state') !== (status?.state || 'idle')) dot.setAttribute('data-state', status?.state || 'idle');
    updateText('[data-live="guard-copy"]', guardCopy(settings));
  }
  function render() {
    const active = routeFromHash(window.location.hash); const view = viewForStatus(status);
    const content = [...header(active), banner(message), status?.coordinator_outdated ? banner("Your collective's coordinator is running an older version — ask the operator to update it.") : null, element('section', { className: 'content', id: 'main-content' })]; const main = content.at(-1);
    main.append(element('h1', { className: 'sr-only', text: `${navigation.find(([route]) => route === active)?.[1] || 'Federation'} in Waspflow Federation` }));
    if (sessionExpired) main.append(panel('Session expired', SESSION_EXPIRED_MESSAGE, button('Reconnect Federation', reconnectFederation), element('p', { className: 'field-help', text: 'If this does not reopen Federation, open it from the Waspflow app.' })));
    else if (daemonUnavailable) main.append(panel('Federation is not running on this computer', 'No new task can start. Your last known state is still shown when Federation reconnects.', lastKnownAt ? element('p', { className: 'detail', text: `Last connected ${formatDate(lastKnownAt)}.` }) : null, button('Reconnect Federation', reconnectFederation), element('p', { className: 'field-help', text: 'If this does not reopen Federation, open it from the Waspflow app.' })));
    else if (active === 'contribute') main.append(contributeView(status, availableTasks, identity, view, control, settings, coordinatorUnavailable, pendingNext, (task) => { pendingNext = task; render(); }, showStopNow, (value) => { showStopNow = value; render(); }, select, () => { window.location.hash = '#/settings'; }));
    else if (active === 'requests') {
      const resultHref = selectedDigest ? `/result/${encodeURIComponent(selectedDigest)}?token=${encodeURIComponent(token || '')}` : '#/requests';
      main.append(requestsView(requests, selectedDigest, selectedTask, submit, select, resultHref, requestForm, selectedExecutionLog, loadExecutionLog, status?.submission, acknowledgeSubmission, probeGit, render));
    }
    else if (active === 'activity') main.append(activityView(ledger, requests, collective, select, selectedContribution, selectContribution, selectedExecutionLog, loadExecutionLog));
    else if (active === 'settings') main.append(settingsView(identity, settings, roster, saveSettings, signIn, status, settingsDraft));
    else main.append(helpView(identity));
    // Polls are intentionally data-only updates. Replacing the app root on
    // each poll destroys selection, focus, and in-progress interaction; only
    // a true layout transition earns a DOM rebuild. The live contribution
    // bindings below update the handful of changing nodes in place.
    const layoutSignature = JSON.stringify({ active, view: view.name, control: view.control, state: status?.state, action: status?.action?.kind, taskIds: status?.state === 'idle' ? availableTasks.map((task) => task.task_digest) : [], selectedDigest, selectedTaskRevision, selectedContribution, executionLogRevision, message, sessionExpired, daemonUnavailable, coordinatorUnavailable, pendingNext: pendingNext?.task_digest, showStopNow, scheduleEnabled: settings?.schedule?.enabled });
    if (layoutSignature === lastLayoutSignature) { updateLiveBindings(view); return; }
    lastLayoutSignature = layoutSignature;
    root.replaceChildren(...content.filter(Boolean));
  }
  window.addEventListener('hashchange', render); render(); void refresh(); pollTimer = window.setInterval(refresh, POLL_INTERVAL_MS);
}

if (typeof document !== 'undefined') createApplication(document.getElementById('app'));
