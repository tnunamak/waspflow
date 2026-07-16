# Federation — Prior-Art & Ground-Truth Research Dossier

**Status:** Research, not design. Surfaces the option space with evidence; commits to nothing.
**Date:** 2026-07-16. **Author:** Fable-owned `federation-research` lane.
**Scope note (owner revision 2026-07-16):** The subscription-sharing ToS conflict is a **documented, accepted tradeoff** — recorded factually below, *not* treated as a blocker or a reason to narrow the design. Scope also **expanded** to cover open/self-hosted/local coding-agent harnesses as a first-class waspflow provider tier and as the ToS-clean substrate for Federation (see §9).

**Method & confidence.** Findings come from (a) a repo inventory of waspflow's existing primitives, (b) a deep-research web workflow (89 sub-agent search/verification passes; each factual claim adversarially voted, most 3-0), and (c) three focused open-harness research agents. Every external claim carries a URL; access date is **2026-07-16** unless noted. **FACT** = sourced/quoted. **ANALYSIS** = my synthesis. The web workflow's own *synthesis* step was cut off by a session limit, so §§1–8 are synthesized by me from the verified per-claim journal rather than by that step — the underlying claims are sourced and vote-verified; the *arrangement* is mine. Gaps are flagged inline, not padded.

---

## How this maps to what waspflow already has (reuse ledger)

Federation does not start from zero. The repo inventory found **no** federation/multi-machine/networking code anywhere — but several primitives are close-fit substrates (all currently single-machine, local-disk):

| Federation need | Existing waspflow primitive | File |
|---|---|---|
| Owner-supplied output validation | **Verify gate** — portable oracle: `verify <lane>` runs prepare+verify from the (optionally isolated) worktree, exits `0=pass / 2=fail`, writes `verify-result.json` with a `failure_class` taxonomy (`task\|prepare\|timeout\|infra\|invalid_oracle\|pre_existing\|none`), re-runs the oracle at the fork point to reclassify already-broken baselines as `pre_existing`. | `lib/artifacts.sh:352` |
| Tamper-evident accounting / attestation | **Receipts** — append-only `receipts.jsonl`, `flock`-guarded, `schema_version:1`, per-provider **runtime attestation** (observed vs requested model/effort), a `stats_eligible` honesty gate with an `ineligibility_reasons[]` vocabulary. `receipts summary` aggregates. | `lib/artifacts.sh:553`, `bin/waspflow:700` |
| Sandboxed execution unit | **Worktree isolation** — `--isolate` branches to a sibling `<repo>-waspflow-<lane>`, refuses dirty removal, is the reset surface for `escalate --reset-tree`. | `lib/worktree.sh` |
| Task identity / exactly-once | **Lane model** — one dir per lane, `state.json` as source of truth, CAS via `arm_generation`+`session_id`, per-lane operation flock; exactly-once segment receipts keyed by `(lane_uuid, segment.index)`. | `lib/core.sh:250-319`, `lib/escalation.sh` |
| Credential-path awareness | **Billing guard** — hard-refuses Claude spawn when `ANTHROPIC_API_KEY` is set (subscription-vs-API path), derives a `BillingPath v1` record per provider. | `lib/billing.sh:38,69` |
| Result integration across machines | **fan-in** — `captured <lane> --in <ref>` answers by content-signature (not git ancestry) whether a lane's work is already present; reap bundles the branch tip to archive. | `lib/fanin.sh` |
| Worker execution boundary | **Provider-adapter contract** — `<provider>_spawn/_is_idle/_revise/_resume_with_arm/_refresh_runtime_settings/_valid_models` + headless `exec`. This is the seam a Federation "open-harness" tier plugs into. | `lib/providers/*.sh` |

**ANALYSIS.** Receipts are explicitly single-operator in v1 (`SCHEMAS_V1.md`: "Pooling receipts across principals is a telemetry-era concern"). Federation is the forcing function that lifts that. The verify gate is the single most valuable pre-existing asset: it is already an *outcome*-checking oracle (state, not transcript), which §2 shows is exactly the correct verification posture under untrusted executors.

---

## Risk register (highest first)

