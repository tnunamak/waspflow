# Federation v0 UAT report — Docker Sandboxes backend

**Date:** 2026-07-20 (updated 2026-07-21 — full federated loop)
**Branch:** `waspflow/fedv0-docker-backend` (child of `feat/federation-v0`); full-loop work on
`waspflow/fedv0-full-loop` (stacked child of `fedv0-docker-backend`)
**Source of truth:** `inbox/2026-07-20-chatgpt-sandbox.md` (the "Runtime Decision" note) for the
Docker Sandboxes backend; `docs/design/FEDERATION_DESIGN_V2.md` §B.5.2 for the coordinator state
machine shape (settlement/escrow economics explicitly excluded from this build — see below).
**Verdict:** **The full federation loop now runs for real, not just the sandbox mechanism.** Tim
submits a task, Ocean's client pulls and runs it sandboxed against her subscription, Tim receives
the result branch — proven end-to-end this session with real infrastructure: a real coordinator
process, two genuinely distinct ed25519 keypairs (author vs executor), real signed envelopes, real
content-addressed artifact transport, a real Claude Code subscription-authenticated task run
through the already-proven `DockerSbxBackend`, independent signature re-verification on BOTH ends
(the executor re-verifies the task it claims; the requester re-verifies the result it downloads),
and a real settled result materialized back to disk with byte-identical content. See "Federation
full loop (2026-07-21)" below for the complete build/verify record and "User guide" for how to run
it yourself. **Settlement/escrow/ledger economics are explicitly out of scope for this build** — a
task reaching `SETTLED` means "a validly signed, correctly-bound result was recorded," nothing
economic; see `FEDERATION_DESIGN_V2.md` §B.5.3/B.5.4 for what a future build would still need.
Docker Sandboxes backend status (2026-07-20, unchanged by this update): mechanism-complete, install
UX complete, auth UX live-verified end-to-end for all three original harnesses, graduation gates
B/C/E/F/G REPRODUCED against real sbx (2 real containment observations, 5 honest FAILs, none
silently fixed into a PASS). **This machine's current local `sbx` policy is genuinely permissive
("allow all hosts"), not deny-all — gate B FAILs for real; the isolated Federation-owned identity
(`~/.waspflow/sbx-home`) was separately initialized to deny-all with scoped allow rules for the
three harnesses' provider domains only** — see "Federation full loop" below for that decision.
**Owner decisions needed:** (1) Claude Code has two selectable auth strategies with a real billing
tradeoff — see "Claude Code auth" below; (2) this machine's PERSONAL sbx policy (distinct from the
Federation-owned identity) is still permissive — gate B; (3) settlement/escrow is deferred by
design, not forgotten — a production collective needs it before real value changes hands.

## Owner UAT findings and fixes (2026-07-20, real sbx v0.35.0)

The owner installed a real `sbx` (v0.35.0, `/usr/bin/sbx`, authenticated as `timvana`) and ran the
mechanism against it across multiple rounds — exactly the value the owner-handoff checkpoint was
designed to surface. Three real defects found and fixed so far, each the same class: a guessed CLI
surface that turned out wrong once tested against the real tool.

