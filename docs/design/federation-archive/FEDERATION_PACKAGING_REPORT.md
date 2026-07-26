# Federation packaging report

**Date:** 2026-07-21
**Scope:** Packaging/distribution wave 3 only. No daemon, UI, tray, or
Federation-loop source code was modified.

## Delivered

`packaging/` now contains an nFPM Linux package definition and build script.
It stages only the Federation entry points, root `lib/*.mjs`, static `public/`
assets, the Go tray helper, and a caller-selected clawmeter executable under
`/usr/lib/waspflow`.

The package also installs:

- `/usr/bin/waspflow-federation`, a Node launcher with the bundled directory on
  `PATH`.
- `/usr/bin/waspflow`, a deliberately federation-only dispatcher. It makes the
  documented `waspflow federation …` command and the existing tray's daemon
  start command work without shipping a partial copy of the main Waspflow CLI.
- `waspflow-federation-daemon.service` as a systemd user unit.
- an XDG autostart desktop entry for the native tray.
- a post-install message: `run: waspflow federation doctor`.

The `.deb` declares `Depends: nodejs (>= 20)` and `Recommends: docker-sbx`.
`CLAWMETER_BIN` is required by the build rather than guessed; it is copied as
`/usr/lib/waspflow/clawmeter`.

Also delivered:

- Homebrew formula template with source-built tray, `brew services` daemon,
  clawmeter dependency, and doctor caveat.
- WinGet version/default-locale/installer manifest skeleton plus a Windows 11
  prerequisite and installer TODO document.
- Packaging README with exact build and smoke commands plus the documented,
  unexecuted `reprepro`/`aptly` signed-by apt-repository plan.
- Plain-Docker Ubuntu smoke script.

## Verification performed

1. Built nFPM 2.47.0 locally and used it to build both artifacts with
   `CLAWMETER_BIN=/home/tnunamak/code/clawmeter/clawmeter` and
   `PACKAGE_VERSION=0.1.0`.
2. Inspected the resulting `.deb` with `dpkg-deb`. Its control data contains
   `Package: waspflow-federation`, `Depends: nodejs (>= 20)`, and
   `Recommends: docker-sbx`; its file list contains the expected wrappers,
   tray, clawmeter, UI, unit, and autostart file. A mode assertion confirmed
   application directories and desktop/unit files are not group-writable.
3. Parsed all package and WinGet YAML with `yq` and syntax-checked all package
   shell scripts with `bash -n`.
4. Ran `go test ./...` in `tray/` and 36 Node Federation CLI/daemon/backend
   tests successfully.
5. Ran `packaging/smoke.sh` successfully with plain Docker. It rebuilt the
   package, started a fresh `ubuntu:24.04` container, installed Node 20 from
   NodeSource, installed the `.deb`, verified `waspflow federation --help`,
   asserted all required installed paths, and ran `systemd-analyze verify` on
   the installed user unit.

## Known limits / follow-up

- The RPM was created by nFPM, but this host lacks the `rpm` inspection tool
  and no Fedora/RHEL installation smoke was run.
- The Homebrew formula has intentionally placeholder release URL/SHA256 and
  was not installed through Homebrew here.
- The WinGet files are intentionally non-submittable placeholders until a
  signed Windows installer, URL, and SHA256 exist; no Windows VM validation
  was run.
- No apt repository, signing key, or package publication was created.
- `docs/design/FEDERATION_OSHIN_EXPERIENCE.md` was not present in this checkout.
  Packaging behavior was instead aligned with the current Oshin UX report and
  `FEDERATION_GUI_DESIGN.md` Distribution section.
