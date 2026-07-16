# Headless worker budget and surface controls should be first-class

**Observed:** 2026-07-12 while delegating a small skill-authoring task from an
expensive orchestrator to Claude Sonnet.

The direct Claude fallback exposed a useful set of controls that Waspflow should
model explicitly instead of leaving callers to assemble raw CLI invocations:

- `--model sonnet --effort low` selected a deliberately cheaper worker.
- `--max-budget-usd 2` put a hard per-turn API-spend ceiling around the task.
- `--no-session-persistence` matched a one-shot worker that did not need resume.
- `--no-chrome` and no MCP configuration minimized ambient integrations.
- `--permission-mode acceptEdits` was initially too restrictive because public
  documentation fetches prompted in headless mode; rerunning in a disposable
  isolated worktree with `bypassPermissions` allowed the bounded task to proceed.
- A manually created disk-backed isolated worktree contained edits after
  Waspflow's MCP-policy parser rejected both `auto` and explicit `none` before
  launch (see `2026-07-11-claude-mcp-policy-json-failure.md`).

Potential product shape:

1. Expose a provider-neutral spend cap (`--max-budget-usd` where supported) and
   record it in lane/exec receipts alongside model and effort.
2. Make the intended capability surface explicit: filesystem writes, network,
   MCP, browser, session persistence, and permission mode. A cheap worker should
   not inherit integrations it does not need.
3. Add a bounded "public-docs + isolated writes" operating point: network is
   allowed, secrets/MCP/browser are absent, writes are confined to an isolated
   worktree, and spend is capped.
4. Distinguish quota/subscription accounting from API dollar caps. Claude's
   `--max-budget-usd` is useful only on API-billed print runs; Waspflow should
   report when a requested cap is enforceable rather than imply protection.
5. Preserve the exact direct invocation in the receipt so fallback behavior is
   auditable and reproducible without leaking prompt data or credentials.

The main design insight is that worker cost is not just model choice. It is a
budget plus an authority/surface envelope, both selected by the orchestrator and
made visible in the receipt.

Follow-up from the same session: direct `codex exec -m terra` and `-m luna`
both returned HTTP 400 (`model is not supported when using Codex with a ChatGPT
account`) before inference. The orchestrator fell back to Claude Sonnet. Model
selection should preflight account/surface compatibility and choose the cheapest
available supported worker rather than discovering unsupported aliases after
launch.
