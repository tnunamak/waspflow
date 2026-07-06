# `waspflow exec` Report

## What Changed

Added a new `waspflow exec` verb for blocking, headless, one-shot provider work:

```bash
waspflow exec --provider <codex|claude> [--model M] [--effort L] [--cwd DIR] [-o FILE] -- "<task prompt>"
```

The implementation lives in `lib/exec.sh` and is sourced by `bin/waspflow`.
It does not create tmux windows, worktrees, lane state, transcripts, artifacts,
or reap contracts. It still loads the provider adapter and runs the provider
preflight before invoking the underlying CLI.

`-o FILE` writes the final message to that file. When `-o` is omitted,
waspflow writes to an internal temp file and then prints the final message to
stdout.

## Provider Invocations

Codex runs from the requested `--cwd`:

```bash
codex exec \
  [-m "$model"] \
  [-c model_reasoning_effort=<low|medium|high>] \
  -c sandbox_mode=workspace-write \
  -c approval_policy=never \
  --skip-git-repo-check \
  "$prompt" \
  -o "$output_path" \
  </dev/null
```

`xhigh` and `max` clamp to Codex `model_reasoning_effort=high`, matching the
existing spawn adapter behavior. `--skip-git-repo-check` is needed because this
verb is expected to work from scratch dirs, and Codex only accepts that flag on
`exec`.

Claude runs from the requested `--cwd`:

```bash
claude --print \
  [--model "$model"] \
  [--effort "$effort"] \
  --dangerously-skip-permissions \
  "$prompt" \
  </dev/null >"$output_path"
```

The `/dev/null` stdin redirect avoids `claude --print` waiting on stdin when the
prompt is already supplied as a positional argument.

## Verification Transcript

Syntax and repo verifier:

```bash
$ bash -n bin/waspflow lib/*.sh lib/providers/*.sh scripts/verify.sh
# no output, rc=0

$ scripts/verify.sh
waspflow: wrote /home/tnunamak/.tmp/waspflow-verify-LZndTD/.waspflow/config.json
waspflow: profiles: basic reports blockers live-stack-mutex openspec
waspflow: next: waspflow check --explain
waspflow verify: ok
```

Required Codex end-to-end run from a scratch directory:

```bash
$ scratch="$HOME/.tmp/waspflow-exec-live-$(date +%s)"
$ mkdir -p "$scratch"
$ rm -f /tmp/exec-test.txt
$ cd "$scratch"
$ PATH="/home/tnunamak/code/waspflow-waspflow-exec-verb/bin:$PATH" \
    waspflow exec --provider codex -o /tmp/exec-test.txt -- "Reply with exactly: EXEC_OK"
$ printf 'rc=%s\n' "$?"
rc=0
$ printf 'file='; cat /tmp/exec-test.txt; printf '\n'
file=EXEC_OK
```

Codex stdout fallback when `-o` is omitted:

```bash
$ PATH="/home/tnunamak/code/waspflow-waspflow-exec-verb/bin:$PATH" \
    waspflow exec --provider codex -- "Reply with exactly: EXEC_STDOUT_OK"
EXEC_STDOUT_OK
```

Claude path, because `claude` was on PATH:

```bash
$ scratch="$HOME/.tmp/waspflow-exec-claude-$(date +%s)"
$ mkdir -p "$scratch"
$ rm -f /tmp/exec-claude-test.txt
$ cd "$scratch"
$ PATH="/home/tnunamak/code/waspflow-waspflow-exec-verb/bin:$PATH" \
    waspflow exec --provider claude -o /tmp/exec-claude-test.txt -- "Reply with exactly: CLAUDE_EXEC_OK"
$ printf 'rc=%s\n' "$?"
rc=0
$ printf 'file='; cat /tmp/exec-claude-test.txt; printf '\n'
file=CLAUDE_EXEC_OK
```

Error paths:

```bash
$ waspflow exec -- "hello"
waspflow: exec: --provider is required (claude|codex)
# rc=1

$ waspflow exec --provider codex
waspflow: exec: a task prompt is required after '--'
# rc=1
```

## Gotchas

- The requested design note, `inbox/2026-07-04-exec-mode-vs-lane-mode.md`, was
  not present in this checkout. I implemented from the task contract and the
  existing headless `revise` primitives.
- A first Codex scratch-dir verification failed with `Not inside a trusted
  directory and --skip-git-repo-check was not specified.` The fix was to add
  `--skip-git-repo-check` to the Codex exec path.
- Output paths are resolved to absolute paths before changing to `--cwd`, so
  `-o result.txt` writes relative to the caller's current directory, not the
  provider working directory. The agent's work still runs from `--cwd`.

## Confidence

High for the requested surface: parser validation, syntax checks, the existing
repo verifier, Codex file output, Codex stdout output, Claude file output, and
the requested error paths all passed locally.
