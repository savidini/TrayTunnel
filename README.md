# VPN CLI Tray

VPN CLI Tray is a small Windows notification-area application for connecting and disconnecting an existing Cisco Secure Client 5.x or legacy Cisco AnyConnect 4.x installation through Cisco's `vpncli.exe`.

It is intentionally a wrapper, not a VPN implementation. Cisco's VPN agent service, VPN profiles, network driver, and corporate policy remain in control.

VPN CLI Tray is an independent, unofficial project. It is not affiliated with, sponsored by, or endorsed by Cisco. Cisco, Cisco Secure Client, and AnyConnect names and trademarks belong to their respective owners.

> [!IMPORTANT]
> Do not run Cisco Secure Client/AnyConnect's own VPN UI (`csc_ui.exe` or `vpnui.exe`) at the same time as VPN CLI Tray. Cisco permits only one client application to control VPN connections, so VPN CLI Tray will refuse to start a connection while Cisco's UI is running. Disable the Cisco UI's **Start with Windows**/autostart option, or fully exit it from its notification-area icon after signing in; closing or minimizing its window is not enough. **Leave Cisco's `csc_vpnagent` (Secure Client 5.x) or `vpnagent` (AnyConnect 4.x) service enabled and running**, because VPN CLI Tray depends on that service.

## What it does

- Left-click the tray icon to connect or disconnect.
- Left-click again while it is yellow, or choose **Cancel connection**, to stop a pending connect or Cisco reconnect.
- Right-click it for status, the current connection action, Settings, Start with Windows, and Exit.
- Prevents duplicate tray instances for the same Windows user.
- Detects when Cisco's own VPN UI has exclusive connect control and fails immediately with corrective guidance.
- Polls Cisco's connection state without freezing the notification-area UI.
- Stores the password with Windows DPAPI for the current user rather than as plaintext.
- Automatically detects Secure Client 5.x before legacy AnyConnect 4.x, including after an in-place Cisco upgrade.

The icon colors are:

| Color | Meaning |
| --- | --- |
| Grey | Normally disconnected, including after a user-requested disconnect or cancellation |
| Amber (`#F5A623`) | Connecting, reconnecting, waiting for a network, cancelling, or disconnecting |
| Green (`#B1CB21`) | Connected |
| Red (`#E04B4F`) | Connection failed, CLI unavailable, disconnect result unavailable, or connection lost |

## Network loss and cancellation

When Wi-Fi disappears, Cisco may remain in its `Reconnecting` state until a route returns. The tray shows **Reconnecting** or **Waiting for network** instead of presenting that as a new connection attempt. Cisco can continue its normal automatic recovery, or you can left-click and choose **Cancel connection** to stop it.

Before a new connection, the app compares Windows Network List Manager with the available physical default routes. It fails fast only when both independently report no network. If either probe is unavailable, the check fails open so unusual enterprise routing is not blocked.

A user cancellation or connection timeout kills the waiting CLI process, sends Cisco's direct disconnect command, and verifies the final state. Settings remain disabled during that bounded cleanup so a save cannot race it. Exit remains available as an emergency escape, but **Cancel connection** is preferred because it verifies Cisco's final state.

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

The Pages workflow deploys `manage.ps1` only from the latest published stable release after verifying GitHub's SHA-256 asset digest. If the short domain is unavailable, use the [direct GitHub Release asset](https://github.com/savidini/VpnCliTray/releases/latest/download/Manage-VpnCliTray.ps1) instead.

For a fixed release, pin both the manager asset and payload version:

```powershell
& ([scriptblock]::Create((irm 'https://github.com/savidini/VpnCliTray/releases/download/v0.2.0/Manage-VpnCliTray.ps1'))) -Action Install -Version v0.2.0
```

