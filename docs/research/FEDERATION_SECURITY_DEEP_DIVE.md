# Federation security deep-dive — the adversarial spine (2026-07-16)

Prompted by Sol's design review (`FEDERATION_DESIGN_REVIEW_SOL.md`, 6 CRITICALs).
The prior-art dossier (`FEDERATION_PRIOR_ART.md`) covered the technology broadly;
this closes the *adversarial* gaps the review exposed. Researched by Fable directly
(web) — sources inline, accessed 2026-07-16. FACT = sourced; ANALYSIS = mine.

The one reframe everything hangs on (from the review): Federation is a **hostile-code
boundary in BOTH directions** — a malicious task attacking the executor, AND a
malicious executor attacking the author at re-verification. Every finding below is
scoped to one of those two directions.

## 1. Hostile task → executor (the sandbox boundary; Sol C1, C2)

**FACT — the boundary must be executor-owned, never task-supplied.** The exact
failure Sol named ("attacker supplies their own devcontainer") is a named 2026 class:
*Configuration-Based Sandbox Escape (CBSE)* — AI-coding-tool sandbox escapes via
privileged config (Cymulate, https://cymulate.com/blog/the-race-to-ship-ai-tools-left-security-behind-part-1-sandbox-escape/;
also Gemini CLI + Claude Code escapes + OAuth-token theft in the same research). The
consensus: *treat AI-generated / pulled code as untrusted BY DEFAULT and enforce it
STRUCTURALLY, not heuristically* (Modal, https://modal.com/resources/run-untrusted-code-safely;
Northflank, https://northflank.com/blog/how-to-sandbox-ai-agents). OWASP Agentic
ASI05 makes sandboxing a REQUIRED control, not a recommendation.

**FACT — isolation tiers, gold standard = microVM.** Plain Docker shares the host
kernel (escape CVE-2024-21626, Snowflake Cortex CLI escape CVE fixed v1.0.25 / Mar
2026). Firecracker microVMs: own kernel, ~125ms boot, <5 MiB overhead, ~150 VM/s/host
(Northflank; Modal). **Ephemeral / destroyed-after-run** is doctrine — prevents
persistence and state leakage (directly relevant to per-task re-verification).

**FACT — credential isolation: the secret never enters the sandbox (Sol C2).** The
2026 best practice, converged across Cloudflare, Anthropic, NSA, MCP guidance: a
**credential-injecting egress proxy** — real secrets stay OUTSIDE, the sandbox sees a
placeholder; the proxy swaps in the real credential only for allowed hosts (Cloudflare
Outbound Workers for Sandboxes, GA 2026-04-13, https://softprom.com/cloudflare-agents-week-2026-20-new-features-for-ai-agents;
Envoy `credential_injector` filter; Claude Code `mask` mode). **Sol's exact criticism
confirmed:** hostname-allowlist proxies that don't terminate TLS are defeated by
domain fronting; you need a **TLS-terminating** proxy for real egress control
(Claude Code secure-deployment docs, https://code.claude.com/docs/en/agent-sdk/secure-deployment;
Anthropic Managed Agents terminate + re-sign all TLS). Bypass prevention needs
DEPTH: Claude Managed Agents give the container **no direct DNS + a network firewall
blocking all direct outbound TCP**, so unsetting proxy env vars cannot route around it
(Pluto Security, https://pluto.security/blog/inside-claude-managed-agents/).

**ANALYSIS — but "credential outside" ≠ "authority inaccessible" (Sol's sharpest C2
point stands).** Any process reaching the proxy can EXERCISE the credential (drain the
subscription, use the GitHub scope, exfiltrate via allowed egress) even without
reading the raw token. The proxy must therefore be a **task-scoped semantic gateway**,
not a generic authenticated proxy: request-count / token / wall-clock limits, a FIXED
model, allowed methods only, NO admin model-server endpoints (Ollama's admin API on
`localhost:11434` is itself an attack surface — Sol was right that the local-model
path narrows but does not close this). Known residual gap even in the best 2026
systems: no built-in credential-DLP body scanning; the egress JWT is readable inside
the sandbox (Cloudflare docs). Accept and document these.

**ANALYSIS — MVP sandbox profile (Linux-first, honest macOS asymmetry).**
Executor-owned, immutable: microVM (Firecracker) OR hardened container
(`--network=none` except the gateway, `--cap-drop=ALL`, `--security-opt
no-new-privileges`, non-root, seccomp, read-only host FS, ephemeral). The task manifest
may *describe* dependencies but is **allowlisted through the executor's profile, never
executed as a devcontainer config**. macOS (Ocean's Mac) has no Firecracker → Seatbelt
+ hardened Docker; require Linux for untrusted-STRANGER execution, allow macOS only for
trusted-colleague tasks. This asymmetry is a scope decision, not a flaw.

## 2. Hostile executor → author (re-verification RCE; Sol C3, C4)

**FACT — this is the "pwn request" problem, and industry solved its shape in 2026.**
Running an untrusted contributor's returned code that then attacks the trusted side is
EXACTLY the GitHub Actions "pwn request" / Poisoned Pipeline Execution class —
researchers compromised Microsoft/Google/Nvidia repos with a single forked PR
(Orca, https://orca.security/resources/blog/pull-request-nightmare-part-2-exploits/;
Wiz, https://www.wiz.io/blog/github-actions-security-guide). GitHub's structural fix
(actions/checkout v7, 2026-06-18, backported 2026-07-16): **refuse to run fork code in
the privileged/secret-bearing context by default** (github.blog changelog). The
transferable doctrine:
- Run untrusted (returned-branch) code in a **secret-less, unprivileged, network-denied**
  context — the analog of `pull_request` not `pull_request_target`.
- **Treat ALL returned artifacts as attacker-controlled** — branch, `package.json`,
  install hooks, test deps, git metadata, even the diff and commit messages.
- **The oracle must be IMMUTABLE**, resolved from the SIGNED base/task, never from the
  returned branch (Sol C3 verbatim). Gate any privileged/settlement step into a
  SEPARATE trusted step that consumes only validated results.
- Pin dependencies to content digests; validate package existence/provenance; freeze
  resolution; limit install-time execution (the slopsquatting / Shai-Hulud npm defense,
  https://techbytes.app/posts/ai-code-supply-chain-attacks-ghost-packages-2026/).

**ANALYSIS — directly fixes Sol C3.** `waspflow verify` runs arbitrary commands
unsandboxed (`artifacts.sh`), so author re-verify must NOT be `waspflow verify` on the
raw branch. It must be: fresh ephemeral sandbox (same executor-owned profile as §1,
network-denied, no credentials), oracle + its deps resolved from the signed task, the
returned branch treated as untrusted input (apply-as-patch into the immutable harness,
never adopt its config). Re-verification is just §1's sandbox pointed the other way.

**FACT — the "already-green oracle" gap (Sol C4) needs before/after semantics.** No-op
work against an already-passing oracle earns credit; `verify_strength:"suite"` is an
author-declared label, not evidence. The verifiable-computation literature's practical
answer for coding (below) is redundant execution, not trusting a single label.

## 3. Cross-principal result trust (Sol C4; the "is the work real" question)

**FACT — the verifiable-computation taxonomy (dl.acm.org/doi/10.1145/3087801.3087872;
en.wikipedia.org/wiki/Verifiable_computing).** Four models, and for CODING tasks the
practical ones are clear:
| Model | Trust basis | Fit for Federation |
|---|---|---|
| Cryptographic proof (ZK/SNARK) | succinct math proof, tiny verify | OVERKILL — you can't SNARK "wrote good code"; reserved for deterministic compute |
| Redundant execution + anti-collusion | N nodes compute, compare | **Best fit.** Anti-collusion: assign *different-but-equivalent* work, keep the transform secret, randomize assignment (USPTO 8,661,537) |
| Optimistic + fraud proofs | assume-correct, challenge window | Viable but heavy — TrueBit challengers re-run, 500–5,000% overhead; prover must stay online |
| Hardware attestation (TEE) | trusted enclave | Depends on hardware trust; overkill for MVP |

**ANALYSIS — Federation's result-trust for the MVP** = **the author's own immutable
oracle re-run in a clean evaluator (§2) as the primary gate**, PLUS optional
**redundant execution** for high-value/stranger tasks (dispatch to 2+ executors, accept
on agreement — the anti-collusion randomization matters only in the stranger tier).
The waspflow verify gate is a NECESSARY component of this but NOT sufficient alone (Sol
was right) — it becomes sufficient only when (a) sandboxed per §2 and (b) the oracle is
immutable + before/after-meaningful. This is the honest trust model the design lacked.

## 4. Credit / escrow / settlement (Sol C6, C7 — anti-freeloading)

**FACT — real compute markets escrow BEFORE work and settle atomically** (Akash:
tenant posts AKT escrow, reverse-auction bid, Burn-Mint settlement live 2026-03-23,
https://akash.network/roadmap/2026/; Flux: Ethereum smart contract holds funds in
escrow until job completes, https://www.artificialintelligence-news.com/news/top-5-ai-compute-marketplaces-reshaping-the-landscape-in-2026/).
The pattern: **reserve/escrow at claim time**, settle only on validated completion.

**ANALYSIS — fixes Sol C6/C7.** The design's negative-balance cap fails because it
debits the author nothing for failed attempts, so impossible tasks burn the pool free.
Correct MVP state machine (mirror the markets, no blockchain needed for the internal
tier): `queued → claimed(generation, executor, expiry) → submitted → author_verified →
settled`, with **claim-time escrow** (author's credit reserved when a task is claimed),
**attempt compensation** (executor earns a small floor for a genuine failed attempt on
a valid task; author pays it — this is what stops impossible-task freeloading),
**timeout/failure rules**, and **atomic cap enforcement**. `receipts.jsonl` is
telemetry, NOT this ledger (Sol C7 verified against code — no signatures, no ordering,
appends unconditionally): the settlement ledger is a SEPARATE signed, sequenced,
coordinator-acknowledged state machine. Separate Federation "credit" from actual
provider-resource budgets — one credit-unit cannot bound tokens/calls/wall-time across
heterogeneous local hardware (Sol C6).

## 5. Topology — master-server is NOT a mesh subset (Sol C5)

**FACT/ANALYSIS.** Sol is right that `PULL`/`CLAIM` target an authoritative
queue+lease+ledger; swapping transport (Iroh/libp2p) doesn't decentralize contention,
ordering, or double-spend authority. The honest framing: the reusable seam is a
**transport-independent task/result ENVELOPE** (signed, content-addressed, versioned),
NOT a "system subset." The MVP is a **trusted central coordinator, permanently** for
the internal tier; the mesh is a genuinely different authority-decomposition problem
(discovery, roster/revocation distribution, coordinator-equivocation, canonical ledger)
that is future work, not a config flip. Do not constrain the MVP around a rewrite-free
promise.

## Synthesis — the buildable MVP shape (and build order)

The MVP is buildable, but as the review said: **NOT as originally specified**, and the
**hostile-task runner must be built and adversarially tested FIRST**. Concrete order:

1. **The executor-owned runner** (§1+§2): immutable sandbox profile (Firecracker/hardened
   container, ephemeral, network-denied-except-gateway), the credential-injecting
   TLS-terminating scoped gateway (or local-model-only to sidestep credential risk
   entirely for v0), manifest-allowlist (never execute task devcontainer config). Same
   runner serves execution AND author re-verification. **Red-team it** against hostile
   devcontainer fields, prepare scripts, git metadata, Docker socket, host files, env
   vars, proxy abuse, domain fronting, DNS/HTTP exfil, model-admin APIs, resource
   exhaustion — BEFORE building anything else.
2. **The signed task/result envelope** (§5): content-addressed (digest, not task_id+sig),
   protocol-versioned, with claim-generation, oracle hash, result digest.
3. **The immutable-oracle re-verification** (§2/§3): author re-runs the signed oracle in
   the clean runner; optional redundant execution for stranger/high-value tasks.
4. **The settlement state machine** (§4): claim-time escrow, attempt compensation,
   atomic caps — a SEPARATE signed ledger, not receipts.jsonl.
5. **The trusted central coordinator** (§5): queue, lease allocator, ledger authority.
   Mesh is future work; the envelope is the only forward-compatible seam.

**v0 scope cut that removes most of the risk:** internal colleagues + **local models
via open harnesses ONLY** (no subscription credential in the loop at all — the §1
credential-gateway risk collapses to "protect host + repo," which the sandbox already
does), non-sensitive allowlisted repos, trusted central coordinator. This is the
narrowest thing that delivers the core value (Ocean's idle local compute runs Tim's
tasks) while deferring every hard cross-principal-credential and stranger-trust problem.

## Sources
Modal https://modal.com/resources/run-untrusted-code-safely · Cymulate CBSE
https://cymulate.com/blog/the-race-to-ship-ai-tools-left-security-behind-part-1-sandbox-escape/ ·
Northflank https://northflank.com/blog/how-to-sandbox-ai-agents · Cloudflare Agents
Week https://softprom.com/cloudflare-agents-week-2026-20-new-features-for-ai-agents ·
Claude Code secure deployment https://code.claude.com/docs/en/agent-sdk/secure-deployment ·
Claude Managed Agents https://pluto.security/blog/inside-claude-managed-agents/ ·
GitHub pwn request https://orca.security/resources/blog/pull-request-nightmare-part-2-exploits/ ·
Wiz GH Actions https://www.wiz.io/blog/github-actions-security-guide · checkout v7
https://github.blog/changelog/2026-06-18-safer-pull_request_target-defaults-for-github-actions-checkout/ ·
Ghost packages https://techbytes.app/posts/ai-code-supply-chain-attacks-ghost-packages-2026/ ·
Verifiable computation https://dl.acm.org/doi/10.1145/3087801.3087872 ·
https://en.wikipedia.org/wiki/Verifiable_computing · anti-collusion USPTO 8,661,537 ·
Akash roadmap https://akash.network/roadmap/2026/ · compute markets
https://www.artificialintelligence-news.com/news/top-5-ai-compute-marketplaces-reshaping-the-landscape-in-2026/
