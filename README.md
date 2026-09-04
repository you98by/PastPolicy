# PastPolicy

> A focused Windows policy workspace for applying per-user registry policies, Microsoft Edge controls, and web access lists.

PastPolicy gives administrators a small, local interface for managing policy settings for enabled local users. Choose a user, configure the controls, review the changes, and apply them with one click.

## Highlights

- Windows workstation, privacy, security, and app-permission policies
- Microsoft Edge privacy, browsing, content, and device-access policies
- Edge web content filtering with independent URL block and allow lists
- Browser restriction support for common browsers
- Per-user policy targeting through the user's registry hive
- Automatic backups before policy work begins
- Save and load reusable JSON configurations
- Restore a user's previous state from a backup
- Optional Microsoft Edge ADMX/ADML template installation
- Live application logs for applied changes and errors

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1 or later
- Administrator privileges
- An enabled local user account to manage
- Microsoft Edge for Edge policies to take effect

No third-party PowerShell modules are required. PastPolicy uses Windows Forms and built-in registry tools.

## Quick Start

### Option 1: Launch the bootstrapper

Run `PastPolicy.ps1` from an elevated PowerShell session or allow it to request elevation:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\PastPolicy.ps1
```

The bootstrapper downloads the project into `C:\PastPolicy` when needed and launches the desktop application.

### Option 2: Run from the project folder

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\src\PastPolicy-App.ps1
```

The application will request administrator privileges automatically if it is not already elevated.

## Using the Workspace

1. Open **Policy Workspace**.
2. Select an enabled local user.
3. Turn policy checkboxes on or off.
4. Add URL patterns to the Edge block or allow list, one entry per line.
5. Select **Apply Changes**.

Changes are written to the selected user's registry hive. PastPolicy then requests a user policy refresh with `gpupdate`.

### Edge URL lists

The workspace exposes two Edge-specific lists:

- **Edge URL block list**: sites or URL patterns Edge should block.
- **Edge URL allow list**: exceptions that should remain accessible.

Examples:

```text
[*.]social.example
https://games.example/*
https://*.distracting.example/*
```

Use Edge's supported URL pattern syntax. The allow list is useful for exceptions when a broader block pattern is enabled. These lists are stored as numbered string values below the Edge `URLBlocklist` and `URLAllowlist` policy keys.

PastPolicy also retains its separate Windows Internet Zone domain block list under **Blocked websites**. Use the Edge list fields when the target is Microsoft Edge.

## Policy Catalog

Policies are grouped in the workspace by the optional category in `policies.txt`. The current catalog includes:

- **Windows**: Task Manager, Registry Editor, Command Prompt, Control Panel, Run, Explorer settings, Windows Script Host, activity history, lock screen, error reporting, and app permissions
- **Privacy**: Location, advertising ID, tailored experiences, and consumer features
- **Security**: AutoPlay and OneDrive synchronization
- **Microsoft Edge**: Passwords, autofill, InPrivate mode, pop-ups, notifications, cookies, downloads, translation, tracking prevention, permissions, media, extensions, and web content filtering

Policy availability can vary by Windows version and Microsoft Edge release. A registry value being written successfully does not guarantee that a particular build supports the policy.

## Configuration File

The default catalog is [policies.txt](policies.txt). Each non-comment line uses this format:

```text
Display Name | Registry Key Path | Value Name | Checked Value | Unchecked Value | Optional Category
```

Example:

```text
Disable Task Manager | Software\Microsoft\Windows\CurrentVersion\Policies\System | DisableTaskMgr | 1 | 0 | Windows
```

Rules:

- Lines beginning with `#` are ignored.
- Separate fields with the pipe character: `|`.
- The first five fields are required.
- Checked and unchecked values must be decimal integers because standard policy rows are written as `REG_DWORD` values.
- Use a category to control the section where the checkbox appears.
- Edge URL block and allow lists are managed by the dedicated workspace fields, not as ordinary rows.

## Backups and Configurations

PastPolicy creates automatic snapshots under:

```text
C:\PastPolicy\States
```

Operational logs are written to:

```text
C:\PastPolicy\Logs\PastPolicy_Log.txt
```

Saved workspace configurations are stored by default under:

```text
C:\PastPolicy\Configurations
```

Use **Save Config**, **Load Config**, and **Restore State** from the workspace to manage these files.

## Edge Administrative Templates

The registry policies applied by PastPolicy work without Local Group Policy Editor. To expose Microsoft's Edge settings in that editor, run:

```powershell
.\Install-EdgePolicyTemplates.ps1
```

The installer downloads the official Microsoft Edge policy templates and copies `msedge.admx` plus language files to `C:\Windows\PolicyDefinitions`. Restart Local Group Policy Editor after installation.

## Safety Notes

Policy changes can restrict access to system tools, apps, websites, and device capabilities.

- Test policies on a non-critical local account first.
- Keep at least one administrator account available.
- Review the selected user before applying changes.
- Create or verify a backup before making broad changes.
- Avoid applying restrictive policies to the account you need for recovery.
- Removing a checkbox does not necessarily remove an existing registry value; it writes the configured unchecked value instead.

PastPolicy is intended for local workstation administration. It is not a replacement for domain Group Policy, Microsoft Intune, or a centralized configuration platform.

## Troubleshooting

### The application does not start

Run it from Windows PowerShell with execution policy bypassed:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\PastPolicy-App.ps1
```

Confirm that you are running on Windows and that the account can elevate to administrator.

### An Edge policy has no effect

Open `edge://policy` in Edge and select **Reload policies**. Confirm the policy name and value. Also check that the policy is supported by the installed Edge version and that no higher-priority domain or device policy overrides it.

### A user is missing from the selector

The workspace lists enabled local users and excludes built-in service or guest accounts. Enable the target account and ensure that Windows has created a profile for it.

### A policy needs to be undone

Use **Discard** before applying unsaved changes, or use **Restore State** to return to an automatic backup. You can also set the relevant checkbox to its unchecked state and apply the workspace again.

## Project Layout

```text
PastPolicy/
|-- Install-EdgePolicyTemplates.ps1  Edge ADMX/ADML installer
|-- PastPolicy.ps1                   Bootstrapper and launcher
|-- policies.txt                     Registry policy catalog
|-- README.md                        Project documentation
`-- src/
	`-- PastPolicy-App.ps1           Windows Forms application
```

## License

No license file is currently included in this repository. Add a license before distributing PastPolicy outside your organization.