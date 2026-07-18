# Federation v2 — Hostile-Code-First Two-Tier Design

**Status:** Revised design proposal; build against Tier B only.
**v0 scope (2026-07-18): see `FEDERATION_V0_SCOPE.md` — it WINS for the first cut.**
Owner steer: keep Firecracker + gateway + signed envelope; DEFER escrow/credit and
author-side re-verification (additive later); network is host/LAN-blocked but
internet-ALLOWED (tasks need egress; exfiltration out of v0 threat model); open-harness
scope includes Claude/Codex CLIs pointed at other models via the gateway.
**Date:** 2026-07-16.
**Supersedes:** `FEDERATION_DESIGN.md`.
**Credential-substrate revision:** v2 now uses owner-operated Claude/Codex-compatible
gateways with owner-issued scoped, rate-limited, revocable keys. It no longer limits v0 to
local models or treats direct subscription sharing as a future Federation path.

**Grounded in:** `FEDERATION_SECURITY_DEEP_DIVE.md`, `FEDERATION_PRIOR_ART.md`,
`FEDERATION_DESIGN_REVIEW_SOL.md`, and the shipped waspflow lane, verification,
worktree, receipt, fan-in, selection, and provider-adapter code.

Federation pools spare coding-agent capacity across a collective. An author publishes a
bounded coding task and grants an executor a purpose-built key to the author's own model
gateway; the executor runs the task in a hostile-code runner; the author accepts only a result
that passes an immutable acceptance oracle in a clean evaluator; a coordinator leases work
and settles credit.

The v1 design got the center of gravity wrong. Federation is not merely a serialized lane. It
is a **hostile-code boundary in both directions**:

1. A malicious or compromised task can attack the executor that runs it.
2. A malicious or compromised executor can return code that attacks the author during
   re-verification.

The centerpiece of v2 is therefore an executor-owned hostile-task runner. The runner is build
order item 1, and no coordinator, credit system, or provider integration may be called an MVP
until the runner passes the adversarial acceptance suite in §B.3. The shipped waspflow verify
gate remains useful and necessary, but it is not a security boundary and is not sufficient by
itself.

---

## 0. Decisions and non-negotiable invariants

These are design constraints, not preferences.

1. **The executor owns the sandbox.** A task never supplies `devcontainer.json`, Docker flags,
   lifecycle hooks, host mounts, devices, network rules, or a sandbox image. Unknown task
   fields and capability requests outside the executor policy are rejected, not ignored.
2. **Every run is ephemeral.** Execution, executor-side checking, author-side re-verification,
   and untrusted artifact inspection each use a fresh sandbox instance. It is destroyed after
   the run and shares no writable state with another task.
3. **There is no direct network path.** The sandbox has no general DNS or outbound TCP/UDP.
   Its only external capability is a vsock connection to a host-side credential injector,
   which can reach one pre-registered owner gateway. The gateway exposes model inference, not
   a generic HTTP CONNECT tunnel or an administrative model API.
4. **The credential substrate is the owner's gateway.** For Tim's task, Ocean uses a scoped,
   rate-limited, revocable API key Tim issued for Tim's Claude/Codex-compatible gateway. The
   gateway may route to Tim's self-hosted models or to provider models Tim accesses through
   ToS-valid provider APIs. Federation never shares or exercises Tim's Anthropic/OpenAI
   subscription credential. The key is intentionally delegable and killable; the host-side
   injector still keeps it out of hostile code, while the gateway enforces task/model/method/
   request/token/wall limits. Pi is the first adapter, but the substrate is not local-model-only.
5. **The same runner protects both principals.** Executor-side task execution and author-side
   result evaluation use the same immutable runner profile, but always in distinct fresh
   instances and modes.
6. **The oracle is immutable.** Its entrypoint, test assets, dependency lock, baseline, and
   acceptance predicate are content-addressed in the author's signed task. Returned code
   cannot replace the oracle or its configuration.
7. **v0 accepts transition tasks only.** The signed baseline must deterministically fail the
   task-specific acceptance predicate, and the candidate must pass it. Already-green,
   subjective, benchmark-only, and “make this better” tasks do not earn automatic credit in
   v0.
8. **Task and result identities are content digests.** Human labels and UUIDs are aliases.
   They are not exactly-once keys and are not part of the trust argument.
9. **Settlement is a separate state machine and ledger.** `receipts.jsonl` remains local
   telemetry. It is not authoritative accounting.
10. **The coordinator is permanent for Tier B.** The reusable future seam is the signed,
    transport-independent envelope. A mesh is a different authority architecture, not a
    transport configuration or strict superset of this MVP.

### 0.1 v0 security and product scope

v0 deliberately supports:

- one internal collective with a trusted central coordinator;
- Linux executors with KVM and the approved Firecracker runner profile;
- public or explicitly non-sensitive allowlisted repositories;
- owner-operated Claude/Codex-compatible gateways, addressed by pre-registered gateway IDs;
- owner-issued per-executor keys that are scoped, rate-limited, revocable, and held outside
  the sandbox by the host-side injector;
- self-hosted models and ToS-valid provider models behind those gateways;
- Pi as the first runtime adapter, plus local contract tests against the real Claude and Codex
  CLIs before the production gateway integration lands;
- deterministic fail-at-baseline/pass-at-candidate tasks;
- one claimed execution by default, with optional two-executor redundancy;
- claim-time mutual-credit escrow and bounded attempt compensation.

v0 deliberately does **not** support direct Anthropic/OpenAI subscription credentials,
unregistered gateway URLs, unscoped provider keys, author or executor GitHub credentials,
arbitrary internet access, author-supplied container configuration, macOS execution, private
data that an executor is not permitted to see, subjective tasks, public strangers, or
decentralized scheduling/accounting.

