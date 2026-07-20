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
| Graduation-gate conformance suite (A-J) | `tests/federation-docker-conformance.sh`, `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md`, `scripts/federation-conformance-live-run.sh` | Built, 2/10 gates pass for real (H, I), 8/10 correctly SKIP pending a live sandbox (gate J's suite-recorded status is SKIP — see below for why its static half is nonetheless proven) |
| Backend-neutral `HarnessSpec` (6 explicit auth strategies) | `lib/federation-harness-spec.mjs` | Built, unit-tested (13 tests), including an adversarial "CORE SAFETY CHECK" proving a spec cannot claim docker-builtin refresh under a strategy that structurally can't provide it |
| 3 concrete harness classifications (Codex, Claude Code, gh-cli) | `lib/federation-harnesses.mjs`, `kits/wf-gh-cli.kit.yaml` | Built, unit-tested (6 tests), each independently classified against Docker docs/issues, not assumed identical |
| Per-harness six-column auth proof (HarnessSpec-driven) | `scripts/federation-harness-auth-proof-live-run.sh`, gate J in the conformance suite | Built, syntax-checked, HarnessSpec resolution verified for all 3 harnesses. Gate J's static regression guard was verified adversarially (see "Auth architecture"); the suite itself records gate J as SKIP because its live half — the actual per-harness proof — cannot run here |

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
| Existing host login detected | **Not exercised.** Script prompts the operator to confirm or perform `sbx secret set -g openai --oauth`. | **Not exercised.** Script starts the sandbox for an in-session `/login`. | **Not exercised.** Script checks whether `GH_TOKEN` is already set on the host. |
| Extra login required | **Not exercised** (depends on operator's answer above). | **Not exercised** (depends on whether `/login` was already completed). | **Not exercised** (depends on whether `GH_TOKEN` was pre-set). |
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

## What's next (in priority order)

1. **Confirm `sbx exec`/`sbx cp` syntax** against a real `sbx` install (or `sbx --help` output) —
   this blocks any live job from running at all, independent of the security gates.
2. **Run `scripts/federation-harness-auth-proof-live-run.sh {codex|claude-code|gh-cli}`** on a
   machine with `sbx` installed, once per harness, completing the one-time interactive host login
   for each (and setting `GH_TOKEN` for gh-cli) — this is the auth-architecture correction's own
   acceptance test and should run before or alongside item 3. For the "refresh works" column
   specifically, a SEPARATE long-duration follow-up is needed: hold a Codex/Claude Code sandbox
   open past a real token's expiry window (~1h) and confirm the CLI still works without a fresh
   login — a short run cannot distinguish "never needed refresh" from "refresh actually works."
3. **Run `scripts/federation-conformance-live-run.sh`** on a machine with `sbx` installed and
   authenticated to turn gates A, B, D, E, G's SKIPs into reproduced PASS/FAIL. This is a
   privileged/live one-off; the script is written and ready for an owner to run, per this task's
   instruction not to block on privilege the orchestrating session doesn't have.
4. **Configure personal `sbx` credentials on the same test machine** before attempting gate C —
   the note is explicit that a clean-machine test is insufficient for the credential-negative
   guest check.
5. **Wire gate F's fork-bomb/memory/disk fixtures into an actual pass/fail measurement** against
   declared resource limits, once `sbx`'s real limit-enforcement flags are confirmed.
6. **Contact Docker** on the 8 outstanding questions tracked in
   `docs/design/FEDERATION_V0_CONFORMANCE_MATRIX.md` (redistribution, commercial-use scope, OEM/
   account-free mode, automation API, independent profile mechanism, SSH-agent disable guarantee,
   storage cap, compatibility/security-support commitments) — none block this preview, but several
   block a production release decision per the note's explicit gate.
7. **Pin a version ceiling** in `profiles/wf-federation-docker-v0.json` once a real adversarial
   conformance pass validates a specific `sbx` release.
8. **Scope a Gemini spike separately** once Codex/Claude's native-auth model is proven — do not
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

**UAT-ready** in the sense the task defined: an operator can install `sbx`, and once the two
unverified CLI surfaces are confirmed, point Waspflow at a job and watch it attempt to run
contained in a Docker sandbox, with an honest, automated report of exactly which security
properties have and have not been proven for that specific release.
