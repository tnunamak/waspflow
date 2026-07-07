# Waspflow: Warm Worker Restart

Status: proposal (design only — no implementation yet)
Created: 2026-07-06
Related: `docs/spike.md` (verified resume mechanics), `docs/lane-closeout-and-fan-in.md`
(the bundle-before-reap artifact this reuses), `inbox/2026-07-05-advisor-lane-stateless-consult-gap.md`
(the sibling "advisor lane" pattern — a *different* reuse shape; see "Scope" below).

## The ask

A worker lane completes a coding task in its isolated worktree (branch `waspflow/<lane>`).
Later, the orchestrator wants to give that **same agent more work**, reusing its accumulated
session context — it already "knows" this codebase — instead of cold-spawning a fresh agent that
must re-learn the repo from zero. The resume machinery already exists (`revise` on an exited lane
resumes the provider session headlessly). The question is what DX turns that primitive into a
trustworthy "warm restart," because the naive version is subtly dangerous.

## Scope: warm WORKER restart, not the advisor lane

The `2026-07-05` note describes an **advisor lane** — a long-lived reasoning agent you consult
repeatedly, no worktree, no deliverable, detach-not-reap. That's real but *separate*: it's
stateless-consult-made-stateful, and the machinery (spawn once, `revise` per question) already
covers it with only docs missing.

This doc is the harder, more valuable case: a **worker** that finished, whose value is its
built-up *codebase* context (repo structure, where things live, what it already changed), and which
you want to re-task against the *same working tree*. The worktree/branch lifecycle and repo drift
make this materially different from the advisor case.

## The core finding that reshapes the design

**"Warm restart" is not "resume a warm model." It is "cold model + a long transcript prefix."**
Neither Claude Code nor Codex restores saved model state on resume — they replay the persisted
*transcript* to reconstruct context. That transcript contains **stale file snapshots**: the agent
"sees" files as they were when it first read them, and neither provider re-reads the filesystem on
resume (Aider is the lone exception in the field — it re-reads in-chat files every turn).

So a resumed worker believes the repo is as it was at completion. If `main` (or the lane branch)
moved since, its world model is wrong — and models **anchor on stale beliefs even when fresh
evidence is available** (STALE benchmark, arXiv 2605.06527: best model 55.2% at acting on updated
evidence; the gap is between *retrieving* an update and *acting* on it). A warm restart therefore
**cannot rely on the agent to notice drift on its own.** This single fact drives every requirement
below.

Corroborating open bugs: Codex #22384 "stale file content remains in model context … may apply a
patch based on the earlier context"; Claude Code staleness reports #45073 / #3104 / #3032;
governance/instruction decay across resume #29746.

## Verified end-to-end (BOTH providers, through waspflow — 2026-07-06)

Ran the exact spike this doc calls for on Claude AND Codex; the load-bearing claims are facts, not
inference. **Both providers behaved identically** on all three points below — the DX generalizes.
(Claude codewords shown; the Codex run reproduced the same BLUEHERON→stale→REDFOX result.)

1. **Same-path resume works after reap.** Spawned an isolated Claude lane that read a marker file
   (`FACT.txt` → codeword `BLUEHERON`) and remembered it; reaped it (worktree removed, branch
   archived to a bundle by fan-in's `fanin_bundle_lane`); recreated the worktree at the **same
   absolute path** via `git worktree add <path> waspflow/<lane>` (rehydrate-ladder step 2); then
   `claude --resume <id> --print` from that path. It resumed cleanly (no "No conversation found")
   and **recalled `BLUEHERON`** from the prior session. → same-path resume is confirmed.

2. **Stale context is real and dangerous.** With `FACT.txt` changed on disk to `REDFOX` under the
   resumed agent, a plain resume question still answered **`BLUEHERON`** — it trusted its replayed
   transcript and did NOT re-read. This is the footgun, reproduced.

3. **Explicit re-grounding fixes it.** The same resume, prefixed with "your view of FACT.txt may be
   STALE — re-read it now," made the agent re-read and correctly answer **`REDFOX`** (it even flagged
   the change). → the design's step-2 re-grounding is not optional polish; it is what makes warm
   restart correct. Raw `revise` on a drifted lane is a stale-belief hazard.

## What we verified against waspflow's own code (not just the literature)