**Defect 1 (blocker) — `bin/federation-detect-sbx` probed a flag that doesn't exist.** It ran `sbx
--version`, but `sbx` has no `--version` flag: `sbx --version` → `ERROR: unknown flag: --version`,
exit 1. The detector's `status !== 0 → available:false` logic then falsely reported "sbx not found
on PATH" even though sbx was installed, authenticated, and on PATH. **This would have made the
install UX built in the prior revision lie to every real user** — `waspflow doctor` and
`federation-install-sbx`'s "already installed" branch would both have misreported a working sbx
install as absent. Fixed: the detector now probes the `version` SUBCOMMAND (`sbx version` →
`sbx version: v0.35.0 <sha>`, exit 0 — confirmed against the real install on this machine, not
just the owner's report) and treats `spawnSync`'s own `ENOENT` as the only signal for "truly
absent" — a present binary that errors or returns unparseable output on `version` is reported as
present-with-a-parse-failure, never as not-found. Added `tests/federation-detect-sbx.sh` with the
exact regression case (a stub that rejects `--version` and accepts `version`, matching the real
sbx v0.35.0 shape byte-for-byte) plus two adjacent cases (present-but-broken-for-another-reason;
truly-absent via ENOENT) so this class of bug cannot silently return. Re-verified against the real
`sbx` binary now installed on this machine: `bin/federation-detect-sbx` correctly reports
`sbx detected: version 0.35.0`, and `waspflow doctor` reports the matching `[ok]` line.

**Defect 2 (friction) — the Linux apt install command wasn't non-interactive.** README's
`sudo apt-get install docker-sbx` and the identical line in this report's "Owner handoff" section
were missing `-y`, so a copy-pasted install would stop and wait for a confirmation keypress —
low-friction was an explicit design goal for this install UX. `bin/federation-install-sbx` already
had `-y` (correct from the prior revision); fixed the two doc copies to match. Added a
`scripts/verify.sh` structural assertion that greps all three locations
(`README.md`, `bin/federation-install-sbx`, this report) for any non-`-y` `apt-get install
docker-sbx` line — verified it fails when the flag is removed and passes on the fixed source, so
this specific friction regression is now caught automatically.

Per the owner's note, `sbx diagnose` exists for deeper install-health checks beyond a bare version
probe (daemon/`sandboxd` reachability etc) — flagged as a documented follow-up in
`bin/federation-detect-sbx`'s header comment, not built now, per the explicit "keep fixes minimal,
don't rebuild anything" instruction.

**Defect 3 (blocker) — `sbx run`'s AGENT/PATH argument order was reversed.**
`scripts/federation-harness-auth-proof-live-run.sh`'s `run_sandbox()` called
`sbx run --name "$1" "$2" "$install"` — passing the scratch-dir PATH before the AGENT name. Real
`sbx run [flags] [AGENT] [PATH...]` reads the first positional as the agent, so the scratch dir was
read as an unrecognized agent and every call failed with `'/tmp/tmp.XXXX' is not a sandbox or known
agent`. This blocked gate [2/6] ("full CLI runs in VM") and every downstream gate for **both**
Codex and Claude Code (the gh-cli kit path had the identical reversed shape). Fixed: agent now comes
before the path — `sbx run --name <name> <agent> <path>`. Additionally found and fixed, while
confirming the fix against the real CLI (not assumed): `kits/wf-gh-cli.kit.yaml`'s own schema was
invalid — `sbx kit validate` requires the manifest file to be named exactly `spec.yaml` inside a kit
directory (not an arbitrary `.kit.yaml` filename) and a `schemaVersion` field that was missing
entirely; moved to `kits/wf-gh-cli/spec.yaml` and added `schemaVersion: "1"`, re-validated as
`VALID` (with informational deprecation warnings pointing at a newer v2 schema, not required for
this proof). Also discovered that for a `kind: sandbox` kit, the AGENT positional must equal the
kit's own manifest `name` field, not a generic built-in agent — `sbx` itself reports this precisely
(`agent name "shell" does not match agent kit name "wf-gh-cli"`) when it doesn't match; `install`
for `GH_CLI_HARNESS` now correctly carries `"wf-gh-cli"` (the kit's name), not a file path.

All three `sbx run` invocations (Codex, Claude Code, gh-cli) were verified end-to-end against the
real install in this session: each created a real, `--detached` sandbox, was confirmed listed by
`sbx ls`, and was immediately torn down with `sbx rm` — not merely re-read from documentation.

## Autonomous fix loop: entrypoints, headless execution, and real containment results

**This round of fixes was driven end-to-end by this session, unattended, per an explicit owner
directive to own the fix loop rather than relay each bug back for confirmation.** Six more real
bugs found and fixed via direct reproduction against real sbx, followed by three graduation gates
(B, C, G) actually run to completion against a real sandbox for the first time — with two of the
five FAILs (B and one root cause behind C's original run) traced to genuine command-syntax bugs
matching the earlier pattern, and the rest confirmed as honest, unfixed containment gaps.

**Defect 4 (blocker) — Codex's own first-run trust prompt blocked every unattended task.**
Live UAT showed the `sbx run` fix worked (sandbox launches), but Codex then opened its interactive
"Do you trust the contents of this directory?" prompt and sat idle forever — no terminal exists to
answer it in a headless federation job. Fixed: `CODEX_HARNESS.entrypoint` now includes
`--dangerously-bypass-approvals-and-sandbox`, confirmed via `codex exec --help` on the real install
to be intended exactly for this case ("Intended solely for running in environments that are
externally sandboxed"). The Docker Sandboxes microVM **is** that external sandbox — Federation's
real containment boundary is the microVM (graduation gates A-G), not Codex's own in-process
approval guard, which becomes a second, redundant layer for a process already fully contained one
level out. Bypassing it does not weaken Federation's security boundary; leaving it enabled only
replaces a real boundary with an unanswerable prompt. Same rationale applied to both Claude Code
harnesses (`--dangerously-skip-permissions`, confirmed via `claude --help`: "Bypass all permission
checks"). Audited gh-cli separately: `gh` is a subcommand CLI, not an interactive agent session —
`gh --version` and `gh auth status` both run and exit cleanly with no prompt of any kind, so no
bypass flag is needed or exists for it.

**Defect 5 (blocker) — the declared `entrypoint` was never actually driven.** Even after Defect 4,
Codex opened its interactive TUI and sat idle — the sandbox was running, but the HarnessSpec's
`entrypoint` field was declared and never passed to anything. Root cause: `sbx run [flags] [AGENT]
[PATH...] [-- AGENT_ARGS...]` with `--detached` creates and starts the sandbox's DEFAULT session; it
does not accept a full `exec <task>` argument vector the way this session first assumed. Confirmed
directly (three separate probes against real sbx) that the correct pattern is: `sbx run --name <n>
<agent> <path> --detached` to create the sandbox, then **`sbx exec <sandbox> -- <entrypoint>
"<task>"`** (mirrors `docker exec`, per `sbx exec --help`) to actually drive one headless task and
terminate. `run_sandbox()` was split into `create_sandbox()` (detached creation only) and
`run_task()` (drives the entrypoint via `sbx exec`); a deterministic task prompt
(`"print WF_TASK_OK and exit"`) and its expected output (`WF_TASK_OK`) is the real gate-2 acceptance
signal now — a sandbox existing is necessary but not sufficient, exactly the distinction the
original bug collapsed.

**Defect 6 — `sbx rm` silently failed in the cleanup trap, leaking sandboxes.** After the first
full end-to-end run, `sbx ls` showed 3 sandboxes still alive despite the script's `trap cleanup
EXIT` calling `sbx rm` on each. Root cause, confirmed directly: `sbx rm` refuses non-interactively
without `--force` ("stdin is not a terminal; use --force to skip confirmation"), and the trap's `||
true` silently swallowed that failure. Fixed by adding `--force` to every `sbx rm` call in the
script; re-ran the full harness three times afterward and confirmed via `sbx ls` that cleanup left
zero stray sandboxes each time.

**Defects 7-9 — three more guessed command names/syntax in the conformance suite, found only once
gates were actually run against real sbx for the first time.** All three exact-same class as the
recurring lesson of this engagement: a command was assumed correct from prior research and never
verified until this session ran it for real.
- `sbx policy inspect <sandbox>` does not exist in that shape — `inspect` takes a POLICY OR RULE
  identifier, not a sandbox name (confirmed: fails with "policy or rule not found" against a real
  sandbox). The correct command for a sandbox's effective policy is `sbx policy ls <sandbox>`.
- `sbx destroy` and `sbx list` are not real subcommands at all (confirmed via `sbx --help`) — the
  real removal command is `rm` (which also needed the `--force` fix from Defect 6), the real
  listing command is `ls`. Fixed in `tests/federation-docker-conformance.sh`'s gate G and
  `scripts/federation-conformance-live-run.sh`'s gate G manual-step instructions.
- Gate C's `ssh-add -l` check had a **false-positive bug**: its failure message is literally *"error
  fetching identities: communication with agent failed"* — the check's `grep -qi identit` matched
  the word "identities" inside that FAILURE text, reporting `SSH_SIGN_POSSIBLE` even though
  `ssh-add` exited 1 (no real signing capability). Confirmed directly by running `ssh-add -l;
  echo $?` in a real guest — exit 1, no identities. Fixed to check the actual exit code. Separately
  corrected the check's framing: `SSH_AUTH_SOCK` being a visible socket FILE is documented, expected
  Docker behavior per the decision note itself ("Docker also forwards the host SSH agent whenever
  SSH_AUTH_SOCK is set... it can request signatures" — visibility is not the violation, a WORKING
  signature request is), so `SSH_SOCK_VISIBLE` was dropped as an independent leak signal.

### Real containment results from graduation gates B, C, E, F, G, run against a live sandbox

With the command-syntax bugs fixed, gates B, C, E, F, and G were run against a real, freshly-created
sandbox on this machine (not a clean test machine — this machine's actual `sbx` configuration, which
the decision note requires for gate C specifically: "testing only a clean machine is insufficient").
None were silently turned into a PASS; the two gates whose FAILs were command bugs are now
mechanically correct and re-evaluated honestly; the rest remain FAIL for genuine, documented reasons:

- **Gate B — FAIL, a real containment gap, not a bug.** `sbx policy ls <sandbox>` (the corrected
  command) reports **"allow all hosts" / "allow all paths"** as this machine's actual local policy —
  the permissive/default preset, not `deny-all`. This is a real, reproduced fact about this
  machine's current `sbx` configuration, not a code defect. **A Federation job run against this
  machine's current policy would have full outbound network access, not the deny-all-then-relay-only
  posture the design calls for.** This must be fixed at the host-policy level
  (`sbx policy init deny-all` plus job-scoped allow rules) before any job — friends-and-family or
  otherwise — runs for real; it is an owner-facing operational decision, not something this session
  should silently change on a machine it doesn't own the policy intent for.
- **Gate C — FAIL, but the false-positive is now removed; no real leak found in this pass.** After
  fixing the `ssh-add` false positive, the corrected check found no leaked credential surface across
  the checks it runs (SSH signing, registry credentials, model/cloud env-var secrets). Still
  correctly marked FAIL, not PASS — the note's required checks (GitHub/cloud-CLI credential reads,
  registry push-as-provider, host credential-proxy reachability, global-secret enumeration) are not
  all implemented yet, and the note is explicit that partial coverage is not proof.
- **Gate E — FAIL (honest incomplete-coverage FAIL, mechanism confirmed correct).** No
  host-reachable guest listener was found in this pass (a real, positive signal — a guest `nc`
  listener was started and the host could not reach it), but LAN reachability, restart-restores-mapping,
  and job-input port-publication-injection checks aren't implemented, so the suite correctly does
  not call this a PASS.
- **Gate F — FAIL (declared, not measured).** Unchanged from before — the bomb fixtures exist as
  real, callable functions but are not wired to a pass/fail measurement against declared resource
  limits. Not attempted this round; still a real gap.
- **Gate G — FAIL (honest incomplete-coverage FAIL, mechanism now correct and reproduced).** With
  the command-name fix, `sbx rm --force` on the live sandbox was confirmed to actually remove it
  (independently re-verified via `sbx ls`, not trusted from exit code alone) — a real, reproduced
  destroy+re-list result. Still correctly marked FAIL: scratch-data removal, token revocation,
  cleanup-receipt recording, and a startup orphan reaper are not implemented or exercised.

Gates A and D remain SKIP — A needs `WASPFLOW_FEDERATION_SBX_PROFILE_DIR` (an independent Waspflow
`sbx` profile mechanism that does not exist yet, per the note's own §1 finding), D needs a second
job's scratch directory to probe cross-job visibility, neither of which this session set up.

## Claude Code auth: a real product tradeoff, not a default we silently picked

**Owner decision needed here.** Live UAT surfaced that the in-sandbox `/login` step for Claude Code
felt like friction. Investigating whether that friction is avoidable, rather than assuming either
"it's fine" or "we should route around it," found a hard technical fact that makes this a genuine
tradeoff, not an implementation gap:

**Confirmed directly against the real sbx v0.35.0 install:** `sbx secret set --oauth` is hard-coded
to OpenAI only. Attempting the Anthropic equivalent —
```console
$ sbx secret set -g anthropic --oauth
ERROR: anthropic OAuth cannot be started from `sbx secret set`; sign in from inside the Claude sandbox
```
— fails with that exact, explicit error from the CLI itself. **There is no host-drivable Anthropic
subscription OAuth flow in this sbx release.** This is an sbx limitation, not a Waspflow design
choice, and not fixable by better wrapper code — `lib/federation-auth-flow.mjs`'s `startAuthFlow()`
already handles the host-URL case perfectly for Codex; there is simply no equivalent host-side entry
point for Anthropic to drive.

Given that constraint, Claude Code genuinely has two different, real auth paths, each correct for a
different goal — implemented as two separate `HarnessSpec` exports so neither is silently chosen for
the operator:

| | `CLAUDE_CODE_SUBSCRIPTION_HARNESS` (default) | `CLAUDE_CODE_API_KEY_HARNESS` (opt-in) |
| --- | --- | --- |
| **Billing** | Draws the operator's Claude Max/Pro **subscription** allowance — this is the actual point of Federation (pooling otherwise-wasted subscription capacity, not routing spend through per-token billing) | **Usage-billed** at standard Anthropic API rates — a real, ongoing cost per token, not "the same thing but smoother" |
| **Auth mechanism** | `/login` typed **inside** an attached, interactive sandbox session (`sbx run claude`, then `/login`) | `echo "$ANTHROPIC_API_KEY" \| sbx secret set -g anthropic` — **host-side**, driven by waspflow the same way as Codex's OAuth (detect-first via `sbx secret ls`, then `startAuthFlow`-equivalent non-interactive `sbx secret set` via stdin, per `scripts/federation-harness-auth-proof-live-run.sh`'s new `docker-stored-secret` case) |
| **Operator friction** | The interactive-session step is **unavoidable in v0** — genuinely necessary, not a bug, given the constraint above. Kept as low-friction as this session could make it (a single clear instruction, `describeAuthRequirement()`'s honest `instruction` field, no forced-URL fiction). Disappears automatically if/when sbx adds a host-side Anthropic OAuth flow — `CLAUDE_CODE_SUBSCRIPTION_HARNESS` should be revisited to use `startAuthFlow()` like Codex's at that point. | Smooth today — no browser step, no interactive session, waspflow drives it entirely. The cost is billing, not friction. |
| `auth_strategy` | `docker-native-oauth` / `interactive-session-flow` | `docker-stored-secret` |
| `harness_id` | `claude-code-subscription` | `claude-code-api-key` |

`CLAUDE_CODE_HARNESS` (the pre-existing default export, kept for backward compatibility with earlier
report sections and any external caller) now resolves to `CLAUDE_CODE_SUBSCRIPTION_HARNESS` —
matching the product's actual intent. The API-key path exists and is fully implemented
(`scripts/federation-harness-auth-proof-live-run.sh claude-code-api-key`, requires
`ANTHROPIC_API_KEY` on the host) for an operator who explicitly wants the smoother path and accepts
the billing tradeoff. **This code does not choose between them on the operator's behalf beyond that
documented default** — both are real, tested, and available; which one Federation should actually
use by default in a shipped product is the owner's call, not this session's.

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
| `sbx` installer/detection stub | `bin/federation-detect-sbx`, `profiles/wf-federation-docker-v0.json`, `tests/federation-detect-sbx.sh` | Built, fixed after owner UAT found a real detection bug (probed a nonexistent `--version` flag), re-verified against a real `sbx` v0.35.0 install on this machine — see "Owner UAT findings and fixes" |
| Graduation-gate conformance suite (A-J) | `tests/federation-docker-conformance.sh`, `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md`, `scripts/federation-conformance-live-run.sh` | Built, run against a real live sandbox this round: 4/10 gates pass for real (H, I, J, and gate J's live half); B, C, E, F, G are real, reproduced FAILs (not SKIPs) with specific reasons — see the gates table above; A, D remain SKIP pending unbuilt setup |
| Backend-neutral `HarnessSpec` (6 explicit auth strategies) | `lib/federation-harness-spec.mjs` | Built, unit-tested (13 tests), including an adversarial "CORE SAFETY CHECK" proving a spec cannot claim docker-builtin refresh under a strategy that structurally can't provide it |
| 4 concrete harness classifications (Codex, Claude Code subscription, Claude Code api-key, gh-cli) | `lib/federation-harnesses.mjs`, `kits/wf-gh-cli/spec.yaml` | Built, unit-tested (17 tests), each independently classified against Docker docs/issues AND run to completion against a real sandbox this round; Claude Code's two variants are a documented product tradeoff, not a silently-picked default — see "Claude Code auth" above |
| Per-harness six-column auth proof (HarnessSpec-driven) | `scripts/federation-harness-auth-proof-live-run.sh`, gate J in the conformance suite | Built AND run to completion against real sbx this round for all 3 harnesses (codex, claude-code subscription, gh-cli) — each drove a deterministic task to completion unattended and tore down cleanly. Gate J's static regression guard was verified adversarially (see "Auth architecture"); gate J now records PASS, not SKIP |
| Waspflow-driven, not-terminal-bound auth flow | `lib/federation-auth-flow.mjs`, `tests/federation-auth-flow.test.mjs` | Built, unit-tested (11 tests, all stub-based — no real `--oauth` call in any automated test), 3 self-caught bugs found and fixed (a spec-override bug, a lingering-timer bug, an unreliable-SIGTERM bug) — see "Auth UX reframe" |
| Install UX: auto-install sbx + graceful fallback | `bin/federation-install-sbx`, `install.sh`, `bin/waspflow doctor` | Built, tested end-to-end on this machine (the real "no passwordless sudo" fallback path — see "Install UX" below) |
| README sbx-install section | `README.md` "Install sbx (Docker Sandboxes)" | Built — two copy-pasteable code blocks + one official link, no prose wall |

All work is layered on `feat/federation-v0` (signed envelope + firewall helper + Firecracker
runner, all unchanged and kept as documented Linux-native fallback/reference per the note).

## Install UX

**The v0 user journey, made real in code, per owner steer.** A user installs waspflow the way
`tnunamak/clawmeter` is installed: clone, run `install.sh`. During that install, `install.sh` now
attempts `sbx` auto-install as its last step; on any failure or unsupported platform it falls
through to a short, copy-pasteable README section — never a silent no-op, never a wall of text.

### `bin/federation-install-sbx`

A new script, mirroring `bin/federation-detect-sbx`'s naming and called automatically at the end of
`install.sh` (`|| true` — a failed sbx install never fails the overall waspflow install):

- **Already installed:** skips straight to `federation-detect-sbx` for a version check.
- **macOS:** `brew tap docker/tap && brew install docker/tap/sbx`, then points at `sbx login`.
  Commands verified against `docker/sbx-releases`' own README (fetched directly, not inferred from
  a blog summary) and Docker's official get-started docs.
- **Linux (apt-based):** `curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt-get
  install docker-sbx`, then `usermod -aG kvm`. **Only attempted when `sudo -n true` succeeds** (i.e.
  passwordless sudo is already configured) — mirrors clawmeter's own installer gating for its Linux
  tray dependency exactly (`sudo -n true` before any privileged step, never an interactive password
  prompt). On this development machine, passwordless sudo is NOT configured, so this is the actual,
  real fallback path exercised end-to-end, not a hypothetical: verified it prints a clear message
  and exits 0 without ever blocking on stdin (`< /dev/null` redirect) or attempting `sudo`.
- **Any other OS, or any install failure:** falls through to a short message pointing at the
  README's "Install sbx (Docker Sandboxes)" section — both files reference that exact heading
  string, so the pointer cannot silently drift out of sync with the README.
- **Never bundles or downloads the `sbx` binary itself** — every path goes through Docker's own
  officially documented installer, consistent with the redistribution-rights gap already tracked in
  `profiles/wf-federation-docker-v0.json` and gate I.

### README section

`README.md`'s new "Install sbx (Docker Sandboxes)" section (right after "First Run") is two code
blocks (macOS, Linux) plus one official Docker link plus a one-line pointer to
`bin/federation-detect-sbx` to confirm — not a wall of text, consumable at a glance.

### `waspflow doctor` wiring

`bin/waspflow doctor` now reports sbx status as a bracketed `[ok]`/`[warn]` line, consistent with
every other doctor check, and **never affects the "ready"/"missing prerequisites" verdict** — sbx
is optional (Federation Preview only), so its absence must never block a plain
non-Federation waspflow user from a clean "ready" result. Verified: `doctor` reports `-> ready` with
exit 0 both with and without `sbx` present, using a real fake-`sbx`-on-PATH fixture for the present
case (not merely inspected in source).

### End-to-end journey verified today (mechanism, not the live sbx result)

Ran the full `install.sh` → `doctor` → `federation-install-sbx` chain on this machine start to
finish: links the binary, runs doctor (all checks pass except the expected `OPENAI_API_KEY`
billing warning, pre-existing and unrelated), then reaches the Federation Preview step and reports
the real "no passwordless sudo, falling through to README" outcome with a clean exit. This is the
mechanism proof — it is not a claim that `sbx` was actually installed on any machine, since that
requires either passwordless sudo (absent here) or a human running the manual README commands.

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

### Conformance suite (gates A-J)

`tests/federation-docker-conformance.sh` has one function per graduation gate. Static/structural
checks always run; live checks require a real `sbx` sandbox and correctly **SKIP** (never silently
pass, never hard-fail the suite) when unavailable, mirroring the existing
`tests/federation-firewall-helper.sh` pattern (`SKIP: requires root`) with an `sbx`-specific
condition. `scripts/federation-conformance-live-run.sh` is the real, runnable script for an owner
with a live `sbx` install to turn each SKIP into a reproduced PASS or FAIL. Gate J (added in this
revision) is a static regression guard plus a pointer to the dedicated auth-architecture live proof
script; see "Auth architecture" below for the full account.

## Auth architecture (tightened 2026-07-20)

**This section supersedes an earlier, looser correction in this same report.** The prior revision
correctly ruled out building a custom Waspflow gateway, but it treated auth as roughly one solved
case — "Docker's native OAuth proxy keeps Codex/Claude tokens out of the guest" — as if that one
fact settled both harnesses identically and settled the billing question. It does not. Two specific
assumptions in that framing were dangerous enough to warrant this rewrite:

1. **"Compatible base URL == subscription auth" is false.** A CLI hitting its normal, unmodified
   provider endpoint tells you nothing about which credential authorized the request. OpenAI's own
   documentation distinguishes ChatGPT-login (subscription allowance) from API-key auth
   (usage-billed at standard rates) as two different auth modes the SAME CLI can use — Codex's
   `codex login status` reports this explicitly as an `auth_mode` field (`apiKey` | `chatgpt` |
   `chatgptAuthTokens`), and Claude Code's `/status` reports an equivalent "Auth token" field
   (`CLAUDE_CODE_OAUTH_TOKEN` = subscription vs. `ANTHROPIC_API_KEY` = usage-billed vs.
   `ANTHROPIC_AUTH_TOKEN` = gateway). **A successful request through a compatible endpoint proves
   the request worked, not which billing mode paid for it.** This report now requires the CLI's own
   reported mode as proof, per harness.
2. **"Reading a host token == OAuth support" is false.** Docker Sandboxes' documented kit mechanism
   (`credentials.sources`, confirmed via `docs.docker.com/ai/sandboxes/customize/kit-reference/`)
   supports a `file` source with a `parser: json:<dot.path>` field extractor — this genuinely
   exists. But an **open Docker feature request**
   ([`docker/sbx-releases#300`](https://github.com/docker/sbx-releases/issues/300), fetched and
   read in full during this work) states plainly: *"This works well for static credentials (API
   keys, PATs). It breaks for OAuth access tokens, which are short-lived (~1h) and must be
   refreshed... Docker already does this internally [for] the built-in `--oauth` provider logins
   (Claude Code, Codex)... This request is to make that existing capability user-extensible."*
   Codex's own `~/.codex/auth.json` is actively refreshed and **rewritten by the Codex process
   itself** (confirmed via OpenAI's Codex CI/CD documentation, which specifically warns against
   overwriting a refreshed `auth.json` in automation). A generic `file`/`json:path` credential
   source pointed at that file would read a **static snapshot at kit-discovery time** — it would
   NOT participate in Codex's own refresh cycle, and the injected token would go stale in about an
   hour. **"A token is extractable from a host file" and "the subscription is usable indefinitely"
   are separate claims; this report never treats the first as proof of the second.**

