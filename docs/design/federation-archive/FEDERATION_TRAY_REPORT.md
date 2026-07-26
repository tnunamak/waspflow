# Federation native tray report

**Date:** 2026-07-21
**Slice:** Native tray helper (design slice 5)

## Delivered

Added the standalone Go module in `tray/`, producing
`waspflow-federation-tray`. It uses `fyne.io/systray` and
`github.com/pkg/browser`; it contains no webview and no Federation-loop logic.

The tray reads `~/.waspflow/federation/daemon.json` (or
`$WASPFLOW_FEDERATION_HOME/daemon.json`), validates its `{port, token}` data,
and polls the localhost daemon's `GET /status` every two seconds. Every daemon
HTTP call carries the token in `X-Waspflow-Session-Token`; opening the browser
uses the daemon's tokenized localhost URL.

| Daemon condition | Tray visual | Tooltip/menu behavior |
| --- | --- | --- |
| `contributing` | green active icon | Pause contributing |
| `paused` or `idle` | gray pause icon | Resume contributing |
| `action_needed` | amber attention icon | Open Federation to complete the action |
| `not_joined`, unreadable record, or unreachable daemon | blue setup icon | Start Federation daemon |

The menu has **Open Waspflow Federation**, dynamic **Pause/Resume
contributing**, **Start Federation daemon** when unavailable, and **Quit**.
Pause/resume uses the daemon's `/contribute/stop` and `/contribute/start`
controls. The start item launches `waspflow federation daemon`, and an
`action_needed` transition opens the local UI once. Native notifications are
intentionally deferred: the persistent attention icon and browser handoff are
the specified minimum behavior.

The placeholder state artwork is generated as small PNGs in Go; it is designed
to be replaced with product icons without changing the daemon boundary.

## Verification

```text
$ cd tray && go test ./...
ok   github.com/tnunamak/waspflow/federation-tray/internal/federationtray

$ cd tray && go build ./...
success
```

Unit coverage includes daemon-state → visual-state mapping, valid and invalid
`daemon.json` parsing, and proof that the HTTP client sends the session-token
header. A live smoke run started the real local daemon with an isolated
Federation home, read its discovery record, fetched authenticated `/status`,
and invoked authenticated `POST /contribute/start`; the unjoined daemon
returned the expected `not_joined` state and `started:false` response.

## Linux tray caveat

GNOME 45/46 requires an AppIndicator or Tray Icons Reloaded extension for a
StatusNotifierItem icon to appear. Modern KDE works out of the box. This is a
desktop-environment limitation, not a dependency of the helper.
