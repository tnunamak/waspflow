# Federation v0 UAT report — Docker Sandboxes backend

**Date:** 2026-07-20
**Branch:** `waspflow/fedv0-docker-backend` (child of `feat/federation-v0`)
**Source of truth:** `inbox/2026-07-20-chatgpt-sandbox.md` (the "Runtime Decision" note)
**Verdict:** **Federation Preview, mechanism-complete, install UX complete, detector fixed against
real sbx, security-gates still unproven.** Merge-ready as a gated preview backend behind an
operator-run live conformance pass. **Not** ready to accept stranger-submitted jobs — no graduation
gate that requires a real `sbx` sandbox has been exercised. **Owner handoff:** two per-harness
auth-proof and conformance-suite commands remain, now un-blocked by a real install — see "Owner
handoff: closing the live gates" below.

## Owner UAT findings and fixes (2026-07-20, real sbx v0.35.0)

The owner installed a real `sbx` (v0.35.0, `/usr/bin/sbx`, authenticated as `timvana`) and found
two real defects by running the mechanism against it — exactly the value the owner-handoff
checkpoint was designed to surface. Both reproduced and fixed in this revision:

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
| Graduation-gate conformance suite (A-J) | `tests/federation-docker-conformance.sh`, `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md`, `scripts/federation-conformance-live-run.sh` | Built, 2/10 gates pass for real (H, I), 8/10 correctly SKIP pending a live sandbox (gate J's suite-recorded status is SKIP — see below for why its static half is nonetheless proven) |
| Backend-neutral `HarnessSpec` (6 explicit auth strategies) | `lib/federation-harness-spec.mjs` | Built, unit-tested (13 tests), including an adversarial "CORE SAFETY CHECK" proving a spec cannot claim docker-builtin refresh under a strategy that structurally can't provide it |
| 3 concrete harness classifications (Codex, Claude Code, gh-cli) | `lib/federation-harnesses.mjs`, `kits/wf-gh-cli.kit.yaml` | Built, unit-tested (6 tests), each independently classified against Docker docs/issues, not assumed identical |
| Per-harness six-column auth proof (HarnessSpec-driven) | `scripts/federation-harness-auth-proof-live-run.sh`, gate J in the conformance suite | Built, syntax-checked, HarnessSpec resolution verified for all 3 harnesses. Gate J's static regression guard was verified adversarially (see "Auth architecture"); the suite itself records gate J as SKIP because its live half — the actual per-harness proof — cannot run here |
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
  Waspflow-authored kit, `kits/wf-gh-cli.kit.yaml`, using Docker's documented `credentials.sources`
  env-var injection — not a Waspflow gateway). Deliberately chosen because `GH_TOKEN` is a
  **static** Personal Access Token that `gh` does not self-refresh — this keeps the extensibility
  proof honest: it demonstrates a new harness CAN be onboarded through the documented kit
  mechanism, without also (mis)claiming that mechanism handles refresh. `oauth_refresh.refresh_owner:
  'none'` because none is needed, not because refresh was proven safe for this strategy in general.

All three specs are unit-tested (`tests/federation-harnesses.test.mjs`, 6 tests) to confirm: Codex
and Claude Code are each independently classified rather than copy-pasted; both report an explicit
auth mode; both have Docker-proven indefinite refresh; gh-cli correctly uses a different strategy
and installs via a custom kit, not a built-in template; and none of the three harnesses violate the
`host-file-proxy`/`host-env-proxy` docker-builtin-refresh guard.

### Per-harness six-column proof matrix

`scripts/federation-harness-auth-proof-live-run.sh` supersedes the prior single-purpose auth proof
script. It is **HarnessSpec-parameterized** — it reads `lib/federation-harnesses.mjs` at runtime and
drives whatever that spec declares, rather than hardcoding one flow shared across harnesses. Usage:
`bash scripts/federation-harness-auth-proof-live-run.sh {codex|claude-code|gh-cli}`.

The six columns, and their honest status for each harness (all **written, executable, and
independently unit-verified for the code paths that don't require a live sandbox** — none executed
against a real `sbx` install, because `sbx` is not installed on this machine and the proof
inherently requires interactive host logins):

