# Federation Sandbox Install Preflight

## Delivered

`waspflow federation doctor` runs the Docker Sandboxes install preflight. It is read-only by default and exits non-zero when any required check fails.

On Ubuntu, it verifies these checks in the same Waspflow-owned sbx profile that the Docker backend will use for the contribution:

1. `sbx_install` — `sbx version` works and `docker-sbx` is installed as an apt package, not merely copied onto `PATH`.
2. `docker_runtime` — `docker-ce` and `containerd.io` are installed and containerd reports major version 2. It recognizes the observed `io.containerd.transfer.v1: no plugins registered` failure.
3. `sbx_daemon` — `sbx diagnose` reports `Daemon healthy`.
4. `network_policy` — `sbx policy ls` succeeds and does not report that the global policy is uninitialized.
5. `kvm_access` — the effective user can read and write `/dev/kvm`; the known `KVM error: Permission denied (os error 13)` diagnostic is surfaced directly.
6. `docker_login` — `sbx diagnose` does not report that the user is unauthenticated to Docker.

Each failure has a copy-paste fix. Package/runtime failures prescribe Docker's apt-repository installation path; daemon failures prescribe a restart; KVM failures prescribe the `kvm` group command and note nested virtualization; login failures prescribe `sbx login`.

`waspflow federation doctor --fix-policy` is the sole opt-in mutation. It explicitly runs `sbx policy init balanced`, then re-probes. No privileged or destructive action is automatic.

## JSON contract

`waspflow federation doctor --json` emits exactly one event:

```json
{
  "schema_version": 1,
  "type": "sandbox_preflight",
  "status": "ready | setup_required",
  "backend_id": "docker-sbx",
  "checks": [
    { "name": "network_policy", "ok": false, "detail": "global network policy has not been initialized.", "fix": "sbx policy init balanced ..." }
  ]
}
```

Every check always contains `name`, `ok`, `detail`, and `fix` (an empty string on PASS). The type is registered in `lib/federation-events.mjs`, so daemon consumers validate it instead of parsing terminal text.

## Contribution and daemon behavior

`waspflow federation contribute` runs the shared preflight immediately after checking local Federation configuration and before roster refresh, task discovery/claim, or harness authentication. A failed preflight emits the event above with `status: "setup_required"` and exits 1; it never reaches `sbx run`.

The local daemon recognizes that event and changes `/status` to:

```json
{
  "state": "setup_required",
  "detail": "Your sandbox is not ready yet. Fix the failed checks before contributing again.",
  "action": { "kind": "sandbox_preflight", "checks": [] }
}
```

`action.checks` contains only failed checks and their fixes, allowing the web UI to render setup instructions rather than an opaque 500 or stack trace.

The bundled web UI maps `setup_required` to a dedicated “Your sandbox isn't ready yet” screen and lists each failed check with its copy-paste fix.

## Verification

- `tests/federation-sbx-preflight.test.mjs` unit-tests every check from stubbed command output, including the exact `transfer.v1`, policy, KVM, and Docker-login diagnostics plus doctor JSON failure output.
- `tests/federation-daemon.test.mjs` proves the daemon preserves failed checks in `setup_required` state.
- Existing CLI/event tests use a full ready stub and prove successful contribution paths retain their one-final-event JSON contract.
- Focused suite run: `node --test tests/federation-sbx-preflight.test.mjs tests/federation-daemon.test.mjs tests/federation-docker-backend.test.mjs tests/federation-events-contract.test.mjs tests/waspflow-federation-cli.test.mjs` — 50 pass, 0 fail.

Docker's current documentation confirms the `sbx diagnose`, `sbx policy init balanced`, `sbx login`, KVM, and Ubuntu installation paths used here: [get started](https://docs.docker.com/ai/sandboxes/get-started/), [local policy](https://docs.docker.com/ai/sandboxes/governance/local/), and [troubleshooting](https://docs.docker.com/ai/sandboxes/troubleshooting/).
