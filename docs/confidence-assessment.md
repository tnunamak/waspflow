# Waspflow bet-the-company confidence assessment

_2026-07-09. Author: the CEO agent. Written to be checked, not trusted._

## Verdict

**UPDATE 2026-07-09 (live matrix run): ~96%, up from ~90%.** A free live run with
haiku workers found AND fixed the real revise/wait bug (turn_mark counted lines, not
completed turns, so the barrier cleared on the pasted message + trailing snapshots),
then proved the core loop green under concurrency: `scripts/live-smoke.sh claude 4
haiku` → 16/16 assertions, 4 parallel lanes, spawn+revise+reap all green, zero
cross-lane contamination. The gate: `bash scripts/verify.sh` (deterministic) AND
`scripts/live-smoke.sh` (live). Remaining ~4%: larger fleets (N>4), codex/grok live
matrix (only claude run live), and failure-injection. Original ~90% analysis below.

**Original: Confidence that the core loop is correct: ~90%. Not yet 98%.** The gap is
not "features missing" — it is **untested surface** on paths only a live run exercises.

**How to re-check any claim here yourself:** `bash scripts/verify.sh` (→ `waspflow
verify: ok`), `git log --oneline`, `git diff`. The suite is the oracle; I am not.

## What changed this engagement (5 commits, all on main)

| Commit | What | Evidence |
|---|---|---|
| ed56041 | false-idle (subagents), exec output-validation, guard_cwd; SKILL.md −32% | 5 behavioral tests |
| 8e8700f | behavioral tests for those 3 fixes | assert on rc + real on-disk schema |
| 4b6d84b | codex idle + fan-in ledger (close/captured) tests | real git fixture proves content-not-ancestry |
| 6ed46f6 | **found + fixed a live race**: `revise; wait` returned on the PRIOR turn's idle, silently dropping steering | reproduced live (wait=0s, edit dropped) |
| e8361c8 | robust barrier via provider `turn_mark`; fixed a regression my first fix introduced | test drives the REAL cmd_wait |

The suite went from grep-heavy to **63 behavioral assertions**.

## The most important finding

`revise` + `wait` — the core value proposition ("steer a live worker") — **silently
dropped the steering instruction** in a real run. 55 passing unit tests did not catch
it; a live smoke test did (wait returned in 0s on the prior turn's idle; the revised
edit never happened; the lane could be reaped mid-work). Fixed and locked with a
deterministic test that drives the real `cmd_wait`. **This is the single best argument
both for the product's value and for why live evidence is non-negotiable.**

I also introduced a regression while fixing it (a stale-flag false-timeout), caught it
with my own edge test, and re-fixed it correctly (session-log `turn_mark`, not the
paste-polluted transcript). That loop — fix, catch own regression, re-fix — is the bar.

## Confidence by risk area

| Area | Confidence | Basis |
|---|---|---|
| reap / verify state machine (`verified`/`verify_failed`/timeout/prepare) | **~98%** | rich behavioral tests, deterministic |
| fan-in ledger (`close`, `captured` content-check) | **~95%** | tested incl. the forward-port case ancestry would miss |
| idle detection: claude (incl. subagents), codex, grok | **~92%** | all three tested on realistic fixtures; claude gated on 3,299 real files |
| revise/wait barrier | **~90%** | deterministic test drives real cmd_wait; live-proven once, but live re-run limited by quota |
| exec cheap-fanout (output validation, guard_cwd) | **~95%** | tested accept/reject incl. false-reject guard |
| **live spawn→submit across all 3 providers, many real tasks** | **~75%** | THE GAP: only hand-run a few times; providers self-verify submission but no automated live matrix |
| token efficiency (SKILL −32%, hot-path output) | **~97%** | measured; capabilities grep-verified intact |

## What stands between us and 98%

1. **A live provider matrix** — automated spawn/wait/revise/reap against a cheap real
   task for claude AND codex AND grok, run repeatedly, asserting the file actually
   changed. Today only claude was live-exercised, and quota-limited at that. This is
   the biggest single lever; ~1 focused session, gated on quota headroom.
2. **Soak / concurrency** — a real fleet of N isolated lanes reaped together, proving
   no cross-lane state corruption under load. Untested at scale.
3. **Failure-injection** — provider crash mid-turn, proxy down, worktree deleted under
   a live lane. Some paths guard for this; none are automated.

## Honest process notes (why "flip-flopping" happened)

- I first reported the verify contract + fan-in ledger as "not built." **Wrong** — I'd
  read the CLI surface, not the code. Corrected before anything shipped on the false
  premise. Lesson: read the guts.
- I claimed work was "on a branch for review." **Wrong** — it was already on main and
  pushed to origin. Surfaced it plainly when I checked.
- I over-spent Claude 5h quota on repeated live smoke tests, then briefly mistook
  quota-throttled worker failures for code bugs. Caught it via clawmeter. Lesson:
  prefer deterministic tests; spend live runs deliberately.

Each error was caught by checking against ground truth, before it cost a shipping
decision. That is the system working — but it is why the number is 90, not 98: a
product you bet the company on should not still be surfacing these under scrutiny.

## Recommendation

Do **not** bet the company yet. Green-light one more session: the **live provider
matrix** (item 1), quota permitting, plus a small soak test. When those pass and stay
green across repeated runs, I will come back with a number at or above 98% — and it
will rest on the suite, not on my confidence.

## UPDATE 2026-07-10: ~97%, and the one thing between us and 98

