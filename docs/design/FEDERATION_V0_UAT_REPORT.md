# Federation v0 UAT report — Docker Sandboxes backend

**Date:** 2026-07-20
**Branch:** `waspflow/fedv0-docker-backend` (child of `feat/federation-v0`)
**Source of truth:** `inbox/2026-07-20-chatgpt-sandbox.md` (the "Runtime Decision" note)
**Verdict:** **Federation Preview, mechanism-complete, security-gates unproven.** Merge-ready as a
gated preview backend behind an operator-run live conformance pass. **Not** ready to accept
stranger-submitted jobs — no graduation gate that requires a real `sbx` sandbox has been exercised.

## What changed and why

The prior plan built a custom Firecracker host layer as the production runtime (branch
`feat/federation-v0` before this work). That effort produced a signed envelope format (kept,
unchanged) and a firewall-helper reference (kept, unchanged), but its Firecracker runner never
executed a real hostile-task journey — `docs/design/FEDERATION_V0_BUILD_REPORT.md` records the
prior verdict as **PAUSED / BLOCKED**, with `execute` always failing "Firecracker host integration
is not wired."

The Runtime Decision note directs a pivot: implement a **backend-neutral runtime interface** and
put **Docker Sandboxes (`sbx`)** behind it as a gated "Federation Preview" backend, since Docker
already supplies the microVM, kernel, network policy engine, and lifecycle management that the
Firecracker track was rebuilding from scratch. This report covers that pivot's first cut.

**`sbx` is not installed on the machine this work was built and verified on.** Docker itself is
(`docker --version` → `29.6.0`). Every claim below is scoped accordingly: what runs and passes for
real today, versus what is real, runnable code correctly waiting on a live sandbox.

## What was built

| Component | File(s) | Status |
| --- | --- | --- |
| Backend-neutral `SandboxBackend` interface + `ValidatedJobSpec` | `lib/federation-runtime.mjs` | Built, unit-tested (30 tests), independently reproduced |
| `DockerSbxBackend` (mechanism over the `sbx` CLI) | `lib/federation-docker-backend.mjs` | Built, unit-tested (14 tests, 1 honest skip), independently reproduced |
| Credential/state hygiene proof | `tests/federation-docker-hygiene.test.mjs` | Built, unit-tested (4 tests), independently reproduced |
| `sbx` installer/detection stub | `bin/federation-detect-sbx`, `profiles/wf-federation-docker-v0.json` | Built, exercised in the "absent" branch (the only branch reachable here) |
| Graduation-gate conformance suite (A-I) | `tests/federation-docker-conformance.sh`, `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md`, `scripts/federation-conformance-live-run.sh` | Built, 2/9 gates pass for real (H, I), 7/9 correctly SKIP pending a live sandbox |

All work is layered on `feat/federation-v0` (signed envelope + firewall helper + Firecracker
runner, all unchanged and kept as documented Linux-native fallback/reference per the note).

### The interface (`lib/federation-runtime.mjs`)

Implements exactly the shape the note specifies: `probeCapabilities()`, `prepare(validatedJob)`,
`start(handle)`, `streamLogs(handle)`, `collectDeclaredOutputs(handle, manifest)`, `cancel(handle)`,
`destroy(handle)`, `inspect(handle)`. `ValidatedJobSpec` is schema-enforced to be host-blind: it
structurally cannot carry host paths, mounts, raw VMM args, ports, personal env vars, or reusable
credentials (`FORBIDDEN_FIELDS`, enforced recursively, 24 forbidden-field tests). This is the same
design principle as the existing `lib/federation-envelope.mjs`'s forbidden-field rejection, applied
one layer down at the backend-dispatch boundary rather than the task-authoring boundary.

### `DockerSbxBackend` (`lib/federation-docker-backend.mjs`)

Implements all seven interface methods over the `sbx` CLI. Concretely:

- **Never mounts a real repo or home directory.** `prepare()` creates a fresh, unique, disposable
  scratch directory per job (`mkdtemp`) and passes only that to `sbx run`.