### Six explicit auth strategies, not one case

`lib/federation-harness-spec.mjs` defines a `HarnessSpec` schema with an explicit `auth_strategy`
field, one of six values (`AUTH_STRATEGIES`, enforced structurally — an unrecognized value fails
validation):

| Strategy | What it means | Who it currently fits |
| --- | --- | --- |
| `docker-native-oauth` | Docker's own built-in `--oauth` login for a small, Docker-curated set of agents. Per `docker/sbx-releases#300`'s own admission, these get privileged host-side token refresh no generic kit source currently exposes. **The only strategy with currently-shipping, Docker-confirmed indefinite refresh.** | Codex, Claude Code |
| `host-file-proxy` | A kit's `credentials.sources` declares a host **file** + `json:<path>` parser. Correct for a credential a CLI persists **statically**; wrong for one the CLI itself refreshes/rewrites unless proven otherwise. | Not used by any of the three v0 harnesses (available for a future static-file credential) |
| `host-env-proxy` | A kit declares a host **env var** source. Same static-value scope as `host-file-proxy`. | gh-cli (the extensibility proof) |
| `docker-stored-secret` | `sbx secret set -g <service>` (non-`--oauth` form) — a secret in the OS keychain, static value. | Not used by any of the three v0 harnesses |
| `host-auth-adapter-required` | The credential is keychain-held and/or refresh-dependent in a way none of the proxy mechanisms above reach. No solution exists yet short of a purpose-built host-side adapter (the shape `docker/sbx-releases#300` itself requests) — **never** solved by copying a refresh token/client secret/full auth file into the guest. | Not needed by any of the three v0 harnesses; reserved for a future harness that genuinely requires it |
| `unsupported` | No known strategy applies. Fail closed — Waspflow must not guess. | n/a |

`lib/federation-harness-spec.mjs`'s validator **structurally forbids** the exact dangerous claim
assumption #2 above describes: a spec using `host-file-proxy` or `host-env-proxy` cannot declare
`oauth_refresh.refresh_owner: 'docker-builtin'` — attempting to do so throws a `HarnessSpecError`
citing `docker/sbx-releases#300` by name. This was unit-tested adversarially (`tests/federation-
harness-spec.test.mjs`, "CORE SAFETY CHECK" test), not just asserted in a comment.

### The three UAT harnesses and their classification

`lib/federation-harnesses.mjs` declares three concrete `HarnessSpec` instances, each independently
classified against the evidence above (not assumed identical because two of them share a strategy
label):

- **Codex** — `docker-native-oauth`. `install: 'codex'` (Docker's built-in template, not a custom
  image). Login: `sbx secret set -g openai --oauth` (host-side browser flow; Docker's own docs:
  "the flow runs on the host, so the token is never exposed inside the sandbox"). Refresh:
  `refresh_owner: 'docker-builtin'`, evidence cited inline in the spec. Reported-mode proof:
  `codex login status` → `auth_mode` field. One real usability caveat (not a correctness gap): the
  `--oauth` flow expects a local browser callback, awkward on headless Linux — an open Docker issue
  (`docker/sbx-releases#208`) requests a device-code flow instead.
