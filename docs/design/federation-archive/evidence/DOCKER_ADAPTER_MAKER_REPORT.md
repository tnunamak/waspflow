# Federation v0 Docker adapter maker report

## Revision

Base: `479fd7f` (`feat(federation): backend-neutral SandboxBackend interface + ValidatedJobSpec`).

## Scope

This report covers `DockerSbxBackend`, a `SandboxBackend` implementation (per
`lib/federation-runtime.mjs`) over Docker Sandboxes' `sbx` CLI, per the
Runtime Decision (`inbox/2026-07-20-chatgpt-sandbox.md`). This is the
**mechanism**: interface conformance, error handling, and the workspace/
credential safety boundary. It is explicitly **not** a claim that any
containment/security gate (A-I in the decision note) passes — those require
an adversarial conformance suite run against a real `sbx` install, which is
out of scope here and was not attempted. `sbx` is not installed on this
machine; every behavior that requires a live binary is either exercised
against a stub executable or explicitly marked unverified below.

## What was built

- `lib/federation-docker-backend.mjs` — `DockerSbxBackend extends SandboxBackend`
  implementing all seven interface methods (`probeCapabilities`, `prepare`,
  `start`, `streamLogs`, `collectDeclaredOutputs`, `cancel`, `destroy`,
  `inspect`), plus an exported `sanitizedEnv(baseEnv)` helper.
- `tests/federation-docker-backend.test.mjs` — `node:test` suite, dependency-free.

### Design decisions

- **No new npm dependencies.** Uses `node:child_process` (`execFile`,
  promisified), `node:fs/promises`, `node:crypto`, `node:os`, `node:path` only.
  `package.json` has no runtime dependencies and none were added.
- **Disposable scratch workspace.** `prepare()` creates a unique directory
  under `os.tmpdir()` (or `WASPFLOW_FEDERATION_SCRATCH_ROOT` if set) via
  `mkdtemp`, named `wf-job-<sandboxId>-XXXXXX`, and passes only that directory
  to `sbx run` as the workspace argument — never the repo checkout, a real
  home directory, or any caller-supplied host path (`ValidatedJobSpec` cannot
  carry a host path at all; see `FORBIDDEN_FIELDS` in `federation-runtime.mjs`).
  A stub-backed test (`prepare() invokes 'sbx run' with the scratch dir as
  workspace...`) asserts the invocation contains the scratch dir and does not
  contain `process.cwd()`.
- **Job-scoped sandbox naming.** `sandboxNameFor(job_id)` derives a stable
  `wf-<sha256-prefix16>` name so `prepare`/`destroy`/`inspect` on the same job
  agree, without leaking the raw `job_id` string verbatim into `sbx` argv.
- **Sanitized environment on every `sbx` child process.** `sanitizedEnv(baseEnv)`
  strips, by exact name: `SSH_AUTH_SOCK`, `DOCKER_HOST`. By pattern (case-
  insensitive): `*_API_KEY`, `*_TOKEN`, and anything prefixed `AWS_`, `GCP_`,
  `GOOGLE_`, `AZURE_`, `GIT_`, `GH_`, `GITHUB_`, `DOCKER_`, `NPM_`, `OPENAI_`,
  `ANTHROPIC_`. It is exported under that exact name for an independent
  hygiene test to import, as requested. It does not mutate its input.
- **Separate Waspflow sbx identity.** Every `sbx` child process gets
  `HOME` overridden to `WASPFLOW_FEDERATION_SBX_HOME` (default
  `~/.waspflow/sbx-home`). The decision note (§1) states there is no
  documented cross-platform `sbx` profile/config-dir flag; this is explicitly
  the **last-resort "distinct OS-level identity"** option from that section's
  numbered list, called out in a code comment, pending Docker confirming a
  supported profile mechanism (graduation gate A / decision-note item 12). It
  is not presented as equivalent to a supported profile mechanism.
- **No credentials configured.** The backend never calls any `sbx` secret/
  credential-configuration subcommand. It relies on (a) the sanitized
  environment above and (b) the separate `HOME` so no personal global `sbx`
  secrets are even reachable from the Waspflow identity. Per-job secrets are
  out of scope for v0 per the decision note; none are wired in.
