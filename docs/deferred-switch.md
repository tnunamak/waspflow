# Waspflow: Deferred Model/Effort Switches

Status: implemented (`escalate --defer`)
Created: 2026-09-25
Related: `docs/design/ESCALATION_V1.md` (the transition this reuses),
`docs/warm-worker-restart.md` (why a resumed session is a transcript replay).

## Why

A resumed or switched session replays its transcript. If the model or effort
changes, the provider prompt cache does not match, so the next call re-reads the
whole transcript uncached. Local Claude Code logs (30 days, 2,059 sessions) show:

| First call after | Median cache hit | Median uncached tokens | n |
|---|---|---|---|
| a mid-session model switch | 2% | 520K | 34 |
| a compaction | 27% | 45K | 53 |
| an idle gap of 5-60 min | 99.8% | — | 4,530 |
| an idle gap over 60 min | 3% | — | 357 |

A switch right after a compaction re-reads about 12x less. After more than 60
idle minutes (the 1-hour cache TTL), the cache is gone anyway, so the switch
costs nothing extra. Source: `ai/research/model-routing/mid-session-model-switches-rewrite-about-12x-more-uncached-prompt-than-switching-right-after-compaction-so-defer-switches-to-cold-cache-boundaries.md`
in the dotfiles repo. Devin Fusion times model switches to compaction boundaries
for the same reason.

## Switch now or defer

- **Switch now** (`escalate --to X`) when the current arm blocks progress, for
  example a verify failure that it cannot fix. Paying for one uncached re-read is
  cheaper than more failed turns.
- **Defer** (`escalate --to X --defer`) for quota pressure, phase changes
  (planning to implementation), and downgrades. These are not urgent, so the
  switch can wait for a boundary where it costs little.

## How it works

`escalate --defer` runs the same target selection and the same eligibility gate
as an immediate escalation. A downgrade after a green checkpoint therefore needs
`--force`, as before. Then it stores a decision, not a transition: the lane field
`deferred_switch` holds `{to_arm, to_op, to_cursor, from_arm, trigger, note,
recorded_at, compactions_seen}`. No segment closes, and the arm does not change.

waspflow has no daemon, so the switch applies lazily. Before `revise` sends a
message, it checks the lane:

1. A cold-cache boundary holds (see below), and
2. the worker is between turns: no live pane, or the provider reports idle and
   the last revise barrier has cleared. waspflow never kills a running turn.

If both hold, `revise` runs the ordinary escalation transition (journal,
closing `lane_segment` receipt, provisional window, confirmed submission, CAS
commit). The revise message is the transition's submission, so the message is
sent once, on the new arm. It then records the same stale-idle barrier that a
live revise records, if the session id carried over. If either check fails,
`revise` sends on the current arm and the switch stays pending.

The operator's message goes first and unchanged. A short trailing note says that
the model/effort changed and carries the transition nonce, which the Claude
adapter needs to confirm the submission. In a live test, a correlation header in
front of the message looked like a prompt injection, and the worker refused it.

`revise --out FILE` needs a headless reply from the current arm, so it never
applies a deferred switch.

A slash command sent with `revise` (for example `revise lane -- /compact`)
completes no model turn. The revise barrier therefore stays set, and the switch
applies one ordinary turn later. This keeps the rule "never interrupt a turn"
without a Claude-specific exception.

Other rules:

- A later `--defer` replaces the pending switch.
- `--cancel-deferred` drops it.
- Any immediate transition supersedes it.
- `--defer` is refused while an escalation transition is pending.
- A handoff (`--handoff`, or a target on another provider) starts a fresh
  session. It has no cache to protect, so `--defer` applies it at once.

`status <lane>` adds `deferred_switch_status` (the record plus
`boundary_now: {holds, boundary, detail}`). `wait` prints one line about a
pending switch when the lane goes idle.

## Boundaries per provider

| Provider | Compaction signal | Idle rule default |
|---|---|---|
| claude | `{"type":"system","subtype":"compact_boundary"}` row in the session JSONL | 60 min (1-hour TTL, measured) |
| codex | top-level `{"type":"compacted"}` item in the rollout (newer CLIs also write `event_msg` `context_compacted`; older ones do not) | off |
| grok, antigravity, qwen, deepseek | not detected | off |

- **Compaction** holds when the count of compaction rows is higher than
  `compactions_seen`, the count when the switch was deferred. So the rule means
  "the session compacted after the switch was deferred", not "during the last
  turn". The saving is largest when the compaction was recent. The context that
  grew after the compaction is still re-read uncached.
- **Idle** holds when the session log has not changed for at least the cache
  lifetime. Configure the lifetime per provider with
  `WASPFLOW_CACHE_TTL_MINUTES_<PROVIDER>` (minutes; 0 turns the rule off). If a
  lane uses Claude's 5-minute cache, 60 is still safe, only late.
- **Codex idle is off by default.** OpenAI's API prompt-caching guide (read
  2026-09-25) says GPT-5.6 and later keep a prefix for 30 minutes after its last
  write or reuse (`prompt_cache_options.ttl: "30m"`). Earlier models use
  `prompt_cache_retention`: `in_memory` lasts about 5-10 idle minutes, up to one
  hour; `24h` is the default for organizations without Zero Data Retention and
  can keep entries up to 24 hours. The Codex CLI on a ChatGPT login does not use
  that API surface. We did not find which retention it gets, and we did not
  measure it, so a default could be wrong in either direction. On a lane that
  bills through the API on GPT-5.6+, `WASPFLOW_CACHE_TTL_MINUTES_CODEX=30`
  matches the documented TTL.
- Providers without a signal keep a deferred switch pending until the operator
  configures an idle lifetime, switches now, or cancels. `status` says which
  signal is missing.

Hooks: a Claude Code `PreCompact`/`SessionStart(compact)` hook would observe the
same event that the `compact_boundary` row records. Reading the row lazily needs
no hook install and no extra state, so waspflow does not use hooks for this.

## Ledger

Every transition now records `boundary` (`compaction`, `idle`, `handoff`, or
`none` for an immediate in-place switch):

- the closing `lane_segment` receipt: `segment.boundary`;
- `arm_history[]` and `escalation_path[]` entries: `boundary`.

Immediate switches record `none`, so they are the control group:

```bash
jq -c 'select(.receipt_kind=="lane_segment") | {lane_uuid, boundary: .segment.boundary}' "$WASPFLOW_HOME/receipts.jsonl"
```

Join these rows with the provider logs (usage on the first call after the switch)
to measure the cache effect per boundary.
