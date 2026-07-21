const POLL_INTERVAL_MS = 1500;
const lifecycleSteps = ['queued', 'claimed', 'running', 'settled'];

export function viewForStatus(status) {
  if (!status || status.state === 'not_joined') return { name: 'join' };
  if (status.state === 'action_needed') return { name: 'action', action: status.action || {} };
  if (status.state === 'setup_required') return { name: 'setup', checks: status.action?.checks || [] };
  const names = { contributing: 'Contributing', paused: 'Paused', idle: 'Idle' };
  return {
    name: 'status',
    title: names[status.state] || 'Checking status',
    control: status.state === 'contributing' ? 'pause' : 'start',
  };
}

export function lifecycleStage(taskStatus) {
  const state = String(taskStatus || '').toLowerCase();
  if (state === 'settled') return 'settled';
  // The v0 coordinator has QUEUED, CLAIMED, and SETTLED only. Once an
  // executor has claimed a task, its work is underway; present that as the
  // useful user-facing running stage while keeping Claimed visibly complete.
  if (['claimed', 'submitted', 'evaluating', 'running'].includes(state)) return 'running';
  return 'queued';
}

function element(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (name === 'className') node.className = value;
    else if (name === 'text') node.textContent = value;
    else if (name.startsWith('on')) node.addEventListener(name.slice(2).toLowerCase(), value);
    else node.setAttribute(name, value);
  }
  node.append(...children.filter(Boolean));
  return node;
}

function button(label, onClick, className = '') {
  return element('button', { type: 'button', className, onClick, text: label });
}

function header() {
  return element('header', {}, element('h1', { text: 'Waspflow Federation' }));
}

// Accordion that remembers its open/closed state across re-renders. The status
// poll rebuilds the DOM when state changes; a bare <details> would collapse back
// every time. `openState[key]` (app-level, survives re-render) is the source of
// truth: we set `open` from it and update it on toggle.
function accordion(key, openState, summaryText, ...children) {
  const details = element('details', openState[key] ? { open: '' } : {},
    element('summary', { text: summaryText }), ...children);
  details.addEventListener('toggle', () => { openState[key] = details.open; });
  return details;
}

function safetyPanel(status, openState) {
  const coordinator = status.coordinator_url ? element('p', {}, element('span', { className: 'badge', text: 'Coordinator: trusted' }), document.createTextNode(` ${status.coordinator_url}`)) : null;
  return accordion('safety', openState, 'How this works / Is this safe?',
    coordinator,
    element('p', { text: 'Tasks run inside an isolated Docker sandbox on your machine. The sandbox can use your Claude or Codex subscription to do the work, but it cannot see anything else on your computer.' }),
    element('p', { text: 'Shared in: only the task files and instructions you choose. Not touched: your other projects, accounts, and personal files.' }),
    element('p', { text: 'Everything else is blocked: the sandbox cannot read your other files, cannot reach your home network, and cannot see other tasks.' }),
    element('p', { className: 'muted', text: 'You can pause anytime. Nothing runs while Waspflow is paused.' }),
  );
}

function lifecycle(status, task) {
  const state = lifecycleStage(task?.status || status.submission?.state || 'submitting');
  const current = lifecycleSteps.indexOf(state);
  const steps = element('ol', { className: 'steps', 'aria-label': 'Task lifecycle' }, ...lifecycleSteps.map((step, index) => element('li', {
    className: index < current ? 'complete' : index === current ? 'current' : '', text: step,
  })));
  const content = [element('h2', { text: 'Requester task' }), steps];
  if (task?.result_address || state === 'settled') {
    const reference = task?.result_address || task?.task_digest || status.submission?.task_digest;
    content.push(element('p', { text: 'Result ready. Copy its reference to review it separately.' }));
    if (reference) content.push(button('Copy result reference', () => navigator.clipboard?.writeText(reference), 'secondary'));
  } else if (status.submission?.detail) {
    content.push(element('p', { className: 'detail', text: status.submission.detail }));
  }
  return element('section', { className: 'card' }, ...content);
}

