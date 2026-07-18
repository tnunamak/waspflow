# Federation v0 runner maker report

## Revision

Base: `718ab9e`. Code implementation revision: `3be98dab3c62350eb1d6703508e1ae8cd952fbec`.

## Design

- Added a Firecracker-only runner with the narrow operations `inspect-artifact`,
  `preflight`, `launch-plan`, `execute`, and CLI compatibility plans.
- The executor-owned profile path is compiled into the runner. It defines the
  Linux/KVM profile, read-only guest constraints, Pi as the only v0 execution
  harness, resource ceilings, Internet-allowed/host-and-LAN-denied policy, and
  reserved envelope `oracle_ref`, `result_verdict`, and `settlement` fields.
- Artifact ingress is local CAS only: SHA-256 verification, canonical task JSON,
  schema rejection, and archive size/entry/path/link/device checks occur before
  any backend is considered.
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
$ id -nG
tnunamak adm cdrom sudo dip video plugdev input render lpadmin lxd sambashare i2c docker
```

The deterministic conformance suite covers hostile task fields, canonical/CAS
identity, archive traversal, M3 cross-gateway rejection, non-exposure and file
mode of the owner key, injector registry pinning, and refusal to substitute a
container/namespace backend. It is now part of the repository suite.

## Untested boundaries

- No guest image, vsock bridge, TAP/firewall helper, cgroup enforcement, or
  Firecracker API launch ran in this checkout.
- Pi has a contract/profile declaration but was not run in a guest.
- Claude/Codex have supported configuration plans only; real CLI streaming,
  cancellation, revocation, and rate-limit compatibility were not run.
- The envelope signature/issuer verification belongs to the signed-envelope
  component; this runner validates content addressing and schema, not a signer.
- Internet-allowed while host/LAN/DNS/metadata are denied is specified as a
  privileged firewall-helper contract, not proven here.

## Exact Firecracker evidence or blocker

**Blocker:** `firecracker` and `jailer` are absent; no runner-owned pinned kernel,
rootfs, guest init, or host firewall helper exists in this worktree. The checked-in
profile deliberately marks each asset digest `UNPINNED_IN_THIS_CHECKOUT`, which
causes `execute` to fail closed even if paths are supplied. `/dev/kvm` exists and
the current user is in `kvm`, but that is insufficient evidence of a Firecracker
backend. No real Firecracker security claim is made.

## Confidence

**High** for the tested host-side schema/CAS/M3/injector configuration and
fail-closed behavior. **Low** for actual Firecracker isolation and gateway/CLI
compatibility until the blocked assets and real-host acceptance suite exist.
