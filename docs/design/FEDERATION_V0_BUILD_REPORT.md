# Federation v0 build report

**Date:** 2026-07-18
**Candidate branch:** `waspflow/federation-v0-orchestrator`
**Candidate before this report:** `1972d38`
**Verdict:** **BLOCKED / REJECT — not release-ready and not merge-ready as Federation v0**

## Protected invariant and stop decision

The acceptance invariant was:

> A pulled task, however hostile, cannot touch the executor host filesystem,
> processes, or LAN; cannot read or exfiltrate the real gateway key; and cannot
> escape the microVM, while retaining Internet access and a working agent harness.

That invariant is **not established**. The checked-in runner deliberately refuses
to execute because its Firecracker lifecycle is not wired. A one-off external
Firecracker probe booted a real KVM guest, but Internet access failed and most
required adversarial fixtures were not implemented or run on that backend. The
correct release decision is therefore BLOCKED. No PR was opened.

## What was built

### Signed envelope and manual handoff

- Dependency-free Node implementation of RFC 8785-style canonical JSON,
  SHA-256 content identity, domain-separated Ed25519 signing, strict parsing,
  and task/result schemas.
- Offline task-file-in/result-bundle-out CLI with signed artifact digest and
  byte-length checks.
- Required v0-null reserved slots: `oracle_ref`, `result_verdict`, and
  `settlement`.
- `base_revision` is signed display metadata only; source artifact SHA-256 is
  the content identity.
- Unit coverage for golden digests, mutations, duplicate/noncanonical JSON,
  malformed UTF-8, invalid timestamps, forbidden task policy fields, symlink
  input, and result bundle bytes.

### Fail-closed runner boundary skeleton

- Executor-owned profile path and declared Firecracker, guest, network, and
  resource policy.
- Local content-addressed artifact checks and rejection of unknown task fields.
- TAR size/entry/traversal/link/device checks; ZIP is rejected entirely.
- One-claim/one-key/one-gateway launch-plan checks addressing critique M3.
- Host-side HTTP credential-injector skeleton that pins a registered HTTPS
  endpoint and route/model, permits inference methods only, and enforces basic
  request/body/concurrency/expiry limits.
- Deterministic conformance tests for those host-side checks and explicit refusal
  to fall back to Docker or namespaces as the containment boundary.

This is scaffolding, not an executable hostile-task runner. In particular,
`bin/waspflow-federation-runner execute` always ends with:

```text
Firecracker host integration is not wired: guest image must expose the pinned
vsock agent and firewall helper must create the per-VM TAP policy
```

The checked-in profile also contains `UNPINNED_IN_THIS_CHECKOUT` for the kernel,
rootfs, guest-init, and firewall-helper digests.

## Verification evidence

### Deterministic checks

The following were reproduced after integration:

```text
bash tests/federation-runner.sh
federation runner conformance: ok

node --test tests/federation-envelope.test.mjs
# tests 8; pass 8; fail 0

node --check bin/waspflow-federation-injector
# exit 0
```

`bash scripts/verify.sh` passed in both isolated maker worktrees through the
waspflow verification contract. An initial baseline run failed in an unrelated
escalation fixture while several live tmux workers were active; the same full
suite later passed in a quiet runner worktree. This report does not use the
repository suite as containment proof.

### Real Firecracker evidence: partial and maker-produced

A Terra maker used a privileged Alpine Docker container only as an ephemeral
host setup helper, passed through `/dev/kvm`, and ran the official Firecracker
v1.15.1 binary with an official Firecracker CI kernel. The serial transcript
records:

```text
Running Firecracker v1.15.1
Successfully started microvm that was configured from one single json
Linux version 6.1.155+
Hypervisor detected: KVM
WF_GUEST_BOOTED
WF_HOST_BLOCKED
WF_METADATA_BLOCKED
WF_INTERNET_FAILED
WF_GUEST_DONE
```

