# Federation v0 Docker Sandboxes conformance suite — maker report

## Revision

Base: `479fd7f` (`feat(federation): backend-neutral SandboxBackend interface +
ValidatedJobSpec`), branch `waspflow/fed-conformance`, branched from
`waspflow/fedv0-docker-backend`.

## Task

Build the graduation-gate adversarial conformance test suite for gates A-I of
`inbox/2026-07-20-chatgpt-sandbox.md` (the Runtime Decision note), against
Docker Sandboxes (`sbx`) as the backend. `sbx` is **not installed** on this
machine; Docker itself is (`docker --version` → `29.6.0`).

## What runs for real today

### Gate H — version-pinned conformance testing

This is the one gate the note explicitly says can run without a live sbx
install, and it does: `tests/federation-docker-conformance.sh`'s
`gate_h_version_pinned_conformance` looks for a version-pinning detection
mechanism at `bin/federation-detect-sbx` or `profiles/wf-federation-docker-v0.json`.

**Neither exists in this checkout as of this suite's authorship.** The two
sibling worktrees building Docker-backend and hygiene/detection work
(`waspflow/fed-docker-adapter`, `waspflow/fed-hygiene-detect`) were both still
at the same base commit (`479fd7f`, no divergent commits) when checked, so
this is an honest absence, not a missed file. Gate H therefore SKIPs today
with `"version-pinning detection not yet implemented"`, exactly as the task
brief said to do in that case.

The stub-`sbx`-on-PATH harness itself is proven correct, not just written.
I built a throwaway `bin/federation-detect-sbx` that enforces a contrived
`0.30.0-0.40.0` supported range, pointed the suite at a copy of the repo
containing it, and ran the real gate:

```text
$ sbx version   # (stub, mktemp'd, chmod +x, PATH-prepended, cleaned via trap)
sbx version 99.99.99-bogus-out-of-range

$ bash tests/federation-docker-conformance.sh   # (against the copy with the throwaway detector)
PASS: H: version-pinned conformance testing — bin/federation-detect-sbx correctly
refused a stubbed out-of-range sbx version
```

This confirms the mechanism works: the moment `bin/federation-detect-sbx` or
`profiles/wf-federation-docker-v0.json` lands for real, gate H starts passing
or failing for real with no changes needed to this suite. That throwaway
detector and its copy of the repo were deleted after the check; nothing from
that experiment is committed.

### Gate I — legal and product confirmation from Docker (documentation gate)

This is a documentation-completeness check, not a legal resolution. It
verifies that `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md` exists and
explicitly lists all eight of Docker's outstanding legal/product questions
(redistribution, commercial use, OEM/account-free mode, automation API,
independent profile mechanism, SSH-agent disable guarantee, storage cap,
compatibility/security-support commitments) as **outstanding/unanswered** —
none have been obtained, and the suite would FAIL if the matrix claimed
otherwise or omitted the acknowledgment. This gate currently reports **PASS**
because the matrix does correctly record the gap. It is not a claim that
Docker answered anything.

```text
PASS: I: legal and product confirmation from Docker — conformance matrix exists
and explicitly lists all eight Docker legal/product questions as
outstanding/unanswered — no answers have been obtained, none are fabricated
```

## What's structurally present but skipped

Gates A-G each have a real bash function in
`tests/federation-docker-conformance.sh` that:

1. SKIPs immediately with `"sbx not installed"` if `sbx` is not on PATH.
2. Otherwise SKIPs with a specific reason if
   `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX` (an operator-provided live
   sandbox name/handle) is unset — some gates need additional env vars
   (`WASPFLOW_FEDERATION_SBX_PROFILE_DIR` for A,
   `WASPFLOW_FEDERATION_CONFORMANCE_SIBLING_SCRATCH` for D).
3. Otherwise attempts the real host-side assertion the note's adversarial
   list calls for (`sbx policy inspect`/`policy check network` for B,
   guest-exec credential probes for C, sibling-scratch visibility for D, a
   guest TCP listener probed from the host for E, `sbx destroy` + independent
   `sbx list` re-check for G) and returns FAIL rather than PASS whenever the
   check only partially covers the note's requirement — see the per-gate
   caveats in each function and in the matrix doc.

Gate F additionally ships real, callable (not merely commented) fixture
functions — `gate_f_fork_bomb_check`, `gate_f_memory_exhaustion_check`,
`gate_f_disk_fill_check` — that are not yet wired into a pass/fail
measurement against a declared limit contract; that wiring is a documented
follow-up, not a placeholder stub.

None of gates A-G can be exercised in this environment because `sbx` is not
installed, so today they all SKIP at step 1. This was proven, not assumed —
`command -v sbx` fails on this machine (confirmed before writing the suite).

Full detail on exactly what each gate checks, what's covered vs. not yet
covered from the note's adversarial list, and how to run it live is in
[`FEDERATION_V0_CONFORMANCE_MATRIX.md`](../FEDERATION_V0_CONFORMANCE_MATRIX.md).

## What remains for a privileged/real-sbx follow-up run

An owner with a real `sbx` install runs
[`scripts/federation-conformance-live-run.sh`](../../../scripts/federation-conformance-live-run.sh),
which:

1. Requires `sbx` on PATH and `WASPFLOW_FEDERATION_CONFORMANCE_SANDBOX` set.
2. Re-runs `tests/federation-docker-conformance.sh` with the live sandbox
   wired in, so gates A-E and G attempt their real checks instead of
   SKIPping.
3. Separately runs the gate F bomb fixtures with bounded timeouts and prints
   PASS-CANDIDATE/FAIL-CANDIDATE lines (labeled "candidate" because they are
   not yet an automated pass/fail gate — an owner must read the output).
4. Prints manual instructions for the gate G daemon-restart/reboot survival
   check, which needs a host action this script cannot itself perform.
5. Reminds the operator that gate I's eight questions remain unanswered and
   this script cannot answer them.

Gate C additionally requires the operator to configure **personal** Docker
Sandboxes with realistic developer credentials on the same machine first —
the note is explicit that testing only a clean machine is insufficient, and
the live-run script's usage comment says so.

## Commands and raw results

```text
$ command -v sbx; echo "rc=$?"
sbx not found
rc=1

$ docker --version
Docker version 29.6.0, build fb59821

$ bash -n tests/federation-docker-conformance.sh scripts/federation-conformance-live-run.sh
(exit 0)

$ bash tests/federation-docker-conformance.sh
SKIP: A: independent security domain — sbx not installed — gate A requires a real sbx sandbox to execute
SKIP: B: locked-down effective policy — sbx not installed — gate B requires a real sbx sandbox to execute
SKIP: C: credential-negative guest — sbx not installed — gate C requires a hostile guest process inside a real sbx sandbox to execute
SKIP: D: disposable filesystem boundary — sbx not installed — gate D requires a real sbx sandbox to execute
SKIP: E: no inbound exposure — sbx not installed — gate E requires a real sbx sandbox to execute
SKIP: F: enforceable resource limits — sbx not installed — gate F requires a real sbx sandbox to execute
SKIP: G: reliable teardown and orphan recovery — sbx not installed — gate G requires a real sbx sandbox to execute
SKIP: H: version-pinned conformance testing — version-pinning detection not yet implemented — neither bin/federation-detect-sbx nor profiles/wf-federation-docker-v0.json exists in this checkout
PASS: I: legal and product confirmation from Docker — conformance matrix exists and explicitly lists all eight Docker legal/product questions as outstanding/unanswered — no answers have been obtained, none are fabricated

PASS=1 FAIL=0 SKIP=8 (total 9)
RESULT: OK — no runnable gate failed (SKIPs require a real sbx + live sandbox follow-up)
(exit 0)

$ bash scripts/verify.sh
...
federation runner conformance: ok
waspflow verify: ok
(exit 0)

$ node --test tests/federation-runtime.test.mjs
ℹ tests 30
ℹ pass 30
ℹ fail 0
```

`scripts/verify.sh` was run to completion twice (once backgrounded, once in
the foreground as confirmation) and passed both times with no new failures
introduced by this change. `tests/federation-runtime.test.mjs` (30/30) and
`tests/federation-runner.sh` (unchanged, still passing as part of
`scripts/verify.sh`) were not modified by this work; they're cited here only
to confirm nothing regressed.

A separate resume-arm escalation fixture (`verify.sh` line ~2820) has been
observed to fail intermittently in sibling worktrees running concurrently
against the same base commit. Tim independently reproduced the same failure
on the `waspflow/fed-docker-adapter` lane and confirmed by inspection that
`scripts/verify.sh` contains no reference to any `federation-docker*` file —
it is pre-existing flakiness unrelated to this suite, not something this
change caused or fixed. Both of *this* worktree's own `verify.sh` runs
completed with `waspflow verify: ok` and exit 0; that fixture did not fail
here.

## Untested boundaries

- No live `sbx` sandbox exists in this environment, so gates A, B, C, D, E, F,
  G were never exercised against real Docker Sandboxes — only their SKIP path
  was exercised.
- Gate H's detection mechanism does not exist in this checkout; only a
  throwaway, non-committed stand-in proved the harness would detect it
  correctly once built.
- Gate F's bomb-fixture functions exist and are callable but have no
  automated pass/fail wiring against a resource-limit contract yet.
- The note's full adversarial list (DNS exfiltration, UDP/ICMP,
  IPv6-private-range scanning, proxy tunnels, inode exhaustion, unbounded
  output, deadline-survival, malicious-archive-in-output) is not fully
  1:1 covered by discrete functions — the matrix doc's coverage table marks
  each of these as an explicit documented gap rather than silently omitting
  them.
- Gate I is a documentation-completeness check; it says nothing about
  whether Docker's answers, once obtained, will be favorable.

## Confidence

**High** that gate H's detection-refusal mechanism works correctly once a
detector exists, because I proved it against a throwaway stand-in rather than
assuming it. **High** that gate I's documentation-completeness check is
correct and non-fabricated. **No confidence claim, positive or negative**, on
gates A-G's actual containment properties — they were never exercised, and
the suite says so explicitly rather than defaulting to PASS. This suite is
new, real, runnable code an operator can point at a live sbx sandbox later;
it is not a report that federation is Docker-conformant today.