The ToS issue is dissolved by construction: Federation authenticates to infrastructure the
issuer owns and to keys the issuer intentionally created for delegation. Any provider model
behind that gateway is reached by the issuer through a ToS-valid provider API path; Federation
does not route consumer subscription credentials between principals.

---

# Tier A — Aspirational Federation

Tier A preserves the product vision: collectives may include friends, companies, or strangers;
executors advertise capacity and policy; authors publish portable work; results settle through
credit or currency; open/self-hosted harnesses remain first-class; and owner-operated gateways
can expose self-hosted or ToS-valid provider models through one delegable API contract.

## A.1 Aspirational layers

| Layer | Direction | Security condition before adoption |
|---|---|---|
| Identity and delegation | Per-principal keys and Biscuit-style attenuated capabilities | Revocation, key rotation, scope, and spend limits must be enforced by the authoritative coordinator or a separately specified decentralized authority. A shared bearer join token is not treated as a degenerate Biscuit. |
| Hostile-task isolation | Firecracker-class microVMs on Linux; a separately proven VM backend on other operating systems | The backend must satisfy the same runner contract and red-team suite as v0. A task-authored devcontainer is never the boundary. |
| Model and credential gateway | Owner-operated Claude/Codex-compatible gateway with scoped, rate-limited, revocable keys; routes to self-hosted and ToS-valid provider models | The task names a pre-registered gateway ID, never a raw destination. A host-side injector keeps the delegated key outside the VM; the owner gateway fixes route/model/methods and enforces request/token/wall limits and revocation. No direct provider subscription credential crosses principals. |
| Result trust | Clean immutable-oracle evaluation plus policy-selected redundant execution | Redundancy means independent candidates are each evaluated; coding outputs need not be byte-identical. Random assignment and non-disclosure of peer identity reduce collusion in a stranger tier. |
| Settlement | Coordinator-backed escrow for ordinary collectives; a separately designed cash or ecash market for strangers | Identity-bound mutual credit and bearer ecash have different trust and data models. Cashu is not a drop-in storage adapter for the Tier B ledger. |
| Transport | HTTPS, Iroh, or another carrier for the same signed envelopes | Transport portability does not decentralize claim ordering, roster authority, revocation, or double-spend prevention. |

## A.2 Topology: what is and is not forward-compatible

The Tier B coordinator is the authoritative scheduler, lease allocator, identity roster, and
ledger sequencer. That is a durable supported topology, not scaffolding that silently becomes a
mesh later.

The task and result envelopes in §B.2 are deliberately transport-independent. A future system
may move large artifacts peer-to-peer or carry envelopes over Iroh without changing what the
author and executor sign. That is the real seam.

A true mesh would still require new designs for discovery, offline store-and-forward,
simultaneous-claim resolution, roster and revocation distribution, coordinator equivocation,
canonical ledger ordering, and double-spend prevention. It may reuse the envelopes, runner, and
oracle evaluator. It is **not** a strict subset/superset migration from Tier B, and v2 makes no
rewrite-free promise.

---

# Tier B — Buildable v0

## B.1 System boundaries and trust model

There are five principals:

- **Author:** chooses the source snapshot, prompt, immutable oracle, budget, and fee; may send a
  malicious task.
- **Executor:** owns the machine, runner, and harness; holds an author-issued gateway key in
  the host credential injector; may return a malicious result or lie about execution.
- **Gateway issuer:** for v0, the task author; registers a gateway descriptor and issues each
  executor a scoped, rate-limited, revocable key. The gateway may serve the issuer's
  self-hosted models or ToS-valid provider routes.
- **Coordinator:** owns queue ordering, leases, escrow, settlement sequencing, roster, and
  revocation for the collective; Tier B explicitly trusts it not to equivocate.
- **Runner:** the locally enforced security boundary. It trusts neither task nor candidate
  content. Its binary/profile digest is allowlisted by the collective.

The author necessarily discloses the task's source, prompt, and test-relevant data to the
executor. A sandbox cannot provide source confidentiality from the machine owner. v0 therefore
permits only repositories the executor is authorized to read and data the executor is
authorized to possess.

The result trust equation is:

> immutable signed task + fresh secret-free guest with task-scoped gateway authority +
> fail-to-pass oracle transition + author-side clean re-evaluation + optional independent redundancy

`waspflow verify` contributes command orchestration and result taxonomy. It is **necessary but
not sufficient** because, by itself, it runs arbitrary commands in a worktree, does not isolate
credentials or network, does not make the oracle immutable, and does not prove an already-green
baseline was made better.

## B.2 Signed content-addressed envelopes

### B.2.1 Canonicalization and signature contract

Tier B uses versioned envelopes with this common contract:

1. Encode `payload` using RFC 8785 JSON Canonicalization Scheme (JCS), UTF-8.
2. Compute `payload_digest = sha256(JCS(payload))`.
3. Sign the domain-separated bytes
   `waspflow-federation/<kind>/v2\0<raw-payload-digest>` with Ed25519.
4. The envelope address is `<kind>:sha256:<hex-digest>`.
5. Every external artifact reference contains `sha256`, byte length, and media type. The bytes
   must match before any parser sees them.

Signatures are outside `payload`; adding a cosignature does not change the content address.
The verifier rejects non-canonical encodings, unknown schema versions, duplicate keys, oversized
fields/artifacts, invalid UTF-8, expired tasks, invalid signatures, and digest mismatches.

`display_id` is for humans only. The coordinator keys idempotency by payload digest and enforces
unique `(task_digest, claim_generation)` and `result_digest` constraints.

