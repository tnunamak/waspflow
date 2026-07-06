# Waspflow Product Synthesis

Status: product recommendation
Created: 2026-07-06
Scope: design only

## Inputs Read

- `README.md`
- `docs/slvp-ideal.md`
- `docs/lane-closeout-and-fan-in.md`
- `docs/warm-worker-restart.md` from branch `docs/warm-worker-restart` (not present in this worktree)
- `inbox/2026-06-16-drive-existing-session-gap.md` from the main checkout
- `inbox/2026-06-16-fire-and-forget-evaluation.md` from the main checkout
- `inbox/2026-06-17-adopt-existing-session-feature.md` from the main checkout
- `inbox/2026-07-03-fan-in-closeout-ledger-gap.md` from the main checkout
- `inbox/2026-07-04-exec-mode-vs-lane-mode.md` from the main checkout
- `inbox/2026-07-05-advisor-lane-stateless-consult-gap.md` from the main checkout

Two tracks are excluded by the brief because they are already being built in
parallel: `waspflow exec` and billing-safety protection for stray provider API
keys. The fan-in ledger is also not a candidate here because this branch already
ships `close`, `captured`, outcome-filtered `list`/`reap`, and
bundle-before-reap in `bin/waspflow` and `lib/fanin.sh`.

## Recommendation

Build the **verification result contract** next.

Surface:

```bash
waspflow spawn --provider codex --lane fix --isolate \
  --report docs/reports/fix.md \
  --verify 'npm test -- --runInBand' \
  -- "Fix the bug and add the regression test."

waspflow wait fix
waspflow reap fix

waspflow status fix
```

`reap` should be able to stamp:

- `result=verified` when the lane produced its required report and the verify
  command exited 0.
- `result=succeeded` when the lane produced the report but no verify contract
  was configured.
- `result=verify_failed` when the report exists but the verify command failed.
- `result=recovered` only for the current missing-report recovery path, not as a
  substitute for verification.
- `result=failed` / `report_missing` for the existing failed deliverable paths.

This is the best value-per-maintenance-cost deliverable because it directly fixes
the trust gap that still blocks true fire-and-forget lane mode while staying in
local shell logic. It does not add new TUI-driving surface, provider-keymap
surface, or model-specific behavior.

## Why This Is The Top Pick

Waspflow already has durable lane machinery: `spawn` records state before launch,
including provider, cwd, worktree, report path, transcript, prompt, timestamps,
and repo root (`bin/waspflow`, `cmd_spawn`). Every lane already gets prompt,
before/after git status, and `git-diff.txt` artifacts (`lib/artifacts.sh`). Reap
already centralizes finalization (`bin/waspflow`, `_reap_one`) and calls
`artifacts_finalize` before killing the pane or removing the worktree.

The remaining correctness gap is explicit in the real fire-and-forget note:
`reap` stamped success because a substantial report existed, even though the
worker's own report said the suite had six failures. Those failures were later
shown to be pre-existing, but waspflow could not know that
(`inbox/2026-06-16-fire-and-forget-evaluation.md`). The current code confirms
that behavior: if there is no report contract, `artifacts_finalize` sets
`result=succeeded`; if the report exists and is large enough, it also sets
`result=succeeded` (`lib/artifacts.sh`).

That means `result=succeeded` currently means "the turn finished and, if a report
was required, a report exists." It does not mean "the work passed a project
gate." That naming is tolerable for live-supervised lane mode; it is too weak for
walk-away delegation.

The maintenance cost is low because verification is local and synchronous:
execute a configured command in the lane cwd, capture stdout/stderr/exit code,
store a receipt under the lane dir, and gate the final result. This reuses the
same design shape as `project_check_commands`, which already runs configured
shell commands from a project root and records bounded output
(`lib/project.sh`). It also fits the SLVP split: waspflow supplies reusable
machinery; projects declare local policy (`docs/slvp-ideal.md`,
`docs/project-checks.md`).

## Exact UX

### Spawn Flags

```bash
waspflow spawn ... \
  --verify '<command>' \
  [--verify-name '<label>'] \
  [--verify-timeout <seconds>] \
  -- '<task>'
```

