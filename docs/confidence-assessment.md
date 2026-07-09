# Waspflow bet-the-company confidence assessment

_2026-07-09. Author: the CEO agent. Written to be checked, not trusted._

## Verdict

**Confidence that the core loop is correct: ~90%. Not yet 98%.** The gap is not
"features missing" — it is **untested surface** on paths only a live run exercises.
This memo says exactly what is proven, what is not, and what would close the gap.

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