| # | Risk | Severity | Evidence | Posture |
|---|---|---|---|---|
| R1 | **Result-trust under untrusted executors.** A puller can return a plausible-but-fake "success." Agent output is non-deterministic, so bit-exact redundancy/replay does **not** work for coding-agent tasks. | **Critical** | Anthropic evals guidance: verify final *environment state*, not transcript; "agent behavior varies between runs." Replication "assumes failures are uncorrelated… cannot help if the failure is faulty logic" (Walfish/Blumberg CACM). | Lean on **owner-supplied validation** (waspflow verify gate) as the primary oracle; redundancy/spot-check as secondary. See §2. **This is the design crux, not ToS.** |
| R2 | **Credential exfiltration.** A pulled task runs on the executor's machine and could read `~/.aws`, `~/.ssh`, subscription tokens, env vars, then exfiltrate over one outbound request. | **Critical** | Claude Code sandbox by default *still allows reading* `~/.aws/credentials`/`~/.ssh`; "no built-in credential deny list." Field guide: "what is not there cannot leak"; env vars are the biggest blind spot. Semantic Kernel prompt-injection→host RCE (CVE-2026-25592/26030). | Credentials must live **outside** the task sandbox; inject via a masking proxy (Claude Code `mask` mode; Cloudflare Sandbox pattern). Egress allowlist mandatory. See §3. |
| R3 | **ToS conflict (ACCEPTED TRADEOFF).** Running others' workloads against a personal Claude/OpenAI subscription violates current consumer terms; enforcement is active (server-side OAuth blocks Jan 2026). | High *(accepted)* | Anthropic: OAuth "intended exclusively" for Claude Code/Claude.ai; routing Pro/Max credentials "on behalf of their users" not permitted; enforced without notice. OpenAI: "may not share your account credentials or make your account available to anyone else." | **Documented, not mitigated away.** Exposure = account suspension. The **open/local-harness path (§9) sidesteps R3 entirely** (own models, no subscription spend). |
| R4 | **Executor churn / preemption.** Idle capacity is reclaimed the moment the owner needs it; nodes vanish mid-task. | High | Spot-GPU post-mortems: "Day 3: 12 GPUs disappeared"; "high utilization and high reliability are inversely correlated." Petals: volunteers disconnect anytime. | Design for churn: heartbeat + wall-clock ceiling + fencing tokens + retry/reassign (waspflow already has bounded-job primitives). Capacity-not-latency promise. |
| R5 | **Freeloading / incentive collapse.** Pure-altruism and pure-recognition incentives don't sustain a network. | Medium | Petals shipped recognition-only incentives and withered (dormant since 2024-08). Mutual-credit failure mode: "run up a negative balance and leave." | For ~15 colleagues: signed ledger + per-member negative-balance caps. Payment/credit tiering is what kept vast.ai alive. See §6. |
| R6 | **Harness churn.** The open-harness ecosystem is volatile — Roo Code shut down (2026-05-15), Continue acquired by Cursor and read-only (2026-06). | Medium | See §9. | Standardize on **ACP + per-harness NDJSON** rather than binding to one vendor's session format. |

---

## (a) Aspirational architecture sketch (one page)

**ANALYSIS — the option space, not a decision.**

```
                    ┌──────────────────────────────────────────┐
                    │  COLLECTIVES (friends / work / public)     │
                    │  join by capability token; each sets rules │
                    └──────────────────────────────────────────┘
   Task author (Tim)                                   Executor (Ocean)
   ┌───────────────┐        mesh transport             ┌───────────────┐
   │ waspflow      │   (Iroh: dial by pubkey, QUIC     │ waspflow      │
   │  federation   │    hole-punch ~90%, relay         │  federation   │
   │  - define task│    fallback, TLS1.3 e2e)          │  - policy: who │
   │  - repo+env+  │◄════════════════════════════════►│    may spend   │
   │    deps+VALID.│                                   │    what, ≤ cap │
   │  - spend cap  │   task capability token           │  - pull by     │
   │  - credit     │   (biscuit: datalog caveats       │    policy/toggle│
   └──────┬────────┘    on budget/tool/time,           └──────┬────────┘
          │             holder-side attenuation)              │
          │                                                   ▼
          │                                        ┌─────────────────────┐
          │                                        │ SANDBOX (per task)   │
          │                                        │ Linux: bwrap/microVM │
          │                                        │ macOS: Seatbelt      │
          │                                        │ creds OUTSIDE, masked│
          │                                        │ proxy injects token; │
          │                                        │ egress allowlist     │
          │                                        │ runs: subscription   │
          │                                        │  agent OR local model│
          │                                        │  via open harness    │
          │                                        └──────────┬───────────┘
          ▼                                                   ▼
   ┌─────────────────┐   validated result + receipt    ┌──────────────────┐
   │ VERIFY (owner's │◄────────────────────────────────│ owner-supplied   │
   │ oracle re-run   │   signed receipt → shared ledger │ verify gate runs │
   │ on final state) │   (mutual-credit, caps by hist.) │ in sandbox       │
   └─────────────────┘                                  └──────────────────┘
```

