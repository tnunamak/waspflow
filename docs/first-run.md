# First run

## 1. Install

```bash
git clone https://github.com/tnunamak/waspflow /path/to/waspflow
cd /path/to/waspflow && ./install.sh
export PATH="$HOME/.local/bin:$PATH" # use the directory printed by install.sh if different
```

`install.sh` adds a `waspflow` symlink to `$HOME/.local/bin` by default. It cannot change the current shell’s `PATH`; open a new shell or export the path before running the next command.

## 2. Check the machine

```bash
waspflow doctor
```

Install every required tool that `doctor` reports missing, then run it again. You need one supported agent CLI; see [Prerequisites](prerequisites.md).

## 3. Run the safe demo

```bash
waspflow demo --provider codex
waspflow demo --provider codex --run
```

Replace `codex` with `claude`, `grok`, or `antigravity` when that is the installed CLI. Antigravity uses the `agy` executable. The demo asks the provider not to edit files; run it in a disposable directory when edits must be impossible.

If Codex displays an update or trust prompt on the first run, Waspflow will not paste the demo prompt into it. The lane stays recorded but never ran. Answer the prompt in the pane, run `waspflow reap <lane> --force`, then rerun the command.

## 4. Run a small task

From a Git repository:

```bash
waspflow spawn --provider codex --accept-provider-default --lane first-task -- \
  "Find one small bug or cleanup opportunity. Do not edit; report what you found."
waspflow wait first-task
waspflow peek first-task
```

To continue the same worker:

```bash
waspflow revise first-task -- "Implement the smallest safe fix and add a test if appropriate."
waspflow wait first-task --reap
```

A lane is a durable worker record. Reaping closes its pane and finalizes state; saved artifacts remain under `$WASPFLOW_HOME`.
