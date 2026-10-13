# TrayTunnel

TrayTunnel is a small Windows notification-area application for connecting and disconnecting an existing Cisco Secure Client 5.x or legacy Cisco AnyConnect 4.x installation through Cisco's `vpncli.exe`.

Cisco's VPN agent service, VPN profiles, network driver, and corporate policy remain in control. But you don't have to enter your password every single time when you want to connect the VPN.

*TrayTunnel is not affiliated with, sponsored by, or endorsed by Cisco. Cisco, Cisco Secure Client, and AnyConnect names and trademarks belong to their respective owners.*

> [!IMPORTANT]
> Do not run Cisco Secure Client/AnyConnect's own VPN UI (`csc_ui.exe` or `vpnui.exe`) at the same time as TrayTunnel. Cisco permits only one client application to control VPN connections, so TrayTunnel will refuse to start a connection while Cisco's UI is running. Disable the Cisco UI's **Start with Windows**/autostart option, or fully exit it from its notification-area icon after signing in; closing or minimizing its window is not enough. **Leave Cisco's `csc_vpnagent` (Secure Client 5.x) or `vpnagent` (AnyConnect 4.x) service enabled and running**, because TrayTunnel depends on that service.

## What it does

- Left-click the tray icon to connect or disconnect.
- Left-click again while it is yellow, or choose **Cancel connection**, to stop a pending connect or Cisco reconnect.
- Right-click it for status, the current connection action, Settings, Start with Windows, and Exit.
- Detects when Cisco's own VPN UI has exclusive connect control and fails immediately with corrective guidance.
- Stores the password with Windows DPAPI for the current user rather than as plaintext.
- Automatically detects Secure Client 5.x before legacy AnyConnect 4.x, including after an in-place Cisco upgrade.
- Optionally disconnects the VPN automatically when your company network's DNS suffix is detected.

The icon colors are:

| Color | Meaning |
| --- | --- |
| Grey | Normally disconnected, including automatic disconnect on the company network, user-requested disconnect, or cancellation |
| Amber | Connecting, reconnecting, waiting for a network, cancelling, or disconnecting |
| Green | Connected |
| Red | Connection failed, CLI unavailable, disconnect result unavailable, or connection lost |

## Requirements

- Windows 10 or Windows 11
- Windows PowerShell 5.1
- A normal, non-elevated user session; the application refuses to run with administrator rights
- Cisco Secure Client 5.x or Cisco AnyConnect 4.x with `vpncli.exe`
- Cisco's `csc_vpnagent` (Secure Client 5.x) or `vpnagent` (AnyConnect 4.x) service enabled and running
- A gateway that accepts the conventional CLI prompt order: address, username, password

## Quick install, update, or uninstall

TrayTunnel is a per-user tray application, not a Windows service. The manager does not request administrator rights and does not install, remove, stop, or reconfigure Cisco software or the Cisco VPN agent service.

To open one menu for install, update, status, and uninstall, run the manager published from the latest verified GitHub Release at the project's short Pages URL:

```powershell
& ([scriptblock]::Create((irm 'https://savidini.de/TrayTunnel/manage.ps1')))
```

For a direct action, use the script-block form so arguments can be passed:

```powershell
# Install
& ([scriptblock]::Create((irm 'https://savidini.de/TrayTunnel/manage.ps1'))) -Action Install

# Update an existing installation
& ([scriptblock]::Create((irm 'https://savidini.de/TrayTunnel/manage.ps1'))) -Action Update

# Uninstall; choose Exit from the tray menu first
& ([scriptblock]::Create((irm 'https://savidini.de/TrayTunnel/manage.ps1'))) -Action Uninstall
```

Add `-DesktopShortcut` or `-NoLaunch` to an install command when needed. `-Action Update` is an explicit alias for the same idempotent install path. The installer closes a recognized running tray in your Windows session, updates it, and starts the new version unless `-NoLaunch` is set. It does not disconnect the VPN or stop Cisco's agent service. An uninstall normally uses the installed local script, so it remains available when GitHub is unreachable.

