# Federation Windows Portability Report

## Scope

Audited the Node Federation daemon, managed contributor configuration, guided
Federation CLI, Docker Sandboxes preflight, and Go tray for the Windows
contributor path. Daemon changes are limited to platform helpers and permission
documentation; no Federation-loop behavior was refactored.

## Findings and fixes

- The daemon browser launcher uses `cmd.exe /c start "" <url>` on Windows. A
  platform-injected unit test proves the empty title argument is retained.
- Managed config and daemon discovery paths use `os.homedir()`/`path.join` in
  Node and `os.UserHomeDir()`/`filepath.Join` in Go. The guided CLI launches
  sibling Node entrypoints through `process.execPath`, not their shebangs.
- `waspflow federation doctor` now has a Windows-specific preflight: `where
  sbx`, Windows Hypervisor Platform state, and Docker login via `sbx diagnose`.
  Linux package, containerd, KVM, and policy checks are not run on Windows.
  It is a post-install backstop: the installer should normally have already
  enabled HypervisorPlatform. Its failure text leads with installer repair;
  the raw PowerShell command is only an administrator last resort.
- POSIX `0600`/`0700` modes are documented as ACL no-ops on Windows. No ACL
  management was added; installer repair owns any needed permission remediation.
- Windows contributor documentation now directs people to the signed
  Federation installer rather than raw setup commands.
- The tray contained no POSIX paths or signal handling. It already uses
  `filepath.Join` and `os.UserHomeDir()`.

## Verification

- `node --test tests/*.test.mjs` — 209 passed, 1 expected live-`sbx` skip.
- Focused Node portability tests — 28 passed, including injected Windows
  browser-launch and Windows preflight branches.
- `GOOS=windows GOARCH=amd64 go build ./...` from `tray/` — passed.

Cross-compiled Go test binaries cannot execute on this Linux host; attempting
`GOOS=windows go test ./...` produced the expected `exec format error` after
compilation. The Windows build is therefore proven, but runtime tray behavior
still needs a Windows desktop smoke test.

## Windows packaging contract

The signed Windows installer runs elevated after the ordinary UAC consent. It
must enable HypervisorPlatform with:

`Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All -NoRestart`

It must then schedule or clearly prompt for the required reboot, install or
repair `sbx`, and offer Docker sign-in through an in-product action. Doctor
must normally pass after this flow. If repair cannot make the device eligible,
the product must show a kind unsupported-device dead-end rather than present
contributor-facing administrator instructions.

## Residual risk

No live Windows 11 machine was available for this audit. In particular, the
real `where sbx`, HypervisorPlatform query, Docker login, and tray launch have
not been exercised together on a Windows contributor machine.

**VERDICT: Windows contributor support: needs the signed installer/repair and in-product Docker sign-in flow, then a Windows 11 live smoke test.**
