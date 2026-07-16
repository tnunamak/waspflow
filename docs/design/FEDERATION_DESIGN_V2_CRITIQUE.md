# Critique of FEDERATION_DESIGN_V2.md (Fable, 2026-07-16)

Role: I judge; Sol authored v2 (resolving its own v1 review) from my research. I did
NOT write the design. Caveat on my own independence: I authored the research
(FEDERATION_SECURITY_DEEP_DIVE.md) that shaped v2, so I am independent of the DESIGN
but not of the research premises — where those premises are wrong, I share the blame.
I attack the SEAMS between the well-specified pieces, since each piece in isolation is
strong.

## Verdict: SOUND-TO-BUILD, with 4 must-fix-before-pilot and 3 watch-items.

v2 genuinely resolves all 6 of Sol's criticals — I verified each against the text, not
the labels: executor-owns-sandbox (§0.1, schema-rejects task devcontainer), one-runner-
two-directions with pwn-request doctrine (§B.3.4), immutable oracle outside the candidate
tree (§B.3.4/§B.4), claim-time escrow + capped attempt-compensation with the author-
withholding fallback (§B.5), content-addressed envelopes (§B.2), and a corrected reuse
ledger that recants every over-claim (§722). The §B.3.5 ten-fixture red-team gate is the
strongest single element — it makes "prove the runner first" executable, not aspirational.
The ToS dissolution via the owner gateway is correct and clean.

## MUST-FIX before pilot

**M1 — The oracle can still be a hostile-code vector even "outside the candidate tree."**
§B.3.4 says the oracle entrypoint is selected from the signed bundle, not package.json —
good. But §0.6 and §B.4 concede "if evaluating the candidate necessarily executes
candidate code, that code is still hostile." For any real coding task the oracle RUNS the
candidate (that's what a test does). So the oracle-vs-candidate boundary is not "oracle
safe, candidate hostile" — it's "candidate code executes WITHIN the oracle's process on
the author's machine." The design handles this correctly for CONTAINMENT (it's all inside
the network-denied evaluator VM), but the SETTLEMENT REPORT is generated inside that same
VM by code the candidate influenced. A candidate that subverts the test runner to emit a
"pass" signal the report-collector trusts defeats settlement. Fix: the pass/fail signal
the trusted report-collector consumes must come from an oracle-controlled channel the
candidate cannot forge — e.g. the oracle writes a signed/HMAC'd result to a path the
candidate can't reach, or exit-code + protected-path-integrity only, NOT test-runner
stdout the candidate's process produced. §B.3.5 fixture 8 gestures at this ("cannot
influence the trusted settlement client beyond the bounded evaluation report schema") but
the report's INTEGRITY against in-VM candidate subversion is under-specified.

**M2 — Preflight baseline determinism is assumed, not enforced, and it gates money.**
§B.5.3 pays attempt_fee only if "preflight reproduced the signed expected baseline
failure." But a task author controls the base + oracle and can craft a baseline that
fails NON-deterministically (flaky test, time/network/random dependence). OPEN 4 says
"ship only deterministic fail-to-pass," but nothing MEASURES determinism. A flaky
baseline lets an author's task pay attempt_fee to a colluding executor on a coin-flip, or
lets an executor claim "baseline didn't reproduce → DISPUTED → author-fault → I get paid"
(§B.5.3 row 3). Fix: preflight must run the baseline N times (v0: 3) and require identical
classification; a non-reproducible baseline quarantines the TASK (author fault) before any
claim, not after. This is cheap and closes a settlement-manipulation seam.

