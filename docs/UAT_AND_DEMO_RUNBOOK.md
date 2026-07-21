# Federation UAT and Oshin Demo Runbook

This runbook checks the current local Federation daemon and browser UI.
It uses a local coordinator on this host.

Important accuracy note: the current build does not yet show `pending_approval`,
an `approve` command, a quota guard, or a contribution ledger. This runbook
marks those product targets as gaps. Do not present them as shipped behavior.

## 1. Owner quick UAT

### 1.1 Prepare the local coordinator

Use two separate Federation config directories. One directory represents Tim.
The other directory represents Oshin. This avoids replacing one identity while
you test both sides on one host.

Open Terminal 1 in the repository root and run:

```bash
export WF_E2E=/tmp/fed-e2e
export WF_REPO="$PWD"
export WF_PORT=9099
export WF_TOKEN='oshin-invite-7clzi-test'
export WF_COORD="$WF_E2E/coord-data"
export WF_ROSTER="$WF_E2E/roster.json"
export WF_TIM_HOME="$WF_E2E/tim"
export WF_OSHIN_HOME="$WF_E2E/oshin"

mkdir -p "$WF_COORD" "$WF_TIM_HOME" "$WF_OSHIN_HOME"

if [ ! -f "$WF_ROSTER" ]; then
  node -e '
    const {generateKeyPairSync}=require("crypto");
    const {publicKey}=generateKeyPairSync("ed25519");
    const pem=publicKey.export({type:"spki",format:"pem"});
    require("fs").writeFileSync(process.argv[1], JSON.stringify({"__bootstrap__":pem}, null, 2));
  ' "$WF_ROSTER"
fi

env \
  WASPFLOW_FEDERATION_COLLECTIVE_TOKEN="$WF_TOKEN" \
  WASPFLOW_FEDERATION_COORDINATOR_DATA_DIR="$WF_COORD" \
  WASPFLOW_FEDERATION_COORDINATOR_HOST=127.0.0.1 \
  WASPFLOW_FEDERATION_COORDINATOR_PORT="$WF_PORT" \
  WASPFLOW_FEDERATION_COORDINATOR_ROSTER_FILE="$WF_ROSTER" \
  node bin/waspflow-federation-coordinator
```

Keep Terminal 1 open. The coordinator prints a `listening` JSON line.
The invite string for the local UI is:

```text
waspflow federation join http://127.0.0.1:9099 oshin-invite-7clzi-test
```

The bootstrap roster entry only lets the coordinator start. Add each real key
to the roster after its owner runs `join`.

### 1.2 Join Tim and approve the test identities

Open Terminal 2 in the repository root. Run the owner join first:

```bash
export WF_E2E=/tmp/fed-e2e
export WF_TOKEN='oshin-invite-7clzi-test'
export WF_ROSTER="$WF_E2E/roster.json"
export WF_TIM_HOME="$WF_E2E/tim"
export WF_OSHIN_HOME="$WF_E2E/oshin"

WASPFLOW_FEDERATION_HOME="$WF_TIM_HOME" \
  waspflow federation join http://127.0.0.1:9099 "$WF_TOKEN" --key-id tim-author

node -e '
  const fs=require("fs");
  const roster=JSON.parse(fs.readFileSync(process.argv[1]));
  const pub=fs.readFileSync(process.argv[2], "utf8");
  roster["tim-author"]=pub;
  fs.writeFileSync(process.argv[1], JSON.stringify(roster, null, 2));
' "$WF_ROSTER" "$WF_TIM_HOME/tim-author.pub.pem"
```

The coordinator hot-reloads a valid roster edit. It does not need a restart.

Do not run `waspflow federation approve`. That command does not exist in the
current build. In v0, approval means adding the public key to the local roster
file. The current coordinator has no network registration endpoint.

### 1.3 Start the daemon and open the UI

Use Terminal 2 for the Oshin identity. Start the daemon, then open the browser:

```bash
WASPFLOW_FEDERATION_HOME="$WF_OSHIN_HOME" \
  waspflow federation daemon >"$WF_E2E/oshin-daemon.log" 2>&1 &

WASPFLOW_FEDERATION_HOME="$WF_OSHIN_HOME" \
  waspflow federation ui
```

`ui` starts the daemon when it is not already running. The separate daemon
command makes the daemon process and its log easy to inspect during UAT.
The UI opens at a tokenized `127.0.0.1` URL. Do not share that URL.

Before continuing, run the read-only sandbox check:

```bash
waspflow federation doctor
```

The contribution path requires Docker Sandboxes, a healthy Docker daemon,
policy, KVM access where applicable, and Docker login.

### 1.4 Four-click contributor journey

The current UI journey is four user actions after the page opens.

#### Click 1: Join card

Paste the invite string into `Invite`.
Click `Join`.

Expected screen:

- Card heading: `Join the federation`
- Invite field contains the pasted command.
- The card contains the sandbox safety sentence.
- The page changes briefly to `Joining the federation…`.

The daemon runs the guided `join` command. The command creates Oshin's keypair,
saves the local configuration, and fetches the current roster.

