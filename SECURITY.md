# Security Policy

## Supported versions

Security fixes are provided for the latest published release. Older releases are unsupported; reproduce an issue on the latest release before reporting it when possible.

## Credential model

VPN CLI Tray stores the VPN password as a current-user DPAPI ciphertext in `%LOCALAPPDATA%\VpnCliTray\settings.json`. It sends decrypted credentials through redirected standard input only to `vpncli.exe` detected in Cisco's standard Program Files installation locations. User-writable and arbitrary configured executable paths are rejected.

The application rejects carriage returns, line feeds, and NUL characters in all response-file values. This prevents a configured address, username, or password from injecting extra Cisco CLI commands.

DPAPI is not a defense against code already running as the same Windows user. Such code may be able to ask Windows to decrypt the stored value. Corporate endpoint controls and VPN credential policies still apply.

The one-time migration from AnyConnect Tray copies and verifies only a recognized schema-version-1 settings document, without exposing plaintext or overwriting an existing valid VPN CLI Tray settings file. Unrecognized or invalid legacy files are preserved. The copied DPAPI ciphertext remains decryptable only in the same Windows user context under normal conditions.

## Login-banner acceptance

The optional banner setting appends `y` after the password. Cisco's silent response-file mode does not provide a reliable binding between that value and a particular prompt, so enable it only for a gateway whose prompt sequence is already known. Leave it disabled when encountering certificate warnings or an unfamiliar sequence.

## Logs

The application records state transitions and summarized errors only. It deliberately does not log raw Cisco CLI output, gateway values, usernames, passwords, or encrypted password material.

## Remote installation trust

The convenience in-memory command executes the manager delivered by the HTTPS endpoint before local verification is possible. Treat control of the domain, DNS, TLS termination, GitHub Pages deployment workflow, and GitHub repository as code-signing authority. Users with stricter requirements should download and inspect the manager first or use a version-pinned manager whose hash or Authenticode publisher is verified out of band.

The short Pages URL hosts only the manager copied from the latest published stable GitHub Release. The deployment workflow requires the exact expected release assets and verifies the manager's published size and GitHub SHA-256 digest before deployment. This reduces release-race and transfer-corruption risk, but it does not make a compromised domain, Pages configuration, workflow, or repository trustworthy.

The manager accepts only HTTPS release addresses. It downloads the manifest and application to randomized temporary files, applies size limits and bounded retries, and requires the application's version, byte count, SHA-256 hash, and PowerShell syntax to match before execution. For GitHub's `latest` route, it resolves the manifest first and then pins the application download to that exact versioned release.

A manifest and payload obtained from the same compromised origin can be changed together. The manifest hash detects corruption and release races; it is not proof of publisher identity. Enable GitHub immutable releases and Authenticode-sign the release scripts with a timestamped code-signing certificate for stronger provenance. Supplying `-PublisherThumbprint` makes the manager require that publisher on downloaded payloads.

The manager invokes `powershell.exe -ExecutionPolicy Bypass` only for its child process. It never changes the machine or user execution policy and does not attempt to bypass Group Policy, AppLocker, or Windows Defender Application Control.

## Reporting a vulnerability

Report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/savidini/VpnCliTray/security/advisories/new). Include the affected version, security impact, reproduction steps, and a sanitized proof of concept when available.

Do not include real VPN addresses, usernames, passwords, certificates, CLI transcripts, or employer-specific configuration in a public issue or report. Redact organization-specific values before submitting anything.

Repository maintainers must enable **Private vulnerability reporting** under **Settings > Security > Code security and analysis** so the private reporting link remains available.