- **`collectDeclaredOutputs` safety.** Rejects any manifest path that is
  absolute, contains `\0`, or has a `.`/`..` path segment, *before* touching
  `sbx` at all (mirrors the traversal-rejection shape of `isRelativeSafePath`
  in `federation-runtime.mjs` and `forbidden()`/`artifact()` in
  `federation-envelope.mjs`, not imported from them — this module has no
  dependency on either). After copy-out, it `lstat`s the local destination and
  refuses (rather than silently following) a symlink, and requires the result
  to be a regular file. Every collected output returns `{path, sha256, bytes}`
  computed from the copied-out bytes.
- **`destroy()` never trusts exit code alone.** Calls `sbx rm`, then calls
  `sbx ls` and greps for the sandbox name in the output to *independently*
  confirm absence. If still present, retries the `rm` once, then reports
  `removed:false` honestly (does not throw, does not claim success) if the
  sandbox is still listed after the retry. Scratch-directory removal is
  verified the same way (`stat` after `rm` must ENOENT) and reported as
  `scratch_removed` in the `CleanupReceipt`.
- **`probeCapabilities()` never throws for "not installed."** Distinguishes
  `ENOENT` (binary absent → `{available:false, missing_prerequisites, install_hint}`)
  from any other failure mode (binary present, some other error → treated as
  available, since only `ENOENT` means "not installed").
- **`cancel()` uses `sbx stop`** (preserves sandbox state) rather than `sbx rm`,
  since `destroy()` is the caller's separate, explicit teardown step per the
  interface contract.

### Marked-unverified CLI surfaces

Two spots are marked in the source with `// UNVERIFIED SBX SYNTAX:` comments,
exactly as scoped:

1. `_copyIn` / `collectDeclaredOutputs` — `sbx cp <name>:<remote-path>
   <local-path>` (and the reverse direction), modeled on `docker cp`
   conventions. Not confirmed against `sbx cp --help`.
2. `start()` — `sbx exec <name> -- <cmd...>`, modeled on `docker exec`.
   Not confirmed against `sbx exec --help`; the exact flag (if any) for
   detached/backgrounded execution is also unconfirmed, which matters for
   `streamLogs()` being a true live tail versus (as currently implemented) a
   replay of the captured stdout/stderr from the `start()` call.

## Changed files

- `lib/federation-docker-backend.mjs` (new)
- `tests/federation-docker-backend.test.mjs` (new)
- `docs/design/federation-evidence/DOCKER_ADAPTER_MAKER_REPORT.md` (this file)

## Commands and raw results

```text
$ node --check lib/federation-docker-backend.mjs
(exit 0, no output)

$ node --test tests/federation-docker-backend.test.mjs
✔ sanitizedEnv strips SSH agent and DOCKER_HOST exactly
✔ sanitizedEnv strips *_API_KEY and *_TOKEN patterns
✔ sanitizedEnv strips cloud provider and git credential-helper vars
✔ sanitizedEnv is non-mutating and tolerates empty/undefined input
✔ scratch directory creation produces a unique, disposable directory per job
✔ sandbox names are deterministic per job_id and distinct across jobs
✔ isSafeRelativeOutputPath rejects traversal, absolute paths, and NUL bytes
✔ collectDeclaredOutputs rejects an unsafe manifest path before touching sbx
✔ collectDeclaredOutputs rejects a copied-out symlink instead of following it
✔ probeCapabilities reports unavailable (never throws) when sbx is missing
✔ probeCapabilities reports available:true and forwards version via a stub sbx
✔ prepare() invokes `sbx run` with the scratch dir as workspace, never a real repo path
✔ destroy() independently verifies removal via `sbx ls` rather than trusting `sbx rm` exit code
SKIP: sbx not installed — skipping live sbx integration test
✔ destroy() honestly reports removed:false when `sbx ls` still shows the sandbox after retry
﹣ live sbx integration (real binary) (# sbx not installed)
tests 15
pass 14
fail 0
skipped 1

$ node --test tests/federation-runtime.test.mjs tests/federation-envelope.test.mjs
tests 38
pass 38
fail 0

$ command -v sbx || true
(no output — sbx is not installed on this machine)

$ git diff --check
(exit 0, no output)

$ bash scripts/verify.sh
(exit 0 — full hermetic suite green; scripts/verify.sh does not yet invoke
tests/federation-docker-backend.test.mjs directly, so it was run standalone
via node --test above)
```