### B.2.2 Task envelope

Illustrative `federation.task.v2` payload:

```json
{
  "schema": "federation.task.v2",
  "collective": "vana-internal",
  "display_id": "fix-flaky-retry",
  "author_key": "ed25519:...",
  "created_at": "2026-07-16T18:00:00Z",
  "expires_at": "2026-07-23T18:00:00Z",
  "source": {
    "base_artifact": {
      "sha256": "...",
      "bytes": 4812073,
      "media_type": "application/vnd.waspflow.source-bundle.v1"
    },
    "base_revision": "git:sha1:da877d6..."
  },
  "prompt": {
    "artifact": {"sha256": "...", "bytes": 1842, "media_type": "text/markdown"}
  },
  "runner": {
    "profile": "wf-federation-linux-v0",
    "profile_digest": "sha256:...",
    "resource_request": {"vcpus": 4, "memory_mib": 8192, "disk_mib": 20480, "wall_seconds": 3600},
    "capabilities": ["workspace-write", "model-chat"],
    "model_class": "coding-high",
    "gateway": {
      "gateway_ref": "gateway:ed25519:tim:primary",
      "issuer_key": "ed25519:...",
      "compatibility": ["anthropic-messages", "openai-responses"],
      "route_class": "coding-high",
      "required_key_scope_digest": "sha256:..."
    }
  },
  "oracle": {
    "harness_artifact": {
      "sha256": "...",
      "bytes": 129044,
      "media_type": "application/vnd.waspflow.oracle-bundle.v1"
    },
    "entrypoint": "oracle/run",
    "dependency_lock_digest": "sha256:...",
    "timeout_seconds": 1800,
    "transition": {"baseline": "fail", "candidate": "pass"},
    "protected_paths": ["oracle/**", ".waspflow-federation/**"]
  },
  "trust": {"replicas": 1, "required_passes": 1},
  "settlement": {
    "currency": "federation-credit-v0",
    "success_fee": 100,
    "attempt_fee": 10,
    "max_paid_attempts": 1
  }
}
```

The task may request fewer resources or a subset of capabilities from the named runner
profile. It cannot supply a container/VM specification, image, mount, device, security option,
raw network destination, shell preparation hook, or provider credential. `gateway_ref` must
resolve through the executor's signed local registry to the same author/issuer identity and an
approved TLS endpoint; the task cannot turn it into an arbitrary URL. The required key-scope
digest lets the executor prove locally that the key Tim issued Ocean is no broader than the
task requests without placing the key in the envelope. Dependencies are either inside the
signed base/oracle artifacts or identified by digests already available in an executor-owned,
allowlisted cache. A missing dependency rejects the task; it does not open the network.

At publish time, the author's client runs the baseline through evaluator mode and includes the
signed preflight report as a referenced artifact. Executors re-run baseline preflight after
claim; an author's report is evidence, not authority.

### B.2.3 Result envelope

Illustrative `federation.result.v2` payload:

```json
{
  "schema": "federation.result.v2",
  "task_digest": "sha256:...",
  "claim": {
    "generation": 3,
    "executor_key": "ed25519:...",
    "lease_token_digest": "sha256:...",
    "lease_expires_at": "2026-07-16T20:00:00Z"
  },
  "base_artifact_digest": "sha256:...",
  "candidate": {
    "artifact": {
      "sha256": "...",
      "bytes": 24591,
      "media_type": "application/vnd.waspflow.candidate-patch.v1"
    },
    "tree_digest": "sha256:..."
  },
  "executor_evaluation": {
    "report_artifact": {"sha256": "...", "bytes": 3094, "media_type": "application/vnd.waspflow.evaluation.v1"},
    "runner_profile_digest": "sha256:...",
    "baseline": "fail",
    "candidate": "pass"
  },
  "metering": {
    "gateway_requests": 37,
    "gateway_input_tokens": 108240,
    "gateway_output_tokens": 18732,
    "wall_seconds": 1461
  },
  "submitted_at": "2026-07-16T19:31:02Z"
}
```

The executor signs the result using the result domain. The coordinator accepts it only while
the exact claim generation and lease token are current. A late result may be stored for audit,
but cannot transition or settle a reassigned claim.

Candidate artifacts are untrusted. Size/path/symlink checks, extraction, patch application,
Git parsing, and tree-digest calculation occur inside a fresh runner instance. The host and
author never check out the executor's branch directly.

## B.3 The hostile-task runner — centerpiece and build gate 1

### B.3.1 Runner interface

The runner is a narrow component with four operations:

```text
runner inspect-artifact <digest> <limits>
runner preflight       <task-digest>
runner execute         <task-digest> <claim-token>
runner evaluate        <task-digest> <candidate-digest>
```

All operations resolve immutable artifacts from a local content-addressed store after hash and
size verification. No operation accepts raw Docker flags, a devcontainer, an arbitrary host
path, a network allowlist, or a shell command from the result.

`execute` gives a harness a writable copy-on-write workspace based on the signed source,
the signed prompt, and access to the host credential injector. `preflight` and `evaluate` do not
start the agent. `evaluate` reconstructs the candidate by applying the untrusted candidate
artifact to the signed base and mounts the immutable oracle separately.

The profile digest covers the VM kernel and root image, launcher, seccomp/landlock policy where
applicable, mount table, firewall, gateway protocol, resource ceilings, artifact limits, and
runner version. A collective allowlist maps the human profile name to approved digests.

### B.3.2 v0 isolation profile

`wf-federation-linux-v0` requires:

- Linux host with KVM and a Firecracker microVM for every operation;
- a runner-owned, read-only root image and separate ephemeral copy-on-write workspace;
- no host filesystem mounts, Docker socket, SSH agent, devices, user home, environment, or
  inherited credential variables;
