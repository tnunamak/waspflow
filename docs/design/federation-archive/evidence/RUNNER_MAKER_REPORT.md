# Federation v0 runner maker report

## Revision

Base: `718ab9e`. Code implementation revisions: `3be98dab3c62350eb1d6703508e1ae8cd952fbec` and `f0f63531b08e1c4c368339924b68c54a223d8cfb`.

## Design

- Added a Firecracker-only runner with the narrow operations `inspect-artifact`,
  `preflight`, `launch-plan`, `execute`, and CLI compatibility plans.
- The executor-owned profile path is compiled into the runner. It defines the
  Linux/KVM profile, read-only guest constraints, Pi as the only v0 execution
  harness, resource ceilings, Internet-allowed/host-and-LAN-denied policy, and
  reserved envelope `oracle_ref`, `result_verdict`, and `settlement` fields.
- Artifact ingress is local CAS only: SHA-256 verification, canonical task JSON,
  schema rejection, and archive size/entry/path/link/device checks occur before
  any backend is considered. ZIP is rejected outright because v0 has no need to
  support its producer-specific link metadata safely.
- `launch-plan` implements critique M3: one claim, one task, one gateway ref,
  one route, and one owner key are bound outside the guest at VM launch. The
  guest-facing plan exposes only a non-secret sentinel and no selectors.
- The injector is a per-VM Unix-socket service intended for a fixed vsock bridge.
  It requires a private host key and pinned HTTPS gateway registry, allows only
  inference paths, pins the route/model, rejects override headers, and enforces
  request/body/concurrency/expiry limits.
- There is no Docker or namespace fallback. `execute` requires Firecracker, KVM,
  pinned kernel/rootfs/guest-init/firewall-helper digests, then still refuses to
  claim backend integration until the real guest image/helper contract exists.

## Changed files

- `bin/waspflow-federation-runner`
- `bin/waspflow-federation-injector`
- `profiles/wf-federation-linux-v0.json`
- `tests/federation-runner.sh`
- `scripts/verify.sh`
- `docs/design/FEDERATION_RUNNER_V0.md`
- `docs/design/federation-evidence/RUNNER_MAKER_REPORT.md`

## Commands and raw results

```text
$ bash -n bin/waspflow-federation-runner tests/federation-runner.sh scripts/verify.sh
$ node --check bin/waspflow-federation-injector
$ bash tests/federation-runner.sh
federation runner conformance: ok

$ bash scripts/verify.sh
federation runner conformance: ok
(exit 0)

$ command -v firecracker || true
(no output)
$ command -v jailer || true
(no output)
$ ls -l /dev/kvm
crw-rw----+ 1 root kvm 10, 232 Jul 13 16:12 /dev/kvm
$ getfacl -p /dev/kvm
# file: /dev/kvm
# owner: root
# group: kvm
user::rw-
user:tnunamak:rw-
group::rw-
mask::rw-
other::---
$ id -nG
tnunamak adm cdrom sudo dip video plugdev input render lpadmin lxd sambashare i2c docker
```

The deterministic conformance suite covers hostile task fields, canonical/CAS
identity, archive traversal, M3 cross-gateway rejection, non-exposure and file
mode of the owner key, injector registry pinning, and refusal to substitute a
container/namespace backend. It is now part of the repository suite.

## Untested boundaries

- No **committed** guest image, vsock bridge, TAP/firewall helper, cgroup
  enforcement, or runner-owned Firecracker API lifecycle exists in this checkout.
  The Docker helper did boot an ephemeral initramfs guest using a config file.
- Pi has a contract/profile declaration but was not run in a guest.
- Claude/Codex have supported configuration plans only; real CLI streaming,
  cancellation, revocation, and rate-limit compatibility were not run.
- The envelope signature/issuer verification belongs to the signed-envelope
  component; this runner validates content addressing and schema, not a signer.
- Internet-allowed while host/LAN/DNS/metadata are denied is specified as a
  privileged firewall-helper contract, not proven here.

## Exact Firecracker evidence or blocker

### Real backend evidence (Docker used only as a privileged host test helper)

```text
$ docker run --rm --privileged --device=/dev/kvm alpine:3.21 ...
docker_privileged_kvm_and_net_admin=ok

$ docker run --rm --privileged --device=/dev/kvm ... firecracker --no-seccomp --config-file /run/fc.json
Running Firecracker v1.15.1
Successfully started microvm that was configured from one single json
[    0.000000] Linux version 6.1.155+ (root@c3d8009cd6d2) ...
Hypervisor detected: KVM
Run /init as init process
WF_GUEST_BOOTED
Linux (none) 6.1.155+ #1 SMP PREEMPT_DYNAMIC Thu Dec 18 15:17:16 UTC 2025 x86_64 Linux
WF_HOST_BLOCKED
WF_METADATA_BLOCKED
WF_INTERNET_FAILED
WF_GUEST_DONE
reboot: System halted
```

This proves a released Firecracker process used `/dev/kvm` and booted a distinct
guest kernel; it is not Docker-only containment evidence. The test used the
official Firecracker v1.15.1 release binary and the official Firecracker CI
`vmlinux-6.1.155`, downloaded to disk-backed
`~/.tmp/waspflow-federation-assets`. The durable transcript is
[`FIRECRACKER_REAL_BOOT_2026-07-18.log`](FIRECRACKER_REAL_BOOT_2026-07-18.log).

### Security BLOCKED

The host capability blocker is narrower than previously reported: the current user
is **not** in the `kvm` group; KVM access is granted by the POSIX ACL
`user:tnunamak:rw-`. `sudo -n` fails with `interactive authentication is required`.

The v0 release gate remains blocked because the real guest test has not achieved
the required Internet-allowed result (`WF_INTERNET_FAILED`), and this worktree
still lacks a committed, pinned rootfs/guest agent, TAP firewall lifecycle,
copy-on-write workspace, resource-cgroup owner, and vsock injector bridge.
Therefore `execute` remains fail-closed, and Pi/real Claude/real Codex were not
run. Calling this runner complete would be a false security claim.

## Confidence

**High** for the tested host-side schema/CAS/M3/injector configuration and
fail-closed behavior; **high** that an actual Firecracker/KVM guest boot occurred;
**low** for the incomplete network, VM lifecycle, resource, ephemerality, and
gateway/CLI gates. The overall runner status is **SECURITY BLOCKED**.
