# Federation v0 hygiene/detection maker report

## Revision

Base: rebased onto `waspflow/fedv0-docker-backend` @ `6509392` (`feat(federation):
DockerSbxBackend spike over the sbx CLI`) so `lib/federation-docker-backend.mjs`
(the parallel worker's file) is present in this worktree. This branch adds no
commits of its own to that file — it was rebased in unmodified, then this
work was layered on top (see "Changed files").

## What this covers

Per the 2026-07-20 decision note (`inbox/2026-07-20-chatgpt-sandbox.md`),
§"The Docker-specific issues that must be resolved" #1 and #3, and §"Mandatory
Docker Sandboxes graduation gates" A and C:

1. An `sbx` installer/detection stub (`bin/federation-detect-sbx`) that never
   downloads or bundles `sbx`, and enforces a pinned minimum version.
2. An independent credential/state hygiene test proving (a) `sanitizedEnv`
   strips personal credentials and (b) the Waspflow-owned sbx-HOME override
   code path is real and exercised, not merely asserted by inspection.

This is **detection/hygiene evidence only**. It does not itself satisfy
graduation gates A/C in full (those require testing on macOS/Linux/Windows
against a real `sbx` install with a hostile guest process, per the note) —
see "Untested boundaries" below and the sibling
`DOCKER_ADAPTER_MAKER_REPORT.md` for the backend's own honest gap list.

## 1. `bin/federation-detect-sbx`

A Node CLI (executable, shebang `#!/usr/bin/env node`), matching the style of
`bin/federation-envelope` since detection requires shelling out to `sbx
--version` and parsing output.

Behavior:
- Runs `sbx --version` via `spawnSync`. If the binary isn't found or exits
  non-zero, reports absent.
- Absent: prints `sbx not found on PATH. Install Docker Sandboxes from
  https://docs.docker.com/ai/sandboxes/get-started/ (do not bundle/redistribute
  — see decision note).` to **stderr**, exit code **1**. Waspflow does not
  attempt to download/bundle `sbx` — the note is explicit that redistribution
  rights are unresolved (§"Commercial use is allowed; redistribution is not
  established").
- Present: parses the version, checks it against
  `profiles/wf-federation-docker-v0.json`'s pinned `min_version`/`max_version`,
  and prints `federation-detect-sbx: sbx detected: version X.Y.Z` to
  **stdout**, exit code **0**. If below the pinned floor, treated as a failure
  (exit 1, stderr) rather than silently accepted — per the note's §H
  requirement not to assume a newly installed release is compatible.
- If no `max_version` is pinned yet (the current state — see below), a
  stderr warning is printed alongside the success message so a caller
  scraping stdout doesn't silently miss that the range is incomplete.

### `profiles/wf-federation-docker-v0.json`

New profile file, sibling to `profiles/wf-federation-linux-v0.json`. Pins only
a floor: `sbx.min_version = "0.35.0"` (the version cited in the decision note
as of its 2026-07-10 release). `max_version` is explicitly `null` — the note
warns against inventing a fake upper bound with false confidence, and I have
no real data on which later releases have passed the adversarial conformance
suite (§H). The file carries an `_owner_review_required` field spelling out
that the range is unreviewed and that this file must not be read as a
graduation-gate pass.

## 2. Credential/state hygiene proof — `tests/federation-docker-hygiene.test.mjs`

Written against the **actual** `lib/federation-docker-backend.mjs` that
landed from the parallel worker's lane (`waspflow/fed-docker-adapter`,
merged into `waspflow/fedv0-docker-backend` at `6509392`). The file did not
exist yet when this task started; I wrote the test to the spec's stated
import path/export name, and it later resolved via rebase (see "Sequence of
events" below). **All 4 tests currently pass against the real module** — this
is not a pending/blocked deliverable.

Tests:

1. **`sanitizedEnv` strips every personal-credential/state variable and keeps
   harmless ones** — builds a dirty env with `SSH_AUTH_SOCK`, `DOCKER_HOST`,
   `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `AWS_ACCESS_KEY_ID`,
   `GCP_SERVICE_ACCOUNT`, `AZURE_CLIENT_SECRET`, `GIT_ASKPASS`, `GH_TOKEN` set,
   runs it through `sanitizedEnv()`, and asserts each key is **absent**
   (`Object.hasOwn` false, not just falsy) from the result. Also asserts
   `PATH`/`HOME` survive unchanged, proving the function isn't a blunt
   allowlist that nukes everything.
2. **`sanitizedEnv` strips `*_API_KEY`/`*_TOKEN` patterns generically** — a
   synthetic `SOME_RANDOM_API_KEY`/`SOME_RANDOM_TOKEN` pair not in any
   hardcoded list, proving the strip logic is pattern-based rather than an
   exact-match table that would miss unanticipated provider keys.
3. **`_internal.sbxHome()` honors `WASPFLOW_FEDERATION_SBX_HOME` and differs
   from the real HOME by default** — calls the exported `_internal.sbxHome()`
   helper with no override set (asserts it still isn't the real user's
   `$HOME` — it defaults to `~/.waspflow/sbx-home`), then sets the env var and
   asserts the override is honored.
4. **The real `sbx` child-process invocation carries the Waspflow-owned HOME
   override, not the real HOME** — this is the "prove the code path is
   exercised, not just asserted by inspection" test the task called for. It
   writes a throwaway shell stub standing in for `sbx` (this machine doesn't
   have `sbx` installed) that echoes `$HOME` back, points `WASPFLOW_SBX_BIN`
   at the stub and `WASPFLOW_FEDERATION_SBX_HOME` at a synthetic directory,
   then calls `new DockerSbxBackend().probeCapabilities()` — the actual
   backend method that shells out via `execFile(sbxBin(), ..., { env:
   sbxChildEnv() })`. Asserts the stub's reported `$HOME` matches the
   Waspflow-owned override and does not match the real `os.homedir()`. This
   exercises `sbxChildEnv()` (not itself exported) indirectly through the
   real public API, rather than re-implementing or guessing its internals.

Note on the module's actual design (differs slightly from my initial
assumption before the file landed): `sanitizedEnv()` does not itself special-
case `WASPFLOW_FEDERATION_SBX_HOME`; separation is achieved by `sbxChildEnv()`
overwriting `HOME` on the sanitized env using `_internal.sbxHome()`, which
reads `WASPFLOW_FEDERATION_SBX_HOME` or falls back to
`~/.waspflow/sbx-home`. Test 4 was written to match that real shape rather
than an assumed one.

## Sequence of events (for the record)

The task spec anticipated `lib/federation-docker-backend.mjs` might not exist
yet when I started, and it didn't — I wrote `bin/federation-detect-sbx`,
`profiles/wf-federation-docker-v0.json`, and the hygiene test file (initially
against the spec's assumed shape) with the module absent, confirmed the test
file skipped cleanly (`node --test` → 3 skipped, exit 0) rather than failing.
I then ran `bash scripts/verify.sh`, which failed once at an unrelated line
(`resume-arm` escalation fixture in the Claude/Codex/Grok provider tests, line
~2820) — I reproduced this on the **unmodified base tree** (my new files
moved aside) and it passed clean on a second run, confirming this is a
pre-existing flake in that fixture, not something introduced by this work.
While investigating, `origin` was fetched and `lib/federation-docker-backend.mjs`
was found already merged into `waspflow/fedv0-docker-backend` (one commit
ahead of this branch's original base). I rebased onto that branch (clean
fast-forward, no conflicts, since this branch had no prior commits of its
own), corrected test 3/4 to match the module's real `_internal.sbxHome()` /
`sbxChildEnv()` shape instead of the guessed shape, and re-ran everything.

## Changed files

- `bin/federation-detect-sbx` (new)
- `profiles/wf-federation-docker-v0.json` (new)
- `tests/federation-docker-hygiene.test.mjs` (new)
- `docs/design/federation-evidence/HYGIENE_DETECTION_MAKER_REPORT.md` (this file)

Not touched: `lib/federation-docker-backend.mjs` (parallel worker's file, per
instructions).

## Commands and raw results

```text
$ node --check bin/federation-detect-sbx
(no output — syntax ok)

$ ./bin/federation-detect-sbx
federation-detect-sbx: sbx not found on PATH. Install Docker Sandboxes from https://docs.docker.com/ai/sandboxes/get-started/ (do not bundle/redistribute — see decision note).
$ echo $?
1
```

(Verified separately that this message and only this message goes to stderr,
stdout is empty, for the absent case — matches the spec's stdout/stderr
convention.)

```text
$ node --test tests/federation-docker-hygiene.test.mjs
✔ sanitizedEnv strips every personal-credential/state variable and keeps harmless ones
✔ sanitizedEnv strips *_API_KEY/*_TOKEN patterns generically, not just the named examples
✔ _internal.sbxHome() honors WASPFLOW_FEDERATION_SBX_HOME and differs from the real HOME by default
✔ the real sbx child-process invocation carries the Waspflow-owned HOME override, not the real HOME
ℹ tests 4
ℹ pass 4
ℹ fail 0
ℹ skipped 0
```

```text
$ bash scripts/verify.sh
...
waspflow verify: ok
$ echo $?
0
```

(Full verify.sh run against the final rebased tree, including all three new
files above. Passed clean on this run; see the note above about one
transient, independently-reproduced-on-clean-tree failure encountered earlier
in an unrelated `resume-arm` escalation fixture.)

## Untested boundaries

- **No real `sbx` binary exists on this machine.** `bin/federation-detect-sbx`
  was only exercised in the "absent" branch. The "present" branch (version
  parsing, floor/ceiling comparison, the success message format) is exercised
  only by code review and `node --check`, not by an actual `sbx --version`
  run. This mirrors the same limitation the decision note anticipates for the
  whole Docker backend track.
- **`profiles/wf-federation-docker-v0.json`'s version range is a floor only,
  explicitly unreviewed.** No upper bound; the file says so. Someone with
  owner authority needs to decide the real supported range after running the
  adversarial conformance suite (§H) against candidate releases.
- **This hygiene test proves the mechanism exists and is exercised, not that
  it is sufficient.** It does not run inside a real `sbx`-provisioned VM, does
  not run as a hostile guest process (graduation gate C requires that), and
  does not test on macOS/Windows. It also does not test the case where a
  user's personal `sbx` already has global secrets/kits/registry credentials
  configured on the same machine (gate C explicitly requires testing "after
  configuring personal Docker Sandboxes ... with realistic developer
  credentials" — not attempted here).
- **`WASPFLOW_FEDERATION_SBX_HOME` defaulting to `~/.waspflow/sbx-home`** is
  the "last resort" isolation option per the note's numbered preference list
  (a distinct OS-level identity via a Waspflow-owned HOME) — not the
  preferred "supported, independent `sbx` profile" (option 1), which the
  backend's own comments say does not yet have a documented mechanism from
  Docker. This test proves the current fallback mechanism works; it does not
  and cannot prove Docker's global-secret/kit/registry-credential inheritance
  is actually blocked by a different `HOME` alone — that requires a real `sbx`
  install and is explicitly out of scope for this maker's task.

## Confidence

**High** that `bin/federation-detect-sbx` behaves correctly for the "absent"
case (the only case reachable on this machine) and follows existing
`bin/federation-*` stdout/stderr/exit-code conventions. **High** that the
hygiene test proves what it claims to prove — both `sanitizedEnv` key removal
and the `WASPFLOW_FEDERATION_SBX_HOME` code path are exercised against the
real module, not asserted by inspection, and all 4 tests pass. **Low** on
whether the underlying isolation mechanism (a distinct `HOME` directory) is
itself sufficient against a real `sbx` — that is explicitly graduation gate A
territory, owned by a real-`sbx` conformance pass this task did not attempt.
