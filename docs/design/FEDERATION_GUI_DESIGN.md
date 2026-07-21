# Federation GUI design — the clawmeter-style contributor tray app

**Date:** 2026-07-21
**Status:** DESIGN (research-backed, not yet built). Prior-art corpus entry:
`ai/research/session-ux/federation-contributor-tray-app-should-reuse-clawmeters-go-systray-stack-and-wrap-the-cli-as-a-thin-ndjson-renderer.md` (multiple converging research passes).
**Depends on:** the shipped guided CLI (PR #17, `bin/waspflow-federation`, `--json` events) + the federation
loop (Node). The GUI reimplements NONE of the federation loop.

## ARCHITECTURE (decided 2026-07-21, supersedes the earlier native-Tauri pick)

**Hybrid: a local Node daemon serving a localhost web UI (opened in the user's own browser) + a thin
no-webview native tray (clawmeter's Go + `fyne.io/systray` stack) + autostart — shipped via apt/brew/WinGet.**

This supersedes the earlier "native Tauri v2 app" decision. It was reconsidered when the owner asked about
(a) easy install across Linux/macOS/Windows and (b) distribution through apt and other package managers.
The reasoning chain, each step research-backed and independently verified:
- **The rich screens move to a browser web UI** (join/paste-invite, trust-safety panel, requester
  submit+watch). Served over `127.0.0.1` by a Node daemon (same `node:http` idiom the federation coordinator
  already uses — see the honest scope note below). Because it renders in the user's *own* browser, there is
  **no bundled webview → the Linux webkit2gtk "won't launch on distro X" hazard vanishes**, and **no
  `.app`/`.exe` GUI to sign → most of the macOS-notarization / Windows-SmartScreen burden vanishes**. Install
  collapses to "install a daemon," which is also the most apt-repo-friendly shape (no `.desktop`/icon/webview
  dependency surface — just a binary + a systemd unit; the Syncthing/Jellyfin/Cockpit model).
- **A native tray is REQUIRED** (owner: non-negotiable) — the ambient "am I contributing / needs my
  attention" signal a browser tab cannot give. But its job is now MINIMAL: 2-3 icon states
  (contributing / paused / action-needed) + a menu whose primary action **opens the web UI URL** in the
  browser, and auto-opens on `awaiting_browser` / `auth_required_manual`. It renders none of the rich UI.
- **A tray-that-opens-a-URL needs NO webview** → a systray-only lib is correct, which is exactly clawmeter's
  actual stack (**Go + `fyne.io/systray`**, verified to link only libc-level libs, zero webkit). So the tray
  kills the webkit2gtk hazard for the native piece by *not containing a webview at all*. This is the piece
  the earlier "systray-only can't do windows, so we need Tauri/Electron/Wails" reasoning ruled out — that
  reasoning only held while the tray had to render the rich screens; it doesn't once they're in the browser.
- **The two-language split (Node daemon + Go tray) is acceptable here** — unlike a full native GUI (which
  would duplicate loop/event logic and force hand-porting the event schema into a second language), the tray
  shares ZERO logic with the daemon: it polls one state endpoint and opens a URL. Thin poll-and-launch, no
  types to port. This is precisely the split the earlier "don't add a Go GUI" memo did NOT object to.
- **Syncthing is the direct template**: a Go daemon serving a localhost web UI, distributed via its own
  signed apt repo, run as a systemd `--user` service, with a SEPARATE optional tray (`syncthingtray`, now
  mainline in Debian). Federation's tray is mandatory rather than optional, but the packaging shape is the same.

### Honest scope correction (recorded so nothing builds on a false premise)
An earlier draft/turn implied the local web UI was "~90% already built" because the coordinator runs a Node
HTTP server. **That is wrong and is corrected here:** the existing `lib/federation-coordinator.mjs` server is
the OWNER-HOSTED, machine-to-machine JSON coordinator API (Tim hosts it; contributors' clients call it over
the network) — it serves **zero HTML** and is not a localhost UI. The **contributor-side local web UI is a
NEW daemon to build.** The accurate claim is "same runtime, same `node:http` idiom, same team-familiar
pattern as the coordinator — a well-understood build, not a new capability class," NOT "already there."

### Residual native cost, stated plainly (the tray is the only native piece left)
- macOS: a menubar-only helper (`LSUIElement`, no window) is still a `.app` and still hits Gatekeeper — but
  it's a TINY dependency-light binary, not a webview GUI. Ship it via a Homebrew cask/formula (clawmeter's
  path); pay the one-time $99/yr Apple notarization only if a non-brew double-click-from-Finder path is
  wanted. Far smaller than notarizing a full Tauri/Electron app.
- Windows: SmartScreen applies to any unsigned `.exe`. `syncthingtray`'s answer is to skip a signed installer
  and ship via WinGet/Scoop/Chocolatey; SignPath Foundation (free OSS OV signing) is the clean fix for a
  native double-click path. Same cost as clawmeter already plans.
- Linux: the tray binary has no webview dep (libc-level only) → no webkit2gtk hazard; packages cleanly as a
  `.deb`/`.rpm` with a systemd/XDG-autostart entry.

## Goal

Give the non-technical contributor ("Oshin") a **set-and-forget background experience**: install in one
command (apt/brew), join with an invite, and mostly ignore it. A persistent **tray** surfaces state and the
occasional required action (a browser login); the richer screens open in the **browser**. No terminal, no
flags, no PEM, no digest.

## Decisions (research-backed)

### Stack decision history (superseded — see the ARCHITECTURE section above for the FINAL decision)
> **SUPERSEDED 2026-07-21.** This section captures the reasoning that led from "Go tray (clawmeter)" →
> "Node/Tauri native GUI" → and finally to the **hybrid web-UI + thin Go tray** now recorded in the
> ARCHITECTURE section at the top. The final call: rich UI in the browser (Node daemon), tray in Go+systray.
> The end-state/language reasoning below is why "a full native GUI, if we built one, should be Node" — but
> we are NOT building a full native GUI; the only native piece is the thin no-webview tray, for which
> Go+systray (clawmeter's stack) is correct precisely because it shares no logic with the daemon. Retained
> for the record.

#### (historical) Node/TypeScript, via Tauri with the federation CLI as a sidecar
**Revised 2026-07-21 after an end-state decision memo (pressure-tested + owner-flagged).** The initial
draft of this doc recommended Go + `fyne.io/systray` (reuse clawmeter's toolchain). That was the right
answer to the *narrow* question "cheapest tray app matching clawmeter's UX bar," but the wrong answer to
the question that actually decides it: **which language is waspflow's product surface consolidating
into?** Verified facts:
- The federation surface is **1,389 lines across 6 Node.js binaries** (`waspflow-federation`,
  `-coordinator`, `-injector`, `-pull`, `-runner`, `-submit`), last touched *today*, under active
  multi-worktree development. The loop already moved OFF bash to Node.
- The bash core is ~6,000 lines but **stable/frozen** (last touched 2026-07-16, the hardening era) — not
  the growing product frontier.
- A root `package.json` (`node >=20`) already exists; Node is a first-class citizen of the repo.

A Go tray app would be a **third language** whose only job is to re-parse JSON a Node process already
emits natively — adding a cross-language IPC seam + a second build/release toolchain for a solo
maintainer, in exchange for a UX bar (tray icon + notifications + browser-open) that is NOT Go-specific.
The first-pass costing of "Go is not a new toolchain" compared Go-GUI to Go-*clawmeter*, not to the
Node-*CLI it actually wraps* — against the correct baseline, Go is the second toolchain, Node is not.

Real-project evidence (see the memo / corpus entry): the language-split GUIs carry documented friction
(Ollama Go-daemon+Electron; gh-vs-GitHub-Desktop = two divergent reimplementations); the consolidated
"success" cases share a language family (Tailscale all-Go; 1Password killed a second native GUI to avoid
exactly this churn). No cited project *added* a GUI-only language sharing nothing with its core just to
match a sibling app's aesthetic — which is what reusing clawmeter's Go stack would be here (clawmeter and
waspflow-federation share no other code).

**Decision: build the GUI in Node/TS so it shares types, tests, and CI with the CLI it renders** —
concretely, **Tauri v2 with the federation CLI packaged as a sidecar** (`externalBin` + `Command.sidecar()`,
a documented first-class pattern), which keeps the "thin renderer over one CLI" architecture while letting
the GUI `import` the CLI's event-schema types directly (no hand-ported Go structs that drift). **Electron
is the acceptable fallback** if Tauri's Rust toolchain overhead proves worse than expected for a solo
maintainer (it's what 1Password/Docker Desktop/Ollama ship), at the cost of ~150MB installers / ~100MB
idle RAM and the known tray friction. Reuse clawmeter's *distribution learnings* (brew one-liner,
`LSUIElement` no-Dock, XDG autostart, the GNOME tray-extension caveat) — those are packaging patterns, not
a reason to adopt its language.

**Ceiling note:** a bare systray-only lib (Go's `fyne.io/systray` OR Node's `systray2`) has no window
capability at all — the moment the join screen (slice 2) or submit form (slice 5) is built, a real
windowing/webview toolkit is required regardless of language. So the realistic choice was never
"systray-vs-systray2"; it's Tauri/Electron (Node family) vs Wails (Go family). Node family wins on the
consolidation logic above.

**This stack decision remains owner-gated** — it flips only if waspflow's *core* is expected to move to
Go (then Go+Wails becomes correct). Absent that, Node/Tauri.

#### (historical) Thin spawn-per-command NDJSON renderer — SUPERSEDED by the daemon architecture
> **SUPERSEDED 2026-07-21.** This "no daemon, spawn-per-command from a native GUI" note belonged to the
> Tauri-native-GUI plan. The FINAL architecture (top ARCHITECTURE section) IS a local daemon serving a
> web UI — the daemon is now required, because a browser UI + a persistent tray are two simultaneous
> observers of one state that must survive tab/window close (exactly the "graduate to a daemon" trigger
> this note named). Retained for the record; the daemon is authoritative.
- The invariant that STILL holds: the CLI/daemon reimplements none of the loop — it shells out to the
  existing `waspflow federation <verb> --json` verbs, reads stderr as opaque progress and the stdout JSON
  line as the authoritative event (schema in `lib/federation-events.mjs`). The daemon is a supervisor +
  HTTP surface; the web UI + tray are thin renderers over its `GET /status` + control API. GitHub-Desktop-
  vs-`gh` (two divergent reimplementations) remains the anti-pattern we avoid: one source of truth.

### Contract discipline (do this to the CLI BEFORE the GUI depends on it)
1. Add a `schema_version` field to the single `printResult()` emitter in `bin/waspflow-federation`, so
   the GUI can detect an unknown event and degrade ("unsupported event — update the app") rather than
   misrender. (Events carry none today.)
2. One shared event-schema definition imported by both the emitter and any consumer.
3. A golden-output CI test: run the real CLI `--json` against canned scenarios, validate every emitted
   line against the schema. Cheap now; expensive to retrofit after users have opinions about a tray
   icon that silently stopped updating.

## The event → UI mapping (the CLI already emits exactly what the GUI needs)

| CLI `--json` event | Tray/UI rendering |
| --- | --- |
| `not_joined` | Tray: "Not joined." Menu → **Join a Federation…** |
| `joined` / `already_joined` `{key_id, coordinator_url}` | Tray steady state; menu shows coordinator + a **Coordinator: trusted** badge |
| `awaiting_browser` `{harness, url}` | **action-needed** tray state + notification with an "Open sign-in" button → `browser.OpenURL(url)`; poll in background; auto-clear on next event. (Codex OAuth / device-flow shape.) |
| `auth_required_manual` `{harness, flow_shape, instruction}` | **action-needed** tray state (SAME urgency badge) + a plain **numbered instruction card** rendering `instruction` (NOT a fake button — Claude `/login` has no host-side URL); state it's a one-time unavoidable manual step and why. |
| `no_task_available` | Tray steady "contributing — idle, nothing to do right now." |
| `contributed` `{task_digest, …}` | Brief success toast; back to steady contributing. |
| `trusted` `{key_id}` | Update the trust badge / peer list. |
| `task_status` `{…}` (requester) | Feeds the submit lifecycle stepper (below). |

## Tray icon: exactly 3 states
- **Contributing** (normal) — set-and-forget steady state.
- **Paused** (user-initiated) — "nothing runs while you're paused" (a pause control is mandatory, per
  the Honeygain/Salad consent pattern).
- **Action-needed** (badge/notification) — persistent until acted on; used for BOTH auth cases.
Do NOT fold "needs login" into a generic "offline/disconnected" glyph (Nextcloud's documented bug).

## Contributor flows

### Join (one paste field)
Tray → "Join a Federation…" → small window with ONE paste field that accepts a deep link
(`waspflow://join?coordinator=…&token=…`), a full `waspflow federation join <url> <token>` command, OR a
raw token — auto-detecting which and parsing out url+token (never make the user split them). → single
confirm screen showing the parsed coordinator URL for a sanity check → **Join**. Register the
`waspflow://` URI scheme so a friend's texted/emailed invite link launches the app pre-filled.

### Contribute (the set-and-forget loop)
After join, the app runs `contribute` (initially on user "Start contributing", later optionally on a
schedule à la Salad's "Scheduled Chopping"). It handles auth pre-flight (surfacing the two auth states
above), pulls a task, runs it sandboxed, returns the result — all reflected in the tray, mostly silent.

### Trust/safety panel (reachable from the menu, not forced on first run)
Follow Docker Sandboxes' 3-part copy structure:
1. Boundary claim: *"Tasks run inside an isolated Docker sandbox on your machine. The sandbox can use
   your Claude/Codex subscription to do the work, but it cannot see anything else on your computer."*
2. Shared-in / not-touched lists (short).
3. Negative-space line: *"Everything else is blocked: the sandbox cannot read your other files, cannot
   reach your home network, and cannot see other tasks."*
Plus the pause-anytime control line and the **Coordinator: trusted** badge (BOINC signed-URL / Storj
reputation pattern — a visible trust signal matters even to non-technical users). Repeat the
negative-space line once on the join-confirm screen (the moment of highest anxiety).

## Requester/submit side (owner submitting a task — GUI-worthy, slightly more technical)
- **Submit form = 3 fields, not a wizard**: native folder picker (→ `--source`), a plain multiline
  prompt box (→ `--prompt-file`), a display-id field (dropdown from `status --json` if it lists
  contributors, else free text). Submit shells out to `submit`, capturing the `contributed`/submit
  event immediately.
- **Lifecycle = one horizontal stepper**: `queued → claimed → running → settled`, updated by polling
  `status --json`; each transition also a toast (background app the user ignores).
- **Result delivery = decoupled "result ready" affordance** (SageMaker's "output available" pattern):
  surface "Open result branch / View diff" the moment the branch lands, independent of success/fail —
  a failed/partial run may still have a branch worth reviewing (v0's review-like-a-PR model).
- Errors are just another lifecycle terminus with the stderr tail shown collapsed-by-default.

## Distribution & install-ease (owner requirement: anyone can install on Linux/macOS/Windows)

**The decisive finding (researched 2026-07-21): install-ease is a GUI-vs-no-GUI / which-webview question,
NOT a Go-vs-Node question.** clawmeter's easy install is verified to come from it being a tray-only app
with NO embedded browser (zero webkit/webview deps; its Linux binary links only 3 libc-level shared libs)
— NOT from being written in Go. Consequences:
- **Go via Wails does NOT preserve clawmeter's superpower.** Wails uses the system `webkit2gtk` just like
  Tauri, so it inherits the exact same Linux "installed but won't launch on distro X" hazard (Ubuntu
  24.04/Debian 13 ship webkit2gtk-4.1 not 4.0; Arch renames it; `wails doctor` exists precisely because
  this bites users). Switching to a Go GUI buys **nothing** on install-ease and re-adds the language split.
  So the earlier "reconsider Go for easy install" instinct is disproven — Node/Tauri stays.
- **macOS:** any double-click GUI (Tauri OR Electron OR Wails) needs Apple notarization ($99/yr, a ONE-TIME
  maintainer cost) to be non-technical-friendly — macOS Sequoia removed the right-click-to-open bypass, so
  unsigned = a multi-step Settings/password dance. This is a GUI cost, not a stack cost; clawmeter dodges
  it only by being a CLI (brew-build-from-source → no quarantine flag). Budget the $99/yr.
- **Windows:** SmartScreen friction is identical for any unsigned installer (Go/Tauri/Electron alike);
  mitigation is SignPath Foundation (free OV signing for OSS, stack-agnostic — clawmeter's own plan).
- **Linux:** the one axis where the webview choice matters. **Tauri** = small but the webkit2gtk
  version-matrix hazard (mitigate via targeted `.deb`/`.rpm` that pull the right webkit2gtk as a dep;
  AppImage-that-bundles-webkit is the "always works" fallback but ~76MB, erasing the size win). **Electron**
  = ~100-150MB but a genuinely self-contained AppImage that "just works" across distros (bundles its own
  Chromium, no system-webview dep).

**Decision on the install-ease axis:** keep **Tauri v2** (the stack-consolidation logic holds, and its
macOS/Windows install profile is fine — system webview always present there). **For Linux specifically,
if install-reliability proves paramount in practice, Electron's self-contained AppImage is the safer
choice for that one platform** (trade size for guaranteed launch) — decide during slice 6 (packaging)
based on how painful the webkit2gtk matrix actually is. Either way, the language stays Node/TS.

Reuse clawmeter's distribution *learnings* (packaging patterns): a Homebrew one-liner (a **cask** for the
signed app), `LSUIElement=true` (no Dock icon), autostart, `.deb`/`.rpm`. Tauri/Electron bundlers
(`tauri build` / electron-builder) produce the `.app`/`.dmg`/`.deb`/`.rpm`/`.msi`/AppImage.
**One tray caveat, inherited not introduced (any stack):** GNOME 45/46 need an AppIndicator/Tray-Icons
extension for the tray icon to appear (modern KDE works out of the box) — a Linux StatusNotifierItem
reality clawmeter carries too.

## Build slices (for the hybrid web-UI + Go-tray architecture)
0. **CLI contract prep** — DONE (PR #18): `schema_version` + `type` on every `--json` event + shared
   `lib/federation-events.mjs` schema + golden test. The daemon/tray/web-UI all build against this.
1. [x] **Local daemon + localhost web server** (Node) — **DONE (slice 1):** a `waspflow federation daemon` (or `ui`) process that
   binds `127.0.0.1:<port>`, serves the web UI static assets + a small JSON state/control API over the
   existing `bin/waspflow-federation` verbs (spawn-per-command, reads its `--json` events). Security from
   the start: Host-header validation, a locally-generated session token, no wildcard CORS. Reuse the
   `node:http` idiom from `lib/federation-coordinator.mjs` (do NOT reuse the coordinator itself — different
   process, different trust domain). A `GET /status` endpoint the tray polls; `POST` control for
   pause/resume/contribute.
2. [x] **Web UI: join + status** (browser, plain HTML/JS — no build step): the join
   screen (one paste field: deep link / `join` command / raw token, auto-detected → confirm coordinator →
   join), and the steady status view (contributing / paused / idle). Talks only to the local daemon's API.
3. [x] **Web UI: contribute + auth-handoff**: drive `contribute` via the daemon, stream progress, render
   `awaiting_browser` (open URL, poll, auto-clear) and `auth_required_manual` (honest numbered instruction
   card); pause/resume control.
4. [x] **Web UI: trust/safety panel** (Docker-Sandboxes 3-part copy + `trusted{key_id}` badge) + **requester
   submit view** (3-field form + lifecycle stepper + decoupled result-ready affordance).
5. [x] **Thin native tray** (Go + `fyne.io/systray`, clawmeter's stack — NO webview): 3-state icon
   (contributing/paused/action-needed) by polling the daemon's `GET /status`; menu → "Open Waspflow
   Federation" (`xdg-open`/`open`/`start` the localhost URL); auto-open the browser on
   `awaiting_browser`/`auth_required_manual`. Shares zero logic with the daemon — poll + open-URL only.
6. **Packaging + distribution**: `nfpm`-generated `.deb`/`.rpm` (daemon depends on `nodejs`; tray is
   libc-only) + systemd `--user` unit / launchd LaunchAgent / XDG autostart for both; a signed **apt repo**
   (reprepro/aptly + GPG `signed-by=` key, Syncthing's pattern); Homebrew formula (daemon) + cask/formula
   (tray); WinGet/Scoop manifests. Document the GNOME AppIndicator-extension tray caveat.

Keep the web UI + tray thin renderers throughout; any logic gap is a CLI/daemon event to add, not
UI-side federation logic. Slices 2-4 (web UI) and 5 (tray) are largely independent behind the daemon's
`GET /status` + control API contract (slice 1) — parallelize once slice 1 lands.

## Non-goals (v0)
No in-app editor, no progress bar beyond streamed milestones, no UI-side crypto/loop logic (the daemon
shells out to the existing verbs; UI is a thin renderer), no Windows-first work (parity path exists via
winget if needed later). NOTE: a local daemon IS in scope now (it's the architecture) — the earlier
"no daemon" non-goal was from the superseded native-GUI plan and is removed.
