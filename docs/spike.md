# Empirical findings — verified mechanics + provider gotchas

Everything in waspflow rests on behavior verified by running it, not assumed.
This records what was proven (2026-06-15) and the provider-specific traps the
adapters handle.

## Verified end-to-end (both providers, through the CLI)

Full loop, with real worker output:

- `spawn → wait → live-revise → wait → reap → headless-resume`
- Codex: turns `WASPFLOW_RACE_FIXED` (spawn) → recalled across reap+resume.
- Claude: turns `ONE` (spawn) → `TWO` (live-revise) → both in transcript;
  headless resume recalled prior turns.

## Idle detection

- **Claude**: `~/.claude/projects/<slug>/<session-id>.jsonl`. Idle = the **last
  `assistant` event** has `stop_reason: "end_turn"`. NOT the genuinely-last line
  (mid-turn that's `tool_use` followed by `user` tool-result lines). Session id
  is minted by waspflow and passed via `--session-id`, so the path is known.
- **Codex**: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`. Idle = the
  **last event** is `event_msg / payload.type == task_complete`.

## Codex gotchas (handled in `lib/providers/codex.sh`)

1. **TUI requires a real PTY.** `codex | tee …` fails with `Error: stdout is not
   a terminal`. Transcripts use `tmux pipe-pane`, never a pipe.
2. **`--skip-git-repo-check` is `exec`-only** — invalid on bare `codex`; passing
   it makes the TUI exit immediately. Don't.
3. **Trust prompt** ("Do you trust the contents of this directory?") blocks
   startup in an untrusted dir. The adapter pre-git-inits a throwaway cwd and
   also answers the prompt (`1` + Enter) if it appears.
4. **Rollout is created lazily on the first turn**, not at boot. So a freshly
   spawned-but-unsubmitted session has no file yet.
5. **Match a session to a lane by `session_meta.cwd`, never by mtime.** A
   background collector re-touches old rollout files (observed: a 410 MB month-
   old file with a *current* mtime), so "newest by mtime" picks the wrong file.
   The rollout's first line records the originating `cwd` — that's the exact key.
6. **Submit is racy.** `send-keys Enter` can land during hook output / `model:
   loading`, leaving the prompt unsubmitted in the composer. The adapter types
   the prompt, then re-sends Enter until a rollout for the cwd appears (spawn) or
   the rollout grows (revise).
7. **Revise (headless, after exit)**: `codex exec resume <SID> "<msg>" -o <FILE>`
   re-enters the same session with full context; `-o` gives a clean last message.
   (`codex resume` = interactive; `codex exec resume` = headless.)
8. **Backend dependency**: Codex routes model calls through a local proxy
   (headroom :8787 here). With it down, a turn never completes — so the adapter
   preflights `$WASPFLOW_CODEX_BACKEND_HEALTH_URL` before spawning.
9. Benign noise: spawned Codex inherits the user's global session hooks (a
   `UserPromptSubmit` hook may inject text into the prompt); and a
   `codex_models_manager … missing field 'models'` error can appear when the
   backend's `/v1/models` envelope differs — neither blocks turns.

## Claude gotchas (handled in `lib/providers/claude.sh`)

1. **Folder-trust gate is separate from tool permissions.** `--dangerously-skip-
   permissions` governs *tools*, NOT the "Is this a project you trust?" folder
   prompt, which still blocks startup in an unfamiliar dir → no JSONL → `wait`
   hangs. The adapter answers it (`1` + Enter) and verifies the JSONL appears.
2. **Prompt auto-runs once trust clears** — it's passed as a positional arg and
   queued, so no separate submit is needed at spawn (unlike Codex).
3. **Live-revise submit is racy too** — same fix as Codex: type, then re-send
   Enter until the JSONL grows.
4. **Headless revise**: `claude --resume <session-id> --print "<msg>"` returns the
   reply with full prior context.
5. On some machines `claude` is itself wrapped to route through a local proxy
   (headroom). That wrapper owns its own health and is transparent to waspflow —
   no gate needed.

## Design consequences

- Idle/discovery read provider session logs; panes are only for human `peek`/
  `attach`. Never screen-scrape for idle.
- Every "did it submit?" is **verified against the session log**, not assumed —
  the single biggest source of flakiness was blind `send-keys Enter`.
- cwd is the durable join key for Codex; the minted UUID is it for Claude.
