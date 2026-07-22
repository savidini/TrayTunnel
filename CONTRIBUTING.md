# Contributing

Contributions should remain compatible with Windows PowerShell 5.1 and the supported Cisco `vpncli.exe` workflow. Keep changes focused, preserve the project's per-user and non-elevated design, and avoid adding unnecessary dependencies.

## Validate changes

Run both offline suites from Windows PowerShell 5.1 before opening a pull request. They do not connect or disconnect a VPN:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-ManagerTests.ps1
```

Keep the `tests` directory tracked; continuous integration and release publishing depend on it.

## Versions and releases

`$script:Version` in `VpnCliTray.ps1` is the application version. Release tags must be exactly `v` followed by that version, such as `v0.2.1`. Update version-specific documentation when the version changes. The release workflow reruns both offline suites, verifies the tag, generates the release manifest, and publishes the manager and application assets.

After a successful release, the Pages workflow resolves the latest stable release and deploys its verified manager asset as `manage.ps1`. Keep the landing page in `pages/index.html`; do not commit a second manager copy. Use the workflow's manual trigger only from `main` when the existing latest release needs to be redeployed.

## Protect private data

Never commit or post real VPN addresses, usernames, passwords, certificates, Cisco CLI transcripts, encrypted settings, logs, or employer-specific configuration. Use reserved example domains and addresses in tests and documentation. Report security issues privately as described in [SECURITY.md](SECURITY.md).