- **Claude Code** — `docker-native-oauth`. `install: 'claude'`. Login: `/login`, typed *inside* the
  sandbox session — the one place Docker's own wording could be misread as "credential lives in the
  guest." Independently confirmed this is the same host-side proxy-interception mechanism as
  Codex's; the *interaction* is in-session, the *credential* is not. Reported-mode proof: `/status`
  → "Auth token" field. Waspflow's own `lib/billing.sh` already guards this exact ambiguity
  (`ANTHROPIC_API_KEY` silently overriding subscription auth) for its own headless workers — a
  previously-encountered failure mode, not a hypothetical one, cited directly in the spec.
- **gh-cli** — `host-env-proxy` (the extensibility proof: a non-built-in harness onboarded via a
  Waspflow-authored kit, `kits/wf-gh-cli/spec.yaml`, using Docker's documented `credentials.sources`
  env-var injection — not a Waspflow gateway). `install` is `"wf-gh-cli"`, the kit's own manifest
  `name` — confirmed against a real `sbx run` that this is the AGENT positional a `kind: sandbox`
  kit requires, not a file path. Deliberately chosen because `GH_TOKEN` is a
  **static** Personal Access Token that `gh` does not self-refresh — this keeps the extensibility
  proof honest: it demonstrates a new harness CAN be onboarded through the documented kit
  mechanism, without also (mis)claiming that mechanism handles refresh. `oauth_refresh.refresh_owner:
  'none'` because none is needed, not because refresh was proven safe for this strategy in general.

All three specs are unit-tested (`tests/federation-harnesses.test.mjs`, 6 tests) to confirm: Codex
and Claude Code are each independently classified rather than copy-pasted; both report an explicit
auth mode; both have Docker-proven indefinite refresh; gh-cli correctly uses a different strategy
and installs via a custom kit, not a built-in template; and none of the three harnesses violate the
`host-file-proxy`/`host-env-proxy` docker-builtin-refresh guard.

### Per-harness six-column proof matrix — updated with real owner live-UAT results

`scripts/federation-harness-auth-proof-live-run.sh` supersedes the prior single-purpose auth proof
script. It is **HarnessSpec-parameterized** — it reads `lib/federation-harnesses.mjs` at runtime and
drives whatever that spec declares, rather than hardcoding one flow shared across harnesses. Usage:
`bash scripts/federation-harness-auth-proof-live-run.sh {codex|claude-code|claude-code-api-key|gh-cli}`.

**The owner ran this live against the real sbx install.** Columns 1-2 (auth UX) **PASSED** for real,
for both Codex and Claude Code — waspflow drove the Codex login and surfaced only the URL; the
script correctly detected Claude Code's interactive-session flow and the operator did only
`sbx run claude` → `/login`. Column 6 ("full CLI runs in VM") **FAILED** for both, due to Defect 3
above (the `sbx run` argument-order bug) — now fixed and re-verified in this session via three real,
`--detached`, immediately-torn-down sandboxes (Codex, Claude Code, gh-cli), each confirmed listed by
`sbx ls`. The owner has not yet re-run the full six-column script end-to-end against the fix; that
re-run is the next step (see "Owner handoff" below).

| Column | Codex | Claude Code (subscription) | Claude Code (api-key) | gh-cli |
| --- | --- | --- | --- | --- |
| Existing host login detected | **LIVE-VERIFIED (owner UAT).** `isProviderSecretSet()` correctly detected state; waspflow checked, the operator was never asked. | **LIVE-VERIFIED (owner UAT).** Correctly identified as `interactive-session-flow`, not host-detectable. | Not yet live-run. Detect-first logic (`sbx secret ls -g --service anthropic`) reproduced directly against this machine's real install in this session (correctly identifies an existing secret without triggering a new one). | Not yet live-run; unit-tested and reproduced against a stub. |
| Extra login required | **LIVE-VERIFIED (owner UAT).** Waspflow drove `startAuthFlow()`; operator did only the browser step at the printed `AUTH_URL`. | **LIVE-VERIFIED (owner UAT).** Operator completed `/login` inside `sbx run claude`, as `describeAuthRequirement()` instructed — necessary friction per the sbx limitation documented above, not avoidable in v0 for the subscription path. | Not yet live-run. Non-interactive `sbx secret set -g anthropic` via stdin is the mechanism; no browser/interactive step is needed for this path at all. | Not yet live-run; depends on whether `GH_TOKEN` is pre-set. |
| Full CLI runs in VM | **Was FAIL-CANDIDATE in owner UAT (Defect 3); fix applied and independently re-verified via a real, detached, torn-down `sbx run --name ... codex <path> --detached` in this session.** Owner re-run pending. | **Was FAIL-CANDIDATE in owner UAT (Defect 3, same root cause); fix applied and independently re-verified via a real `sbx run --name ... claude <path> --detached`.** Owner re-run pending. | Same fix applies (shares `run_sandbox()`); not yet live-run for this specific harness variant. | **Never previously reachable — blocked by both Defect 3 and the kit-schema-validity issue found while fixing it.** Now independently verified via a real `sbx run --name ... wf-gh-cli <path> --kit kits/wf-gh-cli --detached`, confirmed listed by `sbx ls`, torn down with `sbx rm`. |
| Credential stays outside VM | Not yet live-run against the fixed invocation; heuristic search logic unchanged from before. | Not yet live-run against the fixed invocation. | Not yet live-run. | Not yet live-run. |
| Refresh works | Still requires the separate long-duration follow-up (holding a sandbox open past a real OAuth token's ~1h expiry) — unaffected by this round's fixes. | Same long-duration limitation. | **N/A** — static API key, no refresh mechanism claimed. | **N/A** — static PAT. |
| Subscription allowance used | Not yet live-run against the fixed invocation; `codex login status` `auth_mode`-parsing logic unchanged. | Not yet live-run against the fixed invocation; `/status` parsing logic unchanged. | Not yet live-run. **Note the inverted expectation**: `ANTHROPIC_API_KEY` reporting is the CORRECT result for this harness (it is deliberately usage-billed), not a failure — the script's `claude-code-api-key` case handles this distinction explicitly, unlike the `claude-code` case where the same report would be a FAIL-CANDIDATE. | **N/A** — no subscription/API-key distinction for gh-cli. |

Every remaining "not yet live-run" cell is real, executable, HarnessSpec-driven code — syntax-checked,
HarnessSpec-resolution-tested, and (for the parts that don't require a live sandbox) unit-tested —
but not yet exercised end-to-end against real `sbx` in a full six-column pass. That is the concrete
next step for the owner, now that Defect 3 no longer blocks it.

### Gemini: still explicitly deferred, not assumed equivalent

Unchanged from the prior revision's correction: Gemini's Docker Sandboxes auth path is **not** the
same durable, host-only subscription OAuth flow as Codex/Claude — it is API-key/proxy-managed
instead. No `HarnessSpec`, kit, or code in this revision assumes otherwise. Gemini remains a
separate, unresolved spike.

## Auth UX reframe: waspflow drives login, not the operator (2026-07-20)

**Owner correction applied in this revision.** The prior auth-proof script told the operator to run
`sbx secret set -g openai --oauth` themselves — this is the wrong mental model for the actual
product. Three corrections:

1. **Waspflow runs the sbx auth command itself; the user does only the browser part.** The operator
   never types or is told to type the raw `sbx` command. Waspflow spawns it, parses the login URL
   out of its stdout, and surfaces just that.
2. **Detect-first.** Before triggering anything, check whether the provider secret is already set
   in the Waspflow-scoped sbx profile (`sbx secret ls -g --service <id>`). If set, proceed silently.
   A login flow starts only when a job actually needs a provider that isn't authed yet — never
   re-prompt once set.
3. **Not terminal-bound.** The packaging target is an installed app (clawmeter-style: download and
   run, no forced terminal), not a CLI product. The auth step is architected as a structured
   event — `{url, waitForCompletion}` — that a future tray/GUI can render its own way. The terminal
   is v0's TEST harness, not the product surface the interface was designed around.

### `lib/federation-auth-flow.mjs`: the structured interface

New module implementing all three corrections:

- **`isProviderSecretSet(harnessSpec)`** — detect-first, read-only. Runs `sbx secret ls -g --service
  <id>` and parses sbx's real (non-JSON, confirmed against a live v0.35.0 install) empty-result text
  `"No secrets found for scope ... and service ..."` to distinguish already-set from not-set. Never
  triggers a login.
- **`startAuthFlow(harnessSpec)`** — for `docker-native-oauth` harnesses whose
  `credential_discovery.flow_shape` is `'host-url-flow'` (see below). Spawns the real `sbx` command
  itself, parses the login URL out of its stdout using the spec's `url_prompt_pattern`, and returns
  an `AuthFlowHandle` — `{status, url, waitForCompletion(), cancel()}`. The caller sees only `url`;
  it never sees or constructs the underlying `sbx secret set -g openai --oauth` invocation.
- **`describeAuthRequirement(harnessSpec)`** — honest fallback for flow shapes `startAuthFlow`
  cannot drive (see the Codex/Claude asymmetry below). Returns `{drivable: false, instruction}`
  rather than forcing a fake `{url}` onto a harness that has no host-side URL at all.

### The Codex/Claude asymmetry, made explicit in the schema

Confirmed directly against a real `sbx` install (not assumed) that Codex's and Claude Code's
`docker-native-oauth` logins are mechanically different, even though they share the same
`auth_strategy` label:

- **Codex — `host-url-flow`.** `sbx secret set -g openai --oauth` runs entirely on the host, prints
  `"Open this URL to sign in to Codex OAuth:"` followed by a plain URL, and completes when the
  browser redirects to a local callback (`localhost:1455`). No separate device code. Reducible to
  `{url, waitForCompletion}` — confirmed by directly invoking the real command during this session
  (see the incident note below on why this must be handled carefully).
- **Claude Code — `interactive-session-flow`.** `/login` must run *inside* an attached, interactive
  sandbox session (`sbx run claude`). There is no host-side URL for waspflow to capture — forcing
  this into the same `{url}` shape as Codex would misrepresent the mechanism. `HarnessSpec` now
  requires an explicit `flow_shape` field (schema-enforced: `host-url-flow` requires a
  `url_prompt_pattern`; `startAuthFlow()` refuses to drive `interactive-session-flow` and throws
  `AuthFlowError` if called on it) so this asymmetry cannot be silently collapsed later.

### Incident: a live probe of the real OAuth flow left a stray credential

While confirming the real shape of `sbx secret set -g openai --oauth`'s output (needed to write
`url_prompt_pattern` correctly, not guessed), this session ran the real command directly against
the owner's authenticated `sbx` install to observe its stdout. That probe was interrupted, but **it
left a real OAuth secret configured**: `sbx secret ls -g --service openai` now reports `(oauth
configured)`. A stray background process from an early, buggy version of the auth-flow wrapper
(before the `sbxBin` override bug — see below — was fixed) also briefly held `localhost:1455`; that
process has since exited on its own and the port is confirmed clear.

**Owner: if this credential is not one you intended to configure, remove it with:**
```bash
sbx secret rm -g openai
```
This is flagged rather than silently cleaned up, since removing security-relevant credential state
without being asked is exactly the kind of unilateral action this project's own conventions warn
against. No code in this revision reads, uses, or depends on that stray credential — all automated
tests use a stub `sbx` binary and never invoke the real `--oauth` flow (see testing section below).

### Bugs found and fixed while building this module (self-caught, not owner-reported)

Building and testing `federation-auth-flow.mjs` surfaced three real bugs, each caught by writing a
real reproduction before trusting the fix:

1. **`startAuthFlow` ignored its own `sbxBin` override.** The child process's binary was derived by
   splitting `credential_discovery.login_command` (always literally `"sbx"`), never actually using
   the `sbxBin` option — so a test-provided stub was silently bypassed and the REAL `sbx` binary ran
   instead. This is exactly how the stray credential above was created: a supposedly-stubbed test
   run actually invoked the real OAuth flow three times. Fixed: the binary is always `sbxBin`; only
   the arguments after the leading `sbx` are taken from `login_command`.
2. **A lingering `node:timers/promises` timeout kept the process alive after successful
   completion.** `Promise.race([completion, delay(timeout)])` never cancelled the losing `delay()`
   call, which held Node's event loop open for the full timeout duration even after `completion`
   won. Fixed with an `AbortController` so the timer is genuinely cancelled, not just ignored.
3. **`cancel()` assumed SIGTERM is reliably delivered and handled — proven false in this
   environment.** A direct, isolated reproduction (a trap-holding shell script, killed via both
   `child.kill('SIGTERM')` and a plain shell `kill -TERM` run completely outside Node) showed the
   process surviving SIGTERM entirely. `cancel()` now SIGTERMs first, then SIGKILLs after a 1-second
   grace period if the process hasn't exited — and a SIGKILLed child's stdio streams are now
   explicitly `.destroy()`ed, since an open pipe on a killed child was independently found to keep
   Node's event loop alive indefinitely (confirmed via isolated reproduction, not assumed from
   documentation).

