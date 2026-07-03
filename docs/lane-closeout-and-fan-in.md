# Waspflow: Lane Closeout & Fan-In

Status: implemented (2026-07-03) — all three primitives shipped in `bin/waspflow` + `lib/fanin.sh`.
Created: 2026-07-03
Related: `docs/slvp-ideal.md` (this closes a stated-but-unrealized gap in the ideal),
`inbox/2026-07-03-fan-in-closeout-ledger-gap.md` (the real-run diagnosis this is drawn from)

Implementation notes (where the doc and the code differ):
- The closeout state is a **separate `outcome` field** (open|harvested|superseded|abandoned),
  NOT an extension of the lifecycle `status` field (live|reaped). Reap owns `status`; keeping
  them separate means reaping a lane never clobbers its closeout decision — a lane reads as
  `harvested` (outcome) AND `reaped` (status). `list --status` / `reap --status` filter on `outcome`.
- `captured` checks signature tokens by KIND: new-file basenames by PATH presence in the ref,
  added top-level symbols by CONTENT presence. Verdicts: CAPTURED (all present) / UNIQUE (none) /
  PARTIAL (mixed — the unshipped tokens are the harvest candidates).
- Bundles land in `$WASPFLOW_ARCHIVE_DIR` (default `$WASPFLOW_HOME/archive`), verified before any
  deletion; `reap --no-archive` opts out.

## Thesis

Waspflow makes **fan-out** cheap: `spawn` is one command, isolated, fast. It does not yet
make **fan-in** cheap. When many lanes finish, the work of deciding *which produced unique
value, which was superseded, which is already captured, and which is safe to reap* falls back
onto a human (or an orchestrating agent) doing git archaeology, per lane. Creation is O(1);
reconciliation is O(hours). That asymmetry is the gap.

This is not a new idea bolted on — the SLVP ideal already commits to it and just hasn't
realized it. `docs/slvp-ideal.md` lists as reusable machinery:

- "durable lane artifacts: prompt, transcript, state, **status**, diff, and report" — the
  status field is named but under-used; there is no *outcome* status a fan-in can filter on.
- project integrity for "**unreaped lanes**" — flagged as a concern with no cheap way to
  resolve it.
- "**Reaping is cleanup, not data loss; lane artifacts remain inspectable.**" — the right
  principle, but unhonorable in practice without a reliable "this lane's value is safe to
  reap" signal.

This doc proposes the two primitives that turn those commitments into one-command operations.

## The two questions fan-in must answer cheaply

For any finished lane, cleanup gates on:

1. **Is this lane's work already captured somewhere shipped?** → reap-safe.
2. **If not, is it unique-and-wanted, or superseded/abandoned?** → harvest vs. drop.

Today neither has a cheap answer, so both get answered by opening the lane, diffing it, and
searching for its content elsewhere — repeated across every lane. The two primitives below
answer them directly.

## Primitive 1 — Lane closeout status (the ledger)

Extend the lane's existing `status` with a small, closed set of **outcome** states, set at the
moment the decision is made (a PR merges, a lane is judged a dup, work is dropped):

| status | meaning | set when |
|---|---|---|
| `live` | still in flight | default while working |
| `harvested` | work landed in a named ref/PR | that PR/commit lands |
| `superseded` | a better version won | when another lane/ref is chosen over it |
| `abandoned` | dead end, intentionally dropped | when the work is decided against |

```
waspflow close <lane> --status harvested  --into <pr#|ref>
waspflow close <lane> --status superseded --by   <lane|ref>
waspflow close <lane> --status abandoned  --reason "..."

waspflow list --status harvested,superseded,abandoned      # the reap-safe set
waspflow reap --status harvested,superseded,abandoned       # fan-in cleanup in one command
```

Design notes:
- **Provenance, not just a flag.** `--into` / `--by` / `--reason` make the ledger an audit
  trail: "why is this reap-safe?" is answerable later without re-deriving it. This is what
  makes `list --status` trustworthy enough to drive `reap`.
- **Who sets it.** Whoever makes the call — the orchestrating agent when it lands a harvest,
  a human closing out a branch, or `spawn`'s parent when it merges. The primitive is the same.
