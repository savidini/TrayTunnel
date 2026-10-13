# Included by Invoke-Tests.ps1. Process discovery and shutdown are mocked except
# for a disposable, hidden sleep process created by this test.
$shutdownHostPath = Get-WindowsPowerShellPath
$shutdownTrayPath = Join-Path ([IO.Path]::GetTempPath()) 'TrayTunnel.Tests\VpnCliTray.ps1'
$shutdownSession = [Diagnostics.Process]::GetCurrentProcess().SessionId
$shutdownHost = [pscustomobject]@{
    ProcessId = 123456
    ParentProcessId = 1
    SessionId = $shutdownSession
    ExecutablePath = $shutdownHostPath
    CreationDate = [DateTime]::Now.AddMinutes(-1)
    CommandLine = '"{0}" {1}' -f $shutdownHostPath, (Get-AppArguments -ScriptPath $shutdownTrayPath -NoConsoleHost)
}
$shutdownMatch = @{ ScriptPath = $shutdownTrayPath; PowerShellPath = $shutdownHostPath; SessionId = $shutdownSession }
Assert-Equal $true (Test-InstalledTrayProcess -Snapshot $shutdownHost @shutdownMatch) 'the exact installed tray launcher must be recognized'
foreach ($badCommand in @(
    ($shutdownHost.CommandLine + ' -Install'),
    ($shutdownHost.CommandLine + ' -Uninstall'),
    ($shutdownHost.CommandLine + ' -HealthCheck'),
    $shutdownHost.CommandLine.Replace('-File', '-Command'),
    $shutdownHost.CommandLine.Replace($shutdownTrayPath, ($shutdownTrayPath + '.other.ps1'))
)) {
    $shutdownOther = $shutdownHost.PSObject.Copy()
    $shutdownOther.CommandLine = $badCommand
    Assert-Equal $false (Test-InstalledTrayProcess -Snapshot $shutdownOther @shutdownMatch) 'other PowerShell commands must never be mistaken for a running tray'
}
$shutdownOther = $shutdownHost.PSObject.Copy()
$shutdownOther.ProcessId = $PID
Assert-Equal $false (Test-InstalledTrayProcess -Snapshot $shutdownOther @shutdownMatch) 'the installer must never stop itself'
$shutdownOther = $shutdownHost.PSObject.Copy()
$shutdownOther.SessionId++
Assert-Equal $false (Test-InstalledTrayProcess -Snapshot $shutdownOther @shutdownMatch) 'another Windows session must remain untouched'
$shutdownOther = $shutdownHost.PSObject.Copy()
$shutdownOther.ExecutablePath = 'C:\untrusted\powershell.exe'
Assert-Equal $false (Test-InstalledTrayProcess -Snapshot $shutdownOther @shutdownMatch) 'an executable outside Windows PowerShell must remain untouched'

$shutdownCliPath = 'C:\Program Files\Cisco\Cisco Secure Client\vpncli.exe'
$shutdownChild = [pscustomobject]@{
    ProcessId = 123457
    ParentProcessId = $shutdownHost.ProcessId
    SessionId = $shutdownSession
    ExecutablePath = $shutdownCliPath
    CreationDate = [DateTime]::Now
    CommandLine = 'vpncli.exe -s'
}
Assert-Equal $true (Test-TrayChildCliProcess -Snapshot $shutdownChild -Parent $shutdownHost -CliPaths @($shutdownCliPath)) 'the old tray listener must be cleaned up with its parent'
foreach ($unrelatedCli in @('csc_vpnagent.exe', 'vpnagent.exe', 'vpnui.exe', 'csc_ui.exe')) {
    $shutdownOther = $shutdownChild.PSObject.Copy()
    $shutdownOther.ExecutablePath = Join-Path (Split-Path $shutdownCliPath -Parent) $unrelatedCli
    Assert-Equal $false (Test-TrayChildCliProcess -Snapshot $shutdownOther -Parent $shutdownHost -CliPaths @($shutdownCliPath)) 'Cisco services and user interfaces must never be stopped'
}
$shutdownOther = $shutdownChild.PSObject.Copy()
$shutdownOther.ParentProcessId++
Assert-Equal $false (Test-TrayChildCliProcess -Snapshot $shutdownOther -Parent $shutdownHost -CliPaths @($shutdownCliPath)) 'another application CLI must remain untouched'
$shutdownOther = $shutdownChild.PSObject.Copy()
$shutdownOther.CreationDate = $shutdownHost.CreationDate.AddSeconds(-1)
Assert-Equal $false (Test-TrayChildCliProcess -Snapshot $shutdownOther -Parent $shutdownHost -CliPaths @($shutdownCliPath)) 'a child from an earlier reuse of the parent PID must remain untouched'