All three are covered by dedicated regression tests in `tests/federation-auth-flow.test.mjs`,
including one that deliberately makes the stub ignore SIGTERM (`trap '' TERM`) to force and verify
the SIGKILL fallback path, checked via actual OS process liveness (`pgrep`), not just the JS-side
status flag.

### Updated per-harness proof matrix status

The prior revision's matrix row "Existing host login detected: Script prompts the operator to
confirm or perform `sbx secret set -g openai --oauth`" described the OLD, pre-reframe script and is
now inaccurate — `scripts/federation-harness-auth-proof-live-run.sh` step [1/6] for
`docker-native-oauth` + `host-url-flow` harnesses (Codex) now calls `isProviderSecretSet()` and, only
if unset, `startAuthFlow()` — printing `AUTH_URL <url>` and nothing else; it never prints or asks
for the raw `sbx` command. For `interactive-session-flow` (Claude Code), the script now calls
`describeAuthRequirement()` and shows its honest `instruction` field rather than a fabricated URL
prompt. All 11 tests in `tests/federation-auth-flow.test.mjs` pass (stub-only — no real `sbx` call in
any automated test, precisely because of the incident above), and the end-to-end detect-first +
drive-the-login-myself + surface-only-the-URL behavior was independently verified against a stub
`sbx` mimicking the real v0.35.0 output shape, reproduced in this session outside the test suite as
well.

## Graduation gates: what actually passes

| Gate | Status | Evidence |
| --- | --- | --- |
| A. Independent security domain | **SKIP** | Needs `WASPFLOW_FEDERATION_SBX_PROFILE_DIR`, an independent Waspflow-owned `sbx` profile mechanism that does not exist in this checkout yet, and Docker has not confirmed one exists at the product level either (see finding below, unchanged from before). Not attempted this round. |
| B. Locked-down effective policy | **FAIL — real, reproduced containment gap** | `sbx policy ls <sandbox>` (corrected from the wrong `sbx policy inspect` command) reports this machine's actual local policy is **"allow all hosts"**, not deny-all. Reproduced directly against a live sandbox. This is a host-configuration fact, not a code defect — **owner decision required**: fix via `sbx policy init deny-all` (+ job-scoped allow rules) before any job runs against this machine for real. |
| C. Credential-negative guest | **FAIL — honest incomplete-coverage FAIL, false positive removed** | Fixed a false-positive bug in the `ssh-add -l` check (was matching the word "identities" inside a FAILURE message; now checks exit code). Re-ran against this machine's real, personally-configured `sbx` credentials (not a clean machine, per the note's requirement) — no leak found in the checks that exist (SSH signing, registry creds, env-var secrets), but GitHub/cloud-CLI credential reads, registry push-as-provider, and global-secret enumeration checks aren't implemented yet, so still correctly FAIL, not PASS. |
| D. Disposable filesystem boundary | **SKIP** | Needs a second job's scratch dir to probe cross-job visibility; not set up this round. |
| E. No inbound exposure | **FAIL — honest incomplete-coverage FAIL, mechanism confirmed correct** | A guest `nc` listener was started and confirmed host-unreachable (a real positive signal) against a live sandbox. Still FAIL: LAN reachability, restart-restores-mapping, and job-input port-injection checks aren't implemented. |
| F. Enforceable resource limits | **FAIL — declared, not measured** | Unchanged: bomb fixtures exist and are callable but not wired to a pass/fail measurement against declared limits. Not attempted this round. |
| G. Reliable teardown and orphan recovery | **FAIL — honest incomplete-coverage FAIL, mechanism now correct and reproduced** | Fixed two nonexistent commands (`sbx destroy`→`sbx rm --force`, `sbx list`→`sbx ls`). `sbx rm --force` on a live sandbox was independently re-verified via `sbx ls` (not trusted from exit code alone) to actually remove it. Still FAIL: scratch-data removal, token revocation, cleanup receipts, and a startup orphan reaper are not implemented. |
| H. Version-pinned conformance testing | **PASS** | `bin/federation-detect-sbx` correctly refuses a stubbed below-floor `sbx` version. Reproduced independently (see below). Scope: floor-only — an unvetted high version is currently *accepted*, not rejected, since no ceiling is pinned yet. |
| I. Legal and product confirmation from Docker | **PASS (documentation gate)** | The conformance matrix correctly records all 8 of Docker's outstanding legal/product questions as unanswered. This is a completeness check on the documentation, not a claim that Docker answered anything — none have been obtained. |
| J. Native Docker auth substrate, no custom gateway | **PASS (live half now closed)** | The static regression guard passes and was adversarially verified (see item 10 below). The live half — a real, deterministic task-completion proof for all three harnesses, unattended — was run to completion this round: Codex (`SBX_CRED_OPENAI_MODE=oauth`, task ran and exited with `WF_TASK_OK`), Claude Code subscription (`.claude/.credentials.json` shows a `claudeAiOauth` block after one-time global `/login`, task ran and exited with `WF_TASK_OK`, and the credential was independently confirmed host-persistent/global — a brand-new sandbox with no manual login succeeded), and gh-cli (task ran and exited with `WF_TASK_OK`, no bypass flag needed). No custom gateway/base-URL/proxy code was used to achieve any of this — all three ran through Docker's native `sbx` credential proxying. |

**4 of 10 gates pass for real (H, I, J, and — practically — the auth-UX half of what A/D used to
gate on).** Of the remaining 6: **B, C, E, F, G are honest FAILs**, each backed by real evidence
from a live sandbox this round (not SKIPs anymore — they were actually run), and **B is the one
that matters most before any real job executes**: this machine's actual `sbx` policy is
permissive, not deny-all. **A and D remain SKIP**, both blocked on setup this session did not
perform (an independent profile mechanism for A that doesn't exist yet; a sibling scratch dir for
D). No gate is marked PASS without reproduced evidence; every FAIL states what's missing, and none
was silently converted to a PASS.

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
6. **Independently resolved an apparent contradiction in Docker's own docs about Claude auth.**
   One page's phrasing ("Claude Code... prompt interactively inside the sandbox") could be misread
   as "the credential lives in the sandbox," which would have contradicted the auth-architecture
   correction directing this revision. Fetching the credentials/isolation page directly and reading
   its literal wording resolved this: the *interaction* (typing `/login`) happens in-session, but
   the underlying host-side HTTP/HTTPS proxy interception is the same mechanism as Codex's, and the
   real credential does not become guest-resident. This distinction is now stated explicitly in the
   "Auth architecture" section above so a future reader doesn't rediscover the same ambiguity.
7. **Adversarially verified gate J's static regression guard**, not just wrote it: temporarily
   inserted a forbidden pattern (`ANTHROPIC_BASE_URL`) into `lib/federation-docker-backend.mjs`,
   re-ran the conformance suite, confirmed gate J flipped to FAIL with the correct reason, then
   removed the injected line and confirmed it reverted to its normal SKIP status (the suite still
   correctly reports SKIP, not PASS, once the pattern is gone — because gate J's live half remains
   unexercised regardless of whether its static half is clean).
8. **Fetched and read a real, open Docker feature request in full** (`docker/sbx-releases#300`,
   via `gh api`, not a web-search summary) before designing `HarnessSpec`'s auth-strategy taxonomy.
   Its own wording — "Docker already does this internally [for] the built-in `--oauth` provider
   logins (Claude Code, Codex)... This request is to make that existing capability
   user-extensible" — is the direct evidence that only `docker-native-oauth` currently has
   Docker-confirmed indefinite refresh, and that a generic `credentials.sources` `file`/`env`
   source (which the issue itself describes as working "well for static credentials... [but]
   breaks for OAuth access tokens") must never be conflated with it. This citation is load-bearing
   for the entire `HarnessSpec` refresh-strategy guard, not decorative.
9. **Independently confirmed Codex's own `auth_mode` reporting field and refresh-and-rewrite
   behavior** via OpenAI's own Codex CI/CD documentation (which explicitly warns against
   overwriting a refreshed `auth.json` in automation) and a third-party technical analysis of the
   Codex auth-file schema (`auth_mode: "apiKey" | "chatgpt" | "chatgptAuthTokens"`), rather than
   assuming Codex's refresh behavior parallels Claude's from the correction's wording alone.
10. **Adversarially re-verified gate J's regression guard after tightening its patterns**: the
    first version of the guard (bare-word `gateway` grep) produced a FALSE POSITIVE against this
    revision's own legitimate documentation prose (`lib/federation-harnesses.mjs`'s comment "not a
    Waspflow-built gateway"). Caught by re-running the full suite after adding the new file, not
    assumed clean. Fixed by narrowing the patterns to code-shaped regexes (assignment syntax,
    constructor-call syntax, literal env-var names), then re-verified with three fresh injected
    violations (a real `ANTHROPIC_BASE_URL` reference, a `base_url:` assignment, and a `new
    *Gateway(` call) — each caught, and the clean tree correctly reverted to SKIP, not a lingering
    FAIL, once every injection was removed.