- **The worktree path is deterministic:** `<repo-parent>/<repo>-waspflow-<lane>`
  (`lib/worktree.sh:32`). Same lane name → same absolute path, always.
- **Claude resume is keyed purely by the encoded absolute cwd** (`~/.claude/projects/<encoded-cwd>/
  <session-id>.jsonl`; the `--cwd` cross-dir flag was requested and closed WONTFIX upstream, #58591).
  Because the key is the *path string*, **recreating the worktree at the same path makes resume
  "just work"** — inode identity is irrelevant. High-confidence inference from documented
  path-keying; cheap to prove (see Open Questions).
- **Lane state already records** `worktree`, `session_id`, `rollout`, `repo_root`, `origin_cwd`
  (`bin/waspflow` spawn `lane_set`). The **only missing field** warm restart needs is a
  `last_seen` git ref (HEAD at spawn / last revise) to compute the drift diff.
- **`fanin_bundle_lane` (shipped in #2) already produces the rehydrate-from-archive artifact** the
  worktree-lifecycle ladder needs. Fan-in and warm-restart compose directly.

## Prior art — the verb triad the field converged on

Both frontier CLIs independently settled on the same triad; steal it, don't reinvent it.

| concept | Claude Code | Codex | waspflow today |
|---|---|---|---|
| continue same session | `--resume <id>` / `--continue` | `codex exec resume <id>` | `revise` (exited lane) |
| **fork** (new id from same history, original left intact) | `--fork-session`, `/branch`\|`/fork` | `codex fork <id>` | — (missing) |
| pick by cwd | `/resume`, `-c` | `resume --last` | — |
| replay (deterministic, no model) | — | — | (OpenHands has it; distinct concept) |

Lessons:
- **Resume by explicit session ID, never "most recent."** In `-p`/headless, `--continue` can silently
  mint a NEW session; Anthropic's own docs say use explicit `--resume <id>` for automation. waspflow
  already does this (mints `--session-id` at spawn) — keep it.
- **`fork` is cheap and matches mental models** — "more work, but don't pollute the original lane's
  branch/history." Worth offering as an explicit opt-in.
- **Replay ≠ resume.** Keep the vocabulary distinct if we ever add trajectory replay.

## When warm-restart actually beats cold-spawn (be honest — it's narrow)

Warm's advantage is **narrow and mechanical**; cold-spawn's is **broad and compounding**.

**Warm wins when** — the task is a *continuation* of the same work, context is *still small and
clean*, working state is *hard to serialize*, AND the prompt prefix is *frozen* (any tool/instruction
change busts the prompt cache, erasing the main economic win). Prompt-cache reads are 0.1× vs a fresh
1.25× write; reads are ~76% of tokens on SWE-Bench, so not re-deriving repo structure is real savings.

**Cold wins when** — context rot has set in (performance degrades 13.9–85% with transcript length
*even below the window limit and at 100% retrieval recall*, arXiv 2510.05381); the agent would
self-condition on its own possibly-wrong prior outputs; or the drift is large. The labs' actual
convergence is **neither pure-warm nor pure-cold but cold-with-handoff**: a fresh context seeded by a
durable on-disk summary (Anthropic's `claude-progress.txt` + git history; Sourcegraph Amp abandons
compaction entirely and re-seeds a fresh agent). Known failure mode: a verbatim "## Active Task"
block leaking into the fresh session as its own job (#14603) — **handoffs must be reference-only.**

**Design consequence:** don't make warm-restart the only path. Make the warm/cold choice cheap and
reversible by keeping state durable on disk (waspflow already captures prompt/transcript/diff/report
— that IS the cold-handoff substrate). Warm `--fork` and cold `--fresh-handoff` are siblings.

## Proposed DX

A first-class **`warm`** verb (name TBD — `resume` collides with the internal notion; `revise` stays
for live steering). Shape:

```
waspflow warm <lane> -- "<the new task>"          # continue same lane + branch, re-grounded
waspflow warm <lane> --fork <newlane> -- "<task>"  # new lane/branch from the same session history
waspflow warm <lane> --fresh -- "<task>"           # COLD: fresh agent seeded w/ a reference handoff
```

`warm <lane>` (default = continue) does, in order:

1. **Rehydrate the worktree (the "rehydrate ladder"), reusing fan-in's bundle:**
   1. worktree on disk at the deterministic path → reuse in place;
   2. gone but branch survives → `git worktree add <original-path> waspflow/<lane>` (re-add the
      *existing* branch so lane commits aren't lost to an `origin/HEAD` default base);
   3. only the bundle survives → `git fetch <bundle> waspflow/<lane>:waspflow/<lane>`, verify, then
      add. (This is why bundle-before-reap matters: it makes reaped lanes warm-restartable.)
   4. after any rehydrate, re-run env bootstrap — tracked history travels; gitignored deps/`.env`
      do not.

2. **Re-ground the agent BEFORE it acts (the load-bearing step).** Compute drift since `last_seen`
   and inject it as the first thing the resumed agent sees, with an explicit instruction to re-Read
   changed files before acting — a raw diff alone under-grounds:
   ```
   Since you last worked here, the repo moved. Treat your in-context view of these files as STALE
   and re-read them before editing.
     git log --oneline <last_seen>..HEAD     (what changed)
     git status --short                      (working tree)
     git diff --stat <last_seen>..HEAD       (scope)
   Restate the current branch and HEAD before you begin.
   ```
   Claude: a SessionStart `resume`-matcher hook writing `hookSpecificOutput.additionalContext` is the
   native vehicle (post-2.1.0 hooks must use the JSON field, not stdout). Codex: prepend to the
   `exec resume` message. Re-inject CLAUDE.md/AGENTS.md too (demonstrably dropped across resume).

3. **Verify grounding** — require the agent to restate branch/HEAD; if it can't, fall back to cold.

4. **Continue on the same branch** (commits accumulate → one coherent PR). `--fork` opts into a new
   branch/lane for a genuinely separate concern.

`--fresh` skips resume entirely: cold-spawn a new lane, seed it with a **reference-only** handoff
built from the prior lane's durable artifacts (prompt + report + `git diff <base>..HEAD` + a pointer
to the branch), never pasting stale directives as live ones.

State to add: **`last_seen`** (git ref, set at spawn and each `wait`/revise) — the one new field.

## DX shapes to AVOID (learned from upstream)

- Cross-directory resume via a `--cwd`-style flag — rejected upstream, fragile. Recreate the path
  instead.
- "Most recent"/`--continue`-style resume in automation — can silently fork a new session.
- Treating a bare `git diff` as sufficient re-grounding — it under-grounds; pair with forced re-reads.
- Copying an "## Active Task" block verbatim into a fresh handoff — leaks stale directives as new ones.

## What this is explicitly NOT

- **Not the advisor lane** (`2026-07-05`) — that's docs over existing `spawn`/`revise`; this is a
  new re-grounding + worktree-rehydration surface for worker reuse.
- **Not trajectory replay** (OpenHands-style deterministic re-execution) — a different feature.
- **Not a claim that warm > cold** — it's a claim that the *choice* should be cheap, explicit, and
  re-grounded, with cold-handoff as a first-class sibling.

## Priority & open questions

**Priority:** medium. The primitive works today (`revise` an unreaped lane); the value-add is
(a) making it SAFE via re-grounding — without which warm restart is a stale-belief footgun — and
(b) making it possible after reap via the rehydrate ladder. (a) is the part that shouldn't ship as
raw `revise`.

**Open questions to resolve before implementing:**
1. ~~Prove the same-path resume claim for Claude~~ — **DONE (2026-07-06), see "Verified end-to-end"
   above.** Same-path resume works after reap; stale-context reproduced; re-grounding fixes it.
2. ~~Codex path-sensitivity~~ — **DONE (2026-07-06).** Ran the identical spike with `--provider
   codex`: `codex exec resume <id>` from the recreated same-path worktree recalled the prior codeword
   (BLUEHERON), defaulted to stale, and re-read correctly (REDFOX) when re-grounded — matching Claude
   exactly. Both providers verified; no path-sensitivity surprises.
3. **Drift threshold for auto-preferring cold** — is there a commits/files-changed or
   transcript-length line past which `warm` should refuse and recommend `--fresh`? Needs a couple of
   real runs to calibrate, not a guess.
4. **Verb name** — `warm` vs `retask` vs extending `revise --new-task`. Wants one real usage to feel
   the ergonomics before committing.