The manager downloads `VpnCliTray.release.json` and `VpnCliTray.ps1` from GitHub Releases, limits download sizes, verifies the exact version, byte count, and SHA-256 hash, checks that the payload parses as PowerShell, and then invokes Windows PowerShell 5.1 from a temporary file. It never executes the application payload directly from memory. A hash obtained from the same server protects against corruption and inconsistent downloads, but not compromise of that server or repository. Use Authenticode signing and the manager's `-PublisherThumbprint` option when publisher authentication is required.

### Upgrading from AnyConnect Tray

Before installing version `0.2.0` or later, exit either tray application if it is running. When the old application is recognized by its script identity or an exact-owned startup entry or shortcut, the installer locks both application identities. An existing VPN CLI Tray installation takes precedence; otherwise, migration preserves the legacy **Start with Windows** state and, unless `-DesktopShortcut` is explicitly requested, the Desktop shortcut choice.

Legacy settings are copied only when they are valid UTF-8 JSON with schema version 1 and `%LOCALAPPDATA%\VpnCliTray\settings.json` does not already exist, so the current Windows user can continue to decrypt the DPAPI-protected password. An existing VPN CLI Tray settings file must also validate and is never overwritten. The new script, startup entry, shortcuts, and settings must verify successfully before cleanup removes recognized legacy artifacts. Unrecognized or invalid legacy files and unrelated directory contents are left in place. If an owned legacy item is locked or otherwise cannot be removed, the command exits with an error while retaining an identity anchor; close the process holding it and run the same command again.

### GitHub Pages short link