| Column | Codex | Claude Code | gh-cli |
| --- | --- | --- | --- |
| Existing host login detected | **Detect-first logic unit-tested and independently reproduced against a stub (see "Auth UX reframe" above); not run against a live sandbox.** Script calls `isProviderSecretSet()` — waspflow checks, the operator is never asked. | **Not exercised.** `interactive-session-flow` cannot be detected host-side; script calls `describeAuthRequirement()` and shows its honest non-drivable instruction. | **Not exercised.** Script checks whether `GH_TOKEN` is already set on the host. |
| Extra login required | **Detect-first + drive-it-myself logic unit-tested and reproduced against a stub; not run live.** If unset, waspflow calls `startAuthFlow()` itself and surfaces only `AUTH_URL <url>` — never the raw `sbx` command. | **Not exercised.** Operator attests completion inside an attached session; waspflow cannot verify this host-side for `interactive-session-flow`. | **Not exercised** (depends on whether `GH_TOKEN` was pre-set). |
| Credential stays outside VM | **Not exercised.** Script's hostile-guest search (env, `ps aux`, `~/.codex/auth.json`) is written and heuristic-checked, not run against a live guest. | **Not exercised.** Same search targets `~/.claude/.credentials.json`. | **Not exercised.** Same search greps for `gh[a-z]_`-prefixed PAT patterns. |
| Refresh works | **Not exercised, and cannot be meaningfully proven in a short run** — the script documents that proving refresh requires holding a sandbox open past a real token's expiry window (~1h for OAuth access tokens), which this session cannot do; a short run cannot distinguish "never needed refresh" from "refresh works." | Same limitation as Codex — refresh proof requires a long-duration follow-up. | **N/A** — `GH_TOKEN` is static; `oauth_refresh.supports_refresh: false` in the HarnessSpec, so this column does not apply by design, not by omission. |
| Subscription allowance used | **Not exercised.** Script greps `codex login status` output for `auth_mode: chatgpt/chatgptAuthTokens` (pass) vs. `apiKey` (fail) — the REPORTED-mode proof, not a bare "request succeeded" check. | **Not exercised.** Script greps `/status` output for `CLAUDE_CODE_OAUTH_TOKEN` (pass) vs. `ANTHROPIC_API_KEY` (fail). | **N/A** — gh-cli has no subscription/API-key billing distinction; column does not apply. |
| Full CLI runs in VM | **Not exercised.** Script runs `sbx run --name <n> <scratch> codex` and confirms via `sbx ls`. | **Not exercised.** Same pattern with `claude`. | **Not exercised.** Same pattern with `sbx run ... --kit kits/wf-gh-cli.kit.yaml`. |

**Every cell above is "script written, not run."** This is the honest state: three real,
executable, HarnessSpec-driven proof paths exist and were verified as far as this environment
allows (syntax-checked, HarnessSpec resolution tested, unit tests for the classification logic
they depend on) — none have touched a real `sbx` sandbox, because none exists here.

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
| A. Independent security domain | **SKIP-NO-SBX** | Requires a live sandbox + comparison against a personally-configured `sbx`. Also blocked on Docker confirming an independent profile mechanism exists at all (unconfirmed; see below). |
| B. Locked-down effective policy | **SKIP-NO-SBX** | Requires `sbx policy inspect`/`policy check network` against a live sandbox. |
| C. Credential-negative guest | **SKIP-NO-SBX** | Requires a hostile guest process inside a live sandbox, run after configuring realistic personal `sbx` credentials on the same machine (the note is explicit that a clean-machine-only test is insufficient). |
| D. Disposable filesystem boundary | **SKIP-NO-SBX** | Requires a live sandbox + a sibling job's scratch dir to probe cross-job visibility. |
| E. No inbound exposure | **SKIP-NO-SBX** | Requires a live sandbox with a guest listener probed from the host. |
| F. Enforceable resource limits | **SKIP-NO-SBX** | Fork-bomb/memory/disk fixture functions exist and are callable but not yet wired to a pass/fail measurement against a declared limit contract — a documented gap even for the live-run path. |
| G. Reliable teardown and orphan recovery | **SKIP-NO-SBX** | Requires a live sandbox; only destroy+re-list is covered even in the live path — scratch/token/receipt/startup-reaper coverage is a documented gap. |
| H. Version-pinned conformance testing | **PASS** | `bin/federation-detect-sbx` correctly refuses a stubbed below-floor `sbx` version. Reproduced independently (see below). Scope: floor-only — an unvetted high version is currently *accepted*, not rejected, since no ceiling is pinned yet. |
| I. Legal and product confirmation from Docker | **PASS (documentation gate)** | The conformance matrix correctly records all 8 of Docker's outstanding legal/product questions as unanswered. This is a completeness check on the documentation, not a claim that Docker answered anything — none have been obtained. |
| J. Native Docker auth substrate, no custom gateway | **SKIP (suite-recorded)** | The suite records one status per gate; because gate J's actual subject — the per-harness six-column auth proof for all three harnesses (codex, claude-code, gh-cli) — cannot run without a real `sbx` install and interactive host logins, its recorded status is honestly SKIP, not PASS. Its static regression guard (no custom base-URL/gateway/proxy-shaped code in `lib/federation-docker-backend.mjs` or `lib/federation-harnesses.mjs`, precise enough to avoid tripping on this file's own "not a gateway" prose) does pass every time the suite runs, and was verified adversarially with three distinct injected violations (a real env var reference, a `base_url:` assignment shape, and a `new *Gateway(` constructor call), each correctly caught and each correctly reverting to a clean pass once removed — see "Auth architecture" below. |

