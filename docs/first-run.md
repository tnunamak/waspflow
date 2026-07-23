# First Run

This is the shortest path to feeling what waspflow does.

## 1. Install

```bash
git clone <waspflow-repo-url> ~/code/waspflow
~/code/waspflow/install.sh
```

You need `tmux`, `jq`, `git`, `curl`, `uuidgen`, and at least one agent CLI:
`codex`, `claude`, `grok`, or `agy`. If any are missing, use
[Prerequisites](prerequisites.md).

## 2. Check the machine

```bash
waspflow doctor
```

If a required dependency is missing, install it and rerun `doctor`.

## 3. Run the no-edit demo

Preview the commands:

```bash
waspflow demo --provider codex
```

Run them:

```bash
waspflow demo --provider codex --run
```

Use `--provider claude`, `--provider grok`, or `--provider antigravity` if that
is your available agent CLI. For Antigravity, inspect available models first:

```bash
agy models
```

The demo launches a worker, waits until it finishes one turn, shows the result,
and reaps the lane. It does not edit your files.

Reaping means closing the worker pane and finalizing its state. The lane record
and artifacts remain inspectable.

## 4. Delegate real work

From any git repo:

A **lane** is one durable unit of delegated work. Use the lane name in every
later command for that worker.

```bash
waspflow spawn --provider codex --accept-provider-default --lane first-task -- "Find one small bug or cleanup opportunity. Do not edit yet; report what you found."
waspflow wait first-task
waspflow peek first-task
```

If you like the direction:

```bash
waspflow revise first-task -- "Implement the smallest safe fix and add a test if appropriate."
waspflow wait first-task
waspflow peek first-task
waspflow reap first-task
```

## 5. Add project policy only when you need it

Small projects do not need config. Serious repos can add it:

```bash
waspflow init --profile serious-repo
waspflow check --explain
```

If your repo uses OpenSpec:

```bash
waspflow init --profile serious-repo --profile openspec --force
```

If your repo has a live deploy/database window that only one operator should
touch at a time:

```bash
waspflow init --profile serious-repo --profile live-stack-mutex --force
```

Edit `.waspflow/config.json` to point at your actual mutex or report files.