Note on `scripts/verify.sh`: it does not currently `node --test` any of the
`tests/federation-*.test.mjs` files directly (only `bash
tests/federation-runner.sh` is wired in). A subsequent re-run for this report
hit an unrelated pre-existing failure in a Claude/Codex/Grok
`resume_with_arm` escalation fixture (line ~2820, model-selection control
loop code, unrelated to sandboxing). `scripts/verify.sh` does not reference
`federation-docker-backend` anywhere (`grep` confirms zero hits), so this is
not attributable to this change; it was not introduced by this diff and no
file this backend touches is exercised by that fixture.

## What could not be verified — unverified pending real sbx

Everything below requires a real `sbx` binary and a real Docker Sandboxes
install and was **not** exercised. Listed honestly rather than assumed:

- **Exact CLI flag syntax for `sbx exec` and `sbx cp`** (see "Marked-unverified
  CLI surfaces" above). The implementation is a best-guess; it may need
  argument-order or flag-name fixes once run against `sbx --help` output.
- **Whether `sbx run --name <name> <workspace> <image>` is the correct
  positional argument order and flag set.** Docker's own docs were incomplete
  per the task brief; this was implemented from the note's description
  and common CLI conventions, not confirmed against `sbx run --help`.
- **Whether `HOME` override actually yields a separate `sbx` daemon
  state/policy/credential domain**, as opposed to `sbx` reading some other
  fixed OS-level path (e.g. a system service socket shared regardless of
  `HOME`). This is exactly graduation gate A and decision-note item 12/5 —
  unverified, and explicitly flagged in-code as the last-resort option
  pending a documented Docker profile mechanism.
- **Whether `sbx ls` output format is stable/parseable** the way this backend
  assumes (name in the first whitespace-delimited column). Only exercised
  against a hand-written stub, not real output.
- **Whether `destroy()`'s retry-once-then-report-honestly loop is sufficient**
  against real `sbx rm` latency/eventual-consistency behavior, or whether a
  longer poll/backoff is required in practice.
- **Whether `sbx --version` reliably distinguishes "not installed" (ENOENT)
  from "installed but broken/misconfigured."** `probeCapabilities()` treats
  any non-ENOENT failure as "available" for the version string only, which
  may be wrong if `sbx --version` can itself hard-fail on an unauthenticated
  or misconfigured install (relevant to the note's "Docker account is a
  product dependency" and "organization governance fail-closed" concerns —
  gate not addressed by this backend).
- **`streamLogs()` is a replay of captured `start()` output, not a true live
  tail.** Whether `sbx exec` supports incremental/streaming output capture
  (vs. buffering until exit) is unknown; if a job runs long and produces
  output before completing, this implementation will not surface it until
  `start()` returns.
- **Network policy (`sbx policy init deny-all`, per-sandbox allow/deny rules),
  resource limits (CPU/memory/storage/process/output/network caps), port
  non-publication, and orphan reconciliation on startup are entirely
  unimplemented in this module.** They are out of this task's scope (the note
  frames them as separate graduation gates B, E, F, G) — flagging so this
  isn't mistaken for a completed security boundary.
- **No adversarial/hostile-guest testing was performed or claimed** —
  credential-negative execution (gate C), disposable-filesystem boundary from
  inside a guest (gate D), and the full adversarial acceptance suite in the
  decision note are unaddressed here and require a real sandbox to attempt at
  all.

## Explicit non-claims

This report does **not** claim: that Docker Sandboxes provides adequate
isolation for stranger-submitted jobs, that the Waspflow sbx identity is
actually separate from a developer's personal `sbx` config, that no
credential can leak into a guest, that teardown is race-free under real `sbx`
timing, or that any of the mandatory graduation gates A-I pass. Those require
the separate conformance suite the task brief calls out, run against a real
`sbx` install on each target OS.
