# Waspflow Federation packaging

This directory packages the existing Federation Node CLI, static UI, and Go
tray without changing their daemon or UI logic. Linux packages install runtime
assets in `/usr/lib/waspflow`, the public commands in `/usr/bin`, the user
systemd unit in `/usr/lib/systemd/user`, and XDG tray autostart in
`/etc/xdg/autostart`.

## Build Linux packages

Install [nFPM](https://nfpm.goreleaser.com/) and Go, then pass the exact
clawmeter executable to bundle. The build never guesses which clawmeter binary
is safe to distribute.

```bash
CLAWMETER_BIN=/usr/local/bin/clawmeter \
PACKAGE_VERSION=0.1.0 \
packaging/build.sh
```

The Go tray binary is built during that command with:

```bash
cd tray && go build ./cmd/waspflow-federation-tray
```

Artifacts:

- `packaging/dist/waspflow-federation_0.1.0_amd64.deb`
- `packaging/dist/waspflow-federation-0.1.0-1.x86_64.rpm`
- `packaging/stage/` — inspectable package filesystem tree; it is regenerated
  on every build and is not a release artifact.

The `.deb` declares `Depends: nodejs (>= 20)` and `Recommends: docker-sbx`.
`docker-sbx` is deliberately not a hard package dependency; the installed
doctor command evaluates the real local backend readiness. The package also
installs `waspflow-federation` and a federation-only `waspflow` dispatcher, so
both `waspflow-federation doctor` and the documented `waspflow federation
doctor` work. The latter dispatcher intentionally rejects non-Federation
commands; it is not a partial copy of the main Waspflow CLI.

For a disposable package journey, run:

```bash
CLAWMETER_BIN=/usr/local/bin/clawmeter \
PACKAGE_VERSION=0.1.0 \
packaging/smoke.sh
```

It uses plain Docker (not Docker Sandboxes), installs Node 20 in an Ubuntu
container, installs the generated `.deb`, and checks the command, installed
files, and unit syntax.

## Homebrew

`brew/waspflow-federation.rb` is a release template modelled on the local
clawmeter formula: it builds the Go tray from source, runs the daemon through
`brew services`, and prints the doctor next step. Replace its tag URL and
SHA256 when a source release exists, then place it in the Homebrew tap.

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
