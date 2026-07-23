# VPN CLI Tray

VPN CLI Tray is a small Windows notification-area application for connecting and disconnecting an existing Cisco Secure Client 5.x or legacy Cisco AnyConnect 4.x installation through Cisco's `vpncli.exe`.

Cisco's VPN agent service, VPN profiles, network driver, and corporate policy remain in control. But you don't have to enter your password every single time when you want to connect the VPN.

*VPN CLI Tray is not affiliated with, sponsored by, or endorsed by Cisco. Cisco, Cisco Secure Client, and AnyConnect names and trademarks belong to their respective owners.*

> [!IMPORTANT]
> Do not run Cisco Secure Client/AnyConnect's own VPN UI (`csc_ui.exe` or `vpnui.exe`) at the same time as VPN CLI Tray. Cisco permits only one client application to control VPN connections, so VPN CLI Tray will refuse to start a connection while Cisco's UI is running. Disable the Cisco UI's **Start with Windows**/autostart option, or fully exit it from its notification-area icon after signing in; closing or minimizing its window is not enough. **Leave Cisco's `csc_vpnagent` (Secure Client 5.x) or `vpnagent` (AnyConnect 4.x) service enabled and running**, because VPN CLI Tray depends on that service.

## What it does

- Left-click the tray icon to connect or disconnect.
- Left-click again while it is yellow, or choose **Cancel connection**, to stop a pending connect or Cisco reconnect.
- Right-click it for status, the current connection action, Settings, Start with Windows, and Exit.
- Detects when Cisco's own VPN UI has exclusive connect control and fails immediately with corrective guidance.
- Stores the password with Windows DPAPI for the current user rather than as plaintext.
- Automatically detects Secure Client 5.x before legacy AnyConnect 4.x, including after an in-place Cisco upgrade.

The icon colors are:

| Color | Meaning |
| --- | --- |
| Grey | Normally disconnected, including after a user-requested disconnect or cancellation |
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

VPN CLI Tray is a per-user tray application, not a Windows service. The manager does not request administrator rights and does not install, remove, stop, or reconfigure Cisco software or the Cisco VPN agent service.

To open one menu for install, update, status, and uninstall, run the manager published from the latest verified GitHub Release at the project's short Pages URL:

```powershell
& ([scriptblock]::Create((irm 'https://savidini.de/VpnCliTray/manage.ps1')))
```

For a direct action, use the script-block form so arguments can be passed:

```powershell
# Install
& ([scriptblock]::Create((irm 'https://savidini.de/VpnCliTray/manage.ps1'))) -Action Install

# Update an existing installation
& ([scriptblock]::Create((irm 'https://savidini.de/VpnCliTray/manage.ps1'))) -Action Update

# Uninstall; choose Exit from the tray menu first
& ([scriptblock]::Create((irm 'https://savidini.de/VpnCliTray/manage.ps1'))) -Action Uninstall
```

Add `-DesktopShortcut` or `-NoLaunch` to an install command when needed. `-Action Update` is an explicit alias for the same idempotent install path. If the tray is already running, the verified file is updated on disk and the existing process remains on the old version until you choose **Exit** and open it again. An uninstall normally uses the installed local script, so it remains available when GitHub is unreachable.

## Manual start

Use the **VPN CLI Tray** Start Menu shortcut, or run:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -WindowStyle Hidden `
    -STA `
    -File "$env:LOCALAPPDATA\VpnCliTray\VpnCliTray.ps1"
```

The command above is only a short-lived bootstrap process. It immediately hands the tray off to a PowerShell process created without a console window, so no PowerShell window should remain open. Starting it again while it is already running does not create a second icon.

## Settings and credentials

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