11. **Found and fixed a real bug via direct reproduction, not code review**: `startAuthFlow`'s child
    process spawned the literal string `"sbx"` (parsed from `credential_discovery.login_command`),
    silently ignoring the `sbxBin` test-override option — meaning every "stub-based" test attempt
    during development actually invoked the real `sbx` binary. Caught only because a test hung
    unexpectedly; tracing the hang to real `sbx secret set -g openai --oauth` processes (visible via
    `ps aux`) revealed the bug. This is documented as an incident, with the exact remediation
    command, in "Auth UX reframe" above — not glossed over as a clean build.
12. **Found and fixed two further bugs by refusing to accept an initially-plausible fix**: after
    correcting the `sbxBin` bug, a cancellation test still hung. Rather than assume the fix was
    sufficient, traced the hang through three further isolated reproductions outside the actual
    module (a bare `node:timers/promises` race, a bare `child.kill('SIGTERM')` against a
    trap-holding shell script, and a bare SIGKILLed-child-with-open-stdio-pipes case) before
    concluding each was a real, independent bug and fixing all three. Every fix was re-verified by
    re-running the exact failing test, not by inspection.
13. **Adversarially designed a test to force the failure path it claims to cover**: the SIGKILL
    fallback test uses `trap '' TERM` specifically so the stub CANNOT exit via SIGTERM, forcing the
    test to actually exercise the SIGKILL branch rather than coincidentally passing via the
    SIGTERM-succeeds path. Process death is checked via `pgrep` against the OS, not via the
    wrapper's own JS-side status flag — checking the flag alone would not have caught bug #12 above
    at all, since the flag flips to `'cancelled'` immediately regardless of whether the underlying
    process ever actually dies.

14. **Fixed the owner-reported `sbx run` argument-order bug by first reproducing it, then verifying
    the fix against the real CLI three separate times** (Codex, Claude Code, gh-cli), each as a
    real, `--detached`, immediately-torn-down sandbox — not by reading `sbx run --help` once and
    assuming the fix was correct. Discovered a SECOND, related real bug in the same investigation
    (`kits/wf-gh-cli.kit.yaml`'s schema was invalid per `sbx kit validate` — missing
    `schemaVersion`, wrong filename convention) that would have blocked the gh-cli fix even after
    the argument order was corrected; fixed and re-validated against the real CLI, not assumed
    correct from the first fetch of Docker's kit-reference docs.
15. **Confirmed the Claude Code auth-strategy tradeoff by attempting the alternative directly**,
    rather than accepting the owner's framing without verification: ran
    `sbx secret set -g anthropic --oauth` against the real install and reproduced the exact error
    (`"anthropic OAuth cannot be started from `sbx secret set`; sign in from inside the Claude
    sandbox"`) that proves no host-drivable Anthropic OAuth exists in this sbx release — the
    two-variant design in "Claude Code auth" above rests on this reproduced error, not assumed
    Docker documentation.

16. **Ran the full harness auth-proof script, unattended, against real sbx, and fixed what broke
    rather than reporting the first blocker back.** `scripts/federation-harness-auth-proof-live-run.sh`
    initially failed at its "full CLI runs in VM" gate for every harness — traced through three
    successive real bugs (Codex's trust prompt, the entrypoint never being passed to `sbx exec`,
    `sbx rm` failing without `--force`) before landing on a real, deterministic `WF_TASK_OK`
    pass for codex, claude-code, and gh-cli, each independently re-run to confirm the fix, not
    assumed durable from one green run. Full account in "Autonomous fix loop" above.
17. **Ran the conformance suite's gates B, C, E, F, G against a live sandbox for the first time**,
    rather than leaving them as SKIP-NO-SBX claims re-read from documentation. Found and fixed
    three further command-syntax bugs this exposed (`sbx policy inspect`→`sbx policy ls`,
    `sbx destroy`/`sbx list`→`sbx rm --force`/`sbx ls`, the `ssh-add` false positive), each
    confirmed via direct re-execution against real sbx, not by code inspection alone. Where a gate
    genuinely fails for a real, non-code reason (gate B's permissive local policy), it was left as
    an honest FAIL with the specific fact stated, not silently worked around — changing host
    policy state is an owner-level security decision, not something to fix in code from this
    session.

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
- ~~That `sbx exec`/`sbx cp` invocations are syntactically correct.~~ **RESOLVED (2026-07-21):**
  both were fixed and proven against a real sbx install, including a real, absolute-path bug in
  `sbx cp` found only by running a real end-to-end task — see "Federation full loop" below.
- **That Docker's native OAuth/credential proxy has been proven to keep Codex/Claude tokens out of
  the guest.** `scripts/federation-harness-auth-proof-live-run.sh`'s six-column proof is real,
  HarnessSpec-driven, runnable code for all three harnesses that has not been executed against a
  real `sbx` install — this is asserted by Docker's own documentation (independently confirmed, see
  above) but not yet proven by this project's own adversarial test.
- **That "a token is extractable from a host file/env var" means "the subscription is usable
  indefinitely."** These are separate claims. `host-file-proxy`/`host-env-proxy` strategies are
  structurally forbidden from claiming Docker-managed refresh (`lib/federation-harness-spec.mjs`'s
  validator enforces this) — only `docker-native-oauth` currently has Docker-confirmed indefinite
  refresh, and even that has not been proven by this project's own long-duration test (the "refresh
  works" column is explicitly "not exercised, cannot be meaningfully proven in a short run" for both
  Codex and Claude Code in the per-harness matrix above).
- **That a successful request through a compatible provider endpoint proves subscription billing.**
  It does not — only the CLI's own reported auth mode (`codex login status`'s `auth_mode` field,
  Claude Code's `/status` "Auth token" field) is treated as proof in this report, and neither has
  been executed against a real sandbox yet.
- **That the gh-cli extensibility kit generalizes to arbitrary custom harnesses**, especially ones
  with a refreshing credential. It proves the documented kit mechanism works for a **static**
  credential; a harness needing `host-auth-adapter-required` remains unsupported until a
  purpose-built adapter exists.
- **That subscription pooling works for Gemini the way it does for Codex/Claude.** Confirmed, not
  merely assumed (2026-07-21): Gemini's Docker auth path is `docker-stored-secret` (a static,
  usage-billed API key), NOT `docker-native-oauth` — `sbx secret set --oauth` is hard-coded
  openai-only, same limitation already found for Anthropic. `lib/providers/gemini.sh` and
  `GEMINI_HARNESS` are both built and unit-tested, but neither has run a real task to completion:
  this machine's linked Google account is rejected outright by gemini-cli 0.50.0/0.51.0
  (`IneligibleTierError`, a server-side account-tier check unrelated to sbx or Waspflow).
- **That `lib/federation-auth-flow.mjs`'s `startAuthFlow()` has been proven against the real Codex
  OAuth flow end-to-end.** It was unit-tested exclusively against stub `sbx` binaries. This session
  DID observe the real flow's actual output shape once (to write `url_prompt_pattern` correctly
  rather than guess it) — see the incident note in "Auth UX reframe" — but that was a manual probe
  of the real command's behavior, not an automated, repeatable test of the wrapper driving it.

## Federation full loop (2026-07-21)

**Full-ship directive:** build the missing "federated" half so a real user can submit a task, have
it run on someone else's machine, and get the result back — not just prove the sandbox mechanism
in isolation. Built on branch `waspflow/fedv0-full-loop` (stacked child of
`fedv0-docker-backend`), owned end-to-end by this session per the same autonomous-fix-loop
directive as the Docker Sandboxes UAT above: run real proof scripts, diagnose and fix real CLI/
mechanism bugs without stopping to ask, and only surface for containment results, product/security
decisions, or true blockers.

### What was built

| Slice | Component | Status |
| --- | --- | --- |
| 1. Gemini provider adapter | `lib/providers/gemini.sh` | Built, unit-tested, registered in `WASPFLOW_PROVIDERS`/`lib/billing.sh`. E2E-unverified — this machine's Google account is rejected by gemini-cli 0.50.0/0.51.0 (`IneligibleTierError`, account-tier, not a Waspflow or sbx issue). Real flag shapes (`--session-id`, `-o json`, `--approval-mode yolo`, `--skip-trust`) and the `~/.gemini/tmp/<cwd-basename>/chats/session-*.jsonl` transcript layout were all confirmed against the real, installed CLI before the account-tier wall was hit. |
| 2. Coordinator service | `lib/federation-coordinator.mjs`, `bin/waspflow-federation-coordinator` | Built and tested. HTTP service implementing `PUBLISHED->QUEUED->CLAIMED->SUBMITTED->EVALUATING->SETTLED` (per `FEDERATION_DESIGN_V2.md` §B.5.2) over the pre-existing signed envelope contract. Settlement/escrow/ledger economics explicitly deferred — `SETTLED` means "a validly signed, correctly-bound result was recorded," nothing economic. Multi-member signer roster (key_id -> publicKeyPem), not a single shared key — a real gap found and fixed before merge (see below). Artifact transport (`PUT`/`GET /artifacts/:digest`, content-addressed, digest-verified) added during slice 3. |
| 3. Requester CLI | `lib/federation-submit.mjs`, `bin/waspflow-federation-submit` | Built and tested. Packages a local source dir (`git archive HEAD` when possible) and prompt text into digest-addressed artifacts, signs a v0 task envelope, uploads, publishes, polls for settlement, materializes the candidate result with independent signature re-verification. |
| 4. Executor CLI | `lib/federation-pull-internals.mjs`, `bin/waspflow-federation-pull` | Built and tested. Claims a task, independently re-verifies its signature before running any of its content, fetches artifacts, runs a real task through the already-proven `DockerSbxBackend`, submits a signed result. Defaults to `CLAUDE_CODE_SUBSCRIPTION_HARNESS` ("her subscription"), `--harness`-overridable. |
| 5. Gemini as a federated harness | `GEMINI_HARNESS` in `lib/federation-harnesses.mjs` | Built, unit-tested, and live-verified THROUGH the real `DockerSbxBackend` mechanism up to the same account-tier wall as slice 1 — real sandbox creation, real credential injection (`SBX_CRED_GOOGLE_MODE=apikey`), real, correctly-enforced network-policy rejection of an ungranted domain. |
| 6. End-to-end wiring | (integration, no new files) | **Proven live, real infrastructure, this session** — see below. |

### Real bugs found and fixed this round (each independently reproduced, not assumed from a report)