All three providers now live-verified end-to-end on their real (cheap/subscription)
auth paths: claude (full loop + N=4 concurrent + dead-on-arrival), codex (full loop +
submission-confirm, works under 2-way concurrent load, subscription via
`env -u OPENAI_API_KEY` + gpt-5.4-mini), grok (full loop). Deterministic suite: 70
assertions, green + stable under load. The submission guarantee catches dead-on-arrival
on all three (exit 3, not a phantom "spawned").

THE REMAINING RISK (why 97, not 98+): a 3-way mixed-provider fleet run simultaneously
showed 2 of 3 lanes reporting spawn=NO under heavy concurrent startup load. It is NOT
corruption — isolation stayed clean and the same spawns work when re-run or under lighter
load, and the detection correctly flagged submitted=false rather than lying. But it means
sustained heavy fleets can hit spurious submission-timeouts I have not yet root-caused or
tuned. Fleets are the core use case, so this is the gap that matters.

TO REACH 98+: (1) root-cause the mixed-fleet submission timeout (likely wait/submit
attempt bounds too tight under load) and make it robust or self-retry; (2) an N=8+ soak;
(3) failure-injection (crash mid-turn, proxy down). All cheap now with haiku/gpt-5.4-mini.

## UPDATE 2026-07-10 (session 2): ~98%+. The last gap was a test bug, not a product bug.

The "mixed-fleet submission failure" that held us at 97% was ROOT-CAUSED to my own test
harness passing `--model` as one unquoted string ("--model haiku") under `env -u`, which
waspflow correctly REJECTED as an unknown option (no silent mangle). With args passed
correctly:

- Mixed-provider fleet (claude+codex+grok concurrent): GREEN, zero contamination.
- **N=8 soak** (5 claude + 3 grok, concurrent, full loop): 8/8 GREEN, zero contamination.
- **N=9 mixed soak** (3 each claude/codex/grok, scripts/live-soak.sh): 9/9 GREEN, zero
  contamination. Cheap: haiku + gpt-5.4-mini on subscription; quotas barely moved.

Two false alarms surfaced and were dispatched (both TEST artifacts, product behaved
correctly): the unquoted --model arg, and an isolation-check regex that mis-flagged files
where a worker appended without a trailing newline (real files had no foreign tags).

Gates now: `bash scripts/verify.sh` (deterministic, 70 assertions), `scripts/live-smoke.sh`
(single-provider N-lane), `scripts/live-soak.sh` (mixed-provider concurrent). All green.

Residual <2%: unbounded fleet size (tested to 9), long-duration soak (minutes, not hours),
and deliberate failure-injection (provider crash mid-turn / proxy down) — none are
day-one blockers, and the submission guarantee means failures surface honestly rather
than as phantom success. Recommendation: this is bet-the-company grade for launch; run
live-soak.sh in CI-adjacent fashion before major releases.

## UPDATE 2026-07-10 (session 4): mid-run interactive-prompt handling

Owner asked: what happens when a provider throws a mid-run prompt expecting human
input (quota/model-downgrade offer, "additional security check — keep waiting?", y/n)?
Answer BEFORE this session: waspflow only handled the STARTUP folder-trust gate. A
mid-run prompt blocked the worker; `wait` (which reads the session log for turn-end)
never saw idle and stalled BLIND until timeout. Honest (no phantom success) but wasteful
and undiagnosed — the exact class that stranded an earlier fleet.

FIXED (commit 64c1db8): `wait` now watches the lane transcript for activity; if it stops
growing for WASPFLOW_STALL_SECONDS (default 45) AND the pane matches an interactive-prompt
shape, it returns a distinct rc 4 (wait_state=blocked) with an actionable message — in
seconds, not at timeout. Per owner's explicit choice: DETECT + SURFACE, never auto-answer
(guessing could downgrade the model or approve something unwanted); the orchestrator
answers via `revise`. Detector verified: catches model-downgrade/security-wait/y-n/trust/
Enter prompts, 0 false positives on working panes; live sim returns rc 4 in ~5s.

## UPDATE 2026-07-10 (session 5): excellence pass — the seams are closed

Owner: "figure out what excellence is shippable... Apple ships excellence all the way
through, not a mix of excellent and good." Did a full excellence pass:

1. **Fixed the last documented seam — lane_set concurrency.** Per-lane flock serializes
   the read-modify-write: 40 concurrent same-lane writes now keep all 40 fields (was ~7).
   Different lanes don't contend; state-file writes fall back without flock.
   (Lifecycle transitions added later require `flock` and `doctor` now checks it.)

2. **Systematic command-surface audit (Codex gpt-5.6-terra, isolated worktree)** found 5
   seams on the read/control verbs; each independently verified, then fixed:
   - reap no longer launders an unknown `result` into `succeeded` (→ corrupt_result, nonzero)
   - list no longer launders a corrupt lane into a blank row (→ CORRUPT, exit 2)
   - clean input validation: `wait --timeout nope` (was a Bash crash), `peek --lines nope`
     (was a raw tail: error), `list --wat` (was silently ignored) — all now clean errors
   - peek --help no longer leaks grep usage; README verb table completed (ops/close/captured)

Every fix has a regression test. The reactive "fix what's reported" posture is now backed
by a systematic audit that found real seams I'd missed — and they're closed.

HONEST residual: (a) stall-detection prompt WORDING still unverified against a real
provider prompt (mechanism proven, wording is a hint by design); (b) a full per-verb
`--help` framework was deliberately NOT built (a feature, not a seam — the leak it caused
is fixed). Neither is a bet-the-company blocker.
