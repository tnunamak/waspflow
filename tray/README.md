# Waspflow Federation tray

`waspflow-federation-tray` is a tiny native tray helper. It does not contain
Federation logic or a webview: it reads the local daemon record, polls the
localhost daemon every two seconds, and opens the existing browser UI.

## Run from source

Start the daemon first (or use **Start Federation daemon** from the tray):

```sh
waspflow federation daemon
```

In another terminal, build and run the helper:

```sh
cd tray
go build ./...
go run ./cmd/waspflow-federation-tray
```

The helper discovers `~/.waspflow/federation/daemon.json` (or
`$WASPFLOW_FEDERATION_HOME/daemon.json`). It sends the session token in the
`X-Waspflow-Session-Token` header for `/status` and contribute controls; the
browser URL carries the same token as the daemon requires.

## Tray behavior

- Green circle: contributing.
- Gray pause icon: idle or paused.
- Amber `!`: action needed; open the Federation UI to complete sign-in.
- Blue dot: Federation is not joined or the daemon is unavailable.

The menu opens the browser UI, pauses/resumes contribution when the daemon is
available, starts `waspflow federation daemon` when it is not, and quits the
helper. A new action-needed transition also opens the browser once. Placeholder
icons are generated as compact PNGs in Go until product artwork is available.

## Linux caveat

On GNOME 45/46, a StatusNotifierItem tray icon requires an AppIndicator or
Tray Icons Reloaded extension. Modern KDE supports it out of the box. This is
a desktop-environment limitation, not a webview dependency.
