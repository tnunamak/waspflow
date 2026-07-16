# Federation — Two-Tier Design

**Status:** Design proposal (not implementation). A build phase executes against Tier B.
**Date:** 2026-07-16. **Author:** principal-architect design pass.
**Grounded in:** `docs/research/FEDERATION_PRIOR_ART.md` (THE dossier — 8 research areas, risk
register R1–R6, bibliography; built on, not redone), the shipped control-loop specs
(`MODEL_SELECTION_CONTROL_LOOP.md`, `SCHEMAS_V1.md`, `SELECTION_V1.md`, `ESCALATION_V1.md`),
and a code-level read of `lib/*.sh` + `bin/waspflow` (every reuse claim below carries a
`file:line` anchor verified this pass).

**What Federation is (owner intent, preserved).** A downloadable, clawmeter-style executable
lets a user join networks/collectives, set POLICIES for when others may spend their access
tokens, and define/pull WORKLOADS. Tim (engineer, Linux) queues well-defined tasks
(repo + env + waspflow invocation + OUTPUT VALIDATION); Ocean (non-technical, macOS, unused
tokens) pulls one, runs it sandboxed against HER agent account (optionally her GitHub/Linear
auth), returns validated results. Rollout: (1) internal ~10–20 colleagues; (2) ship in
waspflow for anyone; (3) aspirational — strangers collectivize via credit/currency, mesh
topology, not just a master server.

**Two owner steers that shape scope.** (a) The subscription-sharing **ToS conflict is an
ACCEPTED tradeoff** (R3) — documented factually, never used to narrow the design. (b)
**Open/self-hosted harnesses** (Pi, OpenCode, aider, OpenHands, Goose, Hermes, local-model
loops) are a first-class waspflow provider tier AND the ToS-clean substrate — a task run on a
puller's OWN local model sidesteps subscription-sharing entirely, and is the cleanest MVP path.

**The thesis in one sentence.** Federation is not a new system; it is waspflow's existing lane
lifecycle — spawn → verify → receipt → reap — with **three seams cut open**: the *task*
crosses a machine boundary (transport), the *executor* is not the author (trust +
sandbox), and the *receipt* is pooled across principals (accounting). Everything else is
already built.

---

# Tier A — Aspirational architecture (the north star)

The full vision: any waspflow user joins collectives (friends / work / public), advertises
spare capacity under cryptographically-enforced policy, and pulls well-defined validated
workloads from strangers — settling in a credit currency, over a peer-to-peer mesh, with
results trusted because the task carries its own owner-supplied oracle.

## A.1 The stack (committed, with rationale)

The dossier surveyed the option space; here is the defensible commitment. Each choice degrades
to the MVP as a strict subset (§A.4).

| Layer | Aspirational choice | Why this and not the alternative |
|---|---|---|
| **Transport / discovery** | **Iroh** (dial-by-public-key, QUIC hole-punch ~90%, encrypted relay fallback; 1.0 shipped 2026-06-15) | libp2p's Kademlia DHT caps NAT traversal ~70% and "minimizes central points of failure at the cost of effectiveness" (dossier §4). Iroh "accepts a little centralization for near-certain connectivity" — the coordinator degrades from *router* → *bootstrap/relay* as peers dial by key. That degradation path is exactly the owner's "master-server MVP that doesn't foreclose mesh." |
| **Identity / policy** | **Biscuit capability tokens** (Datalog caveats: `max_spend`, `allowed_tools`, `time_window`, `task_family`; public-key offline verify; holder-side attenuation) | The 2026 AIP survey (arXiv:2603.24775) compared macaroons vs Biscuit vs UCAN for *exactly* the "owner defines when others may spend my tokens" problem: Biscuit wins — macaroon caveats too weak for budget limits, UCAN bloats with delegation depth + DID dependency. Attenuation is cryptographically enforced: a block that widens scope fails verification. Verify cost ~0.05ms — negligible vs an LLM call. |
| **Result trust** | **Owner-supplied acceptance testing** (the waspflow verify gate) run on the returned *final environment state*, amortized by **reputation-weighted spot re-execution** (Golem `p = ν·(1−t)`); DiFR token-fingerprinting on the local-model path | Bit-exact replay is impossible for agent output (dossier §2: benign numerical noise, "behavior varies between runs"). SNARK proofs are "basically toys" for general programs. Redundancy voting fails on non-deterministic output. What *works* is grading by running code + tests against a clean isolated state — which waspflow already does. This is R1, the design crux, and it is *not* ToS. |
| **Sandbox** | **Firecracker microVM** for untrusted-stranger tasks (own kernel, <150ms boot) on Linux; **Seatbelt / hardened Docker** on macOS; credentials **outside** the sandbox via a masking proxy; default-deny egress allowlist | Plain Docker shares the host kernel (CVE-2024-21626 escapes). Firecracker is the gold standard but Linux+KVM only → macOS asymmetry is unavoidable (dossier §3). Credential exfiltration (R2) is defeated structurally: "what is not there cannot leak." |
| **Credit** | **Mutual-credit ledger** with per-member negative-balance caps scaled by repayment history; **Cashu ecash** as the accountless stranger endgame | Balances sum to zero; the standard anti-freeloading defense is credit caps (dossier §6). Petals died on recognition-only incentives; vast.ai survived on payment + tiered trust. Not a blockchain — mutual credit is "a currency as old as civilisation." |
| **Execution substrate** | **Cross-provider** (subscription Claude/Codex/Grok, ToS-accepted) **AND open-harness / local-model** (Pi, OpenCode, aider… on Ollama/vLLM), the latter the ToS-clean default | The open-harness tier removes R3 entirely (own models, no subscription spend) and de-risks R6 (harness churn) by not binding to one vendor. See §B.6. |