- **Topology:** master-server MVP that does *not* foreclose mesh. Iroh gives "dial a peer by cryptographic key" today (1.0, 2026-06-15) with relay fallback → the coordinator degrades from task-router to bootstrap/discovery + relay as the mesh fills in.
- **Trust:** verification is owner-supplied acceptance testing (the verify gate), amortized by reputation-weighted spot-checks (Golem's `p = ν·(1−t)` pattern), never blind redundancy.
- **Identity/authz:** capability tokens (biscuit) carry datalog caveats — spend cap, allowed tools, time window — with cryptographically-enforced attenuation.
- **Credit:** mutual-credit ledger; strangers reached by raising negative-balance caps with repayment history; Cashu-style ecash only as the stranger endgame.
- **ToS-clean lane:** any task the author marks "local-model-eligible" can be pulled and run against the executor's *own* local model via an open harness (§9) — no subscription, no R3.

## (b) Shippable MVP sketch (one page) — internal ~10-20 colleagues

**ANALYSIS.** Deliberately boring; every piece has proven prior art.

- **Topology:** **single master-server** (one coordinator process). No mesh, no DHT. Nodes long-poll the coordinator for tasks (BOINC's pull model). Migration path preserved by keeping the wire contract peer-symmetric.
- **Task source:** declared **markdown task files** (repo + env + `waspflow` invocation + `--verify` command) and/or **Linear OAuth** to a project. Task packaging = `devcontainer.json` (repo+env+deps) — an existing standard coding agents already respect; validation travels as the verify command.
- **Identity/join:** static per-collective **join token** (capability token, not yet full biscuit). Coordinator holds the roster.
- **Policy:** executor-side config: `max_spend_per_task`, `allowed_task_families`, `networks_enabled[]`, manual pull toggle. Enforced before spawn (reuse selection/billing preflight).
- **Sandbox:** **Docker devcontainer**, hardened (`--cap-drop=ALL`, `--security-opt=no-new-privileges`, non-root, default-deny egress). Credentials **never mounted**; the agent's provider auth stays on the host behind a masking proxy (Claude Code `mask` mode / `@anthropic-ai/sandbox-runtime`). macOS parity via Seatbelt or Docker Desktop.
- **Verification:** **owner-supplied verify gate re-run on the returned final state** (waspflow already does this). No redundancy in MVP; add reputation-weighted spot re-execution later.
- **Credit:** **single signed append-only ledger** (extend `receipts.jsonl`) with per-member negative-balance caps. Prevents freeloading among 15 people; no blockchain.
- **ToS-clean default:** MVP ships the **open/local-harness provider tier** (§9) so the reference path is "pull task → run on your local model" — subscription-agent execution is opt-in and flagged with the R3 warning.

**MVP explicitly defers:** mesh/P2P, ecash, stranger trust, cryptographic result proofs, TEEs, cross-account API resale.

---

# 1. Distributed / volunteer compute precedents

**FACT.**

- **BOINC** (https://boinc.berkeley.edu/) — **alive** (client 8.2.11, 2026-04-30; ~30 active projects). Pull-based installable client: "downloads scientific computing jobs and runs them invisibly in the background." Trust via **quorum redundancy** (same workunit to 2+ independent hosts, never the same participant twice, outputs compared). Incentives **non-monetary by default** (credits/community), optional Gridcoin crypto overlay. Trusted central operator (UC Berkeley, NSF-funded). **Borrow:** the pull-client + scheduler/validator split, and quorum-as-verification *where output is comparable*. **Caution:** altruistic-only incentive bounds it to donation communities.
- **Petals** (https://github.com/bigscience-workshop/petals) — **dormant** (not archived; 10,283★; last commit 2024-08-25; ~22 months idle). BitTorrent-style *layer-sharded LLM inference*, not task distribution. Trust model **punts**: warns data transits strangers, offers "private swarm among people you trust" as the mitigation. Incentive = **recognition only** (name on swarm monitor for hosting 10+ blocks). **Cautionary tale:** the closest "pool spare AI capacity" analogue, and it withered — recognition-only incentives + churn + no verification.
- **Golem** (https://blog.golem.network/gwasm-verification/) — alive (GLM token, pivoted toward AI inference/rendering). **Verification by redundancy** works *only because gWASM is deterministic* ("what makes this feasible is the fact the WASM computations are deterministic"). Base = 2× redundancy + cross-check, 3rd provider as tie-breaker. **Reputation-weighted probabilistic verification:** verify with `p = ν·(1−t)` for reputation `t` — trusted providers re-checked less. **Borrow:** the probabilistic-verification cost amortization. **Caution:** determinism precondition does not hold for agent output.
- **Bacalhau** (https://bacalhau.org/) — alive (v1.8.0, 2026-04; commercial under Expanso). Requester-node vs compute-node split; jobs pull data from S3/URLs/IPFS; **Docker + WASM** as task formats; permanent audit log *in lieu of* adversarial verification. Threat model is the **inverse** of ours (protects data locality, not the executor from tasks). **Borrow:** requester/compute topology + Docker/WASM task packaging for a small trusted federation.
- **vast.ai** (https://www.gpunex.com/blog/vast-ai-review-2026/) — alive at scale (17,000+ GPUs, 1,400+ providers). Survived where co-ops failed via **payment + tiered host verification** (Standard/unverified → verified datacenter → certified Secure Cloud). Docker isolation. Quantified reliability tax: unverified hosts 20–55% higher effective cost. **Borrow:** the graduated trust tiers (stranger → vetted).

**Not deep-dived (honest gap):** Folding@home, iExec, Render, Akash, Nostr-compute, Ray/Dask, GNU-parallel-over-SSH were named in the brief but the workflow prioritized the higher-signal precedents above; a vendor-adjacent blog touched Aethir/Render/Akash/io.net but is advocacy, not ground truth. **ANALYSIS:** the pattern is consistent enough to generalize — *pull client + central validator + payment/reputation tiering survives; altruism/recognition-only + no verification dies.*

---

# 2. Result verification under untrusted executors (the crux)

**FACT — the core constraint.** Bit-exact replay does **not** work for LLM/agent output. "Re-running the same inference twice often leads to different results due to benign numerical noise" (DiFR, arXiv:2511.20621). Agent behavior "varies between runs regardless of agent type" (Anthropic, https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents). Replication "assumes failures are uncorrelated… cannot help if the failure is faulty logic" (Walfish/Blumberg CACM, https://dl.acm.org/doi/10.1145/2641562).

**FACT — the branches and their tractability:**
- **Cryptographic verifiable computation (SNARK-style):** ruled out. Prover overhead "several orders of magnitude"; systems "basically toys" for general programs; setup amortizes only over many instances of the *identical* computation — mismatched to one-off coding tasks (Walfish/Blumberg).
- **Deterministic-replay + fraud proofs:** works only if you *force* determinism. EigenAI (arXiv:2602.00182): a bit-exact engine makes verification a byte-equality check where "a single honest replica suffices," ~1.8% latency cost — **but breaks across GPU architectures** (A100 vs H100 logits diverge ~1e-7 → "per-architecture verifier pools"). Not achievable for closed-API subscription models.
- **Nondeterminism-aware optimistic verification:** NAO (arXiv:2510.16028) — Merkle-anchored interactive bisection game over the compute graph, tolerance bands not bit-equality; optimistic path ~0.3% overhead; empirically-calibrated thresholds hit 0% attack success. Targets *open-weight* inference, not closed-API agents.
- **Cheap partial re-execution / statistical fingerprinting:** VeriLLM (arXiv:2509.24257) verifies at **~1% of inference cost** via prefill/decode split + "isomorphic" indistinguishable verification tasks (executor can't tell it's being checked). DiFR: seed-synchronized token comparison to a reference detects a swapped 4-bit model at AUC>0.999 within 300 tokens, zero provider overhead; open-source vLLM integration exists.
- **Owner-supplied acceptance testing (the tractable one):** grade by *running code + tests*. SWE-bench Verified and Terminal-Bench both work this way. Check **final environment state, not transcript** ("agent might say 'flight booked' but the outcome is whether a reservation exists in the DB"). Isolate each trial from a clean environment. Graders themselves need human validation across many trials.

**ANALYSIS.** For coding-agent tasks specifically, **the waspflow verify gate is the answer.** Cryptographic proofs are intractable; deterministic replay and open-weight optimistic schemes don't apply to closed-API agents; redundancy voting fails on non-deterministic output. What *does* work is outcome-checking against an owner-supplied oracle — which waspflow already implements (state-based, `failure_class`, fork-point baseline reclassification). Layer on: (1) reputation-weighted **spot** re-execution (Golem `p=ν·(1−t)`) rather than blind redundancy — critical because re-executing on a second member burns their pooled tokens; (2) the "check state not transcript" and "clean isolated env per trial" disciplines; (3) for the *local-model* path (§9), DiFR-style token-fingerprinting becomes available since weights are controllable. **Open sub-question:** owner-supplied validators are only as good as the owner's tests — a weak oracle is gameable (see waspflow's own `invalid_oracle` class and the verification-horizon research in the corpus).

---

# 3. Sandboxing & credential scoping

**FACT — isolation tiers (https://amux.io/guides/ai-agent-sandboxing/):** plain Docker shares the host kernel → insufficient alone (escapes demonstrated, CVE-2024-21626); harden with `--network=none`/`--cap-drop=ALL`/`--security-opt=no-new-privileges`/non-root/seccomp/AppArmor. gVisor = userspace-kernel middle tier (10–30% I/O overhead). **Firecracker microVMs** = gold standard (own kernel, <150ms boot, <5MB overhead) **but require Linux+KVM → no native macOS parity.**

**FACT — macOS/Linux parity, the crux for Ocean's MacBook:**
- Claude Code sandbox: **Seatbelt on macOS, bubblewrap on Linux/WSL2** (WSL1 unsupported); published standalone as `@anthropic-ai/sandbox-runtime`. Apple has **deprecated** `sandbox-exec` (long-term parity risk).
- Cursor's production local-agent sandbox (https://cursor.com/blog/agent-sandboxing): Seatbelt (macOS) vs **seccomp + Landlock** (Linux, "make ignored files completely inaccessible"); on Windows they run the *Linux* sandbox inside WSL2 rather than native primitives. Sandboxed agents stop for approval 40% less often (vendor stat).
- Codex CLI: "the only mainstream coding agent with OS-level sandboxing built in" — isolated container, filesystem restricted to workdir, **network disabled by default**.

**FACT — credential scoping (R2):**
- **Default is unsafe.** Claude Code sandbox by default reads the *entire* computer incl. `~/.aws/credentials`, `~/.ssh`; "no built-in credential deny list." Sandboxed commands inherit parent env (incl. credential env vars) by default.
- **The correct pattern: credentials outside the sandbox, injected by proxy.** Claude Code **`mask` mode** (v2.1.199+): sandbox sees a per-session *sentinel*; a TLS-terminating proxy swaps in the real credential only on requests to `injectHosts`; "the command and anything it logs never hold the real credential." Cloudflare Sandbox SDK does the same (secrets stay in the Worker, sandbox gets short-lived scoped JWTs). Field-guide doctrine: "what is not there cannot leak"; env vars are the biggest blind spot (agent extracted keys via `docker compose config`); "compute isolation is worthless without egress control."
- **Egress caveat:** hostname-allowlist proxies that don't inspect TLS are defeatable by **domain fronting** when broad domains (github.com) are allowed — Anthropic documents this explicitly.
- **Prompt-injection → host RCE is real:** Semantic Kernel CVE-2026-25592/26030 (May 2026), "the agent's tool-calling mechanism became a shell."

**ANALYSIS.** MVP: hardened Docker/devcontainer (`cap-drop ALL`, no-new-privileges, non-root, default-deny egress) on both OSes; the executor's provider token **never enters the sandbox** — host-side masking proxy injects it only for allowed provider hosts. For the local-model path this is even cleaner: the model endpoint is `localhost:11434` and there is *no* subscription token to protect. Firecracker is the Linux-only hardening upgrade for public/stranger tasks; macOS stays on Seatbelt/Docker (accept the asymmetry, or require Linux for untrusted-stranger execution).

---

# 4. Network topology & discovery

**FACT.**
- **Iroh** (https://www.iroh.computer/blog/comparing-iroh-and-libp2p, https://pinggy.io/blog/iroh_1_0_dial_keys_not_ips/) — **1.0 shipped 2026-06-15** (wire-protocol stability; Python/Node/Swift/Kotlin bindings; 200M+ endpoint connections/month; production users incl. Nous Research). **Dial by cryptographic public key, not IP.** QUIC UDP hole-punch **~90% success**, encrypted relay fallback, ~95% of data volume direct. Relays **stateless, cannot read traffic** (QUIC+TLS1.3 e2e). Adopts IETF QUIC-NAT-Traversal. *Caveat:* no DHT; doesn't solve initial key exchange (needs out-of-band discovery — e.g. the coordinator). Pre-1.0 relay support sunsets 2026-09-30.
- **libp2p** — Kademlia DHT + broad language support, but NAT hole-punch **caps ~70%**, and "minimizes central points of failure at the cost of effectiveness."
- **Tailscale/headscale** — Iroh explicitly credits Tailscale's DERP-relay NAT-traversal concepts. For the *trusted-friends* case, a Tailscale/headscale overlay is the simplest "everyone's on one private network" substrate.

**ANALYSIS — master-server→mesh migration path.** Start with a **master coordinator** (task routing + roster + relay). Iroh's model is the clean upgrade: it "accepts a little centralization for near-certain connectivity," so the coordinator degrades gracefully from *router* → *bootstrap/discovery + relay* as peers dial each other directly by key. This is the concrete answer to the owner's "simple master-as-server MVP that doesn't foreclose mesh." **Not deep-dived (gap):** Nostr relays, IPFS/IPLD, Hyperswarm/Holepunch, Matrix, Syncthing discovery — the workflow converged on Iroh vs libp2p as the decisive comparison; Nostr is worth a follow-up as a lightweight pub/sub task-board substrate.

---

# 5. Identity, policy, authz

**FACT — capability tokens (https://arxiv.org/html/2603.24775 "AIP", https://ucan.xyz/specification/):** A 2026 survey directly comparing **macaroons vs Biscuit vs UCAN** for AI-agent delegation — *exactly* the "owner defines when others may spend my tokens" problem — finds **Biscuit gets the most right**: public-key **offline** verification, **Datalog policy** for budget/temporal/tool-parameter constraints, append-only delegation blocks with **holder-side attenuation** (a block that tries to *widen* scope "fails cryptographic verification"). Macaroon caveats too weak for budget limits; UCAN hampered by DID dependency and token bloat that grows with delegation depth. AIP's production protocol uses Biscuit+Datalog for multi-hop delegation; overhead is negligible (verify ~0.05ms Rust / ~0.19ms Python; 0.086% of a real LLM call). No surveyed scheme satisfied more than 4 of 7 required properties — so expect to compose.

**ANALYSIS.** A **biscuit capability token** is the near-blueprint for a Federation spend policy: caveats encode `max_spend`, `allowed_tools`, `time_window`, `task_family`; attenuation is cryptographically enforced so an executor can't escalate. **MVP** can start with a static join token + executor-side config and graduate to biscuit when policies get expressive. OAuth delegation is the *wrong* primitive here (it's what the ToS restricts, R3) except for the task-source side (Linear OAuth to pull tasks). OPA/Rego is an alternative policy engine but heavier than embedding Datalog in a token. **Gap:** how collectives *form/join/revoke* (roster management, membership revocation, collusion between members) was not deeply sourced — a design-phase item.

---

# 6. Credit / mutual-credit systems

**FACT.**
- **Mutual credit** (https://blog.holochain.org/mutual-credit-part-1...) — balances sum to zero; standard anti-freeloading defense is **per-member negative-balance caps** (credit limits) raised with repayment history. Documented failure mode: "run up a negative balance and leave" — which is why such systems stay small/trust-based (<2000 members). **For 15 colleagues: a plain signed ledger with credit limits beats any token machinery; caps-scaled-by-history is the path toward strangers.**
- **Cashu / Chaumian ecash** (https://cashu.space/) — active 2026. Explicitly for **small trusted communities** ("many small mints run by operators in your social circle," Dunbar framing); tokens pubkey-lockable. But **bearer-token, accountless** (in tension with per-member balances) and the **mint is fully custodial**. Better as the **stranger-trust endgame** than the day-one ledger.

**ANALYSIS.** Simplest thing that prevents internal freeloading: **extend `receipts.jsonl` into a signed append-only credit ledger** — each completed+validated task credits the executor and debits the author, with per-member negative-balance caps. No blockchain. Path to strangers: raise caps with repayment history → federated ledgers → Cashu ecash for accountless stranger settlement. **Not deep-dived (gap):** Sardex, LETS, Trustlines, Ripple credit-networks were named but the workflow only sourced the mutual-credit *principle* (Holochain) + Cashu; the caps-by-history mechanism is well-grounded, the specific-system comparisons are a follow-up.

---

# 7. Task definition standard

**FACT.** Prior art for carrying repo+env+deps+validation:
- **devcontainer.json** — coding agents already respect it; doubles as security config (`capDrop ALL`, `no-new-privileges`, read-only root, default-deny egress firewall, bind-mount *only* the one needed credential) per the hardened-devcontainer recipe (https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers). This is the strongest single fit — it packages env+deps *and* is the sandbox spec.
- **Docker + WASM** (Bacalhau) — run existing workloads without rewriting.
- **BOINC workunit** — the classic input-files + validation-rule packaging.
- **CI job specs / Nix flakes / CWL / RO-Crate** — named in the brief but **not sourced this pass (gap).** Nix flakes give reproducible env; CWL/RO-Crate give portable workflow+provenance; GitHub Actions job spec is the familiar mental model. Worth a follow-up for the *validation* half specifically.

**ANALYSIS.** A Federation task = `devcontainer.json` (repo ref + env + deps) + a **waspflow invocation** + a **verify command** (the validation, which waspflow already treats as first-class). Marking a task `local-model-eligible` (a model-class requirement, not a specific model) routes it to the ToS-clean path. The task carries its own oracle — this is what makes owner-supplied validation (§2) the trust mechanism.

---

# 8. Closest existing products & ToS landmines

**FACT — "share your AI subscription capacity": no direct product exists.** The closest analogues are **compute**-sharing (vast.ai, Petals, Golem) not **subscription-token**-sharing. Petals (dormant) is the nearest and its post-mortem is instructive (§1). GPU marketplaces that survived did so on **payment + host verification tiers**, not altruism.

**FACT — ToS (documented; accepted tradeoff per owner):**
- **Anthropic** (https://code.claude.com/docs/en/legal-and-compliance): OAuth is "intended exclusively for purchasers… to support ordinary use of Claude Code and other native Anthropic applications"; "Anthropic does not permit third-party developers to… route requests through Free, Pro, or Max plan credentials on behalf of their users"; "advertised usage limits… assume ordinary, individual usage"; enforceable "without prior notice." Developers building products "should use API key authentication."
- **Anthropic enforcement is active** (https://www.theregister.com, 2026-02-20): Jan 9 2026 server-side blocks of subscription OAuth in OpenCode/OpenClaw/Roo Code/Goose ("This credential is only authorized for use with Claude Code"); framed as a *clarification* of Consumer ToS §3.7 in force since ~Feb 2024. Rationale = **token arbitrage** + "unusual traffic patterns without the usual telemetry."
- **OpenAI consumer** (https://openai.com/policies/row-terms-of-use/, eff. 2026-01-01): "You may not share your account credentials or make your account available to anyone else and are responsible for all activities that occur under your account." Also bars circumventing rate limits.
- **OpenAI business** (https://openai.com/policies/services-agreement/, eff. 2026-01-01): "will not share Account access credentials… may not resell or lease access"; no buying/selling/transferring API keys; each End User Account single-user; the **sanctioned** multi-user path is API-into-Customer-Application.

**ANALYSIS.** A subscription-backed Federation node is squarely what these clauses target — plain reading, active enforcement, consequence = account suspension without notice. **Per the owner this is an accepted tradeoff, not a blocker.** The honest framing: (1) exposure is real and enforced; (2) it applies to the *subscription-agent* execution path only; (3) the **open/local-harness path (§9) removes it entirely** and should be the reference/default path; (4) an API-key path is ToS-sanctioned but defeats the "wasted subscription capacity" premise (you'd be paying per call). Prior compute co-ops failed on incentives+churn+verification, not ToS — so ToS is not the thing most likely to kill this.

---

# 9. Open-harness support as a waspflow provider tier AND as the ToS-clean path for Federation

**Why this matters doubly (ANALYSIS).** Every open/self-hosted harness that can run against a user's **own local model** (Ollama/vLLM/llama.cpp/LM Studio) sidesteps R3 completely — no subscription, no credential-sharing clause, no token-spend to meter or exfiltrate. A task Ocean pulls can run on *her* local Qwen3-Coder via an open harness. So the open-harness tier is simultaneously (a) a general waspflow capability and (b) the cleanest substrate for Federation. It also de-risks R6 by not depending on any one vendor.

**FACT — the harnesses, mapped to waspflow's adapter contract** (`_spawn/_is_idle/_revise/_resume_with_arm/_refresh_runtime_settings/_valid_models` + headless `exec`). All accessed 2026-07-16.

**Named first-class candidates:**
- **Pi** (Earendil Works, `@earendil-works/pi-coding-agent`; MIT; 71.7k★) — **cleanest fit.** Headless `pi -p` / `--mode json` / `--mode rpc`. **JSONL** sessions at `~/.pi/agent/sessions/…`; resume by `--session <id>`; **documented turn-end** (`AssistantMessage.stopReason`) → `_is_idle` from disk. Model *and* effort are CLI flags on resume (`--model provider/id:level`, `--thinking off→max`); on-disk `model_change`/`thinking_level_change` entries make `_refresh_runtime_settings` attestation trivial. `pi --list-models`. Local: Ollama/vLLM/LM Studio/SGLang, 4 API dialects. **Gap:** no built-in permission system (waspflow sandbox must supply safety); `-p`+`--session` combo undocumented (smoke-test).
- **OpenCode** (`anomalyco/opencode`; MIT; 186.5k★) — strong event API. `opencode run --auto --format json -s <id>`; also `serve` (HTTP+SSE) and `acp`. **`session.status`/`session.idle` over SSE** = best `_is_idle` via API; JSON-per-object session store on disk. Effort knob buried in config **variants** (CLI selection unconfirmed — gap). `--auto` had CI-mode permission bugs (#13851). Model listing unconfirmed.
- **Hermes** (NousResearch/hermes-agent; MIT; 215.8k★) — general agent, coding-capable. Headless `hermes -z`/`chat -q`; `--yolo`. **SQLite** sessions (`~/.hermes/state.db`) → `_is_idle` needs SQLite *polling*, not log-tail. **No effort CLI flag** and effort **not recorded per-session** → `_resume_with_arm` and effort-attestation **gaps**. `-z` can't resume. Local via custom `base_url`.

**Broader survey:**
- **Cline CLI 2.0** (Apache-2.0; shipped 2026-02-13; 5M+ devs) — **safest open bet.** `cline "task" -y --json` (NDJSON); **resume by `--id`**; tailable `~/.cline/data/tasks/<id>/*.json`; `--thinking none→xhigh`; Ollama/LM Studio/OpenAI-compat; **native ACP (`--acp`)**. *Caveat:* documented paths have drifted (#11671).
- **Goose** (Block; Apache-2.0; Linux-Foundation AAIF; 51.3k★) — `goose run -t … --output-format json` + `GOOSE_MODE=auto`; **SQLite** sessions, resume-by-name; per-run `--provider/--model`; effort = provider-specific env vars (no flag); Ollama first-class. **Gaps:** effort not persisted (attestation), no-TTY resume panics (#6236).
- **OpenHands** (MIT core; All Hands AI, $23.8M; 81k★) — **best on-disk contract:** per-event JSON files + `FinishAction` + `base_state.json` (real observed LLM settings → clean `_refresh_runtime_settings`); `--resume <id>`. **Opt-in Docker sandbox** (differentiator). *Gaps:* no `--model` flag (env + `--override-with-envs` dance); effort via settings-file edit.
- **aider** (Apache-2.0; ~45k★; **slow-maintenance**) — trivially headless (`-m … --yes-always`); true `--reasoning-effort`; but **one implicit history per directory, no session IDs** → breaks multi-lane unless each lane gets its own worktree (which waspflow's `--isolate` already provides). Weak idle signal (tail `.aider.chat.history.md`).
- **Continue `cn`** — **disqualified as a dependency:** acquired by Cursor 2026-06, repo read-only, product dead (final 2.0.0; `continue-fork` is the community continuity path).
- **Roo Code** — **dead** (shut down 2026-05-15, pivoted to Roomote); never shipped a first-party CLI. Migration lineage: Kilo Code (has a CLI), Cline.

**FACT — local-model substrate (2026):**
- **Ollama** = default; v0.14 Anthropic-compatible Messages API; v0.15 `ollama launch` auto-configures Claude Code/Codex/OpenCode; ≥64K ctx advised for agents.
- **llama.cpp** `llama-server`: OpenAI-compatible, tool calling needs `--jinja`.
- **LM Studio**: **llmster** headless daemon (Jan 2026); OpenAI + Anthropic + `/v1/responses` compat; MCP client.
- **vLLM**: tool calling requires `--enable-auto-tool-choice --tool-call-parser <family>` or "tool calls silently fail."
- **Viable local coding models:** Qwen3-Coder 30B (consensus default), Qwen3-Coder-Next (16GB), **Devstral Small 2** (24B, Apache-2.0, ~68% SWE-bench vendor claim, runs on a 4090 / 32GB Mac), GLM-5.1 32B, Gemma 4 27B, gpt-oss:20b. **Tool-call reliability is the load-bearing constraint** ("the single biggest determinant of whether a local agent finishes or stalls"); **Q4_K_M is the quantization floor**; no clean size↔quality correlation (serving-stack template/parser matters more than parameter count); watch long-context tool-call collapse with optional params.

**FACT — interop standard: ACP (Agent Client Protocol).** Zed-created, Apache-licensed, JSON-RPC over stdio ("LSP for agents"), stable v1, **25+ agents** (JetBrains, Gemini CLI, Copilot CLI, Codex, **Cline native**, Mistral Vibe, OpenCode; Claude Code via a Zed bridge). ACP Registry (Jan 2026) = register once, reachable by every client.

**ANALYSIS — what a waspflow open-harness tier needs.**
1. **Two integration surfaces, not one.** (a) A generic **ACP client adapter** — one integration reaches Cline/Vibe/Gemini/Copilot/Codex/OpenCode + the Claude Code bridge; standardizes session lifecycle, streamed turns, permission callbacks. (b) Per-harness **NDJSON/session-file adapters** for the harnesses with the best headless story (Pi, Cline, OpenCode). ACP is editor-centric so headless orchestration over it is less battle-tested than each harness's own `--json` stream — hence both.
2. **Ranked adapter fit for Federation:** **Pi** (disk turn-end + model *and* effort as flags + on-disk attestation) → **Cline** (resume-by-id, NDJSON, ACP, momentum) → **OpenCode** (SSE idle) → **OpenHands** (best attestation, clumsy arming; +its own sandbox) → Goose → aider (needs per-lane worktree). Avoid Continue/Roo (dead).
3. **Attestation parity:** waspflow's receipts already attest observed model/effort per provider. Pi/OpenHands expose both on disk; Hermes/Goose hide effort → those adapters would emit `attestation_missing`/`effort_default` ineligibility reasons (the honesty gate already has this vocabulary). Local-model runs also enable **DiFR-style token fingerprinting** (§2) since weights are controllable — a verification bonus unavailable on closed APIs.
4. **The ToS-clean default:** ship the local-harness path as the reference Federation flow; subscription-agent execution is opt-in behind the R3 warning.

---

# (c) The 5 hardest open questions for the design phase

1. **How good must an owner-supplied validator be before its result is trustable from a stranger?** The verify gate is the trust mechanism (§2), but a weak/gameable oracle (waspflow's own `invalid_oracle`; verification-horizon gaming in the corpus) means "passed validation" ≠ "correct." What's the minimum-oracle-strength bar, and who audits the auditor across principals? This is R1, unresolved.
2. **Credential isolation on macOS specifically.** The masking-proxy pattern (§3) is proven, but Firecracker-grade isolation is Linux-only and Apple has deprecated `sandbox-exec`. Is Seatbelt/Docker-on-Mac *enough* to run a stranger's task against Ocean's machine, or must untrusted-stranger execution be Linux-only while macOS is restricted to trusted-collective tasks?
3. **What is the smallest credit primitive that both stops internal freeloading AND doesn't foreclose stranger trust?** Signed ledger + caps-by-history is the §6 answer for 15 people, but the migration to accountless stranger settlement (Cashu) changes the trust model — designing the ledger so that transition isn't a rewrite is open.
4. **One adapter or many?** ACP promises one-integration-reaches-many, but is less battle-tested headless than per-harness NDJSON. Does Federation standardize on ACP (betting on the ecosystem) or maintain a small set of first-class native adapters (Pi/Cline/OpenCode) and treat ACP as a fallback? This decision shapes the whole open-harness tier and its churn-resistance (R6).
5. **Master-server→mesh without a rewrite.** Iroh makes dial-by-key production-ready (§4), but the MVP coordinator holds roster, task routing, *and* the credit ledger. Which of those can decentralize incrementally, and which force a hard architectural break? Getting the wire contract peer-symmetric from day one is the hedge, but unproven.

---

# (d) Annotated bibliography

**Verification (§2) — primary:**
- DiFR, arXiv:2511.20621 — seed-synced token comparison detects model swaps at zero provider cost; open-source vLLM integration. *The most borrowable statistical-verification primitive for the local-model path.*
- EigenAI, arXiv:2602.00182 — deterministic inference → byte-equality verify, single honest replica; breaks across GPU architectures. *Why deterministic replay doesn't fit closed-API agents.*
- NAO, arXiv:2510.16028 — nondeterminism-aware optimistic verification with tolerance bands. *Open-weight only.*
- VeriLLM, arXiv:2509.24257 — ~1% verification cost via prefill/decode split; indistinguishable spot-checks. *Economics of not burning a second member's tokens.*
- Walfish & Blumberg, CACM, https://dl.acm.org/doi/10.1145/2641562 — SNARK-family "basically toys" for general programs; replication assumes uncorrelated failures. *Rules out crypto proofs + naive redundancy with citations.*
- Anthropic, "Demystifying evals for AI agents," https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents — check final state not transcript; isolate each trial; graders need human validation. *The doctrine behind the owner-supplied-validation path.*

**Precedents (§1):** BOINC https://boinc.berkeley.edu/ (alive; quorum redundancy) · Petals https://github.com/bigscience-workshop/petals (dormant; the cautionary tale) · Golem https://blog.golem.network/gwasm-verification/ (reputation-weighted probabilistic verification) · Bacalhau https://bacalhau.org/ (requester/compute split, Docker+WASM) · vast.ai https://www.gpunex.com/blog/vast-ai-review-2026/ (tiered host trust; survived).

**Sandboxing (§3):** amux 2026 comparison https://amux.io/guides/ai-agent-sandboxing/ · Claude Code sandbox https://code.claude.com/docs/en/sandboxing (Seatbelt/bwrap, `mask` mode, domain-fronting caveat) · Cursor https://cursor.com/blog/agent-sandboxing (seccomp+Landlock; WSL2 for Windows) · Cloudflare Sandbox SDK https://developers.cloudflare.com/sandbox/ (creds-outside pattern) · hardened devcontainers https://www.danieldemmel.me/blog/coding-agents-in-secured-vscode-dev-containers.

**Topology (§4):** Iroh vs libp2p https://www.iroh.computer/blog/comparing-iroh-and-libp2p · Iroh 1.0 https://pinggy.io/blog/iroh_1_0_dial_keys_not_ips/.

**Authz (§5):** AIP survey arXiv:2603.24775 (macaroon vs Biscuit vs UCAN; Biscuit wins) · UCAN spec https://ucan.xyz/specification/.

**Credit (§6):** Holochain mutual credit https://blog.holochain.org/mutual-credit-part-1-a-new-type-of-cryptocurrency-as-old-as-civilisation/ · Cashu https://cashu.space/.

**ToS (§8):** Anthropic legal/compliance https://code.claude.com/docs/en/legal-and-compliance · The Register 2026-02-20 https://www.theregister.com/2026/02/20/anthropic_clarifies_ban_third_party_claude_access/ · OpenAI consumer terms https://openai.com/policies/row-terms-of-use/ · OpenAI services agreement https://openai.com/policies/services-agreement/.

**Open harnesses (§9):** Pi https://github.com/earendil-works/pi · OpenCode https://github.com/anomalyco/opencode · Hermes https://github.com/NousResearch/hermes-agent · Cline CLI https://cline.bot/blog/introducing-cline-cli-2-0 · Goose https://github.com/block/goose · OpenHands https://github.com/OpenHands/OpenHands · aider https://aider.chat/docs/scripting.html · ACP https://zed.dev/acp · Ollama launch https://ollama.com/blog/launch · local tool-calling https://www.promptquorum.com/power-local-llm/best-local-models-tool-calling-2026 · Devstral 2 https://mistral.ai/news/devstral-2-vibe-cli/.

**Gaps not closed this pass (honest):** Folding@home/iExec/Render/Akash/Ray/Dask (§1); Nostr/IPFS/Hyperswarm/Matrix/Syncthing (§4); collective formation/revocation & collusion (§5); Sardex/LETS/Trustlines/Ripple specifics (§6); Nix flakes/CWL/RO-Crate/GitHub-Actions task-spec details (§7). None change the MVP shape; all are follow-ups for the design phase.
