# Waspflow gap: `exec -o` can silently produce a useless report, and provider sandbox access is too easy to miss

**Date:** 2026-07-09
**Author:** Codex, at operator request
**Context:** A narrow Vercel task was delegated with `waspflow exec --provider codex --model gpt-5.4-mini -o /home/tnunamak/.tmp/ankadata-vercel-cron-disable.md`. The worker stalled and wrote only `Execution error` to the requested report. The orchestrator had to inspect manually, stop the worker, and finish the task directly.

## What happened

The task was simple in the orchestrator's shell: inspect the `ankadata-org` Vercel project, remove the `crons` block from `vercel.json`, push, and verify `vercel crons list` showed no jobs.

The worker did not complete that path:

- It launched under Codex's own `workspace-write` sandbox, not the orchestrator's unrestricted environment.
- The relevant checkout was outside the initial project repo: `/home/tnunamak/code/_NEEDS-REVIEW/ankadata-org`.
- The worker hit MCP transport errors and shell/tool errors.
- It drifted into reading unrelated repo handbook docs.
- It left the requested report file containing only `Execution error`.

The final result was recoverable, but only because the orchestrator manually noticed the report was tiny and took the task back.

## Why this matters

`waspflow exec -o` is often used for cheap, low-attention delegation. If the output file exists but contains only a placeholder error, the caller can falsely assume a report exists. This undermines the main reason to use `exec`: low-burn fan-out with quick harvesting.

The failure was not only model quality. The tool also hid two operational facts that mattered:

- the effective provider sandbox/access differed from the orchestrator's shell;
- the report file was syntactically present but semantically useless.

## Proposed fixes

1. Validate `exec -o` output before returning success:
   - fail if the output is below a small byte threshold;
   - fail if it matches known placeholders like `Execution error`;
   - optionally require a heading or a configurable minimum line count.

2. Print or record effective provider execution context:
   - provider, model, cwd, sandbox, writable roots, approval mode;
   - whether the output path is writable before launch;
   - any known MCP/tool startup errors.

3. Add an access preflight option:
   - `waspflow exec --needs-path /home/tnunamak/code/_NEEDS-REVIEW/ankadata-org ...`
   - fail before model spend if the provider sandbox cannot read/write the required path.

4. Add a timeout/recovery pattern for cheap execs:
   - `--timeout 120 --on-timeout kill`
   - optional `--recovery-provider/--recovery-model` to summarize partial transcript into the report instead of leaving a placeholder.

5. Make report status inspectable:
   - `waspflow status <exec-id>` or equivalent should expose `output_exists`, `output_bytes`, and `output_state`.

## Priority

Medium. This is not a correctness bug in lane execution, but it is a reliability bug in low-burn delegation. The failure mode is especially likely with cheaper models and tasks that depend on local credentials or repos outside the current cwd.
