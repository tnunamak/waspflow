# Sol adversarial review of FEDERATION_DESIGN.md (2026-07-16)

Reviewer: gpt-5.6-sol (high effort), read-only, verified findings against actual
waspflow code. Verdict: **NEEDS-REVISION** — the MVP is not buildable as specified
with its stated safety, anti-freeloading, and strict-subset properties.

Core theme: the design treats "runs on a colleague's machine" as a trust
relationship; it is a HOSTILE-CODE boundary in both directions (malicious author
attacking the executor AND malicious executor attacking the author at re-verify).

## 6 CRITICAL findings
1. §B.3 — the attacker supplies their own sandbox: the task's devcontainer.json
   defines the boundary. A hostile task requests Docker socket / host mounts /
   privileged mode. --isolate is worktree isolation, NOT a sandbox. Executor must
   own an immutable outer profile and allowlist the manifest.
2. §B.3 — "secret is outside the sandbox" ≠ authority inaccessible: any process
   reaching the masking proxy can exercise the credential (drain quota, use the
   GitHub scope, exfiltrate via allowed egress). Domain-fronting defeats hostname
   allowlists (the prior-art doc admits this). Local-model path narrows but does
   not close it. Needs a task-scoped semantic gateway with hard limits.
3. §B.2 — author-side re-verification is reverse RCE: the executor controls the
   returned branch; `waspflow verify` runs arbitrary commands with no sandbox
   (artifacts.sh:371). Re-verify must run in a fresh credential-free network-denied
   evaluator with an IMMUTABLE oracle resolved from the signed base, not the branch.
4. §B.2 — the "trivially-passing oracle" defense does not exist in code: baseline
   classification runs only on failure, only for failure_class=task; test_files_changed
   is explicitly "not a gate". A no-op against an already-green oracle earns credit.
5. §A.4/§B.4 — the master-server MVP is NOT a strict subset of the mesh: PULL/CLAIM
   target an authoritative queue+lease allocator. Swapping transport (Iroh) does not
   decentralize contention/ordering/ledger authority. Call the seam a
   "transport-independent envelope," not a system subset.
6. §B.5 — negative-balance caps reward freeloading: failed attempts cost the
   executor but debit the author nothing → publish impossible tasks, burn the pool
   free. The walkthrough's numbers contradict the ledger semantics. Needs
   claim-time escrow, attempt compensation, dispute/settlement state machine.

## MAJOR (7-12): receipts.jsonl is telemetry not a signed ledger; lane CAS is not
network fencing; several "additive" migrations change the trust/data model (bearer
token ≠ Biscuit, Firecracker ≠ devcontainer wrap, Cashu ≠ mutual-credit); local-model
is ToS-clean only narrowly; the reuse ledger materially over-claims (verified against
code: fanin_captured treats empty-token-set as CAPTURED; billing guard does NOT emit
the R3 warning the design claimed; worktrees don't isolate credentials); the wire
schema lacks replay/canonicalization/digest invariants (task_id+signature is
authenticated, not content-addressed).

## Buildable path (Sol's reframe)
NOT the spec as written. A narrower internal prototype IS buildable as: trusted
central coordinator + local models + non-sensitive allowlisted repos + a FIXED
executor-owned sandbox + sandboxed author-side verification + transactional
claim/escrow/settlement + transport-neutral payloads (no rewrite-free-mesh promise).

**Single highest-risk item to build & adversarially test FIRST, before coordinator
or adapters: the hostile-task execution boundary (the runner).** It must withstand
hostile devcontainer fields, prepare scripts, git metadata, Docker sockets, host
files, env vars, proxy abuse, DNS/HTTP exfiltration, local-model admin APIs, and
resource exhaustion — and the same boundary must protect the author at re-verify.