- **Reap stays non-destructive per the SLVP principle:** reaping a closed lane removes its
  worktree; its branch/bundle and artifacts remain inspectable. `abandoned` is the only status
  where dropping the branch too is the intent (still bundle first — see Ops below).
- **Integrity check falls out.** `slvp-ideal`'s "unreaped lanes" concern becomes: warn on any
  lane that is `live` but idle > N days, or `harvested/superseded/abandoned` but still holding
  a worktree.

## Primitive 2 — Content-capture check (ancestry lies after reconciliation)

The deepest fan-in time-sink in practice: when integration cherry-picks or forward-ports lane
work (rather than a straight merge), `git merge-base --is-ancestor <lane> <ref>` reports "not
captured" even when the lane's content is 100% present. Observed three separate times in one
pdpp fan-in (the g1 tranches, the autoquality lanes, the oj cluster) — every one was "0
ancestors, ~100% captured **by content**." Ancestry is the wrong test; it is actively
misleading after any non-merge integration, which is the norm for reconciliation work.

```
waspflow captured <lane> --in <ref>   # → CAPTURED | UNIQUE | PARTIAL (by content, not ancestry)
```

Heuristic implementation (cheap; need not be perfect):
1. Diff the lane vs its fork point (`merge-base <lane> <fork-ref>`), extracting **signature
   tokens**: added/changed top-level symbol names (exported fns/types/consts) + new file
   basenames.
2. For each token, test presence in `<ref>` (`git grep`/`git ls-tree`).
3. Report `CAPTURED` (≈all present), `UNIQUE` (≈none present), or `PARTIAL` (mixed, list the
   unshipped tokens — the actual harvest candidates).

Even a coarse "N of M signature tokens present in target" collapses a per-lane forensic
delegation into a one-liner. It composes with Primitive 1:

```
for lane in $(waspflow list --status live --json | jq -r '.[].name'); do
  waspflow captured "$lane" --in origin/main
done
# CAPTURED  -> waspflow close <lane> --status harvested --into origin/main
# UNIQUE    -> keep, it's a real harvest candidate
# PARTIAL   -> the listed unshipped tokens are the only thing to harvest
```

That loop *is* fan-in. It turns "delegate N forensic audits and hand-reap 130 branches" into a
scripted pass plus a short human decision on the `UNIQUE`/`PARTIAL` set.

## Ops: bundle-before-reap (already learned, worth encoding)

Nothing is pushed for most lanes, so `git branch -D` is irreversible. The pdpp fan-in used
`git bundle create` + `git bundle verify` per cohort before any deletion, giving a recoverable
archive. `waspflow reap` should do this by default: bundle the reaped lanes' tips to
`<archive>/reaped-<date>.bundle`, verify, *then* delete — so "reaping is cleanup, not data
loss" is literally true even for unpushed branches. A `--no-archive` opt-out for the truly
disposable.

## What this is explicitly NOT solving

- **Not orchestration quality.** Lanes did the work asked; prompts were fine. This is purely
  about the *fan-in* seam.
- **Not a replacement for project skepticism.** The consuming project's verify discipline
  (behavior-preservation gates, prove-the-diff, grep-after-rename) is what *catches lost work*
  during harvest — a genuinely-lost bug fix and two unshipped fixes were saved by it in the
  pdpp run. `captured` tells you *where* to look; it does not replace *checking*.
- **Not the `~/.tmp` reaper's job.** Age-based tmp cleanup stays as-is (safe fallback);
  `close`+`reap` handle the intent-driven common case. They're complementary.

## Priority

1. **`close` + status-filtered `list`/`reap`** — highest leverage, low cost (a status field +
   filters on data waspflow already keeps). This alone makes fan-in tractable.
2. **`captured <lane> --in <ref>`** — high leverage for the reconciled-not-merged case (the
   common one). Heuristic is fine.
3. **bundle-before-reap default** — small, makes the SLVP "not data loss" claim literally hold.

Together these make **fan-in as cheap as fan-out**, which is the one-line statement of the gap.