## A.2 The mesh flow

```
        COLLECTIVES (friends / work / public) — join by biscuit capability token
   Author (Tim)                                            Executor (Ocean)
   ┌──────────────┐         Iroh transport                 ┌──────────────┐
   │ waspflow     │   (dial by pubkey, QUIC hole-punch,    │ waspflow     │
   │  federation  │    relay fallback, TLS1.3 e2e)         │  federation  │
   │  publish TASK│◄═════════════════════════════════════► │  policy: who │
   │  (task pack  │                                         │  may spend   │
   │   §B.1) +    │   biscuit task-capability token         │  what, ≤ cap │
   │   spend cap  │   (Datalog: budget/tool/time caveats,   │  pull by     │
   │   + credit   │    holder-side attenuation)             │  policy/toggle│
   └──────┬───────┘                                         └──────┬───────┘
          │                                                        ▼
          │                                        ┌───────────────────────────┐
          │                                        │ SANDBOX (per task)         │
          │                                        │  Linux: Firecracker microVM│
          │                                        │  macOS: Seatbelt / Docker  │
          │                                        │  creds OUTSIDE, proxy-masked│
          │                                        │  egress allowlist          │
          │                                        │  runs: subscription agent  │
          │                                        │   OR local model via open  │
          │                                        │   harness (ToS-clean)      │
          │                                        │  = a waspflow --isolate lane│
          │                                        └──────────────┬────────────┘
          ▼                                                       ▼
   ┌──────────────────┐   validated result + signed receipt  ┌───────────────────┐
   │ VERIFY (author's │◄──────────────────────────────────── │ owner-supplied     │
   │ oracle re-run on │   signed receipt → mutual-credit      │ verify gate runs   │
   │ returned state)  │   ledger (caps by history)            │ IN the sandbox     │
   └──────────────────┘                                       └───────────────────┘
```

**Trust chain.** The task carries its own oracle (verify command). The executor runs it in a
clean isolated environment and returns the *final state* + a signed receipt. The author
**re-runs the same oracle on the returned state** — the executor never has to be trusted to
report honestly, because the author independently re-verifies. Redundancy (a second executor)
is used only as a *reputation-weighted spot check*, never blindly, because re-execution burns a
second member's pooled tokens (dossier §2, the VeriLLM economics point).

**Currency.** Each author-verified task credits the executor and debits the author in a signed
append-only ledger. Strangers are reached by raising negative-balance caps as repayment history
accrues; the accountless endgame is Cashu ecash (bearer tokens, pubkey-lockable, mints run by
operators "in your social circle"). This is the migration target, not day one.

## A.3 What makes the aspirational version *hard* (honest)

- **R1 — oracle strength.** A weak/gameable owner-supplied validator means "passed validation"
  ≠ "correct." Under a stranger executor with an incentive to fake success, the oracle must be
  strong enough that gaming it costs more than doing the work. waspflow already has the
  vocabulary (`invalid_oracle`, the green-verify anti-gaming hardening, `test_files_changed`) —
  but the minimum-oracle-strength bar across principals is unsolved (open question §D.1).
- **R2 — credential isolation on macOS.** Firecracker is Linux-only; Apple deprecated
  `sandbox-exec`. Running a *stranger's* task against Ocean's Mac may be unsafe at
  Firecracker-grade; the aspirational answer restricts untrusted-stranger execution to Linux
  nodes while macOS runs trusted-collective tasks only (open question §D.2).