function requesterPanel(status, task, submitTask, openState) {
  const source = element('input', { id: 'source', name: 'source', placeholder: '/path/to/folder', required: '' });
  const prompt = element('textarea', { id: 'prompt', name: 'prompt', placeholder: 'Describe the work you want done.', required: '' });
  const displayId = element('input', { id: 'display-id', name: 'display-id', placeholder: 'contributor display id', required: '' });
  const form = element('form', { onsubmit: async (event) => {
    event.preventDefault();
    await submitTask({ source: source.value, prompt: prompt.value, display_id: displayId.value });
  } },
  element('p', { className: 'muted', text: 'For a task you are requesting, enter a local folder path, the work prompt, and the contributor’s display id.' }),
  element('label', { for: 'source', text: 'Folder path' }), source,
  element('label', { for: 'prompt', text: 'What should be done?' }), prompt,
  element('label', { for: 'display-id', text: 'Contributor display id' }), displayId,
  element('div', { className: 'actions' }, element('button', { type: 'submit', text: 'Submit task' })));
  return accordion('submit', openState, 'Submit a task (advanced)', form, lifecycle(status, task));
}

function instructions(text) {
  const lines = String(text || 'Complete the sign-in instruction shown by your agent.').split(/\n+/).filter(Boolean);
  return element('ol', { className: 'manual-steps' }, ...lines.map((line) => element('li', { text: line.replace(/^\s*\d+[.)]\s*/, '') })));
}

function taskChoices(tasks, contribute) {
  const choices = Array.isArray(tasks) ? tasks : [];
  const list = choices.length === 0
    ? element('p', { className: 'muted', text: 'There are no tasks available right now.' })
    : element('ul', { className: 'task-list', 'aria-label': 'Available tasks' }, ...choices.map((task) => {
      const description = typeof task.description === 'string' && task.description.trim() ? task.description : null;
      return element('li', { className: 'task-choice' },
        element('div', {},
          element('strong', { text: task.display_id || 'Task' }),
          description ? element('p', { className: 'muted', text: description }) : null,
        ),
        button('Contribute this', () => contribute(task.task_digest), 'secondary'),
      );
    }));
  return element('section', { className: 'card' },
    element('h2', { text: 'Choose a task' }),
    element('p', { text: 'Pick something that suits you, or let Waspflow choose the next available task.' }),
    element('div', { className: 'actions' }, button('Contribute next available', () => contribute())),
    list,
  );
}

function setupInstructions(checks) {
  if (!Array.isArray(checks) || checks.length === 0) {
    return element('p', { className: 'detail', text: 'Run waspflow federation doctor in a terminal for the exact checks and fixes.' });
  }
  return element('ol', { className: 'manual-steps' }, ...checks.map((item) => element('li', {},
    element('strong', { text: `${item.name}: ` }),
    document.createTextNode(`${item.detail || 'setup check failed.'} `),
    element('code', { text: item.fix || 'Run waspflow federation doctor for the fix.' }),
  )));
}

