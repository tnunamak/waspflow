# Federation v0 Docker Sandboxes conformance matrix

**Date:** 2026-07-20
**Source:** `inbox/2026-07-20-chatgpt-sandbox.md`, §"Mandatory Docker Sandboxes graduation
gates" (A-I) and §"Adversarial acceptance suite"
**Suite:** `tests/federation-docker-conformance.sh`
**Live/privileged follow-up:** `scripts/federation-conformance-live-run.sh`

This mirrors the "Adversarial acceptance matrix" table style from
`docs/design/FEDERATION_V0_BUILD_REPORT.md`: no gate is ever marked PASS
without reproduced evidence. `sbx` (Docker Sandboxes CLI) is not installed on
this machine — Docker itself is (`docker --version` works, `sbx` does not).
Every gate below that requires a live sandbox therefore SKIPs with an honest
reason rather than being marked PASS or FAIL on invented evidence.

## Gate table

| Gate | What's checked | How to run it live | Current status |
| --- | --- | --- | --- |
| A. Independent security domain | Waspflow-scoped `sbx` profile/state does not inherit the user's policy preset, global secrets, kits, or registry credentials, and survives daemon restart without merging state | `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX=<name> WASPFLOW_FEDERATION_SBX_PROFILE_DIR=<dir> bash tests/federation-docker-conformance.sh`, or the standalone probe in `scripts/federation-conformance-live-run.sh` | **SKIP-NO-SBX** (also blocked on an independent Waspflow `sbx` profile/state mechanism, which does not yet exist — see note §1) |
| B. Locked-down effective policy | Waspflow policy domain initializes to `deny-all`; only job-scoped relay endpoints are permitted; `sbx policy inspect`/`policy check network` confirm private IP, loopback, link-local, metadata, LAN, DNS-exfil, UDP, ICMP, and unauthorized TCP are denied | Same as above, with the sandbox's policy domain pre-initialized to `deny-all` | **SKIP-NO-SBX** |
| C. Credential-negative guest | From a hostile guest process with sandbox `sudo`: no SSH-agent socket/signature, no model/GitHub/cloud/registry credential reads, no Docker Hub push, no host credential-proxy reachability, run only after configuring realistic personal `sbx` credentials on the same machine | Configure personal Docker Sandboxes with real dev credentials first, then run with `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX` set | **SKIP-NO-SBX** |
| D. Disposable filesystem boundary | Job sees only its scratch dir, private VM filesystem, and declared inputs — no parent dirs, sibling jobs, user config, removable drives, network shares, or normal repos | Set `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX` and `WASPFLOW_FEDERATION_CONFORMANCE_SIBLING_SCRATCH` to a second job's scratch dir | **SKIP-NO-SBX** |
| E. No inbound exposure | No guest listening service reachable from host/LAN; no port-mapping reuse or restart-restores-mapping; job input cannot inject a port-publication request | Set `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX`; suite starts a guest listener and probes it from the host | **SKIP-NO-SBX** |
| F. Enforceable resource limits | Explicit CPU/memory/storage/process/deadline/output/network-byte/concurrency limits are enforced against fork bomb, memory exhaustion, disk/inode fill, and unbounded output | Set `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX`; the suite ships `gate_f_fork_bomb_check`, `gate_f_memory_exhaustion_check`, `gate_f_disk_fill_check` as real functions but does not yet wire them into a pass/fail measurement against declared limits | **SKIP-NO-SBX** (bomb functions exist but are not yet measured against a limit contract) |
| G. Reliable teardown and orphan recovery | `destroy` independently confirmed (not just exit code), scratch data removed, tokens revoked, cleanup receipt recorded; startup orphan reaper reconciles Waspflow-owned sandboxes | Set `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX`; suite destroys it and re-lists to confirm absence | **SKIP-NO-SBX** (destroy+re-list only; no scratch/token/receipt/reaper coverage yet) |
| H. Version-pinned conformance testing | `bin/federation-detect-sbx` refuses a stub `sbx` reporting a version below the pinned floor (`profiles/wf-federation-docker-v0.json`'s `min_version: 0.35.0`) | `bash tests/federation-docker-conformance.sh` (no live sbx or root required — runs for real today) | **PASS.** `bin/federation-detect-sbx` and `profiles/wf-federation-docker-v0.json` exist and correctly refuse a stubbed below-floor version. Note the scope of this PASS: v0 pins a **floor only** (`max_version: null`) — the note warns against inventing a fake ceiling, so an upgraded-but-unvetted `sbx` release is currently *accepted*, not rejected. Pinning and reviewing an upper bound after running this suite against a real candidate release remains a follow-up (decision-note §H: "do not assume a newly installed release is compatible"). |
| I. Legal and product confirmation from Docker | This report and the runtime decision note both explicitly list Docker's 8 legal/product questions as OUTSTANDING/unanswered — none have been obtained, none are fabricated | N/A — documentation gate, verified by `tests/federation-docker-conformance.sh`'s `gate_i_legal_product_confirmation`, which greps this file for all 8 questions and an explicit "outstanding/unanswered" acknowledgment | **PASS** (documentation gate: this file correctly records the questions as unanswered — see below) |
| J. Native Docker auth substrate, no custom gateway | `lib/federation-docker-backend.mjs` never references a custom base-URL/gateway/OpenAI-compatible pattern for Codex/Claude (static regression guard); the live proof script exists and is syntactically valid; the six numbered live auth requirements (host-side login, in-sandbox execution, credential-negative guest search, real quota consumption, cancellation, rm-without-credential-loss) are exercised by an operator running `scripts/federation-auth-proof-live-run.sh {codex\|claude}` | `bash tests/federation-docker-conformance.sh` (static half runs today); `bash scripts/federation-auth-proof-live-run.sh codex` / `claude` (live half, requires sbx + interactive OAuth login) | **Static check PASSES today** (verified adversarially: injecting a forbidden pattern flips it to FAIL, removing it flips back to PASS). **Live proof SKIPs** — no sbx on this machine, and even with sbx the live half requires a one-time interactive OAuth login this environment cannot perform. |

## Gate I: outstanding Docker legal/product questions

None of the following have been answered by Docker. This is an explicit,
tracked gap — not an oversight — per the runtime decision note, §"I. Legal
and product confirmation from Docker":

1. May Waspflow redistribute `sbx` in its installer?
2. Is invoking `sbx` as the execution backend for a distributed compute
   marketplace within its intended **commercial use**?
3. Is an **OEM**, account-free, service-account, or partner-authentication
   mode available?
4. Is there a supported local **automation API**/SDK for lifecycle
   automation rather than parsing CLI output?
5. Is there a supported **independent profile**/daemon/state mechanism?
6. Can **SSH-agent** forwarding and all personal credential inheritance be
   definitively disabled?
7. Can Docker provide a supported per-sandbox **storage cap**?
8. What **compatibility and security-support** commitments apply to pinned
   releases?

Until redistribution permission exists, Waspflow must use Docker's official
installer rather than bundling the `sbx` binary.

## Adversarial acceptance suite coverage (host-side assertions)

The note's full adversarial list, and how each maps to this suite. Every row
marked "structural only" means: a real function exists in
`tests/federation-docker-conformance.sh` (or is documented as a follow-up in
`scripts/federation-conformance-live-run.sh`) that WOULD perform this check
against a live sandbox handle, guarded by
`WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX`, but has not been executed because
no live sandbox is available in this environment.

| Adversarial check | Suite coverage |
| --- | --- |
| Reach host gateway addresses | Gate B: `host_gateway_guess` + `policy check network` (structural only) |
| Reach localhost / host-local services | Gate B: `policy check network 127.0.0.1` (structural only) |
| Scan RFC1918, IPv6 private, link-local, metadata ranges | Gate B: representative RFC1918/link-local/metadata destinations (structural only); IPv6 private ranges not yet enumerated |
| DNS exfiltration | Gate B: not yet implemented as a discrete check — needs a controlled resolver to detect (documented gap) |
| UDP and ICMP | Gate B: not yet implemented as a discrete check (documented gap) |
| Arbitrary TCP and proxy tunnels | Gate B: `policy check network` covers representative denied TCP destinations; proxy-tunnel establishment not yet implemented |
| SSH-agent socket discovery + signature request | Gate C: `SSH_AUTH_SOCK` visibility + `ssh-add -l` (structural only) |
| Read Docker/GitHub/cloud/model/registry credentials | Gate C: registry config + env-var grep for common secret names (structural only, not exhaustive) |
| Inspect adjacent job state | Gate D: sibling scratch-dir visibility (structural only) |
| Escape scratch workspace via symlink/traversal | Gate D: not yet implemented as a discrete symlink/traversal probe (documented gap; cross-reference `lib/federation-runtime.mjs`'s `isRelativeSafePath`, which is exercised in `tests/federation-runtime.test.mjs` at the schema level) |
| Publish or expose a listening port | Gate E: guest `nc` listener + host TCP probe (structural only) |
| Fork bomb | Gate F: `gate_f_fork_bomb_check` (structural only, not wired into pass/fail) |
| Exhaust memory | Gate F: `gate_f_memory_exhaustion_check` (structural only, not wired into pass/fail) |
| Fill disk and inodes | Gate F: `gate_f_disk_fill_check` covers disk; inode exhaustion not yet implemented |
| Generate unbounded output | Gate F: not yet implemented (documented gap) |
| Survive deadline termination | Gate F: not yet implemented (documented gap) |
| Survive daemon restart | Gate A: daemon-restart survival named as a requirement, not yet implemented (documented gap) |
| Leave resources after deletion | Gate G: destroy + independent re-list (structural only); scratch/token/receipt not yet covered |
| Malicious archive/device/link/filename in output | Not yet implemented in this suite. Host-side archive/traversal/link/device rejection is already covered at the CAS-artifact layer by `bin/waspflow-federation-runner inspect-artifact` and exercised in `tests/federation-runner.sh`; this suite does not duplicate that, but a Docker-backend-specific output-collection check (`collectDeclaredOutputs`) is a documented gap |

## Requires owner-run privileged/live pass

Every SKIP-NO-SBX row above requires a human operator, on a machine with
`sbx` installed and authenticated, to run the standalone script provided at
`scripts/federation-conformance-live-run.sh`. That script is not a
placeholder — it is real, runnable bash that a follow-up owner or judge pass
executes to turn each SKIP into a reproduced PASS or FAIL. See that file for
exact commands and prerequisites (macOS/Linux/Windows `sbx` install, KVM
group membership, personal-credential configuration for gate C, etc).

No SKIP in this matrix should ever be read as a passing result. Per the
runtime decision note: *"A guest reporting 'blocked' is not proof."* The same
standard applies here — a structural function existing is not proof either.