Defaults:

- `--verify-name` defaults to `verify`.
- `--verify-timeout` defaults to 1800 seconds.
- The command runs from the lane's `cwd`, which is the isolated worktree when
  `--isolate` is used (`bin/waspflow`, `cmd_spawn`; `lib/worktree.sh`).
- The command is stored verbatim in `state.json` so a compacted orchestrator can
  see the contract later (`lib/core.sh`, `lane_set`).

### Reap Behavior

On `reap`, after report finalization and before worktree removal:

1. Run the verify command from `lane_get <lane> cwd`.
2. Write:
   - `verify-command.txt`
   - `verify-stdout.txt`
   - `verify-stderr.txt`
   - `verify-result.json`
3. Stamp state:
   - `verify_state=passed|failed|timeout|skipped`
   - `verify_exit_code=<n>`
   - `verify_epoch=<epoch>`
   - `result=verified|verify_failed|...`
4. Return non-zero for `verify_failed`, parallel to the existing non-zero return
   for failed deliverable contracts (`bin/waspflow`, `_reap_one`).

Suggested `verify-result.json`:

```json
{
  "name": "verify",
  "command": "npm test -- --runInBand",
  "cwd": "/repo-waspflow-fix",
  "exit_code": 0,
  "duration_seconds": 74,
  "state": "passed"
}
```

### Status/List Output

`waspflow status <lane>` already prints the full JSON state (`bin/waspflow`), so
no new command is required for machines.

Human-facing `list` can stay compact, but `check --explain` should treat
`result=verify_failed` as a risk, like `failed` and `report_missing`
(`lib/project.sh`, `project_check_lanes`). That keeps the existing "project
integrity gate" story coherent (`README.md`, `docs/project-checks.md`).

### Result Vocabulary

Do not rename the existing `succeeded` state immediately. That would churn
existing scripts. Add `verified` and `verify_failed`, and document the distinction:

- `verified`: project check passed.
- `succeeded`: lane completed and produced required deliverables, but no verify
  gate was configured.

This keeps backward compatibility while giving orchestrators a result they can
actually trust for fire-and-forget.

## Baseline-Aware Verification

The inbox asks for `--verify-baseline` because many real repos have pre-existing
failures (`inbox/2026-06-16-fire-and-forget-evaluation.md`). The product should
not over-promise a generic "no new failures" comparator in v1. Test frameworks do
not expose failures in a universal machine-readable format, and a brittle parser
would become a maintenance sink.

Recommended staged surface:

```bash
waspflow spawn ... \
  --verify 'npm test -- --json --outputFile=.waspflow-test.json' \
  -- '<task>'
```

For v1, `verified` requires exit 0. If the repo has known failures, the project
owner should provide a verification command that already encodes "no new
failures" using that repo's test tooling. Waspflow's job is to run and record the
command, not infer semantics from arbitrary stdout.

For v2, add an explicit comparator hook instead of a built-in parser:

```bash
waspflow spawn ... \
  --verify-baseline 'npm test -- --json --outputFile=/tmp/baseline.json' \
  --verify 'npm test -- --json --outputFile=/tmp/final.json' \
  --verify-compare 'node scripts/no-new-test-failures.mjs /tmp/baseline.json /tmp/final.json'
```

That preserves the architecture: waspflow owns receipts and gating; projects own
policy. It also mirrors `.waspflow/config.json` command checks rather than
creating a fake universal test oracle (`docs/slvp-ideal.md`,
`docs/project-checks.md`).

## Isolation Environment

The inbox correctly flags that isolated worktrees may not have the parent
checkout's virtualenv or gitignored dependencies
(`inbox/2026-06-16-fire-and-forget-evaluation.md`). Do not solve that by
symlinking virtualenvs by default. That is project-specific and can be wrong for
Node, Python, Rust, monorepos, and containerized repos.

Instead add one local hook:

```bash
waspflow spawn ... \
  --prepare 'corepack enable && pnpm install --frozen-lockfile' \
  --verify 'pnpm test' \
  -- '<task>'
```

