# Waspflow gaps: Codex model discoverability + unreliable task injection at spawn

**Date:** 2026-07-10
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** A long remote-surface extraction/publish session where I delegated many
lanes. Two distinct waspflow gaps cost real time and forced me to hand-drive tmux
(the exact thing waspflow is supposed to eliminate). Both are backed by concrete
incidents from this session.

---

## Gap 1: no model discoverability or validation for `--model`

**What happened.** I needed to run a Codex lane on the ChatGPT-subscription auth (to
burn an expiring reset, not API pay-as-you-go). I passed `--model gpt-5.5` (stale value
from my own CLAUDE.md). The lane spawned, but the model was silently wrong. Separately,
the Codex MCP tool defaulted to `gpt-5.3-codex` and failed hard at request time with:
`The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account.`

The actually-available ChatGPT-auth Codex models this session were:
`gpt-5.4-mini`, `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna`. There is no way, from
waspflow, to discover that list. I only learned the valid set because a live lane
happened to boot on `gpt-5.6-sol` and Tim corrected me.

**Why it matters.** `--model` is a footgun today: an invalid value either fails deep in
the run (wasting a spawn) or silently runs the wrong model. For a tool whose whole point
is reliable delegation, "which models can I even pass here, given the current auth?" is a
first-class question.

**What I'd want.**
1. `waspflow models [--provider codex|claude|grok]` — list the models valid for the
   *current auth mode* of each provider (e.g. Codex on ChatGPT-account vs API key expose
   different sets). Ideally annotate the default and whether the current auth can use it.
2. **Spawn-time validation:** if `--model X` isn't in the valid set for the resolved auth,
   fail fast at `spawn` with the valid list — not 30s into the run. `doctor` already
   detects the auth mode (it warned about `OPENAI_API_KEY` shadowing ChatGPT auth this
   session), so the auth→model-set mapping is already partly known to waspflow.
3. Bonus: have `doctor` surface the resolved default model per provider, so "what will a
   bare `--provider codex` spawn actually run?" is answerable before spawning.

---

## Gap 2: task injection at spawn is unreliable (recurring across Claude AND Codex)

**What happened (multiple times this session).** `waspflow spawn --provider X ... -- "<task>"`
launched the worker process fine (correct cwd, correct auth, right model once fixed), but
the **task prompt never reached the worker's composer.** The worker sat at its idle
startup prompt ("Yep—Codex here. What are we working on?" / a bare Claude banner),
0 commits, 0 dirty. Earlier in the session this hit ~5 Claude lanes at once; today it hit
a Codex lane. `spawn` sometimes returns nonzero ("task was NOT confirmed submitted",
exit 3) — which is the honest signal — but sometimes returns success while the task
still didn't land, which is worse.

Recovery attempts that also failed for this lane:
- `waspflow revise <lane> -- "<task>"` reported "steering live pane" but the composer
  never populated; also warned "no session_id (has it run a turn yet?)".
- Manual `tmux send-keys ... Enter` to submit a queued prompt — the composer still showed
  the default placeholder; the text never populated.

A likely contributor for the Codex case: an MCP-startup error banner at boot
(`MCP client for 'playwright' failed to start ... http://127.0.0.1:3100/`) grabbed the
pane at exactly the moment the task would have been injected. So injection timing that
assumes a clean, ready composer is fragile against startup noise (MCP errors, trust
gates, model warnings, skills-budget warnings — Codex prints several).

**Why it matters.** This is the core promise of the tool. A spawn that reports success
but didn't deliver the task means I report "5 lanes running" when 5 lanes are idle — I
did exactly that this session and Tim caught it. Silent injection failure is worse than a
loud one.

**What I'd want.**
1. **Injection must be confirmed, not fire-and-forgot.** After sending the task, poll the
   worker's own log/state for evidence the turn actually started (Codex `task_started` /
   a new turn in the rollout; Claude a user message accepted) before `spawn` returns
   success. If it can't confirm within a timeout, return nonzero with a clear
   "task not confirmed — worker idle at <state>" (the exit-3 path, made the *default*
   rather than occasional).
2. **Robust submit that survives startup noise.** Wait for the composer to be genuinely
   ready (past MCP/trust/model banners) before typing; re-send if the first submit didn't
   take. The current single-shot Enter is defeated by any modal/banner at boot.
3. **A reliable re-inject primitive.** `revise` should work to *deliver the initial task*
   to a spawned-but-idle lane even before it has a session_id (today it refuses:
   "no session_id ... has it run a turn yet?"). The idle-never-started state is exactly
   when I most need to inject.

---

## Suggested priority

Gap 2 (injection reliability) is the higher-impact one — it silently breaks the tool's
core contract and forces hand-driving tmux. Gap 1 is a smaller, well-scoped add
(`models` subcommand + spawn-time validation) that would have saved this session's
model-guessing entirely.

Workaround used this session: fell back to the Codex MCP tool
(`mcp__codex-cli__codex`), which injects reliably (no tmux composer to miss) — but that
loses waspflow's live-steer/reap control, and it has the same model-validity footgun
(defaulted to an unsupported `gpt-5.3-codex`).