This establishes that a distinct Firecracker/KVM guest booted. It does **not**
establish the v0 network contract because Internet reachability failed. It also
does not exercise the checked-in runner, which remains unwired. The selected
transcript is in
`docs/design/federation-evidence/FIRECRACKER_REAL_BOOT_2026-07-18.log`.

The independent Sol judge began a fresh Firecracker probe but was interrupted
when the Codex budget projection exceeded the owner ceiling. Its helper container
was stopped and no independent Firecracker result was produced. Consequently the
real-backend evidence fails the maker-not-judge requirement for a passing claim.

### Independent protocol seam reproduction

Before interruption, the separate GPT-5.6 Sol judge reproduced two critical
integration failures against the integrated revision:

```text
TASK_VERIFY_WITH_A=task:sha256:22c6f502a0ad105c860e501ed5920a7215e9e461763a761251cb3c1767e460c4
TASK_VERIFY_WITH_B_RC=2 STDERR=federation-envelope: invalid signature
SIGNED_IDENTITIES={"author_key":"THIS-IS-NOT-DERIVED-FROM-PUBLIC-KEY-A","key_id":"unrelated-key-id"}
RESULT_IDENTITY={"executor_key":"ALSO-NOT-DERIVED-FROM-PUBLIC-KEY-A","key_id":"another-unrelated-id"}
SIGNED_TASK_TO_PREFLIGHT_RC=1
STDERR=federation-runner: task envelope violates the v0 runner schema
```

Findings:

1. The handoff emits `{payload, signature}` with schema
   `waspflow.federation.task.v0`; runner `validate_task` expects a different,
   unsigned top-level `schema_version/profile/source_digest/...` object. A valid
   signed task cannot enter runner preflight unchanged. There is no end-to-end
   v0 journey.
2. The signature correctly rejects a different public key, but payload
   `author_key`/`executor_key` and signature `key_id` are unchecked arbitrary
   strings rather than identities derived from or matched to the verifying key.
   Signature validity therefore does not establish the claimed principal
   identity without an unstated out-of-band convention.

## Adversarial acceptance matrix

| Required fixture | Expected | Observed | Gate |
| --- | --- | --- | --- |
| Task-supplied devcontainer/Docker/mount/privileged/network rules | Rejected | Host schema tests reject representative `privileged` and envelope policy fields; no signed-envelope-to-runner path exists | **Partial** |
| Host env, home, SSH/GPG, browser/cloud/coordinator/model files, other runs | All unreadable in real guest | One-off guest reported host IP and metadata denial only; other surfaces and cross-run state untested | **Fail** |
| Host and LAN unreachable; Internet reachable | Deny host/LAN, allow Internet | Host probe denied; metadata denied; LAN matrix absent; `WF_INTERNET_FAILED` | **Fail** |
| Real gateway key absent; revoked/expired/wrong-scope refused | Proved through vsock and gateway | Key-file/sentinel/expiry configuration tests only; injector is Unix-socket-only and not bridged to the guest; revocation/scope/real gateway untested | **Fail** |
| Fork, memory, disk/inode, log, and wall-time bombs bounded | Guest terminated within measured ceilings; host healthy | Limits are declarative; no cgroup/VM enforcement or bomb measurements | **Fail** |
| Archive traversal/symlink escape | Cannot write outside ephemeral VM | Host parser rejects traversal and link/device TAR entries; no real-VM extraction or write-boundary proof | **Partial** |
| Destroy/recreate erases writable state | No state observable across runs | No runner-owned ephemeral disk or two-run fixture | **Fail** |
| Pi plus real Claude/Codex CLIs through gateway | Working inference/stream/cancel/revocation | Compatibility plans only; no harness ran in the guest | **Fail** |
| Clean-host rerun with pinned runner/profile/assets | Same denials and measurements | Assets are external/unpinned; no clean-host rerun | **Fail** |

## Envelope forward-compatibility assessment