- non-root guest process, minimal capabilities, no nested container control plane, and a
  read-only root filesystem except declared ephemeral paths;
- cgroup/VM limits for CPU, memory, process count, file descriptors, disk bytes/inodes, output
  bytes, and wall time;
- entropy and clock available, but no host metadata service;
- no direct DNS and no direct outbound TCP/UDP;
- one vsock connection to the task-scoped host credential injector;
- encrypted or memory-backed ephemeral disks destroyed after each run; no cross-task cache is
  writable by the guest;
- structured, size-bounded stdout/stderr and evaluation artifacts returned to the host.

`--isolate` worktrees may be used inside or as input to the VM for convenient source handling,
but they are not the sandbox. They do not provide host, credential, kernel, or network
isolation.

### B.3.3 Owner-operated semantic gateway and credential injection

The model boundary is Tim's own Claude/Codex-compatible gateway. Tim may back it with his
self-hosted models or provider models reached through his ToS-valid provider API paths. Tim
issues Ocean a Federation-purpose API key designed to be shared with her: it is scoped,
rate-limited, revocable, audience-bound to Tim's gateway, and separable from any upstream
provider credential. Federation never sends Ocean an Anthropic/OpenAI subscription token and
never authenticates directly to those providers on Tim's behalf.

Ocean stores Tim's key in the host-side credential injector, not in the VM. The guest receives
a task/claim-bound, non-secret sentinel in the auth shape expected by its harness/CLI and talks
over vsock. The injector validates the claim and `gateway_ref`, replaces the sentinel with the
owner-issued key, and establishes TLS only to the endpoint in Ocean's signed local gateway
registry. Tim's gateway is the semantic enforcement point and exposes only the
Claude/Codex-compatible inference surface allowed by that key:

- key scope bound to issuer, executor, collective/task family, allowed route/model class, and
  expiry, with immediate revocation;
- task/claim-bound session and idempotency identifiers;
- fixed route/model selected before boot; the guest cannot select an upstream provider;
- Claude/Codex-compatible chat/messages/responses, streaming, and cancel methods only;
- no model administration, pull/delete/load, filesystem, arbitrary URL, plugin, raw-header,
  generic proxy, or HTTP CONNECT methods;
- server-enforced request, input-token, output-token, concurrent-request, and wall-clock
  ceilings, in addition to local runner resource limits;
- request/response body limits and signed per-run metering for audit and settlement evidence.

The raw key remaining outside the sandbox is still defense in depth, but the authority concern
is materially smaller than for a stolen subscription token: this credential was created for
delegation, has narrow server-enforced authority, and can be killed without rotating an
upstream account. Host firewall rules still deny direct DNS/TCP, so hostile code cannot bypass
the injector or choose another destination. A task can exercise only the authority Tim
deliberately placed in its key; the gateway, not a hostname-only proxy, enforces the semantic
limits.

Self-hosted model administration endpoints such as Ollama/vLLM/LM Studio remain behind Tim's
gateway and are never exposed to the guest. Provider credentials also remain inside Tim's
gateway infrastructure. The gateway solves credential delegation and ToS provenance; it does
not weaken the hostile-code runner, because the pulled repository and returned candidate are
still attacker-controlled.

### B.3.4 One runner, two directions

Executor flow:

1. `preflight` reconstructs the signed baseline in a fresh VM and runs the immutable oracle.
   It must produce the signed expected `fail` classification.
2. `execute` starts a different fresh VM with the open harness and writable overlay.
3. An executor-side `evaluate` starts another fresh VM and applies the candidate to the signed
   base. It runs the immutable oracle and records the result. A pass is useful early feedback,
   not settlement authority.

Author flow:

1. The author receives only content-addressed envelope/artifact references.
2. The author's runner starts a fresh credential-free, network-denied evaluator VM.
3. It reconstructs the signed base, applies the untrusted candidate inside the VM, and mounts
   the oracle harness read-only from the signed task.
4. It runs baseline and candidate evaluations. The baseline must fail and the candidate must
   pass. The evaluator emits a signed report containing task, candidate, runner-profile,
   oracle, base, and dependency-lock digests.
5. A separate trusted client process sends that report digest to the coordinator. It never
   executes result-controlled code.

This is the GitHub “pwn request” doctrine applied to Federation: untrusted contributor code
runs only in an unprivileged, secret-less, network-denied context, and the privileged
settlement step consumes a validated report rather than the branch.

The immutable oracle lives outside the candidate tree. Its entrypoint is selected from the
signed oracle bundle, not `package.json`, a returned script, a commit message, or candidate
configuration. If evaluating the candidate necessarily executes candidate code, that code is
still hostile and remains inside the evaluator VM. Install hooks are disabled; dependencies
come from the signed lock/bundle. The returned candidate cannot change the dependency
resolution inputs.

### B.3.5 Red-team acceptance criteria

The runner is not complete until automated adversarial fixtures demonstrate all of the
following on the actual backend:

1. Task fields requesting privileged mode, host mounts, Docker socket, host networking,
   devices, alternate images, lifecycle hooks, or an authored devcontainer are schema-rejected.
2. Guest code cannot read host environment variables, home/config files, SSH/GPG agents,
   browser stores, cloud metadata, coordinator keys, model-server files, or another run's data.
3. Direct DNS, TCP, UDP, Unix-socket, and alternate-interface egress fail. Only the vsock
   connection to the host credential injector works.
4. The injector rejects unregistered or issuer-mismatched gateway references and never reveals
   the owner-issued key to the guest. The gateway rejects revoked/expired/wrong-scope keys,
   task/claim/route/model/header overrides, administrative methods, oversized requests, excess
   calls/tokens/concurrency, expired claim capabilities, and calls after wall-time expiry.