function createApplication(root) {
  const token = new URLSearchParams(window.location.search).get('token');
  let latestStatus = null;
  let latestTask = null;
  let availableTasks = [];
  let pollBusy = false;
  let message = '';
  let lastRenderSignature = null;
  const openState = {};

  async function request(path, options = {}) {
    if (!token) throw new Error('This link is missing its Waspflow session token. Open Federation again from Waspflow.');
    const response = await fetch(path, {
      ...options,
      headers: { 'x-waspflow-session-token': token, ...(options.body ? { 'content-type': 'application/json' } : {}) },
    });
    const body = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(body.error || 'Waspflow could not complete that request.');
    return body;
  }

  async function control(path, body) {
    try {
      message = '';
      latestStatus = await request(path, { method: 'POST', body: body ? JSON.stringify(body) : undefined });
    } catch (error) {
      message = error.message;
    }
    render();
  }

  async function refresh() {
    if (pollBusy) return;
    pollBusy = true;
    try {
      latestStatus = await request('/status');
      const digest = latestStatus.submission?.task_digest;
      if (digest) latestTask = await request(`/submit/status?task_digest=${encodeURIComponent(digest)}`);
      availableTasks = latestStatus.state === 'idle' ? await request('/tasks') : [];
      message = '';
    } catch (error) {
      message = error.message === 'Failed to fetch' ? 'Waspflow is not running. Open Federation again from Waspflow.' : error.message;
    } finally {
      pollBusy = false;
      render();
    }
  }

  function render() {
    const content = [header()];
    if (message) content.push(element('div', { className: 'notice', role: 'alert', text: message }));
    const view = viewForStatus(latestStatus);
    if (view.name === 'join') {
      const invite = element('textarea', { id: 'invite', placeholder: 'Paste an invite link, join command, or token', required: '' });
      content.push(element('section', { className: 'card' },
        element('p', { className: 'eyebrow', text: 'Get started' }),
        element('h2', { text: 'Join the federation' }),
        element('p', { text: 'Paste the invite you were sent. Waspflow understands the whole link, command, or token.' }),
        element('label', { for: 'invite', text: 'Invite' }), invite,
        element('div', { className: 'actions' }, button('Join', () => control('/join', { invite: invite.value }))),
        element('p', { className: 'muted', text: 'Everything else is blocked: tasks cannot read your other files, home network, or other tasks.' }),
      ));
    } else if (view.name === 'action') {
      const browserAction = view.action.kind === 'awaiting_browser';
      content.push(element('section', { className: 'card' },
        element('p', { className: 'eyebrow', text: 'Action needed' }),
        element('h2', { text: browserAction ? 'Sign in to continue' : 'One-time sign-in step' }),
        element('p', { text: browserAction ? 'Finish signing in in the browser window. This page will update automatically when it is done.' : 'Your agent needs one manual sign-in step. This is needed because the sign-in happens inside the agent, not in Waspflow.' }),
        browserAction ? element('div', { className: 'actions' }, button('Open sign-in', () => window.open(view.action.url, '_blank', 'noopener'))) : instructions(view.action.instruction),
        element('p', { className: 'detail', text: latestStatus?.detail || '' }),
      ));
    } else if (view.name === 'setup') {
      content.push(element('section', { className: 'card' },
        element('p', { className: 'eyebrow', text: 'Sandbox setup required' }),
        element('h2', { text: "Your sandbox isn't ready yet" }),
        element('p', { text: 'Fix these checks, then run Federation doctor again before contributing.' }),
        setupInstructions(view.checks),
        element('p', { className: 'detail', text: latestStatus?.detail || '' }),
      ));
    } else {
      const pause = view.control === 'pause';
      content.push(element('section', { className: 'card' },
        element('p', { className: 'eyebrow', text: 'Your contribution' }),
        element('div', { className: 'status', 'data-state': latestStatus?.state || '', text: view.title }),
        element('p', { className: 'detail', text: latestStatus?.detail || '' }),
        latestStatus?.coordinator_url ? element('p', {}, element('span', { className: 'badge', text: 'Coordinator: trusted' }), document.createTextNode(` ${latestStatus.coordinator_url}`)) : null,
        element('div', { className: 'actions' }, button(pause ? 'Pause contributing' : 'Start contributing', () => control(pause ? '/contribute/stop' : '/contribute/start'))),
      ));
      if (latestStatus?.state === 'idle') {
        content.push(taskChoices(availableTasks, (taskDigest) => control('/contribute/start', taskDigest ? { task_digest: taskDigest } : undefined)));
      }
    }
    if (latestStatus && latestStatus.state !== 'not_joined') {
      content.push(safetyPanel(latestStatus, openState));
      content.push(requesterPanel(latestStatus, latestTask, (body) => control('/submit', body), openState));
    }
    // Only touch the DOM when the view actually changed. The 1.5s status poll
    // calls render() constantly; rebuilding the DOM every time destroyed the
    // join textarea (and anything the user was typing) mid-interaction — which
    // made the invite field clear itself and the Join click hit an empty field.
    // Guard on a signature of what drives the view so idle polls are no-ops.
    const signature = JSON.stringify({
      view: view.name,
      control: view.control || null,
      action: view.action || null,
      state: latestStatus?.state || null,
      detail: latestStatus?.detail || null,
      coordinator: latestStatus?.coordinator_url || null,
      contribution: latestStatus?.contribution || null,
      task: latestTask?.status || null,
      availableTasks,
      message,
    });
    if (signature === lastRenderSignature) return;
    lastRenderSignature = signature;
    root.replaceChildren(...content);
  }

  render();
  refresh();
  window.setInterval(refresh, POLL_INTERVAL_MS);
}

if (typeof document !== 'undefined') createApplication(document.getElementById('app'));
