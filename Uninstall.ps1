#requires -Version 5.1

[CmdletBinding()]
param()

$installedScript = Join-Path $env:LOCALAPPDATA 'TrayTunnel\TrayTunnel.ps1'
$legacyInstalledScripts = @(
    (Join-Path $env:LOCALAPPDATA 'VpnCliTray\VpnCliTray.ps1')
    (Join-Path $env:LOCALAPPDATA 'AnyConnectTray\AnyConnectTray.ps1')
)
$repositoryScript = Join-Path $PSScriptRoot 'TrayTunnel.ps1'
$scriptToRun = if (Test-Path -LiteralPath $installedScript -PathType Leaf) {
    $installedScript
}
elseif (Test-Path -LiteralPath $repositoryScript -PathType Leaf) {
    $repositoryScript
}
else {
    if (@($legacyInstalledScripts | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -gt 0) {
        throw (
            'A previous tray installation exists, but TrayTunnel.ps1 is required to remove it safely. ' +
            'Run this wrapper from the TrayTunnel repository or use Manage-TrayTunnel.ps1.'
        )
    }
    throw "TrayTunnel is not installed and the repository script was not found: $repositoryScript"
}

& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $scriptToRun `
    -Uninstall
exit $LASTEXITCODE