- **R4 — executor churn.** Idle capacity vanishes the moment the owner needs it. The mesh must
  treat every node as preemptible: heartbeat + wall-clock ceiling + **fencing tokens** (which
  waspflow's `arm_generation`/`session_id` CAS already provides, `lib/core.sh:283`) + reassign.
- **R5 — incentive collapse.** Pure altruism/recognition withers (Petals). The credit ledger
  with caps is load-bearing even at the aspirational tier.

## A.4 Graceful degradation to the MVP (the subset property)

Every aspirational layer degrades to a strictly simpler MVP form **without changing the wire
contract or data shapes** — the MVP is a subset, not a different system:

| Layer | Aspirational | MVP subset (Tier B) | The seam that preserves the path |
|---|---|---|---|
| Transport | Iroh mesh dial-by-key | HTTPS long-poll to one coordinator | Wire messages are **peer-symmetric** (author↔executor, not client↔server): the coordinator is a *relay of the same messages* peers will later exchange directly. |
| Identity | Biscuit token w/ Datalog caveats | Static per-collective join token + executor-side config | The join token is a *degenerate capability token* (one caveat: membership). Biscuit is additive. |
| Trust | oracle + reputation-weighted spot re-exec + DiFR | oracle re-run only (no redundancy) | The receipt already carries everything a spot-check needs; adding redundancy reads the same receipts. |
| Sandbox | Firecracker (Linux) + microVM | hardened Docker devcontainer both OSes | The task pack is a `devcontainer.json` either way; the microVM wraps the same container spec. |
| Credit | mutual-credit → Cashu | single signed ledger + caps | The MVP ledger IS a mutual-credit ledger with one shared mint; Cashu is a settlement-layer swap. |
| Execution | cross-provider + open-harness | open-harness/local default, subscription opt-in | Same provider-adapter contract (`lib/core.sh:947`); the tier is which adapter loads. |

The single design rule that makes this hold: **the coordinator is a message relay of a
peer-symmetric protocol, and the ledger is mutual-credit from day one.** Get those two shapes
right in the MVP and the mesh + currency are additions, not rewrites.

---

# Tier B — Shippable MVP (the thing we build first)

**Audience:** internal ~10–20 colleagues, one collective, one coordinator. Deliberately boring;
every piece has proven prior art AND a shipped waspflow primitive underneath it.

**One-line shape.** A Federation task is a **waspflow lane, serialized** — repo ref + env
(`devcontainer.json`) + the exact `waspflow spawn` invocation + the `--verify` contract. A
puller deserializes it into a real `--isolate` lane on their machine, runs it, and returns the
lane's branch + receipt. The author re-runs the verify gate on the returned branch. Trust =
independent re-verification; accounting = pooled receipts.

## B.1 Task definition schema — `federation-task.v1.json`

A task is a self-contained, signed JSON document. It reuses waspflow's spawn-flag surface
verbatim (`bin/waspflow:200–221`) so deserializing it is "fill in the `spawn` args."

```json
{
  "schema_version": 1,
  "task_id": "ftask-01H…",                  // uuid; the exactly-once key across the network
  "collective": "vana-internal",
  "author": { "pubkey": "ed25519:…", "handle": "tim" },
  "created_at": "2026-07-16T18:00:00Z",
  "title": "Fix flaky retry test in waspflow CI",

  "repo": {                                  // how the executor GETS the code
    "kind": "git",                           // git | bundle | archive_url
    "url": "https://github.com/…/waspflow.git",
    "ref": "da877d6",                        // pinned commit — reproducibility
    "auth": "public"                         // public | executor_github (§B.3)
  },

  "env": {                                   // devcontainer.json IS the env+deps+sandbox spec
    "devcontainer": { … inline or "path": ".devcontainer/federation.json" … },
    "runtime_deps": ["ripgrep", "jq"],       // asserted present; prepare_command installs
    "os_constraint": "any"                   // any | linux | macos (§B.3 macOS trust asymmetry)
  },

  "invocation": {                            // the EXACT waspflow spawn, minus --lane (puller names it)
    "provider_tier": "local-harness",        // local-harness | subscription  (§B.6, ToS routing)
    "model_class": "coding-30b",             // a CLASS, not an id — puller's own model satisfies it
    "effort": "high",
    "prompt_ref": "prompt.md",               // task prompt travels in the pack
    "isolate": true,                         // ALWAYS true for federation (sandbox + reversibility)
    "report": "report.md"                    // opt-in deliverable contract (bin/waspflow:221)
  },

  "validation": {                            // THE trust mechanism — reuses the verify gate verbatim
    "prepare_command": "npm ci",             // lane_get prepare_command (artifacts.sh:387)
    "verify_command": "bash scripts/verify.sh federation-flaky",
    "verify_timeout": 1800,                  // artifacts.sh:385
    "verify_strength": "suite",              // suite | smoke — declared, NEVER inferred (SCHEMAS_V1 §5)
    "fork_point": "da877d6",                 // for baseline reclassification (pre_existing detection)
    "expected_failure_classes_ineligible": ["pre_existing","invalid_oracle","infra","prepare"]
  },

  "budget": {                                // becomes the biscuit caveats at the aspirational tier
    "max_wall_seconds": 3600,
    "max_spend": { "currency": "quota", "amount": 1 },   // 1 task-unit; §B.5
    "allowed_egress": ["registry.npmjs.org","github.com"] // sandbox allowlist (§B.3)
  },

  "signature": "ed25519:…"                   // author signs the canonical form; executor verifies
}
```

**Design notes.**
- The `validation` block is a **1:1 map to the verify-gate fields waspflow already reads**
  (`prepare_command`, `verify_command`, `verify_timeout`, `verify_strength`, `fork_point`
  in lane state; `bin/waspflow:200`, `lib/artifacts.sh:375–423`). Deserializing a task =
  `spawn --isolate --prepare … --verify … --verify-timeout … --verify-strength … --report …`.
- `model_class` (not `model_id`) is the ToS-clean hook: the puller's own local model satisfies
  the class, so the task never demands a specific provider account.
- `os_constraint` encodes the macOS sandbox asymmetry (R2) at the task level, so an author can
  mark a task "linux-only" when it needs Firecracker-grade isolation.
- The pack is content-addressed by `task_id` + author signature; the coordinator never needs to
  read the code, only route the pack.

## B.2 Result verification — the honest trust model

**Primary oracle: the author re-runs the verify gate on the returned final state.** This is the
whole trust argument, and it is *already built*:

- The executor runs the task in an `--isolate` lane and returns the **lane's branch**
  (`waspflow/<lane>`, `lib/worktree.sh:30`) as a thin git bundle
  (`fanin_bundle_lane`, `lib/fanin.sh:206`) + the lane's Receipt v1.
- The author imports the bundle, checks it out, and runs `waspflow verify` — the same
  `artifacts_run_verify_checkpoint` (`lib/artifacts.sh:375`) the executor ran, on the same
  fork-point baseline. **The author does not trust the executor's reported pass** — they
  reproduce it. `verify` exits `0=pass / 2=fail` and writes a `failure_class`.
- **Baseline reclassification defeats the "trivially-passing oracle" attack**:
  `artifacts_classify_pre_existing` (`lib/artifacts.sh:428`) re-runs the oracle at the fork
  point in an **agent-inaccessible detached worktree**; if the task was already passing at the
  fork, the failure is `pre_existing`, not credited work.
- **Green-verify anti-gaming** (already shipped): `test_files_changed`
  (`lib/artifacts.sh:389`) flags a lane that touched test files; the escalation-prompt
  anti-gaming clause ("do not weaken, skip, or edit tests") is delivered to the worker
  (`ESCALATION_V1.md`, prompt section). The author sees `test_files_changed:true` in the
  receipt and can reject.

**The honest limits (state them, don't hand-wave):**
1. **You are running the author's code on the executor's machine.** The trust flows *both*
   ways. §B.3 protects the *executor* from the *task* (credential exfil). §B.2 protects the
   *author* from the *executor* (fake results). The MVP addresses both; neither is fully
   solved against a determined adversary — which is why the MVP is **~15 known colleagues**,
   not strangers.
2. **The oracle is only as good as the author's tests.** A weak oracle is gameable — this is
   R1, unresolved even at the aspirational tier (§D.1). MVP mitigation: `verify_strength` is
   declared and receipted; a `smoke`-strength result is visibly weaker than `suite`; the author
   ratifies the credit.
3. **No redundancy in MVP.** A single executor's result, independently re-verified by the
   author, is the trust unit. Reputation-weighted spot re-execution is Tier-A work — deferred
   because it burns a second member's tokens (dossier §2) and 15 colleagues don't need it.

**Trust model, stated plainly:** *within a collective of mutually-known colleagues, the
combination of (a) author-side independent re-verification against an agent-inaccessible
baseline and (b) the green-verify anti-gaming heuristics is sufficient. It is NOT sufficient
for strangers, and the MVP does not claim to be.*

## B.3 Sandbox + credential scoping

**Sandbox = a hardened Docker devcontainer wrapping the task's `--isolate` worktree.** Both
OSes; the microVM upgrade (Firecracker, Linux) is Tier-A.

- **Container hardening** (from the task's `devcontainer.json`, dossier §3/§7):
  `--cap-drop=ALL`, `--security-opt=no-new-privileges`, non-root user, read-only root FS where
  possible, **default-deny egress** with the task's `allowed_egress` allowlist as the only
  opening.
- **The worktree is the mount.** waspflow's `--isolate` already creates a sibling worktree
  (`lib/worktree.sh:24`) that is the *only* filesystem the container sees writable. Reversibility
  is free: `--reset-tree` (`git reset --hard <fork_point> && git clean -fd`,
  `ESCALATION_V1.md`) throws away a poisoned run.

- **Credentials NEVER enter the sandbox (R2, the critical rule).** The puller's provider auth
  (Claude/Codex token) and optional GitHub/Linear auth stay **on the host**. The pattern
  (dossier §3, proven): a **host-side masking proxy** injects the real credential only on
  requests to allow-listed provider hosts; the sandbox sees a per-session *sentinel*.
  - Claude Code `mask` mode / `@anthropic-ai/sandbox-runtime` implements exactly this and works
    on macOS (Seatbelt) + Linux (bubblewrap) — the macOS/Linux parity path.
  - **For the local-model path, this is trivially clean**: the model endpoint is
    `localhost:11434` (Ollama) and there is *no subscription token to protect* — the sandbox
    talks to a local port, egress to the internet stays default-denied. **This is why the
    local-harness tier is the reference Federation flow.**
  - GitHub/Linear auth (when the task opts into `executor_github`): scoped, short-lived tokens
    minted host-side (a fine-grained GitHub token limited to the one repo), injected by the same
    proxy, never written into the container env. Env vars are the biggest exfil blind spot
    (dossier §3) — so the container inherits *no* credential env vars.

- **macOS / Linux parity + the honest asymmetry.** Both run hardened Docker. Firecracker-grade
  isolation is Linux-only. The MVP's answer: **all MVP tasks are trusted-colleague tasks**, so
  hardened Docker + masking proxy is sufficient on both. `os_constraint` lets an author require
  Linux for a task that must not run under weaker isolation — the seam for the Tier-A
  stranger/microVM story.

## B.4 Topology — master-server that doesn't foreclose the mesh

**One coordinator process.** Nodes long-poll it for tasks (BOINC's pull model, dossier §1). The
coordinator holds: the collective roster, the task queue, and the credit ledger. It does **not**
read task code — it routes signed packs by `task_id`.

**The seam that preserves the mesh future (the load-bearing decision):** the wire protocol is
**peer-symmetric**. Messages are author↔executor, and the coordinator is a *relay*:

```
PUBLISH   author → [coordinator] → queue        (task pack, signed)
PULL      executor → [coordinator] → task pack   (long-poll; policy-filtered server-side is a hint,
                                                   executor re-checks policy locally — never trust the router)
CLAIM     executor → [coordinator]               (fencing: task_id + executor pubkey + lease deadline)
RESULT    executor → [coordinator] → author       (branch bundle + Receipt v1, signed)
CREDIT    author  → [coordinator] → ledger        (author-verified → signed ledger entry)
```

- **Task source** (both supported): (a) **declared markdown task files** — a repo directory of
  `*.federation-task.md` with the schema fields in frontmatter, `git`-versioned, the
  low-ceremony path; (b) **Linear OAuth** — the coordinator reads a Linear project (OAuth is
  fine *here* — it is task-sourcing, not the ToS-restricted subscription-credential sharing,
  dossier §5/§8) and materializes issues as task packs.
- **Fencing against churn (R4):** `CLAIM` records a lease deadline. If the executor's node
  vanishes (idle capacity reclaimed), the lease expires and the task returns to the queue. This
  maps directly onto waspflow's `arm_generation`/`session_id` CAS
  (`lane_update_if`, `lib/core.sh:283`) — the same fencing token that stops a stale runtime
  observer from clobbering state stops a zombie executor from returning a stale result.
- **Migration to mesh:** replace the coordinator's *routing* with Iroh dial-by-key; the
  coordinator degrades to bootstrap/relay + ledger host. Because messages are already
  peer-symmetric, the transport swap does not touch the message shapes. The ledger
  decentralizes last (§D.5).

## B.5 Credit / accounting — the simplest anti-freeloading primitive

**A single signed, append-only credit ledger — extend `receipts.jsonl`, not a new store.**
waspflow already has a `flock`-guarded, append-only, `schema_version:1` receipts file with an
exactly-once append primitive (`_receipts_append`, `lib/artifacts.sh:543`) and a
`receipts summary` aggregator (`bin/waspflow:700`). Federation adds a `receipt_kind:
"federation_credit"` row:

```json
{
  "schema_version": 1,
  "receipt_kind": "federation_credit",
  "task_id": "ftask-01H…",
  "executor": "ed25519:…",  "author": "ed25519:…",
  "amount": 1,  "currency": "quota_unit",
  "verify": { "state": "passed", "verify_strength": "suite", "failure_class": "none",
              "baseline_oracle": { "ran": true, "state": "passed" } },
  "author_reverified": true,           // the trust gate: credit is minted by the AUTHOR's re-verify
  "signed_by": "ed25519:…(author)…", "at": "2026-07-16T19:00:00Z"
}
```

- **Anti-freeloading:** mutual credit — balances sum to zero — with **per-member
  negative-balance caps** (dossier §6). A member who has consumed N task-units but produced 0
  hits their cap and can pull no more until they execute. For 15 colleagues, a plain signed
  ledger + caps beats any token machinery; the documented failure mode ("run up a negative
  balance and leave") is bounded by the cap and by everyone being a known colleague.
- **Credit is minted by the author's re-verification, not the executor's claim** (`verify`
  block above) — so a fake result earns nothing: the author re-runs the oracle and only signs
  the ledger entry on a genuine pass.
- **Path to the aspirational currency:** caps scale with repayment history → federated ledgers
  across collectives → Cashu ecash for accountless stranger settlement. The MVP ledger is
  *already* a mutual-credit ledger with one shared mint, so the currency is a settlement-layer
  addition (§A.4), not a rewrite.

## B.6 The open-harness provider tier (the ToS-clean substrate)

This is both a general waspflow capability and the reference Federation execution path. The
provider-adapter seam is already clean.

**The adapter contract** (enforced at load, `lib/core.sh:947`): a provider is a
`lib/providers/<name>.sh` implementing 9 mandatory functions —
`spawn is_idle revise preflight discover_session session_resumable turn_mark valid_models
mcp_policy` — plus optional `resume_with_arm` / `refresh_runtime_settings` /
`confirm_escalation_submission` (escalation + attestation). Everything downstream dispatches
generically via `${provider}_<fn>`.

**To add a 4th provider tier** (verified this pass — the exact closed sites a build must touch):
1. Add the name to `WASPFLOW_PROVIDERS=(claude codex grok)` — **`lib/core.sh:954`** (the one
   canonical valid-provider list).
2. Add a `_exec_<provider>` runner + an arm in the headless dispatch `case`
   (`lib/exec.sh:124`, has a `die` default — won't silently work).
3. Add arms to **`lib/events.sh:16` and `:67`** (`provider_event_tail`: log-path + the
   raw→`turn_started`/`turn_completed` normalizer). *This is the biggest per-provider surface
   after `is_idle`, and the one most sensitive to transport.*
4. Add arms to `lib/events.sh:112` (inspection classification), `lib/billing.sh:28` + `:69`
   (billing guard + `billing_path_v1`), `bin/waspflow:387` (client-minted vs self-minted
   session id), `lib/escalation.sh:80` (literal `provider/model/effort` arm regex).
5. Usage/help text (cosmetic).

**Spec the two reference adapters:**

**Pi** (`@earendil-works/pi-coding-agent`; the cleanest fit, dossier §9):
- `pi_spawn`: launch `pi` interactive in the lane's tmux window; the prompt travels as with
  the built-ins.
- `pi_is_idle` / `pi_turn_mark` / `pi_discover_session`: **JSONL on disk** at
  `~/.pi/agent/sessions/…`, documented turn-end via `AssistantMessage.stopReason`. This fits
  the built-in mold *directly* — same shape as codex's rollout tail (`codex.sh:587`): discover
  session id → locate JSONL → inspect last terminal event. `turn_mark` counts `stopReason`
  markers.
- `pi_resume_with_arm`: resume by `--session <id>`; **model AND effort are CLI flags on resume**
  (`--model provider/id:level`, `--thinking off→max`) — so escalation's arm switch works
  cleanly, and on-disk `model_change`/`thinking_level_change` entries make
  `pi_refresh_runtime_settings` (attestation) trivial: Pi exposes both model and effort, so its
  receipts are `stats_eligible` where claude's `observed_effort` is `null` (`SCHEMAS_V1.md` §5).
- `pi_valid_models`: `pi --list-models` → `source=live_query`.
- Local models: Ollama/vLLM/LM Studio via 4 API dialects → the ToS-clean path.
- **Gap flagged:** no built-in permission system (the waspflow sandbox §B.3 supplies safety);
  `-p` + `--session` combo undocumented → smoke-test in the build.

**OpenCode** (`anomalyco/opencode`; the SSE case, dossier §9):
- `opencode_is_idle`: **`session.status` / `session.idle` over SSE** (`opencode serve`) is the
  best idle signal, but it is a *transport* difference from the on-disk-JSONL built-ins → the
  adapter runs a tiny local listener or polls the JSON-per-object session store; `events.sh`
  needs a bespoke normalizer arm (the transport-sensitivity called out above).
- `opencode_spawn`: `opencode run --auto --format json -s <id>` (note the documented
  `--auto` CI-mode permission bug #13851 — pin behavior in a contract test).
- `opencode_resume_with_arm`: resume by `-s <id>`; effort lives in config *variants* (CLI
  selection unconfirmed) → effort attestation likely emits `effort_default` ineligibility
  (`SCHEMAS_V1.md`).

**Why the local-model path is the ToS-clean Federation default:** a task marked
`provider_tier: local-harness` + `model_class: coding-30b` is pulled and run against the
*executor's own* Qwen3-Coder / Devstral 2 via Pi on Ollama. No subscription, no
credential-sharing clause (R3 gone), no token to meter or exfiltrate (R2 collapses — the
endpoint is localhost). Subscription-agent execution stays opt-in behind the R3 warning that
`lib/billing.sh` already emits.

## B.7 First-week walkthrough (concrete, step by step)

**Day 0 — Tim announces.** Tim posts in the team channel: "Install `waspflow` (adds
`waspflow federation`), join the `vana-internal` collective with this token: `fed-tok-…`. If you
have spare Claude/Codex capacity or a local coding model, you can execute my queued tasks and
earn credit."

1. **Install & join (10 colleagues).**
   `waspflow federation join --collective vana-internal --token fed-tok-…`
   → the node registers its pubkey with the coordinator, writes executor policy defaults to
   `~/.waspflow/federation/policy.json`:
   ```
   { "max_spend_per_task": {"currency":"quota_unit","amount":1},
     "allowed_task_families": ["*"], "provider_tier": "local-harness",
     "manual_pull": true, "networks_enabled": ["vana-internal"] }
   ```
   Ocean (macOS, no local model, unused Claude capacity) sets `provider_tier: subscription` and
   accepts the R3 warning. Tim's Linux box has Ollama + Qwen3-Coder → `local-harness`.

2. **Tim defines a task.** He writes `tasks/fix-flaky-retry.federation-task.md` (frontmatter =
   the §B.1 schema): repo `waspflow@da877d6`, `devcontainer.json`, prompt "make
   `scripts/verify.sh federation-flaky` pass without editing the test", validation
   `verify_command: bash scripts/verify.sh federation-flaky`, `verify_strength: suite`,
   `fork_point: da877d6`, budget 1 quota-unit / 3600s, egress `[npmjs, github]`.
   `waspflow federation publish tasks/fix-flaky-retry.federation-task.md`
   → signs the pack, pushes it to the coordinator queue. (Alternatively
   `federation publish --linear VANA-123` materializes a Linear issue as a pack.)

3. **A colleague pulls.** Priya (Linux, local model) runs
   `waspflow federation pull` → long-polls, receives the pack, **re-checks it against her local
   policy** (task family allowed? spend ≤ cap? egress subset of policy? os_constraint met?),
   `CLAIM`s it with a 1-hour lease.

4. **Execute (sandboxed, against her account).** The pull deserializes the pack into a real lane:
   ```
   waspflow spawn --provider pi --model-class coding-30b --effort high --isolate \
     --prepare "npm ci" --verify "bash scripts/verify.sh federation-flaky" \
     --verify-timeout 1800 --verify-strength suite --report report.md \
     --lane fed-fix-flaky -- "$(cat prompt.md)"
   ```
   inside the hardened container (§B.3): worktree = only writable mount, creds masked (here:
   none — local model on localhost), egress = `[npmjs, github]` only. Pi runs against her Ollama
   Qwen3-Coder. waspflow's normal lifecycle applies — `wait` polls `pi_is_idle`, `revise` can
   steer.

5. **Validate (on the executor first).** On idle, the pull runs `waspflow verify fed-fix-flaky`
   → `artifacts_run_verify_checkpoint` runs prepare+verify; `artifacts_classify_pre_existing`
   confirms the flaky test was failing at `da877d6` (not `pre_existing`). Result: `passed`,
   `failure_class: none`, `test_files_changed: false`. Priya returns the branch bundle
   (`fanin_bundle_lane`) + Receipt v1 via `RESULT`.

6. **Author re-verifies (the trust gate).** Tim's node receives the result, imports the bundle,
   checks out `waspflow/fed-fix-flaky`, and runs `waspflow verify` **himself** — same oracle,
   same fork-point baseline. It passes; `test_files_changed:false`; `verify_strength:suite`.
   He does *not* take Priya's word — he reproduced it.

7. **Credit.** Tim's re-verify passing triggers `federation credit` → a signed
   `receipt_kind:"federation_credit"` row (amount 1, `author_reverified:true`) appended to the
   ledger under `flock`. Priya's balance: +1. Tim's: −1.
   `waspflow federation ledger` shows every member's balance and cap headroom.

8. **Freeloading is bounded.** Ocean pulls two tasks but her Mac's runs both fail author
   re-verify (weak results). She earns 0, and her −N consumption approaches her negative-balance
   cap; at the cap, `federation pull` refuses until she produces a validated result. No one can
   drain the pool.

By end of week: ~10 nodes, a handful of task families, a live ledger, and every credited task
carries an independently-re-verified receipt. The subscription path (Ocean) works but is
flagged R3; the local-harness path (Tim, Priya) is the clean default.

---

# Reuse ledger — what's reused vs genuinely new

For each Federation need, the SHIPPED waspflow primitive that covers it (anchors verified this
pass). **Federation's core insight: a federated task IS a serialized `--isolate` lane, so the
lane lifecycle carries most of the weight.**

| Federation need | Shipped primitive (REUSED) | Anchor | New work on top |
|---|---|---|---|
| **Result trust** (R1) | **Verify gate** — portable oracle, `passed/failed/timeout/infra/task/pre_existing/invalid_oracle` taxonomy, agent-inaccessible fork-point baseline reclassification | `lib/artifacts.sh:375` (`artifacts_run_verify_checkpoint`), `:428` (`artifacts_classify_pre_existing`) | Author-side **re-verify** of a returned branch; declaring the oracle in the task pack |
| **Accounting substrate** | **Receipts** — append-only `receipts.jsonl`, `flock`-guarded, `schema_version:1`, `stats_eligible` honesty gate, `receipts summary` aggregator | `lib/artifacts.sh:543` (`_receipts_append`), `bin/waspflow:700` | New `receipt_kind:"federation_credit"` row; signed cross-principal entries; mutual-credit caps |
| **Sandbox layer** | **Worktree isolation** — sibling worktree, dirty-refuse removal, reset surface for `--reset-tree` | `lib/worktree.sh:24` | Wrap the worktree in a hardened container + masking proxy + egress allowlist |
| **Exactly-once / fencing** (R4) | **Lane model** — `lane_uuid`, `arm_generation`+`session_id` CAS via `lane_update_if`, per-lane operation flock | `lib/core.sh:250`, `:283`, `:309` | Network lease (`CLAIM` deadline) mapped onto the same CAS; `task_id` as the network exactly-once key |
| **Result integration** | **fan-in** — `captured --in <ref>` by content signature; `fanin_bundle_lane` (thin verified git bundle) | `lib/fanin.sh:150`, `:206` | Bundle transport over the wire; author-side import + capture check |
| **Cross-provider / open-harness execution** | **Provider-adapter contract** (9 mandatory fns) + generic `${provider}_*` dispatch | `lib/core.sh:947`, `:940` | New `lib/providers/pi.sh` + `opencode.sh`; the 8 closed sites (§B.6); local-model routing |
| **Cross-provider transition** | **Escalation** — phased transition record, `resume_with_arm`, cross-provider handoff with structured state, poison counter | `lib/escalation.sh`, `ESCALATION_V1.md` | Reassign-on-churn reuses the handoff shape; no new machinery |
| **Credential-path awareness** (R2) | **Billing guard** + `BillingPath v1` (per-provider auth evidence, `subscription` vs `api_key`) | `lib/billing.sh:38`, `:69` | Masking proxy (creds outside sandbox); the guard already emits the R3 warning |
| **Work unit** | **Lane / spawn flag surface** (`--isolate --prepare --verify --verify-timeout --verify-strength --report`) | `bin/waspflow:200–221` | Serialize/deserialize as `federation-task.v1.json` |
| **Selection / policy preflight** | **Selection gate** (`--op`, `--auto`, availability tri-state, quota predicate) | `lib/selection.sh`, `SELECTION_V1.md` | Executor-side policy check reuses the same preflight before spawn |

**Genuinely NEW (not in waspflow today — the repo inventory found no federation/networking code):**
1. **Transport + coordinator** — the peer-symmetric wire protocol, long-poll queue, roster.
2. **Cross-principal identity** — pubkeys, signed packs/receipts, join tokens → biscuit.
3. **The sandbox container + masking proxy** — hardening the worktree, creds-outside injection,
   egress allowlist (waspflow isolates *files*, not *credentials/network* today).
4. **Mutual-credit semantics** — caps, zero-sum balances, author-minted credit (receipts are
   explicitly single-operator today; `SCHEMAS_V1.md`: "pooling receipts across principals is a
   telemetry-era concern" — Federation is the forcing function that lifts that).
5. **The open-harness adapters themselves** (`pi.sh`, `opencode.sh`) + the 8 closed-site edits.

Everything else is reuse. The verify gate is the single most valuable pre-existing asset:
it is already an *outcome*-checking oracle (state, not transcript) — exactly the verification
posture the dossier proves is correct under untrusted executors (§2).

---

# The 5 hardest open questions (build phase must resolve)

Each with a recommended answer + the tradeoff. These are the dossier's five, sharpened with the
MVP decisions above.

### D.1 How strong must an owner-supplied oracle be before a result is trustable? (R1, the crux)
**Recommendation:** For the MVP, gate credit on **declared `verify_strength: suite`** + an
**author-side re-verify** + the green-verify anti-gaming heuristics (`test_files_changed`,
anti-gaming prompt clause). Do *not* attempt an automated minimum-strength bar in v1 — make it
**owner-ratified per task family** (reuse the control-loop's "human-owned bar" slot,
`MODEL_SELECTION_CONTROL_LOOP.md`). Emit a loud warning on `smoke`-strength credit.
**Tradeoff:** a determined colleague could still author a weak oracle and self-deal — bounded in
the MVP only by "everyone is known." Strangers (Tier A) need reputation-weighted spot
re-execution + an oracle-audit process, which is genuinely unsolved. Confidence: **medium** —
the mechanism is built; the *sufficiency bar* is a judgment call the owner must set.

### D.2 Credential isolation on macOS — is Seatbelt/Docker enough for stranger tasks? (R2)
**Recommendation:** **Yes for the MVP** (all tasks are trusted-colleague), **no for Tier A
strangers** — restrict untrusted-stranger execution to Linux (Firecracker) via the task's
`os_constraint`, keep macOS to trusted-collective tasks. The masking-proxy (creds-outside)
pattern works identically on both OSes, so the MVP is safe; the asymmetry is only about the
*isolation floor* for untrusted code.
**Tradeoff:** macOS pullers (like Ocean) can't safely execute stranger tasks at the aspirational
tier — a real capacity limit on the largest consumer OS. Accept it; the local-model path
(localhost endpoint, no creds) narrows the exposure enormously. Confidence: **high** for the
MVP boundary, **medium** on the exact Tier-A microVM story.

### D.3 The smallest credit primitive that stops freeloading AND doesn't foreclose strangers?
**Recommendation:** **Signed append-only mutual-credit ledger (a `receipt_kind` on
`receipts.jsonl`) with per-member negative-balance caps, credit minted by the author's
re-verify.** Design the ledger entry to be *self-verifying* (author signature over
`(task_id, executor, amount, verify-result)`) so a future federated/Cashu settlement layer can
consume the same entries.
**Tradeoff:** a single shared ledger is a centralization point (the coordinator hosts it) — the
last thing to decentralize (§D.5). Cashu's accountless bearer model is in *tension* with
per-member caps, so the stranger transition is a genuine trust-model change, not a drop-in.
Confidence: **high** for the MVP ledger; **low-medium** that the Cashu transition is
rewrite-free.

### D.4 One adapter (ACP) or many native adapters? (R6, harness churn)
**Recommendation:** **Native adapters for the top 2–3 (Pi, then OpenCode/Cline), ACP as a
fallback.** ACP promises one-integration-reaches-many but is editor-centric and less
battle-tested headless; waspflow's contract is *headless-first* (disk-tail idle detection), which
Pi's on-disk JSONL fits directly and ACP's streamed-turn model fits awkwardly. Native-first,
ACP-as-breadth.
**Tradeoff:** N native adapters = N maintenance surfaces against a churning ecosystem (Roo dead,
Continue read-only). Mitigation: the adapter contract is small (9 fns) and Pi/Cline have the
most stable headless stories. Confidence: **medium-high** — Pi is a clean fit; the ACP fallback
is unproven headless.

### D.5 Master-server → mesh without a rewrite — what can decentralize incrementally?
**Recommendation:** Decentralize in this order: **(1) transport** (coordinator-routing → Iroh
dial-by-key; easy, the messages are already peer-symmetric); **(2) discovery/roster** (Iroh
bootstrap + relay); **(3) ledger LAST** (hardest — it's the shared-consistency point). Get the
wire contract peer-symmetric from day one (§B.4) — that is the whole hedge.
**Tradeoff:** the ledger is the forcing constraint: mesh task-routing is straightforward, but a
*decentralized credit ledger* is where you'd need CRDT/gossip or Cashu — a hard architectural
break if the MVP ledger isn't shaped for it. Keeping the ledger as signed, self-verifying,
append-only entries (§D.3) is the mitigation, but "unproven" is the honest label. Confidence:
**medium** — transport migration is low-risk; ledger decentralization is the real Tier-A
research item.

---

# Explicit MVP scope cuts (and why they're safe)

What the aspirational version has that the MVP deliberately omits:

| Cut | Why it's safe to omit for ~15 colleagues |
|---|---|
| **Mesh / P2P transport (Iroh)** | One coordinator is fine at 15 nodes; the peer-symmetric wire contract (§B.4) means adding Iroh later doesn't touch message shapes. |
| **Biscuit capability tokens** | A static join token + executor-side policy config enforces "who may spend what" adequately among known colleagues; biscuit is additive (the join token is a 1-caveat capability). |
| **Reputation-weighted spot re-execution** | Author-side re-verify + anti-gaming heuristics suffice when all executors are known; redundancy burns a second member's tokens (dossier §2) for marginal MVP value. |
| **Firecracker microVM** | Hardened Docker + masking proxy is sufficient for trusted-colleague tasks on both OSes; `os_constraint` reserves the Linux/microVM seam for the stranger tier. |
| **Cashu ecash / accountless settlement** | 15 colleagues want a readable balance sheet, not bearer tokens; the mutual-credit ledger is the honest primitive and the migration base. |
| **Cross-account subscription resale / API-key path** | Defeats the "wasted subscription capacity" premise (you'd pay per call); the local-harness path is the ToS-clean default instead. |
| **Cryptographic result proofs (SNARK/TEE)** | "Basically toys" for general programs (dossier §2); the verify gate is the tractable trust mechanism. |
| **Automated oracle-strength bar** | Owner-ratified per family (D.1); an automated cross-principal bar is unsolved even at Tier A. |

**The cut discipline:** every omission is either (a) a strict superset addition that the MVP's
data shapes already accommodate (mesh, biscuit, Cashu, microVM), or (b) something that only
matters for *strangers* (redundancy, result proofs, oracle-audit). Nothing cut here forces a
rewrite to add back — that is the §A.4 subset property, applied.

---

# Confidence & decisions that need the owner

**Overall confidence: medium-high** that Tier B is buildable against the shipped primitives —
the verify gate, receipts, worktree, fanin, lane CAS, and provider seam all exist and were read
this pass; the reuse ledger anchors are verified. **Lower confidence** on the two genuinely-new
network pieces: the peer-symmetric wire protocol (unproven but low-risk) and the
sandbox-container + masking-proxy hardening (proven pattern, but the macOS parity and egress
allowlisting need a build-time smoke test against a real exfil attempt).

**Where I'm guessing (flagged honestly):**
- Pi's `-p` + `--session` headless-resume combo is undocumented (dossier §9) — the `pi.sh`
  adapter's idle/resume path needs a smoke test before it's trusted.
- OpenCode's SSE idle signal is a transport mismatch for waspflow's disk-tail model — the
  `events.sh` normalizer arm is the riskiest per-provider surface.
- The Cashu → mutual-credit transition (D.3/D.5) may not be rewrite-free; I've shaped the ledger
  to minimize the break but can't guarantee it.

**Decisions that need the owner (Tim):**
1. **Oracle-strength bar (D.1):** ratify the minimum `verify_strength` that earns credit per
   task family, and whether `smoke` results can ever earn credit. *This is the R1 crux — it's a
   judgment call no stats table produces.*
2. **macOS stranger boundary (D.2):** confirm the MVP restricts to trusted-colleague tasks (so
   hardened Docker suffices) and that untrusted-stranger execution is Linux-only at Tier A.
3. **Default provider tier:** confirm `local-harness` is the reference/default and
   subscription-agent execution is opt-in behind the R3 warning (my read of the owner steer, but
   it's a product default worth ratifying).
4. **Negative-balance cap value** for the internal collective (the one number that bounds
   freeloading).
5. **Task source priority:** markdown-first (low ceremony) vs Linear-OAuth-first (structured) for
   the first-week rollout — affects what the build phase wires first.

**No owner decision is required to *start* the build** — the reuse ledger and Tier-B schemas are
concrete enough to begin the transport + `pi.sh` adapter + task-serialization work while the five
ratifications above are pending.