5. Fork bombs, memory bombs, disk/inode exhaustion, log floods, decompression bombs, and
   long-running processes terminate within configured ceilings without degrading the host.
6. Archive path traversal, absolute paths, device files, hardlinks/symlinks escaping the
   workspace, malformed Git data, and oversized candidate patches cannot write outside the
   ephemeral VM.
7. A candidate that replaces the verify script, `package.json`, install hooks, compiler/test
   plugins, lockfile, Git configuration, or test paths cannot replace the mounted oracle or
   change dependency resolution.
8. A malicious candidate can execute during evaluation but cannot access credentials or
   network, persist, or influence the trusted settlement client beyond the bounded evaluation
   report schema.
9. A no-op candidate, already-green baseline, altered oracle, baseline mismatch, or nondeterministic
   baseline cannot produce a success report.
10. Destroying a run and starting another leaves no observable writable state from the first.

Release evidence includes runner/profile digests, fixture source, expected denial, observed
denial, resource-limit measurements, and a clean-host rerun. Docker-only success is not
evidence for the Firecracker profile.

## B.4 Immutable-oracle result trust

### B.4.1 v0 acceptance predicate

Automatic success settlement requires all of these:

1. Task envelope, author signature, all artifact digests, and expiry validate.
2. Claim generation and lease token match the current coordinator state.
3. Runner profile digest is collective-approved.
4. Clean evaluator runs the signed baseline and observes the task-specific expected failure.
5. A separate clean evaluator instance applies the candidate to that baseline and observes a
   pass using the same oracle digest and dependency lock.
6. Protected oracle paths and declared forbidden paths are unchanged.
7. Evaluator report schema, signature, and referenced digests validate.
8. Required redundancy policy, if any, is satisfied.

The existing `artifacts_run_verify_checkpoint` behavior may execute the oracle inside the VM
and its failure taxonomy may be included in reports. The existing baseline classifier and
`test_files_changed` remain diagnostics. They are not acceptance gates: the shipped baseline
classifier does not prove an already-green oracle was made better, and `test_files_changed`
is explicitly heuristic.

v0 excludes tasks whose baseline is expected to pass. New task families require a new explicit
before/after predicate and settlement policy; a generic “nonempty diff” check is not proof of
useful work.

### B.4.2 Optional redundant execution

For high-value or lower-trust assignments, the author sets `replicas: 2` and
`required_passes: 2`. The coordinator creates independent claims for different executors,
reserves the full maximum settlement for both, withholds peer identity and candidate contents,
and evaluates each candidate independently.

Agreement is on the deterministic predicate (`baseline=fail`, `candidate=pass`), not byte-
identical patches. Both passing executors earn the declared success fee. A failed candidate may
earn the bounded attempt fee under §B.5. Redundancy raises confidence against a malicious or
faulty executor; it does not repair a weak oracle, so v0 still restricts task shape.

## B.5 Coordinator, leases, and settlement

### B.5.1 Coordinator authority

The Tier B coordinator is trusted and authoritative for:

- collective membership, public keys, revocation, and approved runner-profile digests;
- task publication and queue order;
- atomic claim generation, lease issue/expiry, and reassignment;
- balance and escrow constraints;
- evaluation-report acceptance and settlement ordering;
- the canonical signed ledger sequence.

HTTPS long-poll is sufficient. Large artifacts live in a content-addressed object store; the
coordinator routes digest references and may issue short-lived read-only download capabilities.
Artifact delivery transport does not affect the signed identity.

### B.5.2 Claim and evaluation state machine

Each replica has one monotonic `claim_generation`:

```text
PUBLISHED
  -> QUEUED
  -> CLAIMED(generation, executor, lease_expiry, escrow_id)
       -> SUBMITTED(result_digest)
            -> EVALUATING
                 -> SETTLED_SUCCESS
                 -> SETTLED_ATTEMPT
                 -> DISPUTED
       -> EXPIRED -> QUEUED(generation + 1)
       -> ABANDONED -> QUEUED(generation + 1)
  -> CANCELLED                         (only while unclaimed)
```

Every transition is a serializable database transaction with an expected prior state. The
coordinator issues an opaque lease token and stores only its digest. Result submission binds
task digest, replica, generation, executor, lease-token digest, and result digest. Stale or
duplicate submissions cannot settle. The target is **at-most-once settlement per claim**, not
the unsupported claim that network execution is exactly once.

At claim, the coordinator atomically:

1. checks membership, executor policy, task expiry, replica availability, and author cap;
2. reserves `success_fee` for that replica from the author's available credit;
3. increments generation and records executor and lease expiry;
4. appends a signed `escrow_reserved` ledger entry in the same transaction;
5. returns the claim capability.

The reservation is the maximum liability. Success pays `success_fee`. A compensable failure
pays `attempt_fee` from the same reservation and releases the remainder. No submission,
executor abandonment, executor policy violation, or an uncurrent lease pays zero and releases
the reservation.

### B.5.3 Attempt compensation and failure rules

Attempt compensation shares the cost of a valid but unsuccessful task and prevents authors
from publishing impossible work that burns executors for free. It is not proof of useful work
and must be bounded against executor farming.

v0 permits at most one paid failed attempt per task replica. `attempt_fee` must be greater than
zero and at most 10% of `success_fee`. It is paid only when:

- task preflight in the approved runner reproduced the signed expected baseline failure;
- the result arrived under the current lease;
- the candidate artifact is nonempty, valid, within policy, and was evaluated;
- the runner, injector, and owner gateway emitted internally consistent signed run/metering
  reports;