### Upgrading from an earlier name

TrayTunnel replaces **VPN CLI Tray** (`VpnCliTray`) and **AnyConnect Tray** (`AnyConnectTray`). Run the TrayTunnel install or update command above; the installer automatically closes a recognized old tray before migrating it. From a source checkout, you can also run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1`.

The installer copies and verifies existing settings, including the encrypted password and company network rule, into `%LOCALAPPDATA%\TrayTunnel`. It preserves Start with Windows and Desktop shortcut choices, creates the TrayTunnel shortcuts, and removes recognized old scripts, startup entries, shortcuts, logs, and temporary files only after validating the new installation. Unrelated files and invalid settings are left untouched. No password re-entry is needed when upgrading under the same Windows account.

Existing TrayTunnel settings take precedence. If both previous installations exist, valid VPN CLI Tray settings take precedence over AnyConnect Tray settings. Use the new TrayTunnel manager for this upgrade because old managers request release assets under their previous names. The previous `https://savidini.de/VpnCliTray/manage.ps1` address forwards its options to the current TrayTunnel manager for compatibility with saved install commands.

## Manual start

Use the **TrayTunnel** Start Menu shortcut, or run:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -WindowStyle Hidden `
    -STA `
    -File "$env:LOCALAPPDATA\TrayTunnel\TrayTunnel.ps1"
```

The command above is only a short-lived bootstrap process. It immediately hands the tray off to a PowerShell process created without a console window, so no PowerShell window should remain open. Starting it again while it is already running does not create a second icon.

## Settings and credentials

To keep the VPN off while at work, right-click the tray icon, open **Settings**, enable **Automatically disconnect VPN on the company network**, and enter your **Company DNS suffix** (for example, `office.example.com`). Use the connection-specific DNS suffix shown by Windows for your company Ethernet or Wi-Fi adapter.

This option is off by default. While enabled, the app checks every five seconds for an exact, case-insensitive suffix match on an active physical network adapter. Cisco VPN and other recognized virtual adapters are ignored. A match cancels a pending connection or disconnects an active VPN, then shows a grey icon with **Company network; VPN off** after Cisco confirms the disconnect. Connect stays disabled while the network matches; disable the option in Settings to connect manually. Leaving the company network makes Connect available again without automatically starting a VPN connection. Genuine disconnect failures still show the actual VPN state or an error.

The password is encrypted using Windows Data Protection API through PowerShell's current-user `ConvertFrom-SecureString` behavior. It is recoverable only in the same Windows user context under normal conditions. This protects a copied settings file from another ordinary user, but it does not protect against malware already running as you.

Credentials are sent to `vpncli.exe -s` through redirected standard input. They are not placed in process arguments, environment variables, temporary response files, the registry, or the application log.

## Authentication limitations

The automated login is designed for a normal username/password gateway. It may also wait successfully for an out-of-band push approval, depending on gateway behavior.

It does not generally automate:

- browser-based SAML or Microsoft Entra ID sign-in;
- separate or changing OTP/passcode prompts;
- interactive certificate selection;
- untrusted-certificate confirmation;
- a group-selection menu before credentials; or
- arbitrary sequences of policy questions.

Use a Cisco profile alias or `host/group` VPN address when that keeps the prompt sequence fixed.

## Exit and uninstall

**Exit** stops the tray process and its hidden Cisco notification listener. It does not disconnect an active VPN, delete settings, remove shortcuts, disable startup, or stop Cisco's agent; Cisco may show its own dialogs after the listener exits. The app starts again at the next sign-in while **Start with Windows** remains checked.

To uninstall, first choose **Exit**, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

Uninstall removes this application's exact per-user Run value, Start Menu/Desktop shortcuts, installed script, encrypted settings, and log. It does not change or remove Cisco software.

## License
Licensed under the [MIT License](LICENSE).