- **Sanitized environment on every `sbx` child process.** `sanitizedEnv()` strips
  `SSH_AUTH_SOCK`, `DOCKER_HOST` exactly, and `*_API_KEY`/`*_TOKEN`/`AWS_`/`GCP_`/`GOOGLE_`/
  `AZURE_`/`GIT_`/`GH_`/`GITHUB_`/`DOCKER_`/`NPM_`/`OPENAI_`/`ANTHROPIC_` by pattern.
- **Separate Waspflow `sbx` identity.** Every `sbx` child process gets `HOME` overridden to a
  Waspflow-owned directory (`WASPFLOW_FEDERATION_SBX_HOME`, default `~/.waspflow/sbx-home`).
  This is explicitly the **last-resort** option from the note's §1 numbered preference list (a
  distinct OS-level identity), not the preferred "supported, independent `sbx` profile" — no such
  documented mechanism exists (confirmed against Docker's own local-governance docs; see
  "Independent verification" below).
- **`destroy()` never trusts `sbx rm`'s exit code alone.** It independently re-lists (`sbx ls`)
  to confirm absence, retries once, and honestly reports `removed:false` if still present rather
  than claiming success.
- **`collectDeclaredOutputs()` rejects unsafe paths before touching `sbx`** (absolute paths, `..`
  traversal, NUL bytes) and refuses a copied-out symlink rather than following it.
- **Two CLI surfaces are marked unverified in-code** (`// UNVERIFIED SBX SYNTAX:` comments):
  `sbx exec` (used by `start()`) and `sbx cp` (used for input/output copy). Docker's own
  documentation pages did not render complete flag tables when fetched during this work; these
  were implemented from `docker exec`/`docker cp` conventions and the note's prose description,
  not confirmed against `sbx exec --help` / `sbx cp --help`. This is the single highest-priority
  follow-up before any real job can run — see "What's next."

### Credential/state hygiene proof (`tests/federation-docker-hygiene.test.mjs`)

Proves, against the **real** `DockerSbxBackend` module (not a guessed shape): `sanitizedEnv()`
strips every named and pattern-matched personal-credential variable while leaving `PATH`/`HOME`
intact, and the Waspflow-owned `HOME` override is genuinely exercised by
`DockerSbxBackend.probeCapabilities()`'s actual child-process invocation — verified via a stub
`sbx` executable that echoes back the `$HOME` it was launched with.

### Detection stub (`bin/federation-detect-sbx`, `profiles/wf-federation-docker-v0.json`)

Detects `sbx` on `PATH`; if absent, points to Docker's official install docs and never attempts to
download or bundle the binary — the note is explicit that Docker's release repository is marked
"All rights reserved" and redistribution rights are unresolved (gate I, question 1). The profile
pins a version **floor only** (`min_version: "0.35.0"`, the version cited in the note as of its
2026-07-10 release); `max_version` is explicitly `null` with an `_owner_review_required` field —
the note warns against inventing a fake upper bound with false confidence, and no adversarial
conformance pass has been run against any candidate release to justify one.

### Conformance suite (gates A-I)

`tests/federation-docker-conformance.sh` has one function per graduation gate. Static/structural
checks always run; live checks require a real `sbx` sandbox and correctly **SKIP** (never silently
pass, never hard-fail the suite) when unavailable, mirroring the existing
`tests/federation-firewall-helper.sh` pattern (`SKIP: requires root`) with an `sbx`-specific
condition. `scripts/federation-conformance-live-run.sh` is the real, runnable script for an owner
with a live `sbx` install to turn each SKIP into a reproduced PASS or FAIL.

## Graduation gates: what actually passes