- candidate evaluation failed the immutable oracle without sandbox/policy violation; and
- the task has remaining paid-attempt allowance.

These conditions make trivial farming visible and bounded, not impossible. Internal roster
identity and coordinator audit are part of the v0 defense. A future stranger market needs
stronger cost attestation or market pricing.

Failure settlement is deterministic:

| Outcome | Settlement |
|---|---|
| Clean author evaluation passes | Executor receives `success_fee`; unused reservation released. |
| Valid current attempt fails immutable oracle and meets compensation rules | Executor receives `attempt_fee`; remainder released. |
| Baseline does not reproduce, signed artifacts are missing, or immutable oracle is invalid | Task is `DISPUTED`; author liability remains reserved; coordinator assigns an independent clean evaluation. If author fault is confirmed, executor receives at least `attempt_fee` and task is quarantined. |
| Author evaluator does not respond before deadline | Coordinator assigns an independent evaluator. The author cannot avoid settlement by withholding a signature. |
| Executor times out without a valid result, abandons, or violates runner policy | No payment; reservation released; generation increments before requeue. |
| Coordinator cannot determine fault | `DISPUTED`; funds remain reserved for manual collective-admin resolution in v0. |

Author re-verification is normally automatic on the author's node. Its output is a signed
runner report, not an arbitrary `author_reverified: true` assertion. An independent evaluator
uses the same runner and immutable inputs for timeout/dispute fallback.

### B.5.4 Separate signed settlement ledger

Accounting uses a new canonical ledger, not `receipts.jsonl`. Each entry contains:

```json
{
  "ledger_schema": "federation.ledger-entry.v1",
  "collective": "vana-internal",
  "sequence": 184,
  "previous_entry_digest": "sha256:...",
  "event": "escrow_reserved",
  "task_digest": "sha256:...",
  "replica": 0,
  "claim_generation": 3,
  "author_key": "ed25519:...",
  "executor_key": "ed25519:...",
  "currency": "federation-credit-v0",
  "amount": 100,
  "source_event_digest": "sha256:...",
  "committed_at": "2026-07-16T18:31:00Z"
}
```

The coordinator assigns a strictly increasing sequence, links the prior entry digest, signs
the domain-separated entry digest, and commits the domain-state transition and ledger row in
one database transaction. Unique constraints cover event id, sequence, settlement key, and
`(task_digest, replica, claim_generation, terminal_event)`.

Balances and reservations are materialized views derivable from the ledger. Invariants checked
on every commit and by an offline auditor are:

- debits + credits + reservations conserve value according to event type;
- available balance is `balance - active_reservations`;
- an author's negative-balance cap is checked including reservations;
- no claim has more than one terminal settlement;
- sequence and hash chain have no gap or fork;
- every settlement references a current claim and accepted evaluator report.

Author, executor, runner, and evaluation signatures remain attached to source events. The
coordinator signature establishes canonical ordering and acknowledgment. `receipts.jsonl` may
record local observations of these digests for debugging, but cannot change balances.

## B.6 Gateway-backed harness and provider execution

Pi is the first v0 harness adapter. It runs inside the runner image and talks only through the
host injector to the owner gateway. The task names a route/model class, not an upstream model
ID; the signed task, executor policy, issued key scope, and gateway policy must all agree before
claim. The gateway may satisfy that route with a self-hosted model or a ToS-valid provider
model without changing the Federation task contract.

Waspflow's provider-adapter contract is useful execution integration, but adapter output is not
cross-principal attestation. Pi JSONL, stop reason, model-change events, Claude/Codex CLI logs,
and waspflow lane receipts are controlled by the executor. They support orchestration and
audit; settlement rests on the clean evaluator report and coordinator state machine.

The gateway's Claude/Codex API compatibility gives Federation a test path before Tim's gateway
PR merges:

1. Run a loopback compatibility fixture that implements the gateway's scoped-key,
   Anthropic-compatible, and OpenAI-compatible surfaces.
2. Point the **real Claude and Codex CLIs** at that fixture using their supported base-URL/API
   configuration while the host injector supplies disposable test keys.
3. Exercise streaming, cancellation, model/route pinning, rate-limit errors, revocation,
   expired claims, and forbidden admin/generic-proxy calls through the real runner.
4. Re-run the same contract suite against Tim's gateway when its PR lands; only the endpoint
   registry entry changes.

This tests Federation's real CLI, injector, sandbox, and protocol behavior today without
pretending that a test double validates the production gateway implementation. Pi remains the
first shipped adapter because it keeps the initial orchestration surface small; Claude/Codex
CLI compatibility is tested from build order item 1 and can become a shipped adapter after the
same runner contract passes.

The path is **ToS-clean by construction**: Federation exercises an API key the gateway owner
created for delegation to the executor, against the owner's infrastructure. Self-hosted routes
use the owner's models; provider routes use the owner's ToS-valid provider API access behind
the gateway. No consumer subscription credential is shared, proxied, or exposed to Federation.
This does not solve hostile-code isolation, oracle quality, resource abuse, result correctness,
source disclosure, or harness/model-server supply-chain risk. Those remain governed by the
runner and trust model above.

## B.7 End-to-end walkthrough

1. **Author constructs, delegates, and preflights.** Tim registers his gateway descriptor,
   issues Priya a scoped/revocable key, and selects an allowlisted non-sensitive source
   snapshot, immutable oracle bundle, fail-to-pass predicate, gateway route class, prompt,
   resource request, and fees. His local runner confirms the baseline fails. His client
   canonicalizes the task payload, computes its digest, signs it, uploads digest-checked
   artifacts, and publishes the envelope.
