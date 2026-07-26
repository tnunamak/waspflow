# Federation v0 Firecracker runner

`bin/waspflow-federation-runner` is a separate, Firecracker-only security
boundary. It does not use waspflow lanes, worktrees, Docker, or Linux namespaces
as containment. Worktrees remain useful source plumbing only.

## Immutable executor profile

The checked-in profile is [`profiles/wf-federation-linux-v0.json`](../../profiles/wf-federation-linux-v0.json).
The task envelope carries its SHA-256 profile digest, and the runner compares it to the local,
executor-owned profile before accepting a task. The profile path is compiled into
the runner and cannot be overridden by the task or environment. Task envelopes have only the
v0 fields needed for execution plus reserved `oracle_ref`, `result_verdict`, and
`settlement` slots. No v0 execution path reads the latter three fields, so later
verification/settlement are field fills rather than a runner-format rewrite.

The envelope is content-addressed: the runner argument `<task-digest>` is the
SHA-256 of the canonical envelope bytes in the local CAS. Source and prompt are
separate SHA-256-addressed blobs in
`WASPFLOW_FEDERATION_CAS/<digest>`. `inspect-artifact` verifies the digest and
size, entry-count, traversal, link, and device-file constraints before extraction
can happen in a microVM.

## Host launch contract

The deployment host supplies only executor-owned inputs:

```text
WASPFLOW_FEDERATION_CAS=/srv/waspflow/cas
WASPFLOW_FEDERATION_RUNTIME_DIR=/run/waspflow-federation
WASPFLOW_FEDERATION_KERNEL=/srv/waspflow/images/vmlinux
WASPFLOW_FEDERATION_ROOTFS=/srv/waspflow/images/wf-federation-linux-v0.ext4
WASPFLOW_FEDERATION_GUEST_INIT=/usr/local/libexec/waspflow-federation-guest-init
WASPFLOW_FEDERATION_FIREWALL_HELPER=/usr/local/libexec/waspflow-federation-firewall
```

The firewall helper is a privileged, separately deployed host component. For each
VM it must establish the TAP policy that permits Internet egress while denying
host addresses, all LAN/private/link-local ranges, metadata endpoints, direct DNS,
and non-vsock gateway access. It must remove that policy on VM exit. Its interface
is deliberately not task-configurable. This repository does not ship that host
privilege boundary or a rootfs; it therefore cannot claim a real sandbox run.

`execute` requires a readable/writable `/dev/kvm`, `firecracker`, all pinned
assets above, and the helper. The profile also pins SHA-256 values for the kernel,
rootfs, guest-init, and firewall helper; this checkout intentionally marks those
values unpinned until the actual executor-owned assets are supplied. If any is
missing or unpinned it exits nonzero and states
`refusing namespace/container fallback`.

## Credential injector and harnesses

`launch-plan` binds a single claim, task, gateway reference, route, and host key
file before boot. Its guest-facing plan has only a non-secret sentinel; the guest
cannot name a claim, gateway, route, key, or upstream. This is the M3
one-key-per-VM-launch boundary.

`bin/waspflow-federation-injector` validates a private host key file and a pinned
HTTPS gateway registry. Its Unix socket is intended to be bridged to the fixed
vsock port by the host deployment. It accepts only Claude/OpenAI inference paths,
the launch-bound sentinel, and the pinned model; it rejects selector/header/model
overrides and enforces request, body, concurrency, and claim-expiry ceilings.

Pi is the only execution harness in v0. `compatibility-plan claude|codex` exposes
the exact environment contract that a real CLI host test must use. It is a test
surface, not a claim that those CLIs are shipped as v0 task harnesses.

## Real-host acceptance automation

On a disposable Linux/KVM host with the supplied image and firewall helper:

```bash
bash tests/federation-runner.sh
bin/waspflow-federation-runner profile
bin/waspflow-federation-runner execute <task-digest> <claim.json>
```

Before accepting a backend, add the guest-image integration fixture that boots the
pinned init, bridges the injector's Unix socket over vsock, and runs the same
adversarial cases through Firecracker: host/LAN/metadata/DNS denial with Internet
allowed, cross-claim selection, revoked/expired key, resource exhaustion, archive
escape, and real Claude/Codex streaming/cancellation/revocation calls against the
loopback gateway. The repository tests only deterministic host-boundary behavior
until that asset set exists; they must not be interpreted as Firecracker evidence.
