# Excellence audit — full command/config/recovery surface (2026-07-16)

Bet-the-company phase-3 excellence audit (broader than the invariant red-team).
5 auditors by failure class (truth/integrity, reliability/lifecycle, input/trust,
operability, config/schema) in isolated read-only worktrees; synthesis judge;
every finding independently reproduced by the maintainer before fixing.

## Headline
**No fail-open success-fabrication survived through the normal spawn→wait→reap
path, across all five failure classes.** The core result-integrity spine held
under direct attack. Surviving findings are on the edges: operator-facing
misreporting, a liveness busy-spin, output-neutralization, and fail-CLOSED
diagnostic gaps. 12 ranked findings; the 4 highest-value fixed here.

## Fixed in this batch (all reproduced, all regression-tested)
- **Rank 5 (P2, SECURITY)** — `waspflow check` ran arbitrary shell from a
  `.waspflow` config in ANY ancestor directory, no trust gate. `project_find_config`
  walks up parents, so a config planted in a cloned repo / shared parent executed
  as you. Fix: refuse configs outside the resolved project root; require
  `WASPFLOW_ALLOW_PROJECT_COMMANDS=1` to run the arbitrary-command block at all.
  (Doubly relevant to Federation, where you pull others' repos.)
- **Rank 12 (P2, crash)** — garbage numeric knobs (`WASPFLOW_STALL_SECONDS=abc`
  etc.) reached an arithmetic context and aborted the command with an opaque
  `set -u` "unbound variable". Fix: `numeric_knob` validates and fails loud at
  three read sites (stall, gc-age, report-min-bytes).
- **Ranks 1 & 11 (P1, operator-lie)** — `list`'s tab-delimited `read` collapsed
  consecutive tabs, so an empty middle field (`repo_root=""` on a non-isolated
  lane) shifted window/pane_pid empty → a dead lane read as `live`, and human
  `list` disagreed with `list --json`. Fix: delimit with the US control char
  (0x1f), which `read` does not collapse; human and json now agree.

## Deferred (P2 and below, clustered — follow-up batch)
- Rank 2 (P1, liveness): `wait --reap` can busy-spin on a revise-barrier TOCTOU.
- Rank 3 (P1): `peek` leaks OSC terminal-control sequences (strip_ansi covers only
  CSI); output-neutralization hardening.
- Rank 4 (P1→narrowed): corrupt-but-provider-yielding state.json could launder to
  succeeded via a direct finalize call; full reap is protected (empty provider →
  load_provider dies first). Defense-in-depth: add a parseability gate.
- Rank 6/7 (P2): exec `-o` codex freshness; grok exec effort none/minimal drop.
- Rank 8 (P2): raw `cd:` error leaked before the clean waspflow error.
- Rank 9/10 (P2): empty/duplicate operating-points.json accepted; all fail CLOSED.

## Quality evidence
Extensively-attacked surfaces that HELD: per-lane op-lock enforces real
cross-process mutual exclusion; double-reap idempotent; interrupted-escalation
lanes fail closed; `validate_lane_name` rejects traversal/injection; prompts use
paste-buffer not send-keys eval; provider argv `printf %q`-quoted; secrets record
names not values; preferred_over cycle detection correct; quota gate never
fails open.

## Note
The suite has documented load-sensitivity: timing-dependent tests (sleep-based
escalation/wait seams) flake under concurrent machine load. Confirmed the 4 fixes
green on a clean run; failures wandered across unrelated timing tests between runs.
A separate hardening item (make those tests load-robust).