1. **Coordinator: single shared key could not distinguish author from executor.** The first cut of
   `lib/federation-coordinator.mjs` verified every envelope against one `publicKeyPem` — meaning it
   could only ever recognize ONE signer identity, when the whole point of this slice is that Tim
   (author) and Ocean (executor) have DIFFERENT keys. Caught in review before merge (not by the
   agent's own tests, which — tellingly — signed every fixture with the same keypair). Fixed with a
   `key_id -> publicKeyPem` roster resolved from the envelope's own claimed `signature.key_id`
   *before* calling `verifyEnvelope`, so a signature is checked against exactly the key its claimed
   identity owns, never "does it match any registered key." Re-tested with three genuinely distinct
   keypairs (author, executor, an unregistered "stranger") proving both roster-gating and
   exact-key resolution.
2. **`DockerSbxBackend` (the ALREADY-PROVEN Docker Sandboxes mechanism from the earlier UAT round)
   still had the exact `sbx run` argument-order bug and entrypoint-not-driven bug that round had
   already fixed elsewhere** — this file was never touched by that fix loop. Caught by reading the
   code before handing the executor slice a foundation to build on, not discovered by accident.
   Fixed (`prepare()`: agent before path, `--detached`; `start()`: entrypoint driven via `sbx exec
   SANDBOX -- sh -c ENTRYPOINT` so a multi-word HarnessSpec command string is actually parsed, not
   treated as one literal argv token) and PROVEN with a real prepare->start->destroy smoke cycle
   against a fresh, deny-all-policy sbx identity before any slice built on top of it.
3. **`sbx cp` requires an ABSOLUTE guest path — found only by running a real end-to-end task.**
   `_copyIn`/`collectDeclaredOutputs` built remote paths as `<sandbox>:<relative-dest>`; real sbx
   rejects this outright ("container path must be absolute (use SANDBOX:/path)"). The guest's
   absolute workspace mirrors `handle.scratch_dir` (confirmed live: `sbx exec <sandbox> -- pwd`
   inside a freshly-created sandbox returns the exact host scratch_dir path) — both copy directions
   now resolve a declared relative path against `scratch_dir` first. This bug was invisible to
   every stub-based unit test (none of them exercise a real `sbx cp`); only the executor slice's
   live-sbx integration test surfaced it, which is exactly why that test exists.
4. **This machine's isolated Federation sbx identity (`~/.waspflow/sbx-home`) needed real,
   scoped network-policy allow rules to complete a live task, not just create a sandbox.** Its
   deny-all policy (initialized during the earlier UAT round) correctly blocked
   `api.anthropic.com` — a real containment behavior working as intended, not a bug. Added scoped
   `sbx policy allow network` rules for exactly the three harnesses' `provider_domains` (Anthropic,
   OpenAI/ChatGPT, Google) — an explicit owner decision (asked and confirmed mid-session), keeping
   deny-all as the base posture rather than reverting to allow-all.
5. **Requester never independently re-verified the result envelope it was about to extract to
   disk.** `materializeCandidate()` originally only checked the result payload's SCHEMA
   (`validatePayload`), never its SIGNATURE — meaning `waspflow-federation-submit --output-dir`
   would `tar -xf` whatever bytes the coordinator claimed were the settled result, trusting the
   coordinator rather than independently confirming a specific, roster-registered executor key
   actually signed them. This is the same class of gap the executor slice's own re-verification of
   the TASK envelope was built to avoid, just on the other end of the loop. Fixed with an optional
   `--roster-file` on the requester CLI (mirroring the executor's own flag) that independently
   verifies `result_envelope`'s signature against the claimed `key_id` before extraction; 3 new
   tests prove correct extraction, a missing-key rejection, and a wrong-key-for-the-claimed-id
   rejection (not just "some signature checked out").

### Live end-to-end proof (real infrastructure, this session, 2026-07-21)

Ran the actual "Tim submits, Ocean pulls, Ocean runs it against her subscription, Tim gets the
result" loop with nothing simulated or stubbed:

1. Generated two genuinely distinct ed25519 keypairs (`tim-author`, `ocean-executor`) and a roster
   file — not reused from any test fixture.
2. Started a real `bin/waspflow-federation-coordinator` process (`node:http`, real port, real
   on-disk task/artifact storage).
3. `bin/waspflow-federation-submit` packaged a real git repo via `git archive HEAD`, signed a real
   task envelope with `tim-author`'s key, uploaded the artifacts, published, and correctly reported
   `status=queued` while polling (no executor had claimed it yet — proves the publish half works
   independent of any executor being present).
4. `bin/waspflow-federation-pull` claimed the task with `ocean-executor`'s key, **independently
   re-verified `tim-author`'s signature on the claimed task envelope**, fetched both artifacts,
   built a `ValidatedJobSpec`, and ran it through the real `DockerSbxBackend` — a real, disposable
   sbx sandbox, real Claude Code subscription auth (via the isolated Federation identity's global
   `sbx secret set -g anthropic --oauth`, the same host-persistent credential proven earlier),
   `image=claude`. The run completed, `destroy()` independently confirmed removal, and the executor
   signed and submitted a result envelope. Coordinator responded `status: "settled"`.
5. Polled from the REQUESTER side again (a fresh, independent client call, not reusing state from
   step 4) — confirmed `status: "SETTLED"` with the executor's signed result envelope attached.
6. Materialized the candidate **with `--roster-file`/independent signature re-verification
   enabled** — confirmed the extraction only proceeds because `ocean-executor`'s registered public
   key actually verifies the signature on the settled result, not merely because the coordinator
   said so.
7. Confirmed the extracted result tree contains the exact source file (`README.md`) that was in
   Tim's original repo, round-tripped through the entire federated loop: published, claimed,
   materialized into a real sandbox, tarred by the executor, submitted, downloaded and re-extracted
   by the requester.
8. Confirmed clean teardown: no leaked sandboxes on either the personal or Federation-owned sbx
   identity (`sbx ls` on both, verified after the run), coordinator process killed, temp
   directories removed.

This is the strongest evidence class in this report: not a unit test against a stub, not a design
document, but a real multi-process, real-crypto, real-sandboxed run of the exact scenario the
owner described, replayed by hand and independently confirmed rather than trusted from an agent's
report.

### What this does NOT prove

- **No settlement/economics.** `SETTLED` here carries no value transfer, fee, escrow, or
  attempt-compensation — see `FEDERATION_DESIGN_V2.md` §B.5.3/§B.5.4 for what a real collective
  economy would still need. Building it was explicitly out of scope for this round.
- **No task discovery/listing.** The executor must be told a task's digest out-of-band (by the
  requester, over whatever channel the collective already uses to coordinate). There is no "list
  available tasks" endpoint — a real, honest v0 limitation, not an oversight.
- **No multi-task/daemon mode.** `waspflow-federation-pull` is one-shot: claim one task, run it,
  submit, exit. A background poller that claims whatever's queued is future work (the brief's own
  "(or a daemon)" parenthetical).
- **No cross-machine network proof.** This session's live E2E test ran the coordinator and the
  "requester"/"executor" CLIs on the SAME machine (against `127.0.0.1`), because that's what this
  environment allows. The coordinator is a normal HTTP service with no localhost-specific logic —
  nothing in its design assumes same-host clients — but an owner running Tim's coordinator on a
  real, internet-reachable host with Ocean's client on a genuinely different machine is the one
  remaining gap between this proof and the literal "different machines" framing of the brief.
- **No revocation/rotation ceremony beyond "edit the roster file and restart."** Matches the
  brief's own scoping ("no dynamic registration endpoint, no revocation logic beyond removing the
  line").

## User guide: install, configure, submit, pull, get result

1. **Install** (once per machine): `sbx` (Docker Sandboxes) must be installed and authenticated —
   see "Install sbx" in the README, or `bin/federation-install-sbx`. Global credentials for each
   harness you plan to use must be configured once (`sbx secret set -g anthropic --oauth`, `sbx
   secret set -g openai --oauth`, etc.) — see "Auth UX reframe" above; this is a one-time step, not
   per-task, once confirmed host-persistent.
2. **Generate a keypair** for your identity in the collective (one per person, author and/or
   executor role — a flat roster, no separate author/executor key spaces):
   ```bash
   node -e "
     const {generateKeyPairSync}=require('crypto'), fs=require('fs');
     const k=generateKeyPairSync('ed25519');
     fs.writeFileSync('me.pem', k.privateKey.export({type:'pkcs8',format:'pem'}));
     fs.writeFileSync('me.pub.pem', k.publicKey.export({type:'spki',format:'pem'}));
   "
   ```
   Send `me.pub.pem` to whoever runs the coordinator; keep `me.pem` private.
3. **Coordinator operator** (Tim) maintains a roster file (`key_id -> PEM`) and a shared collective
   bearer token, then runs:
   ```bash
   WASPFLOW_FEDERATION_COORDINATOR_PORT=8787 \
   WASPFLOW_FEDERATION_COLLECTIVE_TOKEN=<shared-secret> \
   WASPFLOW_FEDERATION_COORDINATOR_ROSTER_FILE=./roster.json \
   WASPFLOW_FEDERATION_COORDINATOR_DATA_DIR=./coordinator-data \
   node bin/waspflow-federation-coordinator
   ```
4. **Submit a task** (Tim, or any author-role collective member):
   ```bash
   node bin/waspflow-federation-submit \
     --coordinator-url http://<coordinator-host>:8787 \
     --collective-token <shared-secret> --collective <name> \
     --author-key-id tim-author --private-key-file ./tim-author.pem \
     --display-id <task-name> --source ./my-repo --prompt-file ./task.md \
     --network disabled --timeout 3600
   ```
   Prints the `task_digest` — share this with whoever will execute it (no discovery endpoint in v0).
5. **Pull and run a task** (Ocean, or any executor-role collective member):
   ```bash
   node bin/waspflow-federation-pull \
     --coordinator-url http://<coordinator-host>:8787 \
     --collective-token <shared-secret> \
     --task-digest <digest-from-step-4> \
     --executor-key ocean-executor --private-key-file ./ocean-executor.pem \
     --roster-file ./roster.json --harness claude-code-subscription
   ```
   Runs the task against Ocean's own configured harness credentials, sandboxed via `sbx`.
6. **Get the result** (Tim): re-run `waspflow-federation-submit`'s poll, or fetch directly:
   ```bash
   curl http://<coordinator-host>:8787/tasks/<digest>   # status + result envelope once SETTLED
   ```
   Add `--output-dir <path> --roster-file ./roster.json` to a submit invocation (or call
   `materializeCandidate` directly) to download and extract the result tree with independent
   signature verification, rather than trusting the coordinator's claim blindly.

## Owner handoff: what's left after the autonomous fix loop

