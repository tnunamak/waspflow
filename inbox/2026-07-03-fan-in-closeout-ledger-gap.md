# Waspflow gap: spawn is cheap, fan-in is manual archaeology — the missing closeout ledger

**Date:** 2026-07-03
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** The end of a very long PDPP session. Over weeks of overnight fleets, waspflow
(and a couple of hand-rolled orchestrators) spawned ~130 lanes across pdpp — the unification
harvest, the machine sweep, ~17 autoquality lanes, the g1 god-file tranches, dozens of
waspflow/* feature+audit lanes, and the oj owner-journey batch. This session I had to *fan
them back in*: figure out which branches held unique work vs. work already captured, harvest
the survivors, and reap the rest. It took most of a day, multiple delegated forensic audits,
and a ~134→11 worktree reduction. Tim's question: **was this a weakness in waspflow, AGENTS.md,
my prompting, or the pdpp process? How do we avoid it?** This is the honest diagnosis.

## The core finding: a fan-out / fan-in asymmetry

Waspflow is excellent at **fan-out** — `spawn` is one command, cheap, isolated (`--isolate`
gives each lane its own worktree), fast. But there is **no fan-in primitive.** Every lane
leaves durable artifacts (a branch, a worktree, a chunk of maybe-valuable work) and the ONLY
mechanism to reconcile them is a human/agent, later, reconstructing intent from git
archaeology. Creation is O(1); reconciliation was O(hours). That asymmetry — not sprawl
itself — is the disease. The 130 branches accumulated because nobody could cheaply answer, for
any given lane, the two questions that gate cleanup:

1. **Is this lane's work already captured somewhere shipped?** (→ reap-safe)
2. **If not, is it unique-and-wanted, or superseded/abandoned?** (→ harvest vs. drop)

Neither question has a cheap answer today, so both got answered the expensive way.

## Why each question was expensive (both are real tool gaps)

### Gap 1 — no lane closeout state ("what did this lane produce, and was it landed?")
Waspflow tracks lane *identity* (provider, session, prompt, cwd, timestamp) — that state
survived compaction and was genuinely useful. But it does NOT track lane *outcome*. When a
lane finishes, nothing records: did its work land in a PR/main? was it superseded by another
lane? was it abandoned? So "is branch X reap-safe?" required opening X, diffing it, and
searching for its content elsewhere — per branch, ~130 times (batched into delegated audits,
but still the dominant cost).

**Proposed primitive: a four-state closeout on each lane.**
```
waspflow close <lane> --status harvested   --into <pr#|ref>   # work landed here
waspflow close <lane> --status superseded  --by <lane|ref>    # a better version won
waspflow close <lane> --status abandoned   --reason "..."     # dead end, dropped
waspflow close <lane> --status live                            # still in flight
waspflow list --status harvested,superseded,abandoned          # the reap-safe set
waspflow reap --status harvested,superseded,abandoned          # cleanup becomes one command
```
The state is set at the moment the decision is made (when a PR merges, when a lane is judged a
dup, when work is dropped) — by whoever makes it, human or orchestrator. Then cleanup is
`waspflow reap --status=...`, not forensics. This is the durable-closeout-ledger idea that
already surfaced in pdpp's Codex gap audit; it keeps recurring because it's the actual missing
primitive. **This is the single highest-leverage fix.**

### Gap 2 — capture is checked by ANCESTRY, but reconciliation happens by CONTENT
The deepest time-sink: the pdpp unification PR *cherry-picked and forward-ported* work from the
lanes rather than merging them. So `git merge-base --is-ancestor <lane> <pr>` said "0 of N
captured" even when the lane's content was 100% present in the PR. Ancestry lies after any
reconciliation that isn't a straight merge. I confirmed this three separate times (the g1
tranches, the autoquality lanes, the oj cluster) — every one was "0 ancestors, ~100% captured
by content." The only reliable check was: extract the lane's distinctive symbols/files and grep
for them in the target ref. That worked, but it's per-lane and had to be re-derived each time.

**Proposed primitive: a content-capture check.**
```
waspflow captured <lane> --in <ref>   # → CAPTURED | UNIQUE | PARTIAL, by content not ancestry
```
Implementation is cheap and doesn't need to be perfect: take the lane's diff vs its fork point,
pull the added/changed top-level symbols + new file basenames, and check their presence in
`<ref>`. Even a heuristic "N of M signature symbols present in target" turns a per-lane forensic
delegation into a one-liner. Pair it with `close` (Gap 1) and the whole fan-in collapses:
`for lane in $(waspflow list --status live); do waspflow captured $lane --in origin/main; done`.

### Gap 3 (minor, symptom not disease) — worktree/`~/.tmp` sprawl
The 130 worktrees and ~16GB of `~/.tmp` deploy scratch were a *symptom* of Gaps 1–2, not an
independent problem. Tim already has a good age-based `~/.tmp` reaper (systemd daily timer). It
just can't act on *intent* ("this lane is done, reap now") — only on *age* (safe but slow, and
it correctly skips still-warm dirs). Once `close` exists, the reaper (or `waspflow reap`) can be
intent-driven for the common case and fall back to age for the rest.

## What is NOT the weakness (important, so we fix the right thing)

- **Not the prompting.** Tim's spawn prompts were fine. The lanes did the work asked.
- **Not AGENTS.md.** Its discipline (verify-before-claiming-done, prove-the-diff,
  behavior-preservation-is-a-gate, "after a rename grep for the old name") is precisely what
  *caught the lost work* during fan-in — a genuinely-lost recovery-liveness bug fix and two
  unshipped console fixes would have been silently dropped without that skepticism. The process
  worked; it just worked expensively, at fan-in, because fan-in was manual.
- **Not really the pdpp docs either.** pdpp's "get everything back to main" intent is
  well-documented and repeated; the reason it was hard to honor is the missing primitives above,
  not missing documentation.

**~15% is operator habit:** I reached for hand git/worktree forensics before asking "is there a
lane-state answer for this?" — because there wasn't one, but I also didn't push for one early.
An orchestrator should, at spawn time, be recording enough closeout metadata that fan-in is cheap
later. That's a discipline change that only pays off once the `close` primitive exists to record
into.

## The SLVP framing (Tim's actual question)

"How do I avoid this?" reduces to: **make fan-in as cheap as fan-out.** The smallest primitive
that does it is a *lane closeout ledger* (`close` + status-filtered `list`/`reap`) plus a
*content-capture check* (`captured … --in <ref>`). Those two turn every future cleanup from
"delegate N forensic audits and hand-reap" into "run one status-filtered reap." Everything else
(worktree sprawl, `~/.tmp` growth, re-deriving capture per lane) is downstream of not having
them. It is a missing *primitive*, not more docs and not stricter prompts.

## Priority / cost

- **`close` + status-filtered `list`/`reap`** — highest leverage, low cost (it's a state field +
  a filter on data waspflow already keeps). Do this first.
- **`captured <lane> --in <ref>`** — high leverage for the "reconciled, not merged" case (which is
  the pdpp norm). Heuristic is fine; ancestry-only is actively misleading here.
- **intent-driven reap wiring into the existing `~/.tmp` reaper** — falls out of `close` for free.

**Not urgent** — logged from a real, expensive run so the next big fan-in isn't a day of
archaeology. The manual path works; it's just the toil waspflow should delete, same as the
`adopt` note (2026-06-16). Related: `docs/slvp-ideal.md` (this is a fan-in gap against that bar).