Copy Oshin's public key into the roster from Terminal 2:

```bash
node -e '
  const fs=require("fs");
  const roster=JSON.parse(fs.readFileSync(process.argv[1]));
  const pub=fs.readFileSync(process.argv[2], "utf8");
  roster["oshin-executor"]=pub;
  fs.writeFileSync(process.argv[1], JSON.stringify(roster, null, 2));
' "$WF_ROSTER" "$WF_OSHIN_HOME/oshin-executor.pub.pem"
```

#### Click 2: Pending or idle check

Current screen: `Idle`, with `Ready to contribute.`

The north-star design calls for a `pending_approval` screen that says,
`Waiting for Tim to approve you — you'll start automatically once he does.`
The current daemon does not implement that state. It returns to `Idle` after
`join`, even if the key is not yet in the coordinator roster.

Expected current screen:

- Card eyebrow: `Your contribution`
- Large status: `Idle`
- Button: `Start contributing`
- `Choose a task` card appears when the coordinator has claimable tasks.

#### Click 3: Choose a task

After Tim publishes a task, wait for the `Choose a task` card to appear.
Click `Contribute this` for the named task, or click `Contribute next available`.

Expected screen:

- Heading: `Choose a task`
- Text explains that the contributor can pick a task.
- Each available task shows its `display_id`.
- The selected action starts contribution.

The UI does not claim a task before this click.

#### Click 4: Contribute, authenticate, and observe the run

If the provider needs authentication, the current screen changes to:

- Eyebrow: `Action needed`
- Heading: `Sign in to continue` for a browser URL flow
- Button: `Open sign-in`

Click `Open sign-in`, finish the provider login in the browser, and start the
contribution again when the page returns to `Idle`.

Expected running screen:

- Large status: `Contributing`
- Button: `Pause contributing`
- Progress text updates as the daemon receives child-process output.

When the task finishes, the current screen returns to `Idle` and says,
`Contribution finished.` The current UI has no ledger line. Treat a missing
ledger line as a known product gap, not as a failed UAT step.

### 1.5 Requester submit and result check

Use Tim's config directory in Terminal 2. Create a small demo source and prompt:

```bash
mkdir -p "$WF_E2E/demo-source" "$WF_E2E/result" "$WF_E2E/tim"
printf '%s\n' 'Federation demo source' > "$WF_E2E/demo-source/README.md"
printf '%s\n' 'Review the source and return a short result.' > "$WF_E2E/task.md"

WASPFLOW_FEDERATION_HOME="$WF_TIM_HOME" \
  waspflow federation submit \
    --display-id oshin-demo \
    --source "$WF_E2E/demo-source" \
    --prompt-file "$WF_E2E/task.md" \
    --output-dir "$WF_E2E/result"
```

The browser's `Submit a task (advanced)` accordion is the UI equivalent.
It asks for a folder path, a prompt, and a contributor display ID.

Check the result by task digest:

```bash
WASPFLOW_FEDERATION_HOME="$WF_TIM_HOME" \
  waspflow federation status --task-digest <task-digest>
```

The browser shows a requester lifecycle card with `queued`, `running`, and
`settled`. On `settled`, it shows `Result ready` and a `Copy result reference`
button. The submit command with `--output-dir` independently verifies and
materializes the result into `$WF_E2E/result`.

### 1.6 Troubleshooting

| Symptom | Check | Current fix |
|---|---|---|
| Daemon is not up | Run `WASPFLOW_FEDERATION_HOME="$WF_OSHIN_HOME" waspflow federation ui`, then inspect `$WF_E2E/oshin-daemon.log`. | Run `waspflow federation doctor`. Restart the daemon if the log shows a startup error. |
| UI says it cannot fetch | Check that the tokenized URL came from `waspflow federation ui`. | Reopen the UI. Do not remove the `token` query parameter. |
| Coordinator is unreachable | Run `curl http://127.0.0.1:9099/roster` and inspect Terminal 1. | Restart the coordinator with the exact environment variables in §1.1. |
| Join rejects the invite | Compare the coordinator URL and token with the invite string. | Re-run `join` with `http://127.0.0.1:9099` and `oshin-invite-7clzi-test`. |
| `401 unknown signer key_id` | Read the signer ID in the error. | Add that member's public key to `$WF_ROSTER`. Save valid JSON. Wait for the hot-reload message, then retry. This is the current v0 approval operation. |
| Oshin appears `Idle` but no task appears | Check that Tim's submit reached `QUEUED`. | Refresh the page. Confirm that the roster contains both `tim-author` and `oshin-executor`. |
| `Your sandbox isn't ready yet` | Open the failed checks in the UI. | Run `waspflow federation doctor` and apply each printed fix. Use `--fix-policy` only when doctor offers that safe policy fix. |
| Auth screen has `Open sign-in` | Provider credentials are not configured for the Federation sandbox identity. | Click `Open sign-in`, complete login, then start contribution again. |
| Contribution says no task is available | The coordinator has no claimable task. | Submit a task, then refresh the UI. |
| Result stays `queued` | Oshin has not started contribution or the worker stopped. | Open Oshin's UI and click `Contribute this` or `Contribute next available`. |
| You expect a ledger line | The current UI does not implement the ledger. | Record this as a known gap. Do not call the UAT complete for the ledger requirement. |