The [VPN CLI Tray page](https://savidini.de/VpnCliTray/) provides the install command and publishes the released manager at:

```text
https://savidini.de/VpnCliTray/manage.ps1
```

GitHub's default `https://savidini.github.io/VpnCliTray/` address redirects to the custom domain. After a successful release run, the Pages workflow independently resolves the latest stable release, requires the exact expected asset set, downloads `Manage-VpnCliTray.ps1` over HTTPS, verifies its published size and SHA-256 digest, and deploys that unchanged file. It can also be run manually to restore or verify the site without creating a release.

Only the manager is mirrored to Pages; the manifest and application remain GitHub Release assets, so do not use the Pages directory as `-ReleaseBaseUri`.

The one-line form necessarily trusts the HTTPS endpoint before it can perform its own checks. Users who need to inspect the manager first should open or download `manage.ps1`, review it, and run that file instead of executing the downloaded text directly from memory.

## Install from a local clone

Open Windows PowerShell in this repository and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1
```

The installer performs current-user changes only:

1. Copies `VpnCliTray.ps1` to `%LOCALAPPDATA%\VpnCliTray`.
2. creates the `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\VpnCliTray` startup value;
3. creates a Start Menu shortcut named **VPN CLI Tray**; and
4. launches the installed application hidden.

The first run opens Settings. If Cisco has saved a default host and username in its preferences, those values are prefilled. Enter the password and save.

To create an additional Desktop shortcut:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install.ps1 -DesktopShortcut
```

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

Settings are stored in:

```text
%LOCALAPPDATA%\VpnCliTray\settings.json
```

The Cisco CLI path is detected whenever the app loads settings and whenever Settings opens. The supported standard locations include:

- Secure Client 5.x: `C:\Program Files (x86)\Cisco\Cisco Secure Client\vpncli.exe`
- AnyConnect 4.x: `C:\Program Files (x86)\Cisco\Cisco AnyConnect Secure Mobility Client\vpncli.exe`

The field remains read-only because the saved password must never be sent to an arbitrary executable. Use **Detect again** after installing or upgrading Cisco while the tray is already running.

The password is encrypted using Windows Data Protection API through PowerShell's current-user `ConvertFrom-SecureString` behavior. It is recoverable only in the same Windows user context under normal conditions. This protects a copied settings file from another ordinary user, but it does not protect against malware already running as you.

Credentials are sent to `vpncli.exe -s` through redirected standard input. They are not placed in process arguments, environment variables, temporary response files, the registry, or the application log.

State checks and disconnects use Cisco's direct `vpncli.exe state` and `vpncli.exe disconnect` commands. Response-file mode is reserved for the credentialed connect flow; closing it immediately after a disconnect request can cancel the asynchronous disconnect on some AnyConnect versions.

The optional **Append 'y'...** setting is intentionally off. Enable it only if the known gateway displays a login banner after the password. Cisco's response-file interface does not identify which yes/no question consumes a pre-supplied response, so it could otherwise accept an unexpected prompt.

Your organization's policy may prohibit stored VPN passwords or scripted authentication. Check that policy before use.

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

**Exit** only stops the tray process. It does not disconnect an active VPN, delete settings, remove shortcuts, disable startup, or stop Cisco's agent. The app starts again at the next sign-in while **Start with Windows** remains checked.

To uninstall, first choose **Exit**, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Uninstall.ps1
```

Uninstall removes this application's exact per-user Run value, Start Menu/Desktop shortcuts, installed script, encrypted settings, and log. It does not change or remove Cisco software.

## Run without installing

For a temporary test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File .\VpnCliTray.ps1
```

Settings still live under `%LOCALAPPDATA%\VpnCliTray` so a later installation can reuse them.

## Validation and troubleshooting

Run the offline test suite (it never connects or disconnects):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

Validate the manager and release-integrity path without making installation changes:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-ManagerTests.ps1
```

Include a read-only query of the locally installed Cisco CLI:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1 -IncludeLocalHealthCheck
```

Or run only the health check:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\VpnCliTray.ps1 -HealthCheck
```

The health check prints JSON and calls only Cisco's `state` command. Diagnostic events are written to `%LOCALAPPDATA%\VpnCliTray\VpnCliTray.log`; raw Cisco output and credentials are never logged.

If a connect attempt says **Quit Cisco Secure Client, then retry**, fully exit Cisco's own Secure Client/AnyConnect UI from its notification-area icon; merely closing or minimizing its window is not enough. Cisco permits only one client application to own the connect capability at a time. Leave the Cisco VPN agent service running.

If the icon is not visible, expand the taskbar's notification-area overflow once. Do not disable or terminate Cisco's `csc_vpnagent` (Secure Client 5.x) or `vpnagent` (AnyConnect 4.x) service; the wrapper depends on it.

A new, app-owned PowerShell window that remains after launch means an older tray build is still running or the script was started with the internal `-NoConsoleHost` switch. Exit that instance, rerun the installer, and launch **VPN CLI Tray** from the Start Menu. A terminal in which you manually entered the launch command remains your terminal; the tray bootstrap returns control to it. `-NoConsoleHost` is reserved for the application's own console-free handoff.

## Support

Support is provided on a best-effort basis through GitHub issues. This independent project cannot provide Cisco product support, configure an employer's VPN, grant account or gateway access, or override organizational policy. Contact your IT administrator or Cisco support for those issues, and never post real VPN addresses, usernames, passwords, certificates, or CLI transcripts in a public issue.

## Repository notes

- The project deliberately does not redistribute Cisco icons or binaries. Generated colored status icons are used at runtime, while shortcuts may reference the locally installed `UI\csc_ui.exe` or legacy `vpnui.exe` icon.
- The manager and documented install URLs target `savidini/VpnCliTray`; keep them aligned if the repository is ever transferred or renamed.
- Pushing a tag such as `v0.2.0` runs both offline suites, requires the tag to match `$script:Version`, generates the release manifest, uploads the manager and application as draft assets, and then publishes the release.
- A successful Release workflow triggers the Pages workflow, which republishes the verified manager asset from GitHub's latest stable release at the short URL.
- Protect `main` and restrict creation, update, and deletion of `v*` tags to trusted maintainers before enabling releases. The tag workflow deliberately runs release code with `contents: write`; a GitHub environment approval is an additional safeguard.
- Enable immutable releases in the GitHub repository or organization settings so published tags and assets cannot be replaced.
- Licensed under the [MIT License](LICENSE).