2. **Executor filters locally.** Priya's Linux node receives the signed task envelope, verifies
   the signature/digests/expiry/profile, resolves Tim's pre-registered `gateway_ref`, confirms
   her key's scope digest covers no more than the task requests, checks source authorization
   and local resource policy, and asks to claim replica 0.
3. **Coordinator escrows and leases atomically.** It checks Tim's cap including active
   reservations, reserves 100 credits, advances generation to 3, appends the sequenced signed
   `escrow_reserved` event, and returns a one-hour claim capability.
4. **Executor preflights in a fresh VM.** Priya's runner reconstructs the signed baseline and
   immutable oracle. If baseline does not fail as promised, it submits an invalid-task report
   without starting the model.
5. **Executor runs through Tim's gateway.** A new Firecracker VM starts Pi. Pi sees only the
   ephemeral workspace and prompt plus the vsock session capability. Priya's host injector
   adds Tim's scoped key outside the VM; Tim's gateway fixes the route/model and
   limits calls/tokens/wall time. The route may use Tim's self-hosted model or his ToS-valid
   provider API. There is no direct provider subscription, GitHub, Linear, SSH, or cloud
   credential in the VM and no general internet route.
6. **Executor checks in a clean VM.** A third VM applies the candidate to the signed base and
   runs the immutable oracle. Priya signs the result envelope over the candidate and evaluation
   digests and submits it under generation 3.
7. **Author re-verifies safely.** Tim's node downloads opaque content-addressed artifacts. A
   fresh evaluator VM inspects and applies the candidate; Tim never checks out or runs it on
   his host. The evaluator proves the same baseline fails and candidate passes, then signs a
   bounded report.
8. **Coordinator settles.** It validates the report and atomically appends settlement rows:
   Tim's reservation becomes a 100-credit debit and Priya receives 100 credits. The claim
   becomes `SETTLED_SUCCESS`. Replays or a late result from generation 2 cannot settle.
9. **Failed valid attempt.** If the candidate instead fails but meets the bounded compensation
   rules, Priya receives 10 credits, 90 are released to Tim, and the paid-attempt allowance is
   exhausted. Tim cannot burn repeated executor runs for free, and Priya cannot collect an
   unbounded stream of no-op attempt fees.

---

# Corrected reuse ledger

Federation uses shipped waspflow code as execution plumbing. None of these local primitives is
promoted into a security, network-consensus, or cross-principal-accounting guarantee it does not
provide.

| Federation need | What is actually reusable | What is explicitly new / not covered |
|---|---|---|
| Agent orchestration | Lane lifecycle, tmux control, wait/revise/reap flow, prompt delivery | Cross-principal authorization and hostile-code containment |
| Local source concurrency | `--isolate` sibling worktrees and reset/removal helpers | Worktrees do **not** isolate credentials, network, host files, kernel, Docker socket, or principals; the runner is new |
| Oracle execution vocabulary | `artifacts_run_verify_checkpoint`, timeout/failure taxonomy, prepare/verify reporting | Immutable oracle packaging, fail-to-pass baseline evaluation, clean evaluator, and settlement acceptance are new; the existing baseline classifier does not prove green useful work |
| Anti-gaming diagnostics | `test_files_changed`, failure classes, reports | `test_files_changed` and `fanin_captured` are heuristics, not trust or settlement gates; `fanin_captured` can report captured for an empty token set |
| Candidate handling helpers | Fan-in/bundle concepts and Git worktree integration may inform formats | Existing thin bundles assume repository context and are not hardened untrusted ingress; content-addressed candidate format, parser isolation, limits, and tree digest are new |
| Local telemetry | Receipt v1 and `receipts.jsonl` remain useful for lane audit/debugging | Receipts are not a signed, sequenced, canonical cross-principal ledger; escrow, balances, caps, hash chain, and atomic settlement are new |
| Local race prevention | Per-lane locks and `arm_generation`/`session_id` CAS demonstrate useful stale-writer handling | Network claim generation, lease capabilities, coordinator transactions, and at-most-once settlement are new |
| Provider integration | Mandatory provider-adapter interface and generic dispatch | Pi integration, Claude/Codex-compatible gateway profiles, closed dispatch/event sites, host credential injector, gateway registry/client, and runner integration are new; adapter/CLI logs do not attest cross-principal work |
| Cross-provider escalation | Structured handoff concepts may inform later reassignment UX | Escalation is not network reassignment, lease fencing, or settlement machinery |
| Billing/auth-path observation | BillingPath can distinguish some direct local provider auth paths | Existing BillingPath does not represent an owner-issued gateway key or verify its scope/revocation. Federation needs a new `owner_gateway` auth-path record keyed by gateway/issuer/key-scope digests; the current billing guard neither supplies nor enforces this contract |
| Selection/preflight | Availability/quota-policy patterns can inform executor-local filtering | Task authorization, collective capabilities, source authorization, runner-policy checks, and escrow eligibility are new |

Genuinely new load-bearing components are: hostile-task runner and profile; owner-gateway
registry, credential injector, scoped-key integration, and compatibility fixture;
artifact/envelope canonicalization and signing; immutable-oracle packager/evaluator;
coordinator queue/lease state machine; cross-principal keys and roster; signed sequenced
settlement ledger; claim-time escrow/attempt compensation; Pi-in-runner integration; and the
adversarial conformance suite.

---

# Corrected build order and release gates

Work proceeds in this order. Later steps may use mocks, but no step may weaken an earlier gate.