| Gate | Status | Evidence |
| --- | --- | --- |
| A. Independent security domain | **SKIP-NO-SBX** | Requires a live sandbox + comparison against a personally-configured `sbx`. Also blocked on Docker confirming an independent profile mechanism exists at all (unconfirmed; see below). |
| B. Locked-down effective policy | **SKIP-NO-SBX** | Requires `sbx policy inspect`/`policy check network` against a live sandbox. |
| C. Credential-negative guest | **SKIP-NO-SBX** | Requires a hostile guest process inside a live sandbox, run after configuring realistic personal `sbx` credentials on the same machine (the note is explicit that a clean-machine-only test is insufficient). |
| D. Disposable filesystem boundary | **SKIP-NO-SBX** | Requires a live sandbox + a sibling job's scratch dir to probe cross-job visibility. |
| E. No inbound exposure | **SKIP-NO-SBX** | Requires a live sandbox with a guest listener probed from the host. |
| F. Enforceable resource limits | **SKIP-NO-SBX** | Fork-bomb/memory/disk fixture functions exist and are callable but not yet wired to a pass/fail measurement against a declared limit contract — a documented gap even for the live-run path. |
| G. Reliable teardown and orphan recovery | **SKIP-NO-SBX** | Requires a live sandbox; only destroy+re-list is covered even in the live path — scratch/token/receipt/startup-reaper coverage is a documented gap. |
| H. Version-pinned conformance testing | **PASS** | `bin/federation-detect-sbx` correctly refuses a stubbed below-floor `sbx` version. Reproduced independently (see below). Scope: floor-only — an unvetted high version is currently *accepted*, not rejected, since no ceiling is pinned yet. |
| I. Legal and product confirmation from Docker | **PASS (documentation gate)** | The conformance matrix correctly records all 8 of Docker's outstanding legal/product questions as unanswered. This is a completeness check on the documentation, not a claim that Docker answered anything — none have been obtained. |

**2 of 9 gates pass for real. 7 of 9 correctly SKIP pending a live `sbx` install and, for several,
additional unimplemented measurement wiring even once `sbx` is available.** No gate is marked PASS
without reproduced evidence; every SKIP states its specific blocking reason.

## Independent verification (maker ≠ judge)

This work was built by three parallel Claude workers (mechanism, hygiene/detection, conformance
suite) in isolated git worktrees, each producing a maker report
(`docs/design/federation-evidence/*_MAKER_REPORT.md`). Before merging any of their work, the
orchestrating pass in this session:

1. **Read the actual source** of `lib/federation-docker-backend.mjs` line-by-line against its
   maker report's claims — confirmed sanitized-env stripping, scratch-dir isolation, symlink
   rejection, and independently-verified-destroy all match what the report described.
2. **Independently re-ran** every test suite (`node --test tests/*.test.mjs`,
   `bash tests/federation-docker-conformance.sh`, `bash scripts/verify.sh`) after each merge,
   rather than trusting a maker's "tests pass" claim.
3. **Found and fixed a real bug via this independent re-run**: the conformance suite's gate H
   stub tested rejection of a *high, bogus* `sbx` version (`99.99.99`), but the detection stub it
   was testing against deliberately implements floor-only enforcement (no ceiling, per the note's
   own "don't invent a fake upper bound" guidance) — so the detector correctly *accepted* that
   stub, and gate H FAILed on first integrated run. This was not a flaw in either individual
   worker's isolated logic; it only surfaced once both pieces were combined and exercised
   together, which is exactly why independent, integrated verification (not per-lane trust) was
   run before this report was written. Fixed by changing the stub to a below-floor version, which
   the detector does and should reject — gate H now passes for real, confirmed by direct
   re-execution, not by re-reading the fix.
4. **Independently confirmed the "no documented independent-profile mechanism" claim** in the
   decision note by fetching Docker's own local-governance documentation
   (`docs.docker.com/ai/sandboxes/governance/local/`) directly, rather than trusting the note's
   citation: confirmed it describes exactly one machine-level policy preset plus sandbox-scoped
   rules, with "no alternative state management approach" documented. This directly supports why
   `DockerSbxBackend`'s `HOME`-override approach is explicitly framed as a last resort pending
   Docker confirmation, not presented as an equivalent to a supported profile mechanism.
