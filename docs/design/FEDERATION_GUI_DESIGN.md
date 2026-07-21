# Federation GUI design — the clawmeter-style contributor tray app

**Date:** 2026-07-21
**Status:** DESIGN (research-backed, not yet built). Prior-art corpus entry:
`ai/research/session-ux/federation-contributor-tray-app-should-reuse-clawmeters-go-systray-stack-and-wrap-the-cli-as-a-thin-ndjson-renderer.md` (three converging research passes).
**Depends on:** the shipped guided CLI (PR #17, `bin/waspflow-federation`, `--json` events). The GUI is a
**renderer + launcher** over that CLI — it reimplements NONE of the federation loop.

## Goal

Give the non-technical contributor ("Oshin") a **background system-tray app**, in the exact mold of
clawmeter, that makes contributing spare AI-subscription capacity a set-and-forget experience: install
in one command, join with an invite, and mostly ignore it — the tray surfaces state and the occasional
required action (a browser login). No terminal, no flags, no PEM, no digest.

## Decisions (research-backed)

### Stack: Node/TypeScript, via Tauri with the federation CLI as a sidecar (Electron fallback)
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

### Architecture: thin spawn-per-command NDJSON renderer (NO daemon for v0)
- The CLI emits **one terminal JSON line per invocation** on stdout and streams live progress on stderr.
- The GUI `spawn`s `waspflow federation <verb> --json`, reads stderr as **opaque progress text**
  (never parsed for control flow), and treats the single stdout JSON line as the **authoritative event**.
- This matches lazygit/gitui/gh ("thin renderer, real logic in the binary"). GitHub-Desktop-vs-`gh`
  (two independent reimplementations that drift) is the anti-pattern we explicitly avoid: one CLI is
  the source of truth, so one security review covers both surfaces.
- **Defer** a daemon + event-endpoint (Syncthing/Ollama/Docker-Desktop model) until we actually need
  multiple simultaneous observers, restart-durable state, or a long-running `contribute --loop`.

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

## Distribution
Reuse clawmeter's distribution *learnings* (the packaging patterns, not its language): a Homebrew
one-liner, `LSUIElement=true` (no Dock icon), a `brew services`-style autostart, Linux XDG autostart +
`.deb`/`.rpm` artifacts. Tauri/Electron have their own bundlers (`tauri build` / electron-builder) that
produce the `.app`/`.dmg`/`.deb`/`.rpm`/`.msi` — map those onto a brew cask + the Linux packages.
**One documented caveat, inherited not introduced:** GNOME 45/46 need an AppIndicator/Tray-Icons
extension for the tray icon to appear (modern KDE works out of the box) — this is a Linux-desktop
StatusNotifierItem reality that applies to any tray app (clawmeter carries it too), independent of stack.

## Build slices (proposed, for a future lane)
0. **CLI contract prep** (small, do first; STACK-INDEPENDENT — already dispatched as lane `fedgui-s0`):
   `schema_version` on every `--json` event + shared event schema + golden CI test. Lands on the CLI side
   (extends PR #17). Needed no matter which GUI language wins.
1. **Tray skeleton + config read**: Node/TS Tauri app (Electron fallback), reads
   `~/.waspflow/federation/config.json`, 3-state tray icon, menu scaffold. Set up the Tauri sidecar
   packaging of the federation CLI here.
2. **Join flow**: paste-field window + `waspflow://` deep-link handler + confirm screen; shells out to
   `join`, renders the result event.
3. **Contribute loop + auth-handoff**: run `contribute`, stream stderr as progress, render
   `awaiting_browser` (device-flow: open URL, poll, auto-clear) and `auth_required_manual` (instruction
   card); pause/resume control.
4. **Trust/safety panel** + trust badge.
5. **Requester submit view**: 3-field form + lifecycle stepper + decoupled result-ready affordance.
6. **Packaging**: brew formula, `.app`/LSUIElement, Linux autostart + deb/rpm, the GNOME caveat doc.

Keep the GUI a thin renderer throughout; any logic gap is a CLI event to add, not GUI logic to write.

## Non-goals (v0)
No daemon/event-endpoint, no in-app editor, no progress bar beyond streamed milestones, no GUI-side
crypto/loop logic, no Windows-first work (parity path exists via clawmeter's winget if needed later).
