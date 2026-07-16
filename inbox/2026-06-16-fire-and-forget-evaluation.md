# Waspflow fire-and-forget evaluation — feedback from a real delegation run

**Date:** 2026-06-16
**Author:** Claude (orchestrating agent), at Tim's request
**Context:** Tim asked me to adopt waspflow for delegation but specifically wants
a **fire-and-forget** level of autonomy — spawn a worker, walk away, and trust
the result without babysitting the live stream. His ask: "try it, but if you see
challenges in having that level of delegation, let me know so we can get it
fixed." This doc is that report.

## What I ran (real, not a demo)

One lane, used exactly as fire-and-forget should work:

```
waspflow spawn --provider claude --lane toolextract --isolate \
  --report docs/design/TOOLCALL_EXTRACTORS_REPORT.md -- "<well-specified task>"
waspflow wait toolextract --timeout 1500     # blocked, did NOT peek the stream
waspflow reap toolextract                     # result=succeeded
```

Task: implement six tool-call family extractors (Hermes/Mistral/Command-R/
Qwen-XML/Gemma/Llama) as opt-in response-phase built-ins in a real project
(the Vivid Fish AI gateway), with a required report. I deliberately spawned,
confirmed it *started* with one peek, then walked away and only `wait`ed —
to honestly test the autonomy, not the live-steering path.

**Outcome: the work was excellent** — verified formats against vLLM parser
source + official chat templates, honest per-family confidence flags, *refused
to guess* the one undocumented format (Command-R "melody"), built a
disambiguation guard for the Hermes/Qwen `<tool_call>` collision, and got the
"false-extract is the dangerous failure → pass-through on ambiguity" principle
right. The worker committed to its branch and wrote an 11.8K report. This is the
quality fire-and-forget needs the model to deliver, and it did.

## What worked well (keep these — they make fire-and-forget viable)

1. **The spawn → wait → reap loop ran clean end-to-end** with no babysitting.
   `wait` correctly detected idle from the agent's own session log (not pane
   scraping), so I genuinely didn't need to watch.
2. **`check --no-fail` caught a dirty/renamed branch BEFORE I spawned.** Fire-
   and-forget that blindly inherits a bad repo state is dangerous; the pre-flight
   gate prevented it. This is a real safety win for unattended use.
3. **`--isolate` kept the worker off the dirty main tree** — it worked and
   committed in its own worktree/branch (`waspflow/<lane>`), zero collision.
4. **Honest result stamp + safety default on reap:** `reap` refused to remove
   the worktree because it had uncommitted (untracked) files, rather than
   silently discarding. Right default.
5. **Lane state on disk** survives orchestrator compaction — important for long
   unattended sessions.

## The gap that blocks TRUE fire-and-forget (the one to fix)

**`reap` stamps `result=succeeded` on the basis that a substantial REPORT was
written — NOT that the work is correct or that tests pass.**

Concretely, in my run: the worker's own report stated the full suite showed
`6 failed`. `reap` still stamped `succeeded`. The 6 failures turned out to be
pre-existing (collateral from a concurrent auth commit, which I verified
independently by running the tests on the base branch without the lane's work).
So the outcome was fine — **but the contract didn't know that.** `succeeded`
meant "an agent produced a deliverable," not "the deliverable is verified."

For fire-and-forget, the promise has to be: *the result is good, not just that
something was produced.* Today the correctness gate still falls on a human/
reviewer reading the diff and running the tests. That's the ~20% that keeps it
from being true walk-away-and-trust.

### Proposed fix: a verification contract on the lane

Add an optional `--verify '<command>'` (and/or `--verify-baseline`) to `spawn`
that `reap` runs and **gates the result on**:

- `--verify './venv/bin/python -m pytest -q'` → `reap` runs it; `succeeded`
  requires BOTH the report exists AND the command exits 0.
- A regression-aware variant matters in practice: many real repos have some
  pre-existing failures (mine had 6 from concurrent work). "Exit 0" is too
  strict; "no NEW failures vs a captured baseline" is the honest gate. Consider
  `--verify-baseline '<cmd>'` captured at spawn time, with `reap` failing only
  on *new* failures. (In my run, a naive `pytest` gate would have stamped
  `failed` for failures the lane didn't cause — the inverse error.)
- Result vocabulary could extend: `verified` (report + verify passed) vs
  `succeeded` (report written, not verified) vs `recovered` / `failed`. Then an
  orchestrator can trust `verified` for fire-and-forget and knows `succeeded`
  still needs review.

### Secondary gap that makes the fix harder: `--isolate` worktrees have no venv

The isolated worktree is a fresh `git worktree`; the project's virtualenv is
gitignored and lives only in the main checkout. So a worker in an isolated lane
**cannot run the project's Python / tests** unless it bootstraps its own venv —
and a `--verify './venv/bin/python ...'` command would fail for the same reason.
For verification-in-isolation to work, waspflow likely needs to either share/
symlink the parent's venv into the worktree, or document a project hook that
provisions the env. (My worker worked around it by committing without running
the full suite in-worktree; it relied on its own static analysis + the report,
which is exactly why the verify gap matters.)

### Minor observation: auto-saved `git-diff.txt` only captures the working tree

The lane auto-saves `git-diff.txt`, but my worker *committed* its work, so the
working tree was clean and `git-diff.txt` was empty (1 line). "What did this
agent change?" was answerable via `git log` on the lane branch, but the auto-diff
didn't capture committed work. Consider also snapshotting `git diff <base>..HEAD`
(committed delta vs the spawn-point base) so the committed change is recorded
where the orchestrator looks for it.

## Net assessment

Waspflow gets fire-and-forget **~80% of the way today**: the spawn / wait /
reap / isolate / report machinery is solid, the pre-flight gate is a real safety
win, and a clean walk-away worked. The missing 20% is **verification in the
contract** — `succeeded` should be able to mean "verified" (report + a passing/
no-new-failures check), not just "produced." Add a `--verify` (baseline-aware)
gate, make it runnable in isolated worktrees (venv sharing), and fire-and-forget
becomes genuinely trustworthy: an orchestrator can spawn, walk away, and act on
the result stamp without re-reviewing every diff by hand.

Until then, the honest operating model is: fire-and-forget the *execution*, but
the orchestrator still owns the *correctness gate* (read the diff, run the
tests). Which is what I did here — and the work held up.
