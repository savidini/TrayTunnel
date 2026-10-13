#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$DesktopShortcut,
    [switch]$NoLaunch
)

$arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'TrayTunnel.ps1'), '-Install')
if ($DesktopShortcut) {
    $arguments += '-DesktopShortcut'
}
if ($NoLaunch) {
    $arguments += '-NoLaunch'
}

& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') @arguments
exit $LASTEXITCODE