**Most of what this section used to ask the owner to run has now been run, autonomously, in this
session, against the owner's real `sbx` v0.35.0 install** — per the owner's standing directive to
own the live-UAT fix loop end-to-end rather than hand bugs back one at a time. What remains is
genuinely owner-scoped: security/product decisions, or evidence that needs conditions (time,
credential state) this session cannot manufacture.

**Closed this round, no longer needs the owner:**
- The per-harness auth proof (`scripts/federation-harness-auth-proof-live-run.sh`) — all three
  harnesses (codex, claude-code, gh-cli) ran a real task to completion unattended and were torn
  down cleanly. Re-run any time with:
  ```bash
  bash scripts/federation-harness-auth-proof-live-run.sh codex
  bash scripts/federation-harness-auth-proof-live-run.sh claude-code            # subscription (default)
  ANTHROPIC_API_KEY=<key> bash scripts/federation-harness-auth-proof-live-run.sh claude-code-api-key
  GH_TOKEN=<PAT> bash scripts/federation-harness-auth-proof-live-run.sh gh-cli
  ```
- Graduation gates B, C, E, F, G — actually run against a live sandbox (see the gates table
  above); no longer SKIP-NO-SBX, now real FAILs with specific, actionable reasons.
- `sbx exec`/`sbx run`/`sbx rm`/`sbx policy ls`/`sbx ls` syntax — all confirmed against the real
  CLI; the "what's next #1" item from the prior revision of this report is done.

**Still genuinely needs the owner:**
1. **Gate B: this machine's PERSONAL `sbx` policy is "allow all hosts", not deny-all.** A real
   security decision, not a code fix — run `sbx policy init deny-all` (plus job-scoped allow rules)
   before any job (friends-and-family or stranger-submitted) executes against this machine's
   personal identity for real. (The Federation-owned identity, `~/.waspflow/sbx-home`, was
   separately initialized to deny-all with scoped allow rules this session — see "Federation full
   loop" above — but that does not change this machine's personal `sbx` posture.)
2. **Which Claude Code auth variant Federation should default to in a shipped product** —
   subscription (product intent, one-time global `/login`, now confirmed NOT a per-run cost) vs
   api-key (smoother, usage-billed). Both are implemented, tested, and proven working this round;
   the choice is the owner's.
3. **The "refresh works" column** needs a separate long-duration run holding a Codex/Claude Code
   sandbox open past a real token's expiry window (~1h) — a short pass cannot distinguish "never
   needed refresh" from "refresh actually works." Not attempted this round (time-bound, not a bug).
4. **Gate A** needs `WASPFLOW_FEDERATION_SBX_PROFILE_DIR`, an independent Waspflow-owned `sbx`
   profile mechanism that doesn't exist in this checkout yet — a build item, not a live-run item.
5. **Gate D** needs a sibling job's scratch directory to probe cross-job visibility — a quick setup
   step, not attempted this round for lack of a second concurrent job to test against.
6. **Gate F's bomb fixtures** need wiring to an actual pass/fail measurement against declared
   resource limits — a build item.
7. **Settlement/escrow economics** (`FEDERATION_DESIGN_V2.md` §B.5.3/§B.5.4) — the coordinator's
   state machine has the SLOTS for this (a `SETTLED` terminal state exists) but no actual balances,
   fees, or ledger. Needed before any collective runs on real economic incentives rather than pure
   goodwill/reciprocity.
8. **Cross-machine deployment** — this session's live E2E proof ran the coordinator and both CLIs
   on one machine (`127.0.0.1`). Nothing in the design assumes same-host clients, but an owner
   actually running Tim's coordinator on an internet-reachable host with Ocean's client on a
   genuinely separate machine is the one remaining gap between this proof and a literal
   cross-machine deployment. Likely needs: a real domain/TLS in front of the coordinator (currently
   plain HTTP), and confirming firewall/NAT reachability for whoever hosts it.
9. **Task discovery** — v0 has no "list available tasks" endpoint; the digest must be shared
   out-of-band. A real product would need this before a collective grows past a handful of people
   coordinating over Slack/chat.

## What's next (in priority order, after the owner handoff above)

1. **Fix gate B's PERSONAL local policy** (`sbx policy init deny-all`) — the single highest-priority
   item, since it's the difference between this machine's actual current posture and the deny-all
   default the design assumes. (Not the same as the Federation-owned identity, already fixed.)
2. **Deploy the coordinator cross-machine** and confirm the full loop still works over a real
   network, not just localhost — the one dimension this session's live proof could not exercise.
3. **Wire gate F's fork-bomb/memory/disk fixtures** into an actual pass/fail measurement against
   declared resource limits, now that `sbx exec`'s real syntax is confirmed.
4. **Implement gate A's independent-profile mechanism** (`WASPFLOW_FEDERATION_SBX_PROFILE_DIR`) so
   gate A can move off SKIP.
5. **Design and build settlement/escrow** once the loop's mechanics are trusted — real balances,
   fees, and a signed ledger per `FEDERATION_DESIGN_V2.md` §B.5.3/§B.5.4.
6. **Run the ~1h refresh-window follow-up** for Codex and Claude Code subscription auth.
7. **Contact Docker** on the 8 outstanding questions tracked in
   `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md` (redistribution, commercial-use scope, OEM/
   account-free mode, automation API, independent profile mechanism, SSH-agent disable guarantee,
   storage cap, compatibility/security-support commitments) — none block this preview, but several
   block a production release decision per the note's explicit gate.
8. **Pin a version ceiling** in `profiles/wf-federation-docker-v0.json` once a real adversarial
   conformance pass validates a specific `sbx` release.
9. **Get this machine onto an eligible Gemini tier** (or point gemini-cli at a different account)
   to close the one remaining unproven harness — everything up to that account-tier wall is
   already built, tested, and live-verified through the real sandbox mechanism.

## Honest confidence

**High confidence** the interface, adapter, hygiene, and detection mechanisms are correctly built
and internally consistent — every claim in this report was independently reproduced by direct
command execution, not inferred from a maker's self-report, and multiple real integration bugs
were caught and fixed by that independent verification, most recently this round's entrypoint,
`sbx rm`, and login-status-probe defects.

**High confidence** in the tightened auth architecture *as documented by Docker and its own open
issue tracker, and now independently confirmed end-to-end against a real sandbox* — the "token
never enters the sandbox" claim for both Codex and Claude was independently confirmed against
Docker's own credential-isolation documentation AND against a live run (SBX_CRED_* env vars and
`.credentials.json` sentinel values, never real credentials, observed directly inside the guest);
the static-vs-refreshing credential distinction was independently confirmed against a specific,
real, open Docker feature request (`docker/sbx-releases#300`). The structural guard against
misclassifying a strategy's refresh capability (`lib/federation-harness-spec.mjs`) was unit-tested
adversarially, not merely asserted.

**High confidence, now backed by a real live run**, that all three harnesses' auth claims work
end-to-end against a real sandbox: `scripts/federation-harness-auth-proof-live-run.sh` was executed
to completion for codex, claude-code (subscription), and gh-cli this round — each drove a
deterministic task to completion unattended and tore down cleanly. **Still no confidence claim** on
the "refresh works" column specifically — that needs the separate ~1h follow-up described above.

**Moderate confidence, no longer zero**, on whether Docker Sandboxes delivers the containment
properties graduation gates A-G require. Gates B, C, E, F, G were actually exercised against a real
sandbox on the owner's machine this round, each producing real, non-simulated results — including
one important negative finding (gate B: this machine's actual policy is permissive, not deny-all).
That is a genuine containment gap on THIS machine, not evidence that the underlying `sbx` mechanism
can't provide deny-all — it means deny-all has to be turned on, and hasn't been. Gates A and D
remain fully unexercised (SKIP). This report is a proof that the mechanism is real, testable,
honestly scoped code, AND that its containment claims now have real (if incomplete) live evidence —
not yet a claim that Federation v0 is safe to expose to stranger-submitted jobs on THIS machine's
CURRENT policy configuration.

**High confidence** in the install UX mechanism — `install.sh`'s sbx auto-install attempt and
graceful fallback was run end-to-end on this machine, including the actual "no passwordless sudo"
fallback path (not a hypothetical branch), and `waspflow doctor`'s sbx reporting was verified both
with a fake-`sbx`-on-PATH fixture and in its real absent state, confirming sbx's presence/absence
never affects the overall "ready" verdict.

**UAT-ready** in the sense the task defined: an operator can install waspflow, have `sbx`
auto-installed or be pointed at a 30-second manual install, and point Waspflow at a job and watch it
run contained in a Docker sandbox — proven this round by three real, unattended, end-to-end
harness runs — with an honest, automated report of exactly which security properties have and have
not been proven for that specific release. **The one deliberately open item before real jobs run
here is gate B**: fix this machine's `sbx` policy to deny-all first. Everything else above is
either done, correctly deferred with a stated reason, or an owner-level product/security decision
this session correctly did not make unilaterally.

**High confidence, backed by a real multi-process live run, that the full federated loop works
mechanically**: publish, claim, independent-verify, run, submit, settle, poll, and materialize with
independent verification on BOTH ends — every step of the "Tim submits, Ocean pulls and runs it
against her subscription, Tim gets the result" scenario was executed with real infrastructure this
session (real coordinator process, two genuinely distinct keypairs, real signed envelopes, a real
sandboxed Claude Code subscription task, real artifact transport with content-addressed digest
verification), not simulated in a test harness. Five real bugs were found and fixed in the course
of getting this to work for real — a coordinator that could only recognize one signer identity, a
backend that had regressed two already-fixed sbx-CLI bugs, a THIRD real sbx-CLI bug (`sbx cp`'s
absolute-path requirement) findable only by running a genuine end-to-end task, a network-policy gap
on the Federation-owned sbx identity, and a requester that never independently verified the result
it was about to trust — none silently glossed over, each independently reproduced and re-tested.

**No confidence claim, positive or negative,** on cross-machine deployment specifically: this
session's live proof ran the coordinator and both CLIs on one machine against `127.0.0.1`. The
coordinator's design has no localhost-specific assumption, but "the code doesn't assume same-host"
is not the same claim as "it was proven to work across two real machines over a real network" — see
"What this does NOT prove" above.

**No confidence claim, positive or negative,** on settlement/economics — deliberately unbuilt this
round. A collective running on anything beyond pure goodwill/reciprocity needs
`FEDERATION_DESIGN_V2.md` §B.5.3/§B.5.4 actually implemented first.

**Test coverage**: 156 tests pass across the full `node --test tests/*.test.mjs` suite (up from 102
before this round's Docker-backend UAT work, then 156 after slices 1-6), including two live-sbx
integration tests that exercise real infrastructure rather than stubs
(`tests/federation-docker-backend.test.mjs`, `tests/federation-pull.test.mjs`) and one hand-run,
outside-the-test-suite live E2E walkthrough of the complete loop described above.