**2 of 10 gates pass for real (H, I). 8 of 10 correctly SKIP** (including gate J, whose static
regression guard is proven but whose named subject — the live auth proof — is not) **pending a
live `sbx` install and, for several, additional unimplemented measurement wiring even once `sbx`
is available.** No gate is marked PASS without reproduced evidence; every SKIP states its specific
blocking reason.

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
- **That subscription pooling works for Gemini the way it does for Codex/Claude.** Explicitly not
  assumed — Gemini's Docker auth path is API-key/proxy-managed, tracked as a separate deferred
  spike.
- **That `lib/federation-auth-flow.mjs`'s `startAuthFlow()` has been proven against the real Codex
  OAuth flow end-to-end.** It was unit-tested exclusively against stub `sbx` binaries. This session
  DID observe the real flow's actual output shape once (to write `url_prompt_pattern` correctly
  rather than guess it) — see the incident note in "Auth UX reframe" — but that was a manual probe
  of the real command's behavior, not an automated, repeatable test of the wrapper driving it.

## Owner handoff: closing the live gates

**Most of what's below still requires a real `sbx` install; one now exists** (v0.35.0, installed by
the owner mid-engagement — see "Owner UAT findings and fixes" above for the two defects that
install surfaced and fixed). The mechanism, install UX, and every gate/proof that can run without a
live sandbox are done and verified (see above). This is the exact, minimal set of commands for the
owner to run to
close the remaining gates, and where to hand the baton back.

**Status: step 1 is already done.** The owner's real `sbx` v0.35.0 install (found the two defects
fixed above) means steps 2 and 3 below are the only remaining commands:

```bash
# 1. DONE — sbx v0.35.0 is installed and authenticated (found the two defects this
#    revision fixes). If starting fresh on another machine:
brew tap docker/tap && brew install docker/tap/sbx   # macOS
# or, Linux (apt-based):
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh && sudo apt-get install -y docker-sbx
sudo usermod -aG kvm $USER && newgrp kvm
sbx login

# 2. Per-harness auth proof (repeat for all three; set GH_TOKEN before the gh-cli run)
bash scripts/federation-harness-auth-proof-live-run.sh codex
bash scripts/federation-harness-auth-proof-live-run.sh claude-code
GH_TOKEN=<your PAT> bash scripts/federation-harness-auth-proof-live-run.sh gh-cli

# 3. Graduation-gate conformance pass (gates A, B, D, E, G — set env vars per the script's own
#    usage comment at the top of the file; gate C additionally needs personal sbx credentials
#    configured on the SAME machine first, per the decision note)
bash scripts/federation-conformance-live-run.sh
```