## 2. Oshin demo script

Target time: ten minutes. Keep the safety panel available but closed until the
safety explanation. Use a prepared coordinator and one queued demo task.

### Opening: the safety story

Say:

> You are helping Tim, not joining an open job market. Tim sends the task.
> Your own subscription does the work. Waspflow runs the task inside an
> isolated Docker sandbox. The task cannot read your other files, reach your
> home network, or see other tasks.

Show the `Join the federation` card and its safety sentence.
Open `How this works / Is this safe?` and show the boundary, shared-in, and
not-touched text. Say that Oshin can pause at any time.

### Screen 1: Join

Say:

> Tim gave you one invite. Paste the whole thing here. You do not need a PEM
> file, a task digest, or a roster command.

Show the invite field. Paste the invite command. Click `Join`.

Point to `Joining the federation…`, then wait for the status card.

### Screen 2: Idle

Say:

> The app is ready. It does not run anything until you choose to contribute.
> In the finished experience, a new member can wait here while Tim approves
> the membership. This build returns to Idle while that approval remains a
> roster-file operation.

Show `Idle`, `Ready to contribute.`, and the coordinator trust badge.
Do not describe the current screen as `pending approval`.

### Screen 3: Choose a task

Say:

> Tim's task appears by name. You choose the work that suits you. The app
> does not make you copy a digest.

Show the `Choose a task` card and the task display ID.
Click `Contribute this`.

### Screen 4: Authentication and running

If authentication is already configured, say:

> Your subscription is already connected for this demo. The task now runs in
> the sandbox on this machine.

If authentication is required, say:

> This is the only action the subscription needs from you. Click once, finish
> the provider sign-in in the browser, and return here.

Show `Action needed`, then click `Open sign-in` if required. Return to the UI,
click `Start contributing`, and show `Contributing` with `Pause contributing`.

Say:

> You can stop this at any time. When the run finishes, the task result goes
> back to Tim. Your credentials stay in the provider and sandbox flow. They
> are not copied into the task.

When the run returns to `Idle`, say:

> This current build shows completion by returning to Idle. The contribution
> ledger is part of the product target, but it is not in this build yet.

### Requester view and close

Open `Submit a task (advanced)` on Tim's browser or show the requester terminal.
Enter the source folder, prompt, and contributor display ID. Click `Submit task`.

Say:

> On Tim's side, the same local UI can submit and watch a task. The lifecycle
> shows queued, running, and settled. Tim can review the result reference when
> the task settles.

Show the lifecycle card. Wait for `settled`, then show `Result ready`.

Close with:

> The promise is simple: tomorrow you will get an installer. It will be these
> same four clicks: join, wait for approval, choose a task, and sign in when
> needed. You will help Tim only when you have spare capacity, and you can
> pause whenever you want.

Do not promise the capacity guard, pending screen, ledger, or platform
installer until the checklist below passes.

## 3. Before-you-promise checklist

Complete this checklist before saying, “Tomorrow you will get an installer.”

### Platform floors

Confirm Oshin's machine meets the floor before promising tomorrow.

| OS | Required floor | Planned artifact |
|---|---|---|
| macOS | Apple Silicon and macOS 26 or newer | Apple Silicon Homebrew cask or formula for the daemon and tray. |
| Windows | Windows 11 x64, Windows Hypervisor Platform enabled, and administrator approval once | Windows x64 installer or WinGet package. |
| Linux | Ubuntu 24.04 or newer and KVM access | Ubuntu x64 `.deb` package. |

The current repository does not contain these shipping artifacts. The table
records the intended mapping, not a claim that the installers are ready.
The browser UI itself is local. The tray and packaging work remain separate
from the current Node daemon and `waspflow federation ui` path.

### Subscription and trust checks

- Ask: “Do you have a spare subscription or spare capacity for this demo?”
- Confirm that Oshin understands that her own provider account performs the
  task inside the sandbox.
- Confirm that Oshin can complete one browser sign-in if the provider asks.
- Confirm that Tim will approve membership by adding Oshin's public key to the
  trusted roster.
- Confirm that Tim will not promise automatic quota protection until the
  account-level capacity guard exists and has passed UAT.
- Confirm that Tim will not promise a contribution ledger until the UI shows a
  real ledger entry.

### OS to artifact decision

Record Oshin's OS and architecture before the demo:

- macOS + Apple Silicon → planned Apple Silicon Homebrew artifact.
- Windows 11 + x64 + Hypervisor Platform → planned Windows x64 installer or
  WinGet artifact.
- Ubuntu 24.04+ + x64 + KVM → planned Ubuntu x64 `.deb` artifact.
- Any other combination → do not promise tomorrow's installer. Record the
  machine as unsupported until a tested artifact exists.
