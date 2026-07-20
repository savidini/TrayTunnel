#requires -Version 5.1

[CmdletBinding()]
param()

$installedScript = Join-Path $env:LOCALAPPDATA 'VpnCliTray\VpnCliTray.ps1'
$legacyInstalledScript = Join-Path $env:LOCALAPPDATA 'AnyConnectTray\AnyConnectTray.ps1'
$repositoryScript = Join-Path $PSScriptRoot 'VpnCliTray.ps1'
$scriptToRun = if (Test-Path -LiteralPath $installedScript -PathType Leaf) {
    $installedScript
}
elseif (Test-Path -LiteralPath $repositoryScript -PathType Leaf) {
    $repositoryScript
}
else {
    if (Test-Path -LiteralPath $legacyInstalledScript -PathType Leaf) {
        throw (
            'A legacy AnyConnect Tray file exists, but VpnCliTray.ps1 is required to remove it safely. ' +
            'Run this wrapper from the VPN CLI Tray repository or use Manage-VpnCliTray.ps1.'
        )
    }
    throw "VPN CLI Tray is not installed and the repository script was not found: $repositoryScript"
}

& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $scriptToRun `
    -Uninstall
exit $LASTEXITCODE