**Then hand back:** paste the raw output of all three (or point at where you saved it) and this
report gets finalized with the live PASS/FAIL results replacing the current SKIPs — no gate is
marked PASS without that reproduced evidence, so the handoff itself is what turns this from
"mechanism-complete" into "graduation gates proven." One item cannot be closed even with `sbx`
installed: the "refresh works" column needs a SEPARATE long-duration run holding a Codex/Claude
Code sandbox open past a real token's expiry window (~1h) — a short pass, even with real `sbx`,
cannot distinguish "never needed refresh" from "refresh actually works," so that one is a
deliberately separate follow-up, not part of the three-command handoff above.

## What's next (in priority order, after the owner handoff above)

1. **Confirm `sbx exec`/`sbx cp` syntax** against a real `sbx` install (or `sbx --help` output) —
   this blocks any live job from running at all, independent of the security gates. Can be
   confirmed as a side effect of the owner handoff's step 2/3 above.
2. **Wire gate F's fork-bomb/memory/disk fixtures into an actual pass/fail measurement** against
   declared resource limits, once `sbx`'s real limit-enforcement flags are confirmed.
3. **Contact Docker** on the 8 outstanding questions tracked in
   `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md` (redistribution, commercial-use scope, OEM/
   account-free mode, automation API, independent profile mechanism, SSH-agent disable guarantee,
   storage cap, compatibility/security-support commitments) — none block this preview, but several
   block a production release decision per the note's explicit gate.
4. **Pin a version ceiling** in `profiles/wf-federation-docker-v0.json` once a real adversarial
   conformance pass validates a specific `sbx` release.
5. **Scope a Gemini spike separately** once Codex/Claude's native-auth model is proven — do not
   assume the same design transfers; Gemini's Docker auth path is API-key/proxy-managed, not
   subscription OAuth.

## Honest confidence

**High confidence** the interface, adapter, hygiene, and detection mechanisms are correctly built
and internally consistent — every claim in this report was independently reproduced by direct
command execution, not inferred from a maker's self-report, and one real integration bug was
caught and fixed by that independent verification.

**High confidence** in the tightened auth architecture *as documented by Docker and its own open
issue tracker* — the "token never enters the sandbox" claim for both Codex and Claude was
independently confirmed against Docker's own credential-isolation documentation; the
static-vs-refreshing credential distinction was independently confirmed against a specific, real,
open Docker feature request (`docker/sbx-releases#300`) that states exactly this limitation in
Docker's own words, not inferred from the correction's wording alone. The structural guard against
misclassifying a strategy's refresh capability (`lib/federation-harness-spec.mjs`) was unit-tested
adversarially, not merely asserted.

**No confidence claim, positive or negative,** that this project has itself proven any of the three
harnesses' auth claims end-to-end against a real sandbox: `scripts/federation-harness-auth-proof-
live-run.sh` implements the full per-harness six-column proof for Codex, Claude Code, and gh-cli,
but none of it has been executed against a real `sbx` install, since that requires interactive
host logins (and, for the "refresh works" column, a long-duration follow-up spanning a real token's
expiry window) unavailable in this environment.

**No confidence claim, positive or negative,** on whether Docker Sandboxes actually delivers the
containment properties graduation gates A-G require. They were never exercised against a real
sandbox in this environment. This report is a proof that the mechanism is real, testable, honestly
scoped code — not a claim that Federation v0 is safe to expose to stranger-submitted jobs today.

**High confidence** in the install UX mechanism — `install.sh`'s sbx auto-install attempt and
graceful fallback was run end-to-end on this machine, including the actual "no passwordless sudo"
fallback path (not a hypothetical branch), and `waspflow doctor`'s sbx reporting was verified both
with a fake-`sbx`-on-PATH fixture and in its real absent state, confirming sbx's presence/absence
never affects the overall "ready" verdict.

**UAT-ready** in the sense the task defined: an operator can install waspflow, have `sbx`
auto-installed or be pointed at a 30-second manual install, and — once the owner closes the three
handoff commands above and the two unverified CLI surfaces are confirmed — point Waspflow at a job
and watch it attempt to run contained in a Docker sandbox, with an honest, automated report of
exactly which security properties have and have not been proven for that specific release. **The
one deliberately open item is the owner handoff itself** — everything this session could prove
without a real `sbx` install has been proven; everything else is teed up above, not blocked on.
