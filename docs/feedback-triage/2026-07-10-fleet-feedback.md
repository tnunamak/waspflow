# Fleet feedback triage — 2026-07-10

Source: ~/code/dotfiles/inbox/waspflow-feedback.md (real 20-lane codex fleet runs).
Each item verified against current code.

## Verified ALREADY HANDLED (no action; confirmed the product is sound)
- **Prompt fragmentation** (long blank-line-separated prompt split into multiple codex
  submissions): NOT reproducing. `tmux_paste_text` (load-buffer/paste-buffer) delivers a
  multi-paragraph prompt as one brief — verified live (both sections landed).
- **"wait returns before first turn"** on fresh codex lanes: the fix is at a BETTER layer
  than the author's proposed `--require-turn`: `spawn` now CONFIRMS a turn started
  (spawn_submitted=true, else exit 3) before returning, so by the time `wait` is callable a
  turn has provably started. The residual "lane idled after a conversational first turn" is
  caught HONESTLY by the `--report` contract (reaps report_missing, never a phantom success).

## SHIPPED this pass
- **Thin bundle-before-reap** (commit below): batch reap on a big repo was slow because each
  lane's archival bundle included the branch's FULL history (clone-sized per lane; a 20-lane
  reap took >2min in the field). Now archives only the lane's own commits (fork-point..tip),
  ~14x smaller in tests, still verified-recoverable; full-history fallback when there's no
  fork point (orphan branch). Same safety, fraction of the cost.

## Noted, deliberately NOT shipped (below the excellence bar / adds surface)
- billing notice fires per-revise → once/lane/session: minor UX; not worth the state.
- `--report` custom names / glob / multiple contracts: real ergonomic ask, but adds surface;
  revisit if fleets consistently need non-<lane> report names.
- codex idles after a revise turn without re-reading the standing task: that's codex CLI
  behavior, not waspflow; the workaround (restate "continue to completion") is correct.