$shutdownSavedFunctions = @{}
foreach ($shutdownFunction in @('Get-CiscoExecutablePaths', 'Test-ApplicationScriptIdentity', 'Test-ProcessOwnedByCurrentUser', 'Stop-VerifiedProcessSnapshot', 'Send-TrayExitRequest')) {
    $shutdownSavedFunctions[$shutdownFunction] = (Get-Item -LiteralPath "Function:\$shutdownFunction").ScriptBlock
}
try {
    $shutdownForeignOwner = $shutdownHost.PSObject.Copy()
    $shutdownForeignOwner.ProcessId = 123458
    $shutdownForeignChild = $shutdownChild.PSObject.Copy()
    $shutdownForeignChild.ProcessId = 123459
    $shutdownSnapshots = @($shutdownHost, $shutdownChild, $shutdownForeignOwner, $shutdownForeignChild)
    $shutdownStopped = New-Object 'Collections.Generic.List[int]'
    $shutdownRequested = New-Object 'Collections.Generic.List[string]'
    function Get-CimInstance { param($ClassName, $Filter, $ErrorAction) return $shutdownSnapshots }
    function Get-CiscoExecutablePaths { return $shutdownCliPath }
    function Test-ApplicationScriptIdentity {
        param($Path, $ExpectedAppId, $ExpectedProductName, $ExpectedInstalledFileName)
        return $Path -eq $shutdownTrayPath
    }
    function Test-ProcessOwnedByCurrentUser { param($Snapshot) return $Snapshot.ProcessId -in @(123456, 123457) }
    function Stop-VerifiedProcessSnapshot { param($Snapshot, [switch]$ExitRequested) $shutdownStopped.Add($Snapshot.ProcessId) }
    function Send-TrayExitRequest { param($ApplicationId) $shutdownRequested.Add($ApplicationId); return $false }
    Stop-RunningInstalledTrays -LegacyStates @([pscustomobject]@{
        AppId = 'VpnCliTray'; ProductName = 'VPN CLI Tray'; InstalledFileName = 'VpnCliTray.ps1'; InstalledScriptPath = $shutdownTrayPath
    })
    Assert-Equal '123456,123457' ($shutdownStopped -join ',') 'automatic shutdown must stop only the verified user-owned tray and its user-owned listener'
    Assert-Equal 'VpnCliTray' $shutdownRequested[0] 'automatic shutdown must first request a cooperative tray exit'
}
finally {
    foreach ($shutdownFunction in $shutdownSavedFunctions.Keys) { Set-Item -LiteralPath "Function:\$shutdownFunction" -Value $shutdownSavedFunctions[$shutdownFunction] }
    Remove-Item -LiteralPath 'Function:\Get-CimInstance'
}

$shutdownEventId = 'TrayTunnel.Tests.' + [Guid]::NewGuid().ToString('N')
Assert-Equal $false (Send-TrayExitRequest -ApplicationId $shutdownEventId) 'older trays without a cooperative channel must use the verified fallback'
$shutdownEvent = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, (Get-TrayExitEventName -ApplicationId $shutdownEventId))
try {
    Assert-Equal $true (Send-TrayExitRequest -ApplicationId $shutdownEventId) 'new trays must receive the cooperative exit request'
    Assert-Equal $true $shutdownEvent.WaitOne(0) 'the cooperative request must be observable by the tray timer'
}
finally { $shutdownEvent.Dispose() }

$shutdownStartInfo = New-Object Diagnostics.ProcessStartInfo
$shutdownStartInfo.FileName = $shutdownHostPath
$shutdownStartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "Start-Sleep -Seconds 30"'
$shutdownStartInfo.UseShellExecute = $false
$shutdownStartInfo.CreateNoWindow = $true
$shutdownStartInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
$shutdownFixtureProcess = [Diagnostics.Process]::Start($shutdownStartInfo)
try {
    $shutdownFixture = [pscustomobject]@{
        ProcessId = $shutdownFixtureProcess.Id
        ExecutablePath = $shutdownFixtureProcess.MainModule.FileName
        CreationDate = $shutdownFixtureProcess.StartTime.AddSeconds(-2)
    }
    Assert-Throws -Because 'a reused process ID must not authorize terminating a different process' -MessagePattern '*process changed during upgrade*' -Operation {
        Stop-VerifiedProcessSnapshot -Snapshot $shutdownFixture
    }
    Assert-Equal $false $shutdownFixtureProcess.HasExited 'a mismatched process snapshot must leave the process alive'
    $shutdownFixture.CreationDate = $shutdownFixtureProcess.StartTime
    Stop-VerifiedProcessSnapshot -Snapshot $shutdownFixture
    Assert-Equal $true ($shutdownFixtureProcess.WaitForExit(1000)) 'a verified process handle must be stopped and awaited'
}
finally {
    if (-not $shutdownFixtureProcess.HasExited) { $shutdownFixtureProcess.Kill(); [void]$shutdownFixtureProcess.WaitForExit(1000) }
    $shutdownFixtureProcess.Dispose()
}
