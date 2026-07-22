# Waspflow Federation packaging

This directory packages the existing Federation Node CLI, static UI, and Go
tray without changing their daemon or UI logic. Linux packages install runtime
assets in `/usr/lib/waspflow`, the public commands in `/usr/bin`, the user
systemd unit in `/usr/lib/systemd/user`, and XDG tray autostart in
`/etc/xdg/autostart`.

## Build Linux packages

Install Go. `build.sh` uses a local `nfpm` when present and otherwise runs the
official `goreleaser/nfpm` image through Docker, so a release build does not
depend on a workstation-specific packaging tool.

```bash
PACKAGE_VERSION=0.1.0 \
packaging/build.sh
```

The Go tray binary is built during that command with:

```bash
cd tray && go build ./cmd/waspflow-federation-tray
```

Artifacts:

- `packaging/dist/waspflow-federation_0.1.0_amd64.deb`
- `packaging/dist/waspflow-federation_0.1.0_linux_amd64.tar.gz`
- `packaging/stage/` — inspectable package filesystem tree; it is regenerated
  on every build and is not a release artifact.

The `.deb` declares `Depends: nodejs (>= 20)` and `Recommends: docker-sbx`.
`docker-sbx` is deliberately not a hard package dependency; the installed
doctor command evaluates and explains the real local backend readiness. The
package bundles the Federation CLI entry points, all Federation runtime
modules, static UI, native tray binary, a systemd user unit, and XDG autostart
entry. It installs `waspflow-federation` and a federation-only `waspflow`
dispatcher, so both `waspflow-federation doctor` and `waspflow federation
doctor` work. The dispatcher intentionally rejects non-Federation commands;
it is not a partial copy of the main Waspflow CLI.

The package also includes a `waspflow-federation-coordinator.service` systemd
**user** unit. `waspflow federation host` uses it for a hosted collective,
because it is the same user-scoped lifecycle primitive already packaged for
the local daemon: no root service, no hand-managed PID, and restart on
failure. The optional `@ngrok/ngrok` SDK is declared only in
`coordinator/package.json`; the package stages that tiny manifest but not its
`node_modules`. A host installs the SDK into its own private coordinator state
only after selecting ngrok, so a contributor never downloads native tunnel
binaries and the member `.deb` stays small.

For a disposable package journey, run:

```bash
PACKAGE_VERSION=0.1.0 \
packaging/smoke.sh
```

It uses plain Docker (not Docker Sandboxes), installs Node 20 in a fresh
Ubuntu 24.04 container, installs the generated `.deb`, proves `doctor` gives
the expected detect-and-guide result without `sbx`, starts the installed
first-run daemon, and fetches the authenticated localhost UI.

## Curl installer

`bin/federation-install.sh` is the public Linux installer. It queries the
latest GitHub release, prefers its `.deb`, and falls back to the release
portable tarball under `~/.local` when `dpkg` is unavailable or installation
fails. It intentionally requires Node.js 20+ rather than silently installing
a third-party runtime. During development, `WASPFLOW_FEDERATION_RELEASE_API`
and `WASPFLOW_FEDERATION_INSTALL_ROOT` point it at a staging release and a
temporary destination.

## Homebrew

`brew/waspflow-federation.rb` is a best-effort release formula: it builds the
Go tray from source, runs the daemon through `brew services`, and prints the
doctor next step. Replace its tag URL and SHA256 when a source release exists,
then place it in the Homebrew tap. It is deliberately marked untested here;
the Linux smoke is the release gate for this pass.

## Windows

See [windows/README.md](windows/README.md). The WinGet files are a deliberately
non-submittable skeleton until a signed installer exists.

## Next step: signed apt repository

Do not create the repository as part of package builds. The release follow-up
is a signed, small apt repository in the same operational style as Syncthing:

1. Generate and protect a dedicated offline-capable Waspflow archive signing
   key; publish only its armored public key and fingerprint.
2. Use `reprepro` or `aptly` in CI/release automation to publish the tested
   `.deb` into `stable` (and later `testing`) under a conventional `dists/` and
   `pool/` layout.
3. Publish `InRelease` and `Release.gpg`; never rely on deprecated global
   `apt-key` trust.
4. Document installation with a dedicated keyring and `signed-by`, for example:

   ```bash
   curl -fsSL https://packages.example.invalid/waspflow-archive-keyring.gpg \
     | sudo gpg --dearmor -o /usr/share/keyrings/waspflow-archive-keyring.gpg
   echo "deb [signed-by=/usr/share/keyrings/waspflow-archive-keyring.gpg] https://packages.example.invalid/apt stable main" \
     | sudo tee /etc/apt/sources.list.d/waspflow.list
   sudo apt update
   sudo apt install waspflow-federation
   ```

5. Verify a fresh Ubuntu VM/container installs from that repository and that a
   rotated key fails safely until its replacement is installed.

The host name above is intentionally a placeholder; no repository, key, or
publication infrastructure is created by this change.