1. **Hostile-task runner and owner-gateway integration skeleton.** Build the immutable
   Linux/Firecracker profile, artifact ingestion boundary, no-network rules, host credential
   injector, signed gateway registry, Claude/Codex-compatible method allowlist, and resource
   ceilings. Use a loopback compatibility fixture and disposable scoped keys first; run the
   real Claude/Codex CLIs against it. **Gate:** all §B.3.5 adversarial fixtures and the §B.6
   compatibility suite pass on clean hosts and repeated runs, including revocation and
   server-enforced rate/token/wall limits.
2. **Immutable oracle packager and evaluator mode.** Produce signed base/oracle bundles,
   reconstruct baseline/candidate in fresh VMs, and implement deterministic fail-to-pass
   reports. **Gate:** returned-branch pwn-request fixtures cannot reach credentials/network or
   replace oracle/dependencies; no-op/already-green results cannot pass.
3. **Canonical task/result envelopes and artifact store.** Implement JCS canonicalization,
   domain-separated Ed25519 signatures, digest/size verification, schema/version limits, and
   hostile parser fixtures. **Gate:** stable golden vectors across implementations; every
   mutation/replay/malformed artifact is rejected deterministically.
4. **Settlement ledger and pure state-machine model.** Implement transitions, claim-time
   reservation, caps including reservations, success/attempt/failure rules, sequence/hash
   chain, and invariant auditor before networking. **Gate:** model/property tests cover stale
   generations, duplicate messages, crashes between writes, cap races, replay, timeout,
   impossible tasks, and author withholding.
5. **Trusted coordinator.** Expose publish/pull/claim/submit/evaluate/settle APIs around the
   already-tested state machine; add roster/revocation and content-addressed artifact delivery.
   **Gate:** multi-client integration tests prove at-most-once settlement and recovery after
   coordinator restart at every transition.
6. **Gateway-backed provider integrations inside the runner.** Bind Pi only to the host
   injector and owner gateway, then map waspflow lane lifecycle to runner execution. Re-run the
   real Claude/Codex CLI contract against Tim's production gateway when available. **Gate:**
   end-to-end tasks succeed through both a self-hosted route and a ToS-valid provider route,
   with direct egress disabled, upstream/admin APIs unreachable, revocation effective, and all
   resource usage bounded.
7. **End-to-end internal pilot.** Use non-sensitive allowlisted repositories, small balances,
   one paid attempt, manual admin dispute resolution, and audit every ledger event. **Gate:**
   complete the walkthrough in §B.7 plus forced executor death, stale result, invalid task,
   malicious result, author timeout, and redundant-execution drills.
8. **Only then evaluate broader scope.** macOS VM backend, additional open harnesses, private
   repositories, additional gateway issuers/routes, public membership, and peer-to-peer
   transport each require a new threat-model delta and acceptance gate. None is implied by v0
   success.

---

# OPEN decisions

### OPEN 1 — macOS executor support

**Recommended answer:** Linux/KVM executors only for v0. Build a distinct Apple Virtualization
Framework VM backend later and require it to pass the same runner contract; do not relabel
hardened Docker or a worktree as equivalent isolation. macOS may author, inspect reports, and
coordinate in v0 without executing hostile code.

### OPEN 2 — attempt-fee calibration

**Recommended answer:** start at 10% of success fee, one paid failed attempt per replica, with
small pilot caps and weekly audit. The exact number is economic policy, not a security proof.
Raise it only with evidence that valid failed attempts are undercompensated; lower or suspend
nodes showing no-op farming patterns.

### OPEN 3 — redundant execution default

**Recommended answer:** one executor for the internal v0 default; require two independent
passes for high-value changes and for any later stranger tier. The author funds both replicas
at claim time. Do not use byte equality as the agreement rule.

### OPEN 4 — additional verifiable task families

**Recommended answer:** ship only deterministic fail-to-pass tasks. Add migrations, performance
work, refactors, and subjective review one family at a time, each with an explicit before/after
predicate, noise budget, and settlement rule. A declared `verify_strength` label is never
enough.

### OPEN 5 — gateway registry and scoped-key identity contract

**Recommended answer:** for v0, require the task author to be the gateway issuer. Bind each
gateway descriptor to the author's Federation signing key; bind each API key to executor,
collective/task family, route/model class, ceilings, and expiry; store only key IDs/scope
digests in Federation; and require an online revocation check at claim and first model request.
Do not let tasks provide raw URLs or broaden a locally registered endpoint/key scope. A future
third-party gateway marketplace requires a separate issuer/payment/trust design.

### OPEN 6 — source confidentiality and private repositories

**Recommended answer:** v0 accepts only public or explicitly non-sensitive repositories.
Federation reveals source to the executor by design. Encryption in transit and a sandbox do
not hide it from the executor's machine owner. Private-repository support requires an explicit
membership/data-handling policy, not merely a scoped Git token.

### OPEN 7 — mesh and decentralized settlement

**Recommended answer:** keep the central coordinator as a permanent supported authority model.
Experiment with peer-to-peer artifact delivery only after v0; treat decentralized claims,
revocation, and settlement as a separate design. Reuse the signed envelopes and runner, not the
claim that the systems are the same.

---

# Buildability verdict

This v0 is buildable as specified because it narrows the product to boundaries that can be
implemented and tested: owner-issued gateway keys only, a fixed Linux microVM runner,
deterministic fail-to-pass tasks, content-addressed signed inputs/results, a trusted
coordinator, and an explicit transactional settlement model. The owner gateway preserves full
model capability—self-hosted and ToS-valid provider routes—without sharing consumer
subscription credentials.

The highest-risk item remains the hostile-task runner. If its actual red-team suite does not
prove both task-to-executor and result-to-author isolation, Federation does not proceed to a
pilot. The coordinator and adapter are downstream conveniences; the runner is the product's
permission to exist.