The envelope does reserve the required nullable oracle, verdict, and settlement
slots, and the result schema has no callback or synchronous dependency on an
author evaluator. At the schema level, deferred author re-verification and
settlement can be additional consumers of immutable references.

That forward-compatibility claim is only partial today because the runner does
not consume the signed envelope at all. Until the two schemas are unified and
principal key identities are bound, the full task-to-runner format is not a
stable permanent seam.

## Deviations from the brief

1. **Security gate not achieved.** No complete Firecracker runner, vsock
   injector, Internet-allowed/host-LAN-denied profile, resource enforcement,
   ephemeral disk lifecycle, or real harness journey was delivered.
2. **Real-backend judge reproduction incomplete.** The maker boot is real
   Firecracker evidence but not independent acceptance evidence.
3. **No merge-ready PR.** Opening or presenting this as Federation v0 would
   launder a blocked state into progress. The partial components remain on the
   feature branch for diagnosis/reuse only.
4. **Budget projection exceeded.** Clawmeter started at Codex 4% used and an
   estimated 60% at reset. It reached 87% after the maker fleet and 99% during
   the independent Sol judge, exceeding the requested under-90% projection.
   The judge was interrupted immediately; no model downgrade was accepted and
   no further worker calls were made. This pacing failure is explicit rather
   than hidden.
5. **Docker helper use.** Docker was used as a privileged ephemeral host setup
   wrapper for the one-off Firecracker probes, never as the hostile-code
   boundary. That probe does not substitute for the missing checked-in runner
   or clean-host Firecracker profile.

Four explicit ephemeral helper containers left by the probes were stopped. Ten
untracked DevSpecs task-pack files created during orchestration were removed;
they were generated diagnostics, not product artifacts.

## What remains for a future continuation

These are v0 blockers, not v1 scope:

1. Make the signed envelope the runner's sole input schema; bind claimed
   principal IDs/key IDs to canonical public-key fingerprints.
2. Commit a reproducible, digest-pinned Firecracker binary/kernel/rootfs/guest
   init supply path and make `execute` own the API process lifecycle.
3. Implement a real guest-vsock-to-host injector transport with one key and one
   registered gateway bound out of band per launch.
4. Implement TAP/firewall creation and cleanup that blocks host, LAN, metadata,
   alternate interfaces, and direct bypass while preserving Internet access.
5. Implement and measure VM/cgroup CPU, memory, PID, FD, disk/inode, output, and
   wall ceilings plus copy-on-write disposable disks.
6. Put all §B.3.5 fixtures behind one real-Firecracker command, including
   destroy/recreate and clean-host rerun.
7. Run Pi and the real Claude/Codex CLIs through a loopback gateway fixture,
   including streaming, cancellation, expiry, revocation, scope, method, model,
   header, request/token/concurrency, and wall-limit failures.
8. Have a fresh GPT-5.6 Sol judge reproduce the complete real-backend suite from
   the exact candidate revision and issue `PASS`, `REVISE`, or `REJECT`.

Still deferred to v1 exactly as directed: escrow/credit/settlement logic,
author-side adversarial re-verification, redundant execution, stranger tier,
mesh/decentralized authority, macOS executors, and private repositories. Only
their envelope slots exist; no deferred logic was added.

## Confidence and release decision

**High confidence that the acceptance gate is not met.** That judgment rests on
the unconditional unwired `execute` path, unpinned profile assets, failed
Internet probe, incompatible signed-task/runner schemas, and absence of most
required fixtures. There is **no positive confidence claim** for the bettable
containment invariant.

**Release decision: BLOCKED / REJECT.** The smallest truthful next milestone is
a single checked-in command that boots the wired Firecracker runner and produces
an expected-vs-observed report for Internet success plus host/LAN denial, with
resource and destroy/recreate fixtures. Until the full matrix and independent
rerun pass, this branch must not be described as Federation v0 or merge-ready.