5. **Independently confirmed default network-blocking and credential-forwarding behavior** via
   Docker's security-defaults docs: private/loopback/link-local ranges and host network are
   blocked by default; no credentials are forwarded into a sandbox unless explicitly configured.
   This matches the mechanism's design (no credential configuration is ever performed by this
   backend) but does **not** substitute for gate C's requirement to test against a machine with
   *personal* `sbx` credentials already configured — that remains unverified.

No claim in this report rests solely on a subagent's self-report. Every PASS above was reproduced
by direct command execution in this session after all three lanes were merged together.

## Explicit non-claims

Per the decision note's constraints, this work does **not** claim:

- **Confidential computing.** A malicious provider (the machine running the sandbox) can still
  inspect job inputs, guest memory/disk, network traffic, and outputs. Federation v0 provides no
  defense against this — jobs must be limited to non-sensitive, disclosed data, per the note's
  §"Protecting the requester from the provider."
- **Result integrity.** Nothing here verifies that a returned result reflects honest execution.
  The note's answer (author manual review, deferred author-side re-verification) is unchanged by
  this work and out of scope for a runtime-backend cut.
- **Any of graduation gates A-G, or the resource-limit half of F/G, pass.** They are unproven,
  not merely untested — the distinction matters. A SKIP is not a PASS.
- **That the Waspflow `sbx` identity is actually isolated from a developer's personal `sbx`
  config.** The `HOME`-override mechanism is real, exercised code, but whether it produces true
  daemon-state/policy/credential separation on a real `sbx` install is exactly graduation gate A,
  unverified here.
- **That `sbx exec`/`sbx cp` invocations are syntactically correct.** Two CLI surfaces are marked
  unverified in-code and must be confirmed against a real `sbx --help` before any job can run.

## What's next (in priority order)

1. **Confirm `sbx exec`/`sbx cp` syntax** against a real `sbx` install (or `sbx --help` output) —
   this blocks any live job from running at all, independent of the security gates.
2. **Run `scripts/federation-conformance-live-run.sh`** on a machine with `sbx` installed and
   authenticated to turn gates A, B, D, E, G's SKIPs into reproduced PASS/FAIL. This is a
   privileged/live one-off; the script is written and ready for an owner to run, per this task's
   instruction not to block on privilege the orchestrating session doesn't have.
3. **Configure personal `sbx` credentials on the same test machine** before attempting gate C —
   the note is explicit that a clean-machine test is insufficient for the credential-negative
   guest check.
4. **Wire gate F's fork-bomb/memory/disk fixtures into an actual pass/fail measurement** against
   declared resource limits, once `sbx`'s real limit-enforcement flags are confirmed.
5. **Contact Docker** on the 8 outstanding questions tracked in
   `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md` (redistribution, commercial-use scope, OEM/
   account-free mode, automation API, independent profile mechanism, SSH-agent disable guarantee,
   storage cap, compatibility/security-support commitments) — none block this preview, but several
   block a production release decision per the note's explicit gate.
6. **Pin a version ceiling** in `profiles/wf-federation-docker-v0.json` once a real adversarial
   conformance pass validates a specific `sbx` release.

## Honest confidence

**High confidence** the interface, adapter, hygiene, and detection mechanisms are correctly built
and internally consistent — every claim in this report was independently reproduced by direct
command execution, not inferred from a maker's self-report, and one real integration bug was
caught and fixed by that independent verification.

**No confidence claim, positive or negative,** on whether Docker Sandboxes actually delivers the
containment properties graduation gates A-G require. They were never exercised against a real
sandbox in this environment. This report is a proof that the mechanism is real, testable, honestly
scoped code — not a claim that Federation v0 is safe to expose to stranger-submitted jobs today.

**UAT-ready** in the sense the task defined: an operator can install `sbx`, and once the two
unverified CLI surfaces are confirmed, point Waspflow at a job and watch it attempt to run
contained in a Docker sandbox, with an honest, automated report of exactly which security
properties have and have not been proven for that specific release.
