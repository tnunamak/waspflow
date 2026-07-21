# Windows packaging status

This folder is a WinGet manifest skeleton, not a Windows installer. Windows
support needs Windows 11 with the Hypervisor Platform feature enabled. In an
elevated PowerShell session, run this exact command and restart when prompted:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -All
```

Install Docker Sandboxes before Federation:

```powershell
winget install Docker.sbx
```

## Installer work still required

1. Build or bundle the Windows tray executable and the Node 20 runtime.
2. Produce a signed x64 installer (the current manifest assumes Inno Setup).
3. Include the Windows clawmeter binary and the Federation Node files.
4. Add per-user PATH, Start menu, and tray autostart behavior to the installer.
5. Replace each `0.0.0`, release URL, and all-zero SHA256 in `winget/`.
6. Run `winget validate` and install/uninstall the local manifest on Windows 11.

Do not submit the skeleton to `microsoft/winget-pkgs`; its URL and SHA256 are
intentional placeholders.