**M3 — The credential injector's vsock is a confused-deputy surface.**
§B.3.3: the guest sends a sentinel over vsock; the injector swaps in the real key for the
registered gateway. But the injector validates "the claim and gateway_ref" — where does
the guest-supplied request's gateway_ref come from? If the guest can name the gateway_ref
in its request, hostile code in one task could try to exercise a DIFFERENT task's key (if
the injector holds several) or replay. Fix: the injector must bind the vsock connection to
ONE claim's ONE key at VM launch (out of band, from the host, not from guest request
fields); the guest names nothing. §B.3.5 fixture 4 tests "issuer-mismatched gateway refs"
but not "guest selects among multiple concurrently-held keys." State one-key-per-VM-launch
explicitly.

**M4 — "Author cannot avoid settlement by withholding" needs the independent evaluator to
be FUNDED and AVAILABLE, which v0 doesn't guarantee.** §B.5.3: if the author's evaluator
doesn't respond, "coordinator assigns an independent evaluator." In an internal v0 with
~10-20 colleagues, who runs it, on whose credit, against whose gateway key? The oracle
needs a gateway key to run the candidate (the candidate calls the model? no — re-verify
runs the ORACLE, which may not need the model at all; confirm this). If the independent
evaluator needs ANY gateway credential, you've created a third principal who must be
provisioned. Fix: specify that re-verification runs the oracle with NO model access
(network-denied is already stated — so the oracle must be self-contained and not call the
gateway), making any collective member a valid independent evaluator with zero credential
provisioning. If some oracles DO need model access to evaluate, that's a real gap for the
fallback path — flag which task families.

## WATCH-ITEMS (not blockers, but track)

**W1 — Redundant execution (OPEN 3) says "do not use byte equality as the agreement
rule" but never says what the rule IS.** For coding, two correct solutions differ byte-for-
byte. The only sound agreement rule is "both candidates pass the SAME immutable oracle" —
which means redundancy adds executor-collusion resistance but NOT correctness beyond the
oracle. That's fine, but state it: redundancy in v0 guards against a single lying executor,
not against a weak oracle. Two passes of a gameable oracle is still gamed.

**W2 — Firecracker excludes macOS executors (OPEN 1), which excludes Ocean's exact
example.** The founding walkthrough is Ocean on a MacBook. v0 makes her AUTHOR/coordinate-
only, not execute. That's the correct security call, but it means the flagship use case
(Ocean's idle Mac runs Tim's task) DOESN'T WORK in v0 — only Linux colleagues execute.
Not a design flaw, but a PRODUCT expectation the owner must accept explicitly: v0's
executors are Linux users; the Apple Virtualization Framework backend (OPEN 1) is what
unlocks the motivating story. Sequence accordingly.

**W3 — The signed-source-bundle assumes the author can produce a clean base artifact, but
`base_revision: git:sha1:...` (§B.2.2) is SHA-1.** Git is SHA-1; a motivated adversary can
craft SHA-1 collisions (SHAttered, 2017). The base_artifact carries its own sha256 (good),
so the bundle CONTENT is sha256-addressed — but if the design ever trusts base_revision as
an identity (it shouldn't), that's a hole. Confirm base_revision is display-only and the
sha256 artifact digest is the sole trust root.

## What I did NOT find wrong (attacked, held)
- The escrow state machine's at-most-once (not exactly-once) honesty, and the (task,
  replica, generation, terminal_event) uniqueness constraint — sound.
- The hash-chained ledger with conservation invariants — a real ledger, not receipts.jsonl.
- The reuse ledger — I tried to find a remaining over-claim; it correctly recants
  worktrees/fanin_captured/BillingPath and marks the new load-bearing components. Clean.
- OPEN 6 (source is revealed to the executor by design; a sandbox doesn't hide it) — the
  honest admission the product needs. Correct.
- Build order gates each step adversarially and forbids weakening an earlier gate. Sound.

## Recommendation
Fold M1-M4 (all are seam-tightening, none require re-architecting), accept W1-W3 as stated
tradeoffs, and the design is buildable. Build-order step 1 (the runner + its §B.3.5 red-team
suite) remains the make-or-break gate: if it doesn't pass on a real Firecracker host, nothing
downstream matters. This is a design worth building.