`--prepare` should run in the lane cwd before `--verify`, at reap time, and write
the same receipt shape. It should be optional, explicit, and boring. A later
project-profile integration could source this from `.waspflow/config.json`, but
the per-lane flag is the smallest useful product surface.

## What This Does Not Solve

- It does not prove semantic correctness beyond the configured command. If the
  command is weak, `verified` is weak.
- It does not replace review for invasive changes. It gives an orchestrator a
  hard result stamp, not omniscience.
- It does not solve provider spend safety; that is the separate billing guard
  track excluded by this brief.
- It does not solve stateless analysis; that is the separate `waspflow exec`
  track excluded by this brief.
- It does not solve stale context on warm resumes. That belongs to the warm
  restart design.

## Ranking Of Remaining Deliverables

1. **Verification result contract**: highest value, low maintenance. It upgrades
   lane mode from "produced a report" to "passed the configured project gate" and
   is pure local orchestration over state waspflow already owns
   (`lib/artifacts.sh`, `bin/waspflow`, `lib/project.sh`).

2. **Advisor lane surfacing**: very high value-per-cost, but smaller than
   verification. The machinery already exists: `spawn` creates a session,
   `revise` resumes or steers it, and state survives under `$WASPFLOW_HOME`
   (`README.md`, `lib/core.sh`, provider adapters). Add an `advisor` recipe to
   README/skill and optionally a `kind=advisor` state field so `check` does not
   nag about a deliberately long-lived consult lane
   (`inbox/2026-07-05-advisor-lane-stateless-consult-gap.md`). This is mostly
   product naming and documentation.

3. **Warm worker restart**: valuable but narrower and more dangerous. The design
   already found the hard truth: resume is a replayed transcript, not warm model
   state, and stale file beliefs are real (`docs/warm-worker-restart.md`). Ship
   only after the product can re-ground the agent before it acts. Maintenance
   cost is moderate because it touches worktree rehydration, provider resume
   semantics, and drift thresholds, though it benefits from deterministic
   worktree paths (`lib/worktree.sh`) and bundle-before-reap (`lib/fanin.sh`).

4. **Adopt/state-aware revise**: defer. The problem is real and painful, but the
   proposed fix couples waspflow to fast-moving TUI behavior: Codex Enter/Tab
   semantics, keymaps, regressions, pane-state heuristics, and provider-specific
   busy/idle UI (`inbox/2026-06-16-drive-existing-session-gap.md`,
   `inbox/2026-06-17-adopt-existing-session-feature.md`). The current code
   already carries provider-specific TUI driving for spawned lanes
   (`lib/providers/codex.sh`, `lib/providers/claude.sh`); expanding that to
   arbitrary pre-existing panes is expensive forever.

## Deliverables To Decline Or Defer

Decline a generic built-in "no new failures" parser. It sounds like verification
but would actually encode test-framework policy inside waspflow. Prefer
`--verify-compare` hooks later.

Defer `adopt` as a first-class command. It is the highest maintenance item in
the inbox because it depends on externally changing TUIs. If it is ever built,
the narrow first slice should be "read-only adopt" (`peek`/`wait` with a state
header) before allowing `revise` to drive a human-owned pane.

Defer `warm` until re-grounding is mandatory and testable. Raw `revise` on an
old lane already exists, but the warm-restart doc shows why exposing that as a
product promise without drift detection would be unsafe
(`docs/warm-worker-restart.md`, `lib/providers/claude.sh`,
`lib/providers/codex.sh`).

Do not re-propose `exec` or billing safety in this lane. They are already active
parallel workstreams by instruction.

## Open Questions

- Should `--verify` be a spawn-time contract only, or should `waspflow verify
  <lane>` also exist for rerunning after manual fixes?
- Should `--prepare` be allowed to mutate the lane worktree before the final
  bundle/reap? The practical answer is yes, but the receipt must make that
  visible.
- Should `result=succeeded` eventually be renamed to `result=unverified`? The
  product meaning would be clearer, but the compatibility cost may not be worth
  it yet.
- Should `.waspflow/config.json` define default verify/prepare commands for a
  repo, with per-lane override? This matches the SLVP policy split, but the
  first implementation can stay flag-only.
