# Federation packaging 2 report

## Result

Linux now has a self-service path:

```text
curl installer -> .deb (or ~/.local portable bundle) -> waspflow federation
  -> doctor summary + local onboarding UI -> paste invite -> click Contribute
```

`packaging/build.sh` builds an inspectable staging tree, a Debian package, and
a portable tarball. It uses a local `nfpm` when available and otherwise runs
`goreleaser/nfpm` in Docker. The package includes the Federation entry points,
all runtime `lib/*.mjs` modules, browser UI, Go tray executable, systemd user
unit, and XDG autostart entry. `nodejs (>= 20)` remains a package dependency;
`docker-sbx` remains a recommendation and doctor continues to detect and guide
rather than pretend it is installed.

The old package build required a workstation-specific clawmeter executable
even though Federation does not use it. That requirement has been removed.

`bin/federation-install.sh` is the public Linux installer. It queries the
latest GitHub release, installs its `.deb` when possible, and otherwise places
the release tarball below `~/.local`. It checks for Node 20+ instead of
silently configuring a third-party Node repository on a contributor machine.

`waspflow federation` with no argument now runs the sandbox summary when the
machine has not joined, starts the loopback-only daemon through the existing
`ui` path, prints its authenticated localhost URL, and tells the contributor
where to paste the invite. Browser launching is best-effort so a headless host
still receives the usable URL.

## Actual Ubuntu smoke

Ran the generated `waspflow-federation_0.1.0_amd64.deb` in a fresh
`ubuntu:24.04` container. The container installed Node 20, installed the deb,
checked the packaged user-service and autostart paths, confirmed doctor reports
the expected `sbx` setup guidance, ran the no-argument first-run command,
waited for `daemon.json`, and fetched the tokenized localhost UI. Exit status:
`0`.

Transcript tail:

```text
Setting up nodejs (20.20.2-1nodesource1) ...
Selecting previously unselected package waspflow-federation.
Unpacking waspflow-federation (0.1.0-1) ...
Setting up waspflow-federation (0.1.0-1) ...
Waspflow Federation installed. Run: waspflow federation
usage: waspflow federation <doctor|join|contribute|submit|status|trust|approve|daemon|ui> ...
ExecStart=/usr/bin/waspflow-federation daemon
Sandbox install preflight
Paste the invite from your collective operator into the Join screen, then click Contribute.
    <title>Waspflow Federation</title>
    <main id="app">Loading Waspflow Federation…</main>
```

Focused source regressions also passed: 44 Federation daemon/CLI tests and
`go test ./...` in `tray/`.

## Documentation and deployment

The top-level README now has a one-screen Federation journey and links the
operator deployment note. Remote members need an internet-reachable
coordinator: the collective operator should choose either a reverse proxy with
TLS or a private tailnet. The coordinator is the collective's hosting choice;
that is the **single remaining owner decision** for remote onboarding.

The Homebrew formula is retained as best-effort only. It was not tested on
macOS in this Linux environment and still needs a published release tarball
URL and checksum before it can be represented as a validated macOS install.

## Confidence

High confidence in the Linux package, first-run daemon, and served UI: all
were exercised from the installed deb in a clean Ubuntu container. Medium
confidence in the curl installer: its release-asset discovery and portable
fallback are implemented and shell-validated, but a real GitHub release has
not yet been published to exercise its network path. No macOS runtime claim is
made.
