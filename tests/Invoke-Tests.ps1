#requires -Version 5.1

[CmdletBinding()]
param(
    [switch]$IncludeLocalHealthCheck
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$scriptPath = Join-Path $repositoryRoot 'TrayTunnel.ps1'
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Because)
    if ($Expected -cne $Actual) {
        throw "Assertion failed: $Because. Expected '$Expected', got '$Actual'."
    }
    $script:Passed++
}

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) {
        throw "Assertion failed: $Because."
    }
    $script:Passed++
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation,

        [Parameter(Mandatory = $true)]
        [string]$Because,

        [string]$MessagePattern = '*'
    )

    try {
        & $Operation
    }
    catch {
        if ($_.Exception.Message -notlike $MessagePattern) {
            throw "Assertion failed: $Because. Unexpected error: $($_.Exception.Message)"
        }
        $script:Passed++
        return
    }

    throw "Assertion failed: $Because. No error was raised."
}

foreach ($powerShellFile in (Get-ChildItem -LiteralPath $repositoryRoot -Recurse -Filter '*.ps1' -File)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($powerShellFile.FullName, [ref]$tokens, [ref]$parseErrors)
    Assert-Equal 0 $parseErrors.Count "$($powerShellFile.Name) must parse without syntax errors"
}

. $scriptPath
Assert-Equal 'TrayTunnel' $script:ProductName 'the display product name must use the neutral application identity'
Assert-Equal 'TrayTunnel' $script:AppId 'the per-user application ID must use the neutral identity'
Assert-Equal '0.3.0' $script:Version 'the TrayTunnel rename and company network feature must use the new release version'
Assert-True ($script:InstalledScriptPath.EndsWith('\TrayTunnel\TrayTunnel.ps1')) 'the install namespace and script name must be TrayTunnel'
Assert-True ($script:LogPath.EndsWith('\TrayTunnel\TrayTunnel.log')) 'the log namespace and file name must be TrayTunnel'
Assert-Equal 'AnyConnectTray' $script:LegacyAppId 'the former application ID must remain available only for migration'
Assert-True ((Get-MutexName) -like 'Local\TrayTunnel-*') 'the primary tray mutex must use the new application ID'
Assert-True ((Get-LegacyMutexName) -like 'Local\AnyConnectTray-*') 'the compatibility mutex must coordinate with the legacy tray'

$testMutexNames = @(
    ('Local\TrayTunnel.Tests.{0}.new' -f [Guid]::NewGuid().ToString('N'))
    ('Local\TrayTunnel.Tests.{0}.legacy' -f [Guid]::NewGuid().ToString('N'))
)
$testMutexLease = Enter-AppMutexSet -MutexNames $testMutexNames
try {
    Assert-Equal $true $testMutexLease.Acquired 'a tray instance must atomically acquire both identity mutexes'
    Assert-Equal $true (Test-NamedMutexExists -Name $testMutexNames[0]) 'the new identity mutex must remain held for the tray lifetime'
    Assert-Equal $true (Test-NamedMutexExists -Name $testMutexNames[1]) 'the legacy identity mutex must remain held for the tray lifetime'
    $competingMutexLease = Enter-AppMutexSet -MutexNames $testMutexNames
    Assert-Equal $false $competingMutexLease.Acquired 'another old or new tray must not coexist during transition'
}
finally {
    Exit-AppMutexSet -Lease $testMutexLease
}
Assert-Equal $false (Test-NamedMutexExists -Name $testMutexNames[0]) 'the new identity mutex must be released on exit'
Assert-Equal $false (Test-NamedMutexExists -Name $testMutexNames[1]) 'the legacy identity mutex must be released on exit'

Assert-Equal $null (Assert-NonElevatedExecution -IsElevated $false) 'ordinary per-user execution must be allowed'
Assert-Throws -Because 'elevated execution must stop before any application action' -MessagePattern '*must not run as administrator*' -Operation {
    Assert-NonElevatedExecution -IsElevated $true
}

$disconnectedOutput = @'
  >> state: Connected
  >> state: Disconnected
  >> notice: Ready to connect.
'@
Assert-Equal 'Disconnected' (Get-ConnectionStateFromText $disconnectedOutput) 'the final state event must win'

$statsOutput = @'
  >> state: Disconnected
  Connection State: Connected
  Management Connection State: Disconnected (disabled)
'@
Assert-Equal 'Connected' (Get-ConnectionStateFromText $statsOutput) 'the exact Connection State field must be authoritative'
Assert-Equal $null (Get-ConnectionStateFromText 'Management Connection State: Connected') 'management state must not be treated as tunnel state'
Assert-Equal $null (Get-ConnectionStateFromText 'state: translated-or-unknown') 'unknown output must fail safely'
Assert-Equal 'Reconnecting' (Get-ConnectionStateFromText '>> state: Reconnecting') 'Cisco reconnecting output must remain distinguishable'
Assert-Equal 'Connected' (Get-ConnectionStateFromText 'VPN>   >> state: Connected') 'persistent response-mode prompts must not hide Cisco state events'

$germanStateOutput = ">> state: Unbekannt`r`r`n>> state: Verbindung getrennt`r`r`n>> notice: Bereit zur Verbindung."
Assert-Equal 'Disconnected' (Get-ConnectionStateFromText $germanStateOutput) 'German Secure Client state output must map to the canonical disconnected state'

$germanStateMappings = [ordered]@{
    'Verbunden'                 = 'Connected'
    'Verbindung getrennt'       = 'Disconnected'
    'Wird verbunden'            = 'Connecting'
    'Wird getrennt'             = 'Disconnecting'
    'Wird erneut verbunden mit' = 'Reconnecting'
}
foreach ($translatedState in $germanStateMappings.Keys) {
    Assert-Equal $germanStateMappings[$translatedState] (Get-ConnectionStateFromText ">> state: $translatedState") "German state '$translatedState' must be canonicalized"
}

Assert-Equal $null (Get-ConnectionStateFromText ">> state: Verbunden`r`n>> state: Unbekannt") 'a final unknown state must override an earlier recognized state'
Assert-Equal $null (Get-ConnectionStateFromText '>> notice: Verbindung getrennt') 'localized notice text must not be parsed as a state event'

Assert-Equal $false (Test-NetworkEvidenceAvailable -InternetConnected $false -PhysicalRouteAvailable $false) 'two independent negative network signals must report offline'
Assert-Equal $true (Test-NetworkEvidenceAvailable -InternetConnected $true -PhysicalRouteAvailable $false) 'positive NLM evidence must permit enterprise networking'
Assert-Equal $true (Test-NetworkEvidenceAvailable -InternetConnected $false -PhysicalRouteAvailable $true) 'a physical default route must tolerate delayed or disabled NLM'
Assert-Equal $true (Test-NetworkEvidenceAvailable -InternetConnected $null -PhysicalRouteAvailable $false) 'an unavailable network probe must fail open'

$offlineSnapshots = @(
    [pscustomobject]@{
        Name                 = 'Tailscale'
        Description          = 'Tailscale Tunnel'
        OperationalStatus    = 'Up'
        NetworkInterfaceType = '53'
        GatewayAddresses     = @()
    }
    [pscustomobject]@{
        Name                 = 'Wi-Fi'
        Description          = 'Physical wireless adapter'
        OperationalStatus    = 'Down'
        NetworkInterfaceType = 'Wireless80211'
        GatewayAddresses     = @('192.0.2.1')
    }
)
Assert-Equal $false (Test-NetworkInterfaceSnapshotAvailable -Snapshots $offlineSnapshots) 'virtual connectivity and a down Wi-Fi adapter must not look usable'

$wifiSnapshot = [pscustomobject]@{
    Name                 = 'Wi-Fi'
    Description          = 'Physical wireless adapter'
    OperationalStatus    = 'Up'
    NetworkInterfaceType = 'Wireless80211'
    GatewayAddresses     = @('192.0.2.1')
}
Assert-Equal $true (Test-NetworkInterfaceSnapshotAvailable -Snapshots @($wifiSnapshot)) 'an up Wi-Fi adapter with a default gateway must look usable'

$virtualGatewaySnapshot = [pscustomobject]@{
    Name                 = 'vSwitch'
    Description          = 'Hyper-V Virtual Ethernet Adapter'
    OperationalStatus    = 'Up'
    NetworkInterfaceType = 'Ethernet'
    GatewayAddresses     = @('192.0.2.1')
}
Assert-Equal $false (Test-NetworkInterfaceSnapshotAvailable -Snapshots @($virtualGatewaySnapshot)) 'a virtual switch must not mask loss of the physical network'

Assert-Equal 'office.example.com' (ConvertTo-CompanyDnsSuffix -Value ' OFFICE.Example.COM. ') 'DNS suffixes must normalize case, surrounding whitespace, and the final dot'
Assert-Equal '' (ConvertTo-CompanyDnsSuffix -Value '') 'a disabled rule may have an empty suffix'
foreach ($invalidSuffix in @('*.example.com', 'office example.com', 'office..example.com', 'office.example.com..', '-office.example.com', '.', "office.example.com`nother.example.com", ('a' * 64) + '.example.com')) {
    Assert-Throws -Because 'invalid DNS suffixes must be rejected' -MessagePattern '*valid DNS suffix*' -Operation {
        ConvertTo-CompanyDnsSuffix -Value $invalidSuffix
    }
}

$companyWifi = [pscustomobject]@{
    Name                 = 'Wi-Fi'
    Description          = 'Physical wireless adapter'
    OperationalStatus    = 'Up'
    NetworkInterfaceType = 'Wireless80211'
    DnsSuffix            = 'OFFICE.example.com.'
    GatewayAddresses     = @()
}
Assert-Equal $true (Test-CompanyNetworkSnapshot -Snapshots @($companyWifi) -DnsSuffix 'office.example.com') 'a physical company adapter must match even without a default gateway'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($companyWifi) -DnsSuffix 'example.com') 'a parent domain must not match a different connection-specific suffix'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($companyWifi) -DnsSuffix 'otheroffice.example.com') 'a partial suffix match must not trigger disconnect'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($companyWifi) -DnsSuffix '') 'an empty suffix must never detect a company network'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($companyWifi) -DnsSuffix '*.example.com') 'malformed stored rules must never detect a company network'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($wifiSnapshot) -DnsSuffix 'office.example.com') 'missing adapter DNS data must not match'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @() -DnsSuffix 'office.example.com') 'missing network adapters must not match'

$companyEthernet = $companyWifi.PSObject.Copy()
$companyEthernet.Name = 'Ethernet'
$companyEthernet.Description = 'Physical Ethernet adapter'
$companyEthernet.NetworkInterfaceType = 'Ethernet'
Assert-Equal $true (Test-CompanyNetworkSnapshot -Snapshots @($wifiSnapshot, $companyEthernet) -DnsSuffix 'office.example.com') 'any active physical company adapter must match on a multihomed computer'
foreach ($description in @('Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter', 'Cisco Secure Client Virtual Miniport Adapter for Windows x64', 'WireGuard Tunnel', 'Hyper-V Virtual Ethernet Adapter')) {
    $tunnelSnapshot = $companyEthernet.PSObject.Copy()
    $tunnelSnapshot.Description = $description
    Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($tunnelSnapshot) -DnsSuffix 'office.example.com') 'a DNS suffix supplied by a VPN or virtual adapter must not trigger disconnect'
}
$downCompanyWifi = $companyWifi.PSObject.Copy()
$downCompanyWifi.OperationalStatus = 'Down'
Assert-Equal $false (Test-CompanyNetworkSnapshot -Snapshots @($downCompanyWifi) -DnsSuffix 'office.example.com') 'a remembered suffix on a disconnected adapter must not match'

Assert-Equal '#7A7A7A' (Get-TrayPresentation -State 'CompanyNetwork').Color 'the company network state must use the grey icon'
Assert-Equal 'VPN not needed' (Get-TrayPresentation -State 'CompanyNetwork').Action 'the company network state must explain why Connect is unavailable'
Assert-Equal 'Ignore' (Get-TrayActionKind -State 'CompanyNetwork') 'a tray click must not connect while the company network rule applies'
Assert-Equal $true (Test-TraySettingsEnabled -State 'CompanyNetwork') 'the user must be able to disable or edit the company network rule'

Assert-Equal 'CancelConnect' (Get-TrayActionKind -State 'Connecting' -ActiveOperationName 'Connect') 'an active connect must be cancellable'
Assert-Equal 'CancelConnect' (Get-TrayActionKind -State 'Connecting' -ActiveOperationName 'Status') 'Cisco reconnecting discovered by status must be cancellable'
Assert-Equal 'Ignore' (Get-TrayActionKind -State 'Connecting' -ActiveOperationName 'Status' -DisconnectPending $true) 'disconnect verification must remain authoritative'
Assert-Equal 'Disconnect' (Get-TrayActionKind -State 'Connected' -ActiveOperationName 'Status') 'connected state must request disconnect'
Assert-Equal 'Connect' (Get-TrayActionKind -State 'DisconnectedError' -ActiveOperationName 'Status') 'disconnected state must request connect'
Assert-Equal 'Ignore' (Get-TrayActionKind -State 'DisconnectedError' -ActiveOperationName 'Status' -StateDetail 'VPN state unavailable') 'an unknown Cisco state must not expose Connect'
Assert-Equal $true (Test-StateDetailUncertain -Detail 'Cancellation result unavailable') 'an expired cancellation with no state is uncertain'
Assert-Equal $false (Test-StateDetailUncertain -Detail 'No network connection') 'a definitive offline preflight is not an unknown Cisco state'
Assert-Equal 'State unavailable' (Get-TrayPresentation -State 'DisconnectedError' -Detail 'VPN state unavailable').Action 'an unknown state must be non-actionable'

Assert-Equal $false (Test-TraySettingsEnabled -State 'Connecting') 'settings must be disabled during connect or reconnect'
Assert-Equal $false (Test-TraySettingsEnabled -State 'Disconnecting') 'settings must be disabled during disconnect verification'
Assert-Equal $true (Test-TraySettingsEnabled -State 'Connected') 'settings must be available in a stable state'
Assert-Equal $true (Test-SettingsSaveAllowed -State 'Connected') 'settings save must preserve a stable connected state'
Assert-Equal $false (Test-SettingsSaveAllowed -State 'Connected' -ActiveOperationName 'Status') 'settings save must not race an active status query'
Assert-Equal $false (Test-SettingsSaveAllowed -State 'Connected' -DisconnectPending $true) 'settings save must not race disconnect verification'
Assert-Equal $false (Test-SettingsSaveAllowed -State 'Connecting') 'a form opened earlier must reject save after Cisco becomes transitional'
Assert-Equal 'Cancel connection' (Get-TrayPresentation -State 'Connecting').Action 'the yellow Connecting action must offer cancellation'

Assert-Equal '' (Get-DisconnectingDetail -Reason 'UserDisconnect') 'ordinary disconnect must retain the standard status label'
Assert-Equal 'Cancelling connection' (Get-DisconnectingDetail -Reason 'UserCancel') 'user cancellation must be explicit'
Assert-Equal 'Cancelling timed-out connection' (Get-DisconnectingDetail -Reason 'ConnectTimeout') 'timeout cleanup must be explicit'
Assert-Equal 'Cancelling failed connection' (Get-DisconnectingDetail -Reason 'ConnectFailure') 'failed-connect cleanup must be explicit'

$completedDisconnectOutput = "  Connection State: Connected`r`n  >> state: Disconnecting`r`n  >> state: Disconnected"
Assert-Equal 'Disconnected' (Get-ConnectionStateFromText $completedDisconnectOutput) 'a completed asynchronous disconnect must use the last reported state'

$cancelledDisconnectOutput = "  Connection State: Connected`r`n  >> state: Disconnecting`r`n  >> state: Connected"
Assert-Equal 'Connected' (Get-ConnectionStateFromText $cancelledDisconnectOutput) 'a cancelled disconnect must not be mistaken for success'

Assert-Equal 'state' (Get-VpnCliArguments -Operation 'Status') 'status must use the direct CLI state command'
Assert-Equal '-s' (Get-VpnCliArguments -Operation 'Connect') 'only credentialed connect must use response-file mode'
Assert-Equal 'disconnect' (Get-VpnCliArguments -Operation 'Disconnect') 'disconnect must use the direct CLI command so vpncli remains attached until completion'
Assert-Equal $false (Test-VpnCliUsesStandardInput -Operation 'Status') 'the direct state command must not redirect standard input'
Assert-Equal $true (Test-VpnCliUsesStandardInput -Operation 'Connect') 'response-file connect must receive credentials through standard input'
Assert-Equal $false (Test-VpnCliUsesStandardInput -Operation 'Disconnect') 'the direct disconnect command must not be cancelled by closing redirected standard input'
Assert-Equal '-s' (Get-VpnCliArguments -Operation 'NotificationListener') 'the persistent listener must use response mode so redirected state commands are processed'
Assert-Equal $true (Test-VpnCliUsesStandardInput -Operation 'NotificationListener') 'the persistent listener must keep redirected input available'
Assert-Equal 'NotificationListener' (Get-CliOperationTransport -Operation 'Status' -NotificationListenerAvailable $true -NotificationListenerRunning $true) 'connected status checks must reuse the registered listener'
Assert-Equal 'Defer' (Get-CliOperationTransport -Operation 'Status' -NotificationListenerAvailable $false -NotificationListenerRunning $true) 'status polling must not launch a competing CLI while the listener registers'
Assert-Equal 'Process' (Get-CliOperationTransport -Operation 'Status' -NotificationListenerAvailable $false -NotificationListenerRunning $false) 'status checks must retain the one-shot fallback before a listener exists'
Assert-Equal 'Process' (Get-CliOperationTransport -Operation 'Connect' -NotificationListenerAvailable $true -NotificationListenerRunning $true) 'credentialed connects must remain one-shot operations'
Assert-Equal 'Process' (Get-CliOperationTransport -Operation 'Disconnect' -NotificationListenerAvailable $true) 'verified disconnects must retain their bounded direct process'

$listenerHealthStart = [DateTime]'2026-01-01T00:00:00Z'
$savedCliNotificationListenerVariable = Get-Variable -Name 'CliNotificationListener' -Scope Script -ErrorAction SilentlyContinue
$savedCliNotificationListener = if ($null -eq $savedCliNotificationListenerVariable) { $null } else { $savedCliNotificationListenerVariable.Value }
try {
    $script:CliNotificationListener = [pscustomobject]@{
        Process              = [pscustomobject]@{ HasExited = $false }
        Registered           = $false
        ReadFailed           = $false
        RegistrationDeadline = $listenerHealthStart.AddSeconds(10)
    }
    Assert-Equal $true (Test-CliNotificationListenerRunning) 'a live Cisco CLI process must count as an in-progress registration attempt'
    Assert-Equal $false (Test-CliNotificationListenerAvailable) 'a live process must not be reused before Cisco confirms registration'
    Assert-Equal $false (Test-CliNotificationListenerRegistrationTimedOut -Listener $script:CliNotificationListener -Now $listenerHealthStart.AddSeconds(9)) 'registration must retain its full handshake interval'
    Assert-Equal $true (Test-CliNotificationListenerRegistrationTimedOut -Listener $script:CliNotificationListener -Now $listenerHealthStart.AddSeconds(10)) 'a listener that never registers must time out'
    $script:CliNotificationListener.Registered = $true
    Assert-Equal $true (Test-CliNotificationListenerAvailable) 'only a live registered listener may carry status queries'
    Assert-Equal $false (Test-CliNotificationListenerRegistrationTimedOut -Listener $script:CliNotificationListener -Now $listenerHealthStart.AddSeconds(20)) 'successful registration must cancel the handshake timeout'
    $script:CliNotificationListener.ReadFailed = $true
    Assert-Equal $false (Test-CliNotificationListenerAvailable) 'a registered listener with a failed stream must not be reused'
}
finally {
    if ($null -eq $savedCliNotificationListenerVariable) {
        Remove-Variable -Name 'CliNotificationListener' -Scope Script -ErrorAction SilentlyContinue
    }
    else {
        $script:CliNotificationListener = $savedCliNotificationListener
    }
}

$capturedError = Get-CiscoCliNotificationFromLine 'VPN>   >> error: Session expired'
Assert-Equal 'error' $capturedError.Kind 'listener error lines must be classified for logging'
Assert-Equal 'Session expired' $capturedError.Message 'listener error text must exclude the Cisco prompt'
Assert-Equal $null (Get-CiscoCliNotificationFromLine 'VPN>   >> state: Connected') 'state events must not be mistaken for notices'
Assert-Equal $true (Test-CiscoCliRegistrationLine 'VPN>   >> registered with local VPN subsystem.') 'only Cisco''s exact positive acknowledgement may complete registration'
Assert-Equal $false (Test-CiscoCliRegistrationLine 'VPN> not registered with local VPN subsystem') 'a negative registration line must not activate the listener'
Assert-Equal $false (Test-CiscoCliRegistrationLine 'VPN>   >> error: not registered with local VPN subsystem') 'an error mentioning registration must not activate the listener'
Assert-Equal $true (Test-CliNotificationListenerRequired -State 'Connected') 'a connected tunnel must retain the Cisco notification listener'
Assert-Equal $true (Test-CliNotificationListenerRequired -State 'Connecting') 'Cisco reconnecting must retain the notification listener'
Assert-Equal $true (Test-CliNotificationListenerRequired -State 'Disconnecting') 'Cisco terminal transitions must retain the listener for any trailing error'
Assert-Equal $false (Test-CliNotificationListenerRequired -State 'InitialDisconnected') 'a disconnected tray must not keep an idle CLI process'

$retentionStart = [DateTime]'2026-01-01T00:00:00Z'
$retentionDeadline = $retentionStart.AddSeconds(5)
Assert-Equal 'Keep' (Get-CliNotificationListenerRetentionAction -State 'Disconnecting' -Now $retentionStart -StopAfter ([DateTime]::MaxValue)) 'Cisco disconnecting must keep the notification channel registered'
Assert-Equal 'StartGrace' (Get-CliNotificationListenerRetentionAction -State 'DisconnectedError' -Now $retentionStart -StopAfter ([DateTime]::MaxValue)) 'a terminal state must begin the trailing-error grace period'
Assert-Equal 'Keep' (Get-CliNotificationListenerRetentionAction -State 'DisconnectedError' -Now $retentionStart.AddSeconds(4) -StopAfter $retentionDeadline) 'the listener must remain registered throughout the trailing-error grace period'
Assert-Equal 'Stop' (Get-CliNotificationListenerRetentionAction -State 'DisconnectedError' -Now $retentionDeadline -StopAfter $retentionDeadline) 'the listener may stop after the trailing-error grace period'

$listenerFixture = [pscustomobject]@{
    Registered    = $true
    StateSequence = [long]4
    LastState     = $null
}
$script:ActiveOperation = [pscustomobject]@{
    Transport            = 'NotificationListener'
    MinimumStateSequence = [long]4
    ReportedState        = $null
    Completed            = $false
}
Assert-Equal $false (Test-CliNotificationStatusOperationSucceeded -Operation $script:ActiveOperation) 'an unfinished listener status query must not survive listener exit as success'
Receive-CliNotificationListenerLine -Listener $listenerFixture -Line 'VPN>   >> state: Reconnecting'
Assert-Equal 5 $listenerFixture.StateSequence 'each listener state event must advance its correlation sequence'
Assert-Equal 'Reconnecting' $script:ActiveOperation.ReportedState 'a post-command listener state must complete with its canonical value'
Assert-Equal $true $script:ActiveOperation.Completed 'a listener status query must complete without waiting for process exit'
Assert-Equal $true (Test-CliNotificationStatusOperationSucceeded -Operation $script:ActiveOperation) 'a parsed state must remain successful even if the listener reaches EOF in the same drain'
$script:ActiveOperation = $null

$notificationTestDirectory = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Notifications.' + [Guid]::NewGuid().ToString('N'))
$savedNotificationInstallDirectory = $script:InstallDirectory
$savedNotificationLogPath = $script:LogPath
$savedNotificationStateVariable = Get-Variable -Name 'ApplicationState' -Scope Script -ErrorAction SilentlyContinue
$savedNotificationDetailVariable = Get-Variable -Name 'StateDetail' -Scope Script -ErrorAction SilentlyContinue
$savedNotificationIconVariable = Get-Variable -Name 'NotifyIcon' -Scope Script -ErrorAction SilentlyContinue
$savedNotificationState = if ($null -eq $savedNotificationStateVariable) { $null } else { $savedNotificationStateVariable.Value }
$savedNotificationDetail = if ($null -eq $savedNotificationDetailVariable) { $null } else { $savedNotificationDetailVariable.Value }
$savedNotificationIcon = if ($null -eq $savedNotificationIconVariable) { $null } else { $savedNotificationIconVariable.Value }
$savedNotificationOperation = $script:ActiveOperation
try {
    $script:InstallDirectory = $notificationTestDirectory
    $script:LogPath = Join-Path $notificationTestDirectory 'TrayTunnel.log'
    $script:ApplicationState = 'Connected'
    $script:StateDetail = ''
    $script:NotifyIcon = $null
    $script:ActiveOperation = $null
    $sequenceListener = [pscustomobject]@{
        Registered    = $true
        StateSequence = [long]0
        LastState     = $null
    }

    Receive-CliNotificationListenerLine -Listener $sequenceListener -Line 'VPN>   >> state: Disconnecting'
    Assert-Equal 'Disconnecting' $script:ApplicationState 'a Cisco disconnecting event must retain the listener on its own timer tick'
    Assert-Equal 'Keep' (Get-CliNotificationListenerRetentionAction -State $script:ApplicationState -Now $retentionStart -StopAfter ([DateTime]::MaxValue)) 'the disconnecting tick must not retire the listener'

    Receive-CliNotificationListenerLine -Listener $sequenceListener -Line 'VPN>   >> state: Disconnected'
    Assert-Equal 'DisconnectedError' $script:ApplicationState 'the following disconnected event must become an unexpected terminal state'
    Assert-Equal 'StartGrace' (Get-CliNotificationListenerRetentionAction -State $script:ApplicationState -Now $retentionStart -StopAfter ([DateTime]::MaxValue)) 'the disconnected tick must retain the listener for a trailing Cisco error'

    $sensitiveCiscoMessage = 'Your connection to vpn.private.example for alice requires re-authentication.'
    Receive-CliNotificationListenerLine -Listener $sequenceListener -Line ('VPN>   >> error: ' + $sensitiveCiscoMessage)
    $notificationLog = [IO.File]::ReadAllText($script:LogPath)
    Assert-True $notificationLog.Contains('Cisco CLI error received by the hidden notification listener.') 'a trailing Cisco error must be consumed by the registered listener'
    Assert-True (-not $notificationLog.Contains($sensitiveCiscoMessage)) 'raw gateway error text must never enter the application log'

    $disposedReader = New-Object IO.StringReader('VPN>   >> state: Connected')
    $completedReadTask = $disposedReader.ReadLineAsync()
    $disposedReader.Dispose()
    $streamFailureListener = [pscustomobject]@{
        OutputReader   = $disposedReader
        OutputReadTask = $completedReadTask
        ReadFailed     = $false
        Registered     = $true
        StateSequence  = [long]0
        LastState      = $null
    }
    $script:ActiveOperation = [pscustomobject]@{
        Transport            = 'NotificationListener'
        MinimumStateSequence = [long]0
        ReportedState        = $null
        Completed            = $false
    }
    Receive-CliNotificationListenerStream -Listener $streamFailureListener -StreamName 'Output'
    Assert-Equal $true $streamFailureListener.ReadFailed 'failure to schedule the next asynchronous read must retire the listener'
    Assert-Equal $null $streamFailureListener.OutputReadTask 'a failed asynchronous-read reschedule must clear the stale completed task'
    Assert-Equal 'Connected' $script:ActiveOperation.ReportedState 'a valid current line must be retained before a subsequent stream failure'
    $script:ActiveOperation = $null
}
finally {
    $script:InstallDirectory = $savedNotificationInstallDirectory
    $script:LogPath = $savedNotificationLogPath
    foreach ($variableRestore in @(
        [pscustomobject]@{ Name = 'ApplicationState'; Variable = $savedNotificationStateVariable; Value = $savedNotificationState }
        [pscustomobject]@{ Name = 'StateDetail'; Variable = $savedNotificationDetailVariable; Value = $savedNotificationDetail }
        [pscustomobject]@{ Name = 'NotifyIcon'; Variable = $savedNotificationIconVariable; Value = $savedNotificationIcon }
    )) {
        if ($null -eq $variableRestore.Variable) {
            Remove-Variable -Name $variableRestore.Name -Scope Script -ErrorAction SilentlyContinue
        }
        else {
            Set-Variable -Name $variableRestore.Name -Scope Script -Value $variableRestore.Value
        }
    }
    $script:ActiveOperation = $savedNotificationOperation
    if (Test-Path -LiteralPath $notificationTestDirectory -PathType Container) {
        [IO.Directory]::Delete($notificationTestDirectory, $true)
    }
}

$inputWithoutBanner = New-VpnCliInput -VpnAddress 'vpn.example.com/group' -Username 'alice' -Password 'p@ss word' -AcceptLoginBanner $false
Assert-Equal "connect vpn.example.com/group`r`nalice`r`np@ss word`r`n" $inputWithoutBanner 'connect input must preserve values and line order'

$inputWithBanner = New-VpnCliInput -VpnAddress 'vpn.example.com' -Username 'alice' -Password 'secret' -AcceptLoginBanner $true
Assert-True ($inputWithBanner.EndsWith("secret`r`ny`r`n")) 'banner acceptance must append exactly one y response'

$injectionRejected = $false
try {
    [void](New-VpnCliInput -VpnAddress "vpn.example.com`r`ndisconnect" -Username 'alice' -Password 'secret')
}
catch {
    $injectionRejected = $true
}
Assert-True $injectionRejected 'newlines in response-file settings must be rejected'

$ciphertext = Protect-Password -Password 'unit-test-password'
Assert-True (-not $ciphertext.Contains('unit-test-password')) 'DPAPI ciphertext must not contain the plaintext password'
Assert-Equal 'unit-test-password' (Unprotect-Password -EncryptedPassword $ciphertext) 'DPAPI password round-trip must work for this user'

$expectedPresentations = @{
    InitialDisconnected = '#7A7A7A'
    Connecting          = '#F5A623'
    Disconnecting       = '#F5A623'
    Connected           = '#B1CB21'
    DisconnectedError   = '#E04B4F'
}
foreach ($state in $expectedPresentations.Keys) {
    $presentation = Get-TrayPresentation -State $state
    Assert-Equal $expectedPresentations[$state] $presentation.Color "the $state presentation must use its documented color"
}

$startupCommand = Get-StartupCommand -ScriptPath 'C:\Path With Spaces\TrayTunnel.ps1'
Assert-True ($startupCommand.Contains('-NoProfile')) 'startup must not load a user profile'
Assert-True ($startupCommand.Contains('-STA')) 'startup must use STA for Windows Forms'
Assert-True ($startupCommand.Contains('-File "C:\Path With Spaces\TrayTunnel.ps1"')) 'startup must quote the script path'
Assert-Equal $false ($startupCommand.Contains('-NoConsoleHost')) 'interactive launchers must hand off instead of hosting the long-running tray'

$noConsoleArguments = Get-AppArguments -ScriptPath 'C:\Path With Spaces\TrayTunnel.ps1' -NoConsoleHost
Assert-True ($noConsoleArguments.EndsWith(' -NoConsoleHost')) 'the console-free child must be marked to prevent a rehost loop'
Assert-Equal $true (Test-AppRehostRequired -IsNoConsoleHost $false -ApartmentState STA) 'an ordinary STA launch must still hand off to a console-free child'
Assert-Equal $true (Test-AppRehostRequired -IsNoConsoleHost $true -ApartmentState MTA) 'an MTA child must be relaunched as STA'
Assert-Equal $false (Test-AppRehostRequired -IsNoConsoleHost $true -ApartmentState STA) 'the console-free STA child must run the tray directly'

Initialize-WindowsForms
$leftNotifyClick = New-Object Windows.Forms.MouseEventArgs -ArgumentList ([Windows.Forms.MouseButtons]::Left), 0, 0, 0, 0
$rightNotifyClick = New-Object Windows.Forms.MouseEventArgs -ArgumentList ([Windows.Forms.MouseButtons]::Right), 0, 0, 0, 0
$middleNotifyClick = New-Object Windows.Forms.MouseEventArgs -ArgumentList ([Windows.Forms.MouseButtons]::Middle), 0, 0, 0, 0
Assert-Equal 0 $leftNotifyClick.Clicks 'the regression fixture must match the click count emitted by NotifyIcon under Windows PowerShell 5.1'
Assert-Equal $true (Test-TrayPrimaryClick -EventArgs $leftNotifyClick) 'a NotifyIcon left click must activate even when its Clicks value is zero'
Assert-Equal $false (Test-TrayPrimaryClick -EventArgs $rightNotifyClick) 'a NotifyIcon right click must remain reserved for the context menu'
Assert-Equal $false (Test-TrayPrimaryClick -EventArgs $middleNotifyClick) 'a NotifyIcon middle click must not activate the VPN action'
Assert-Equal $false (Test-TrayPrimaryClick -EventArgs $null) 'missing mouse event data must fail closed'

foreach ($color in @('#7A7A7A', '#F5A623', '#B1CB21', '#E04B4F')) {
    $testIcon = New-StatusIcon -ColorHtml $color
    try {
        Assert-Equal 'System.Drawing.Icon' $testIcon.GetType().FullName "the $color runtime status icon must be constructible"
    }
    finally {
        $testIcon.Dispose()
    }
}

$originalLocalAppData = $script:LocalAppData
$testPreferenceRoot = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Preferences.' + [Guid]::NewGuid().ToString('N'))
try {
    $securePreferencePath = Join-Path $testPreferenceRoot 'Cisco\Cisco Secure Client\VPN\preferences.xml'
    $legacyPreferencePath = Join-Path $testPreferenceRoot 'Cisco\Cisco AnyConnect Secure Mobility Client\preferences.xml'
    New-Item -ItemType Directory -Path (Split-Path -Parent $securePreferencePath) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $legacyPreferencePath) -Force | Out-Null
    [IO.File]::WriteAllText($securePreferencePath, '<Preferences><DefaultHostName>secure-current</DefaultHostName><DefaultUser>secure-user</DefaultUser></Preferences>')
    [IO.File]::WriteAllText($legacyPreferencePath, '<Preferences><DefaultHostName>legacy-stale</DefaultHostName><DefaultUser>legacy-user</DefaultUser></Preferences>')
    $script:LocalAppData = $testPreferenceRoot

    $preferenceDefaults = Get-CiscoPreferenceDefaults
    Assert-Equal 'secure-current' $preferenceDefaults.VpnAddress 'Secure Client preferences must win over stale legacy AnyConnect preferences'
    Assert-Equal 'secure-user' $preferenceDefaults.Username 'Secure Client username preferences must win after a Cisco upgrade'
}
finally {
    $script:LocalAppData = $originalLocalAppData
    if (Test-Path -LiteralPath $testPreferenceRoot -PathType Container) {
        [IO.Directory]::Delete($testPreferenceRoot, $true)
    }
}

$originalInstallDirectory = $script:InstallDirectory
$originalSettingsPath = $script:SettingsPath
$originalLogPath = $script:LogPath
$testSettingsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Tests.' + [Guid]::NewGuid().ToString('N'))
try {
    $script:InstallDirectory = $testSettingsDirectory
    $script:SettingsPath = Join-Path $testSettingsDirectory 'settings.json'
    $script:LogPath = Join-Path $testSettingsDirectory 'TrayTunnel.log'
    $defaultSettings = Read-AppSettings
    Assert-Equal $false $defaultSettings.AutoDisconnectOnCompanyNetwork 'automatic disconnect must be opt-in'
    Assert-Equal '' $defaultSettings.CompanyDnsSuffix 'new settings must not embed employer-specific configuration'
    $unicodeVpnAddress = 'vpn.example.com/Gr{0}ppe' -f [char]0x00FC
    $unicodeUsername = 'J{0}rg' -f [char]0x00F6
    $unicodeSettings = [pscustomobject]@{
        VpnAddress        = $unicodeVpnAddress
        Username          = $unicodeUsername
        PasswordEncrypted = $ciphertext
        AcceptLoginBanner = $false
        AutoDisconnectOnCompanyNetwork = $true
        CompanyDnsSuffix  = ' Office.Example.Com. '
        VpnCliPath        = 'C:\Program Files\Cisco\vpncli.exe'
    }
    Save-AppSettings -Settings $unicodeSettings
    $roundTrippedSettings = Read-AppSettings
    Assert-Equal $unicodeVpnAddress $roundTrippedSettings.VpnAddress 'UTF-8 VPN addresses must round-trip under Windows PowerShell 5.1'
    Assert-Equal $unicodeUsername $roundTrippedSettings.Username 'UTF-8 usernames must round-trip under Windows PowerShell 5.1'
    Assert-Equal $true $roundTrippedSettings.AutoDisconnectOnCompanyNetwork 'the automatic disconnect preference must survive saving and reloading'
    Assert-Equal 'office.example.com' $roundTrippedSettings.CompanyDnsSuffix 'the normalized company suffix must survive saving and reloading'

    $emptyRule = $unicodeSettings.PSObject.Copy()
    $emptyRule.CompanyDnsSuffix = ''
    Assert-Throws -Because 'an enabled rule must require a suffix' -MessagePattern '*Enter a company DNS suffix*' -Operation {
        Save-AppSettings -Settings $emptyRule
    }

    $storedDocument = [IO.File]::ReadAllText($script:SettingsPath, (New-Object Text.UTF8Encoding($false))) | ConvertFrom-Json
    $storedDocument.AcceptLoginBanner = 'false'
    $storedDocument.AutoDisconnectOnCompanyNetwork = 'true'
    $storedJson = $storedDocument | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($script:SettingsPath, $storedJson, (New-Object Text.UTF8Encoding($false)))
    $strictSettings = Read-AppSettings
    Assert-Equal $false $strictSettings.AcceptLoginBanner 'a string-valued banner flag must fail closed'
    Assert-Equal $false $strictSettings.AutoDisconnectOnCompanyNetwork 'a string-valued auto-disconnect flag must not enable the feature'
    $storedDocument.PSObject.Properties.Remove('AutoDisconnectOnCompanyNetwork')
    $storedDocument.PSObject.Properties.Remove('CompanyDnsSuffix')
    [IO.File]::WriteAllText($script:SettingsPath, ($storedDocument | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false)))
    $olderSettings = Read-AppSettings
    Assert-Equal $false $olderSettings.AutoDisconnectOnCompanyNetwork 'existing settings must load with automatic disconnect disabled'
    Assert-Equal '' $olderSettings.CompanyDnsSuffix 'existing settings must load without requiring a suffix'
    Assert-Equal $true $olderSettings.Configured 'adding optional settings must preserve existing credentials'
    $storedDocument.SchemaVersion = $script:SettingsSchemaVersion + 1
    $storedJson = $storedDocument | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($script:SettingsPath, $storedJson, (New-Object Text.UTF8Encoding($false)))
    $unsupportedSchemaSettings = Read-AppSettings
    Assert-Equal $false $unsupportedSchemaSettings.Configured 'an unsupported settings schema must fail closed'
    Assert-True (-not [string]::IsNullOrWhiteSpace($unsupportedSchemaSettings.LoadError)) 'an unsupported settings schema must surface a load error'

    $storedDocument.PSObject.Properties.Remove('SchemaVersion')
    $storedJson = $storedDocument | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText($script:SettingsPath, $storedJson, (New-Object Text.UTF8Encoding($false)))
    $missingSchemaSettings = Read-AppSettings
    Assert-Equal $false $missingSchemaSettings.Configured 'a missing settings schema must fail closed'
    Assert-True (-not [string]::IsNullOrWhiteSpace($missingSchemaSettings.LoadError)) 'a missing settings schema must surface a load error'

    $script:NotifyIcon = $null
    $script:DisconnectReason = 'UserDisconnect'
    $script:DisconnectDeadline = [DateTime]::UtcNow.AddSeconds(30)
    Complete-DisconnectVerification -Outcome 'Success'
    Assert-Equal 'InitialDisconnected' $script:ApplicationState 'a verified user-requested disconnect must return to the neutral disconnected state'
    Assert-Equal '#7A7A7A' (Get-TrayPresentation -State $script:ApplicationState -Detail $script:StateDetail).Color 'a verified user-requested disconnect must use the grey icon'

    $script:DisconnectReason = 'UserCancel'
    $script:DisconnectDeadline = [DateTime]::UtcNow.AddSeconds(30)
    Complete-DisconnectVerification -Outcome 'Success'
    Assert-Equal 'InitialDisconnected' $script:ApplicationState 'a verified user cancellation must return to the neutral disconnected state'
    Assert-Equal 'Connection cancelled' $script:StateDetail 'a verified cancellation must retain its explanatory status text'
    Assert-Equal '#7A7A7A' (Get-TrayPresentation -State $script:ApplicationState -Detail $script:StateDetail).Color 'a verified user cancellation must use the grey icon'

    $script:DisconnectReason = 'ConnectFailure'
    $script:DisconnectDeadline = [DateTime]::UtcNow.AddSeconds(30)
    Complete-DisconnectVerification -Outcome 'Success'
    Assert-Equal 'DisconnectedError' $script:ApplicationState 'cleanup after a failed connection must remain an error state'
    Assert-Equal '#E04B4F' (Get-TrayPresentation -State $script:ApplicationState -Detail $script:StateDetail).Color 'cleanup after a failed connection must retain the red icon'

    $originalSnapshotProbe = ${function:Get-NetworkInterfaceSnapshot}
    $originalCliStarter = ${function:Start-CliOperation}
    $originalCliStopper = ${function:Stop-CliProcess}
    try {
        function Get-NetworkInterfaceSnapshot {
            if ($script:CompanyProbeThrows) { throw 'Adapter enumeration unavailable' }
            return $script:CompanyTestSnapshots
        }
        function Start-CliOperation {
            param($Operation, $InputText, $TimeoutSeconds)
            $script:CompanyTestCommands.Add($Operation)
            $script:ActiveOperation = [pscustomobject]@{ Name = $Operation; Transport = 'Process' }
            return $true
        }
        function Stop-CliProcess {
            param($Operation, $Reason)
            $script:CompanyTestStopped.Add($Operation.Name)
        }

        $script:Settings = $roundTrippedSettings
        $script:CompanyTestCommands = New-Object 'Collections.Generic.List[string]'
        $script:CompanyTestStopped = New-Object 'Collections.Generic.List[string]'
        $script:CompanyTestSnapshots = @($companyWifi)
        $script:CompanyProbeThrows = $false
        $script:CompanyNetworkDetected = $false
        $script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
        $script:DisconnectDeadline = [DateTime]::MinValue
        $script:ApplicationState = 'Connected'
        $script:ActiveOperation = [pscustomobject]@{ Name = 'Status'; Transport = 'Process' }

        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 1 $script:CompanyTestCommands.Count 'arriving on a company network must issue one automatic disconnect'
        Assert-Equal 'Disconnect' $script:CompanyTestCommands[0] 'automatic disconnect must use Cisco disconnect'
        Assert-Equal 'Status' $script:CompanyTestStopped[0] 'automatic disconnect must detach a pending status query'
        Assert-Equal 'CompanyNetwork' $script:DisconnectReason 'automatic disconnect must retain its intentional reason'
        Assert-Equal 'Disconnecting' $script:ApplicationState 'the icon must not claim the VPN is off before Cisco confirms'
        Invoke-CompanyNetworkPolicy
        Assert-Equal 1 $script:CompanyTestCommands.Count 'repeated timer ticks must not duplicate an in-flight disconnect'

        $script:ActiveOperation = $null
        Complete-StatusQuery -State 'Disconnected' -Succeeded $true -TimedOut $false
        Assert-Equal 'CompanyNetwork' $script:ApplicationState 'a verified automatic disconnect must enter company network mode'
        Assert-Equal '#7A7A7A' (Get-TrayPresentation -State $script:ApplicationState).Color 'a verified automatic disconnect must be grey rather than red'
        Complete-StatusQuery -State 'Disconnected' -Succeeded $true -TimedOut $false
        Assert-Equal 'CompanyNetwork' $script:ApplicationState 'subsequent status polls must preserve the company network explanation'
        Invoke-TrayAction
        Assert-Equal 1 $script:CompanyTestCommands.Count 'clicking the tray on the company network must not start a connection'

        $script:CompanyTestSnapshots = @($wifiSnapshot)
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 'InitialDisconnected' $script:ApplicationState 'leaving the company network must restore the ordinary disconnected state'
        Assert-Equal 'Connect' (Get-TrayActionKind -State $script:ApplicationState) 'Connect must become available after leaving the company network'
        Assert-Equal 1 $script:CompanyTestCommands.Count 'leaving the company network must not automatically connect'

        $script:Settings.AutoDisconnectOnCompanyNetwork = $false
        $script:CompanyTestSnapshots = @($companyWifi)
        $script:ApplicationState = 'Connected'
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 'Connected' $script:ApplicationState 'disabling the feature must leave an active VPN alone even with a matching suffix'
        Assert-Equal 1 $script:CompanyTestCommands.Count 'a disabled rule must not issue commands'

        $script:Settings.AutoDisconnectOnCompanyNetwork = $true
        $script:ApplicationState = 'Connecting'
        $script:ActiveOperation = [pscustomobject]@{ Name = 'Connect'; Transport = 'Process' }
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 'Connect' $script:CompanyTestStopped[1] 'arriving during authentication must stop the pending connect process'
        Assert-Equal 2 $script:CompanyTestCommands.Count 'a pending connect must also be cancelled through Cisco disconnect'
        $script:ActiveOperation = $null
        Complete-DisconnectVerification -Outcome 'Connected'
        Assert-Equal 'Connected' $script:ApplicationState 'a failed automatic disconnect must not pretend the VPN is off'
        Assert-Equal 'Disconnect failed; still connected' $script:StateDetail 'failed automatic disconnect must explain the real state'
        Invoke-CompanyNetworkPolicy
        Assert-Equal 2 $script:CompanyTestCommands.Count 'failed automatic disconnects must have a retry cooldown'
        Invoke-CompanyNetworkPolicy -Now ([DateTime]::UtcNow.AddSeconds(31))
        Assert-Equal 3 $script:CompanyTestCommands.Count 'automatic disconnect may retry after the cooldown'
        $script:ActiveOperation = $null
        Complete-DisconnectVerification -Outcome 'Unavailable'
        Assert-Equal 'DisconnectedError' $script:ApplicationState 'an unverified disconnect must retain a visible error'
        Assert-Equal 'Disconnect result unavailable' $script:StateDetail 'an unverified automatic disconnect must describe the failed verification'

        $script:CompanyProbeThrows = $true
        $script:ApplicationState = 'Connected'
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal $false $script:CompanyNetworkDetected 'an unavailable adapter probe must not claim the company network is present'
        Assert-Equal 3 $script:CompanyTestCommands.Count 'an unavailable adapter probe must never trigger a disconnect'
        $script:CompanyProbeThrows = $false
        $script:CompanyTestSnapshots = @($tunnelSnapshot)
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 3 $script:CompanyTestCommands.Count 'a matching virtual adapter alone must not disconnect an active VPN'

        $script:CompanyTestSnapshots = @($companyWifi)
        $script:ApplicationState = 'InitialDisconnected'
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 'CompanyNetwork' $script:ApplicationState 'starting disconnected on the company network must show the neutral company state'
        Assert-Equal 3 $script:CompanyTestCommands.Count 'an already disconnected VPN must not need another disconnect command'
        $script:Settings.CompanyDnsSuffix = 'other.example.com'
        Update-CompanyNetworkStatus -Force
        Assert-Equal 'InitialDisconnected' $script:ApplicationState 'editing the suffix to a different network must remove company network mode'

        $script:Settings.CompanyDnsSuffix = 'office.example.com'
        $script:ApplicationState = 'Connecting'
        Update-CompanyNetworkStatus -Force
        Invoke-CompanyNetworkPolicy
        Assert-Equal 4 $script:CompanyTestCommands.Count 'Cisco-owned reconnects must also be stopped on the company network'
        $script:ActiveOperation = $null
        $script:CompanyTestSnapshots = @($wifiSnapshot)
        Update-CompanyNetworkStatus -Force
        Complete-DisconnectVerification -Outcome 'Success'
        Assert-Equal 'InitialDisconnected' $script:ApplicationState 'leaving during disconnect verification must finish in ordinary grey disconnected state'

        $script:CompanyTestSnapshots = @($companyWifi)
        $script:ApplicationState = 'Connected'
        Update-CompanyNetworkStatus -Force
        Set-ApplicationStateFromCiscoState -State 'Disconnected'
        Assert-Equal 'CompanyNetwork' $script:ApplicationState 'a Cisco disconnect event on the company network must not be misreported as connection loss'
    }
    finally {
        Set-Item -LiteralPath 'Function:\Get-NetworkInterfaceSnapshot' -Value $originalSnapshotProbe
        Set-Item -LiteralPath 'Function:\Start-CliOperation' -Value $originalCliStarter
        Set-Item -LiteralPath 'Function:\Stop-CliProcess' -Value $originalCliStopper
        $script:CompanyNetworkDetected = $false
        $script:NextCompanyNetworkCheck = [DateTime]::MinValue
        $script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
        $script:ActiveOperation = $null
    }
}
finally {
    $script:InstallDirectory = $originalInstallDirectory
    $script:SettingsPath = $originalSettingsPath
    $script:LogPath = $originalLogPath
    if (Test-Path -LiteralPath $testSettingsDirectory -PathType Container) {
        [IO.Directory]::Delete($testSettingsDirectory, $true)
    }
}

$originalProgramFiles = $env:ProgramFiles
$originalProgramFilesX86 = ${env:ProgramFiles(x86)}
$originalProgramW6432 = $env:ProgramW6432
$missingCiscoRoot = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Missing.' + [Guid]::NewGuid().ToString('N'))
$testCiscoRoot = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Cisco.' + [Guid]::NewGuid().ToString('N'))
$secureClientDirectory = Join-Path $testCiscoRoot 'Cisco\Cisco Secure Client'
$legacyClientDirectory = Join-Path $testCiscoRoot 'Cisco\Cisco AnyConnect Secure Mobility Client'
$secureCliPath = Join-Path $secureClientDirectory 'vpncli.exe'
$legacyCliPath = Join-Path $legacyClientDirectory 'vpncli.exe'
$secureUiPath = Join-Path $secureClientDirectory 'UI\csc_ui.exe'
$legacyUiPath = Join-Path $legacyClientDirectory 'vpnui.exe'
$pathSettingsDirectory = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.PathSettings.' + [Guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $secureClientDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $legacyClientDirectory -Force | Out-Null
    [IO.File]::WriteAllText($secureCliPath, 'test')
    [IO.File]::WriteAllText($legacyCliPath, 'test')

    $env:ProgramFiles = $testCiscoRoot
    ${env:ProgramFiles(x86)} = $testCiscoRoot
    $env:ProgramW6432 = $testCiscoRoot
    $productionCandidates = @(Get-CiscoExecutablePaths -ExecutableName 'vpncli.exe')
    Assert-Equal $false ($productionCandidates -contains $secureCliPath) 'caller-controlled Program Files environment variables must not redirect Cisco discovery'
    Assert-Equal $false ((Resolve-VpnCliPath -ConfiguredPath '') -ieq $secureCliPath) 'production discovery must ignore a fake Cisco CLI below a poisoned environment root'
    Assert-Equal $false ((Resolve-VpnCliPath -ConfiguredPath $scriptPath) -ieq $scriptPath) 'an arbitrary configured executable path must not be trusted'

    $failedHealth = Invoke-ReadOnlyHealthCheck -ProgramFilesRoots @($missingCiscoRoot)
    Assert-Equal $false $failedHealth.Success 'an injected missing Cisco root must make the health check fail'
    Assert-True (-not [string]::IsNullOrWhiteSpace($failedHealth.Error)) 'a failed health check must explain why Cisco was not found'

    $testProgramFilesRoots = @($testCiscoRoot)
    Assert-True ((Get-CiscoExecutablePaths -ExecutableName 'vpncli.exe' -ProgramFilesRoots $testProgramFilesRoots) -contains $secureCliPath) 'explicit test roots must support deterministic offline discovery'
    Assert-Equal $secureCliPath (Resolve-VpnCliPath -ConfiguredPath '' -ProgramFilesRoots $testProgramFilesRoots) 'Secure Client 5.x must be detected automatically'
    $staleLegacyPath = Join-Path $missingCiscoRoot 'Cisco\Cisco AnyConnect Secure Mobility Client\vpncli.exe'
    Assert-Equal $secureCliPath (Resolve-VpnCliPath -ConfiguredPath $staleLegacyPath -ProgramFilesRoots $testProgramFilesRoots) 'a removed AnyConnect path must migrate to Secure Client'
    Assert-Equal $secureCliPath (Resolve-VpnCliPath -ConfiguredPath $legacyCliPath -ProgramFilesRoots $testProgramFilesRoots) 'Secure Client must win when both generations remain installed'

    $uiCandidates = @(Get-CiscoVpnUiExecutablePaths -ProgramFilesRoots $testProgramFilesRoots)
    Assert-True ($uiCandidates -contains $secureUiPath) 'Secure Client csc_ui.exe must be a trusted VPN UI candidate'
    Assert-True ($uiCandidates -contains $legacyUiPath) 'legacy vpnui.exe must remain a trusted VPN UI candidate'
    Assert-Equal $true (Test-CiscoVpnUiExecutablePath -ProcessPath $secureUiPath.ToUpperInvariant() -CandidatePaths $uiCandidates) 'Cisco VPN UI path matching must be case-insensitive'
    Assert-Equal $false (Test-CiscoVpnUiExecutablePath -ProcessPath (Join-Path $testCiscoRoot 'Unrelated\csc_ui.exe') -CandidatePaths $uiCandidates) 'an unrelated same-name process must not block a connection'
    Assert-Equal $false (Test-CiscoVpnUiExecutablePath -ProcessPath (Join-Path $secureClientDirectory 'vpnagent.exe') -CandidatePaths $uiCandidates) 'the Cisco VPN agent service executable must not count as a UI conflict'

    New-Item -ItemType Directory -Path (Split-Path -Parent $secureUiPath) -Force | Out-Null
    [IO.File]::WriteAllText($secureUiPath, 'test')
    Assert-Equal $secureUiPath (Resolve-CiscoIconPath -ProgramFilesRoots $testProgramFilesRoots) 'Secure Client csc_ui.exe must be available as the shortcut icon'

    $script:InstallDirectory = $pathSettingsDirectory
    $script:SettingsPath = Join-Path $pathSettingsDirectory 'settings.json'
    $script:LogPath = Join-Path $pathSettingsDirectory 'TrayTunnel.log'
    $migrationSettings = [pscustomobject]@{
        SchemaVersion      = $script:SettingsSchemaVersion
        VpnAddress        = 'vpn.example.com'
        Username          = 'test-user'
        PasswordEncrypted = $ciphertext
        AcceptLoginBanner = $false
        VpnCliPath        = $staleLegacyPath
    }
    Save-AppSettings -Settings $migrationSettings
    $migratedSettings = Read-AppSettings -ProgramFilesRoots $testProgramFilesRoots
    Assert-Equal $secureCliPath $migratedSettings.VpnCliPath 'loading settings must replace a stale cached CLI path with the current detection'

    [IO.File]::Delete($secureCliPath)
    Assert-Equal $legacyCliPath (Resolve-VpnCliPath -ConfiguredPath '' -ProgramFilesRoots $testProgramFilesRoots) 'legacy AnyConnect must remain supported when Secure Client is absent'
}
finally {
    $env:ProgramFiles = $originalProgramFiles
    ${env:ProgramFiles(x86)} = $originalProgramFilesX86
    $env:ProgramW6432 = $originalProgramW6432
    $script:InstallDirectory = $originalInstallDirectory
    $script:SettingsPath = $originalSettingsPath
    $script:LogPath = $originalLogPath
    foreach ($temporaryDirectory in @($testCiscoRoot, $pathSettingsDirectory)) {
        if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
            [IO.Directory]::Delete($temporaryDirectory, $true)
        }
    }
}

$atomicCopyDirectory = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.AtomicCopy.' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($atomicCopyDirectory)
    $atomicSourcePath = Join-Path $atomicCopyDirectory 'source.ps1'
    $atomicDestinationPath = Join-Path $atomicCopyDirectory 'destination.ps1'

    [IO.File]::WriteAllText($atomicSourcePath, 'first version')
    Copy-FileAtomically -SourcePath $atomicSourcePath -DestinationPath $atomicDestinationPath
    Assert-Equal 'first version' ([IO.File]::ReadAllText($atomicDestinationPath)) 'an atomic first install must create the complete destination'

    [IO.File]::WriteAllText($atomicSourcePath, 'second version')
    Copy-FileAtomically -SourcePath $atomicSourcePath -DestinationPath $atomicDestinationPath
    Assert-Equal 'second version' ([IO.File]::ReadAllText($atomicDestinationPath)) 'an atomic update must replace the complete destination'
    Assert-Equal 0 @(Get-ChildItem -LiteralPath $atomicCopyDirectory -Filter 'TrayTunnel.install.*' -File).Count 'successful atomic copies must remove their staging and backup files'

    [IO.File]::WriteAllText($atomicDestinationPath, 'stable version')
    $missingAtomicSourcePath = Join-Path $atomicCopyDirectory 'missing.ps1'
    Assert-Throws -Because 'a failed atomic copy must not disturb the installed script' -MessagePattern '*source file was not found*' -Operation {
        Copy-FileAtomically -SourcePath $missingAtomicSourcePath -DestinationPath $atomicDestinationPath
    }
    Assert-Equal 'stable version' ([IO.File]::ReadAllText($atomicDestinationPath)) 'a failed atomic copy must preserve the previous destination'
}
finally {
    if (Test-Path -LiteralPath $atomicCopyDirectory -PathType Container) {
        [IO.Directory]::Delete($atomicCopyDirectory, $true)
    }
}

$tempShortcutPath = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Tests.' + [Guid]::NewGuid().ToString('N') + '.lnk')
try {
    New-AppShortcut -ShortcutPath $tempShortcutPath -ScriptPath $scriptPath
    Assert-True (Test-AppShortcutOwned -ShortcutPath $tempShortcutPath -ScriptPath $scriptPath) 'a shortcut created by the app must be recognized as owned'

    $wshShell = New-Object -ComObject WScript.Shell
    $changedShortcut = $wshShell.CreateShortcut($tempShortcutPath)
    $changedShortcut.Arguments = '-NoProfile'
    $changedShortcut.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($changedShortcut)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshShell)
    Assert-Equal $false (Test-AppShortcutOwned -ShortcutPath $tempShortcutPath -ScriptPath $scriptPath) 'a modified shortcut must not be treated as owned'
}
finally {
    if (Test-Path -LiteralPath $tempShortcutPath -PathType Leaf) {
        Remove-Item -LiteralPath $tempShortcutPath -Force
    }
}

$migrationTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Migration.' + [Guid]::NewGuid().ToString('N'))
try {
    $legacyInstallDirectory = Join-Path $migrationTestRoot 'AnyConnectTray'
    $newInstallDirectory = Join-Path $migrationTestRoot 'TrayTunnel'
    [void][IO.Directory]::CreateDirectory($legacyInstallDirectory)
    [void][IO.Directory]::CreateDirectory($newInstallDirectory)

    $legacyInstalledScriptPath = Join-Path $legacyInstallDirectory 'AnyConnectTray.ps1'
    $legacySettingsPath = Join-Path $legacyInstallDirectory 'settings.json'
    $legacyLogPath = Join-Path $legacyInstallDirectory 'AnyConnectTray.log'
    $legacyStartMenuShortcutPath = Join-Path $migrationTestRoot 'AnyConnect Tray Start.lnk'
    $legacyDesktopShortcutPath = Join-Path $migrationTestRoot 'AnyConnect Tray Desktop.lnk'
    $newInstalledScriptPath = Join-Path $newInstallDirectory 'TrayTunnel.ps1'
    $newSettingsPath = Join-Path $newInstallDirectory 'settings.json'
    $newStartMenuShortcutPath = Join-Path $migrationTestRoot 'TrayTunnel Start.lnk'
    $newDesktopShortcutPath = Join-Path $migrationTestRoot 'TrayTunnel Desktop.lnk'

    $validLegacyScript = @'
$script:ProductName = 'AnyConnect Tray'
$script:AppId = 'AnyConnectTray'
$script:Version = '0.1.8'
$script:InstallDirectory = 'unused'
$script:InstalledScriptPath = Join-Path $script:InstallDirectory 'AnyConnectTray.ps1'
function Uninstall-App {
}
if ($Uninstall) {
    Uninstall-App
}
'@
    $validSettingsJson = '{"SchemaVersion":1,"VpnAddress":"vpn.example.com"}'
    [IO.File]::WriteAllText($legacyInstalledScriptPath, $validLegacyScript)
    [IO.File]::WriteAllText($legacySettingsPath, $validSettingsJson)
    [IO.File]::WriteAllText($legacyLogPath, 'legacy log')
    [IO.File]::WriteAllText("$legacyLogPath.old", 'older legacy log')
    New-AppShortcut -ShortcutPath $legacyStartMenuShortcutPath -ScriptPath $legacyInstalledScriptPath
    New-AppShortcut -ShortcutPath $legacyDesktopShortcutPath -ScriptPath $legacyInstalledScriptPath

    Assert-Equal $true (Test-ApplicationScriptIdentity -Path $legacyInstalledScriptPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'all strict legacy identity markers must be recognized'
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $legacyInstalledScriptPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'TrayTunnel.ps1') 'a mismatched installed filename marker must fail identity recognition'
    Assert-Equal $true (Test-ApplicationScriptIdentity -Path $scriptPath -ExpectedAppId 'TrayTunnel' -ExpectedProductName 'TrayTunnel' -ExpectedInstalledFileName 'TrayTunnel.ps1') 'the current script must pass strict identity recognition'
    $invalidVersionIdentityPath = Join-Path $migrationTestRoot 'Invalid version legacy.ps1'
    [IO.File]::WriteAllText($invalidVersionIdentityPath, $validLegacyScript.Replace('0.1.8', 'not-semver'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $invalidVersionIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'an invalid SemVer marker must fail identity recognition'
    $missingUninstallIdentityPath = Join-Path $migrationTestRoot 'Missing uninstall legacy.ps1'
    $uninstallMarkerIndex = $validLegacyScript.IndexOf('function Uninstall-App')
    [IO.File]::WriteAllText($missingUninstallIdentityPath, $validLegacyScript.Substring(0, $uninstallMarkerIndex))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $missingUninstallIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'missing uninstall markers must fail identity recognition'

    $duplicateIdentityPath = Join-Path $migrationTestRoot 'Duplicate identity assignment.ps1'
    [IO.File]::WriteAllText($duplicateIdentityPath, ($validLegacyScript + [Environment]::NewLine + '$script:AppId = ''AnyConnectTray'''))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $duplicateIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'duplicate top-level identity assignments must fail identity recognition'

    $leadingZeroVersionIdentityPath = Join-Path $migrationTestRoot 'Leading-zero version legacy.ps1'
    [IO.File]::WriteAllText($leadingZeroVersionIdentityPath, $validLegacyScript.Replace('0.1.8', '01.1.8'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $leadingZeroVersionIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'a leading-zero version must fail strict SemVer validation'

    $hereStringIdentityPath = Join-Path $migrationTestRoot 'Here-string identity decoy.ps1'
    [IO.File]::WriteAllText($hereStringIdentityPath, ('$decoy = @"' + [Environment]::NewLine + $validLegacyScript + [Environment]::NewLine + '"@'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $hereStringIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'identity markers inside a here-string must not authorize cleanup'

    $blockCommentIdentityPath = Join-Path $migrationTestRoot 'Block-comment identity decoy.ps1'
    [IO.File]::WriteAllText($blockCommentIdentityPath, ('<#' + [Environment]::NewLine + $validLegacyScript + [Environment]::NewLine + '#>'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $blockCommentIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'identity markers inside a block comment must not authorize cleanup'

    $redirectedPathIdentityPath = Join-Path $migrationTestRoot 'Redirected installed path identity.ps1'
    $redirectedPathScript = $validLegacyScript.Replace(
        '$script:InstalledScriptPath = Join-Path $script:InstallDirectory ''AnyConnectTray.ps1''',
        '$script:InstalledScriptPath = Join-Path $script:InstallDirectory ''AnyConnectTray.ps1'' *> $null'
    )
    [IO.File]::WriteAllText($redirectedPathIdentityPath, $redirectedPathScript)
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $redirectedPathIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'a redirected Join-Path command must fail identity recognition'

    $filterIdentityPath = Join-Path $migrationTestRoot 'Filter uninstall identity.ps1'
    [IO.File]::WriteAllText($filterIdentityPath, $validLegacyScript.Replace('function Uninstall-App', 'filter Uninstall-App'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $filterIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'an uninstall filter must not masquerade as the required function'

    $redirectedUninstallIdentityPath = Join-Path $migrationTestRoot 'Redirected uninstall dispatch.ps1'
    [IO.File]::WriteAllText($redirectedUninstallIdentityPath, $validLegacyScript.Replace('    Uninstall-App', '    Uninstall-App *> $null'))
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $redirectedUninstallIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'a redirected uninstall call must fail identity recognition'

    $extraDispatchIdentityPath = Join-Path $migrationTestRoot 'Extra uninstall dispatch statement.ps1'
    $extraDispatchScript = $validLegacyScript.Replace('    Uninstall-App', ('    Uninstall-App' + [Environment]::NewLine + '    Get-Date'))
    [IO.File]::WriteAllText($extraDispatchIdentityPath, $extraDispatchScript)
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $extraDispatchIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'an arbitrary second uninstall-dispatch statement must fail identity recognition'

    $trappedDispatchIdentityPath = Join-Path $migrationTestRoot 'Trapped uninstall dispatch.ps1'
    $trappedDispatchScript = $validLegacyScript.Replace('    Uninstall-App', ('    trap { continue }' + [Environment]::NewLine + '    Uninstall-App'))
    [IO.File]::WriteAllText($trappedDispatchIdentityPath, $trappedDispatchScript)
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $trappedDispatchIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'an uninstall dispatch with a trap must fail identity recognition'

    $nonzeroExitIdentityPath = Join-Path $migrationTestRoot 'Nonzero uninstall dispatch exit.ps1'
    $nonzeroExitScript = $validLegacyScript.Replace('    Uninstall-App', ('    Uninstall-App' + [Environment]::NewLine + '    exit 1'))
    [IO.File]::WriteAllText($nonzeroExitIdentityPath, $nonzeroExitScript)
    Assert-Equal $false (Test-ApplicationScriptIdentity -Path $nonzeroExitIdentityPath -ExpectedAppId 'AnyConnectTray' -ExpectedProductName 'AnyConnect Tray' -ExpectedInstalledFileName 'AnyConnectTray.ps1') 'only exit 0 may follow the uninstall call'

    Assert-Equal $true (Test-MigrationSettingsFileValid -Path $legacySettingsPath) 'SchemaVersion 1 UTF-8 JSON must be valid migration settings'

    $legacyStartupCommand = Get-StartupCommand -ScriptPath $legacyInstalledScriptPath
    $legacyStateParameters = @{
        InstallDirectory      = $legacyInstallDirectory
        InstalledScriptPath   = $legacyInstalledScriptPath
        SettingsPath          = $legacySettingsPath
        LogPath               = $legacyLogPath
        StartMenuShortcutPath = $legacyStartMenuShortcutPath
        DesktopShortcutPath   = $legacyDesktopShortcutPath
        StartupCommand        = $legacyStartupCommand
    }
    $legacyState = Get-LegacyMigrationState @legacyStateParameters
    Assert-Equal $true $legacyState.HasArtifacts 'the one-time migration must recognize exact legacy per-user artifacts'
    Assert-Equal $true $legacyState.IdentityRecognized 'strict legacy identity must gate migration cleanup'
    Assert-Equal $true $legacyState.InstallScriptRecognized 'the valid legacy script must be an identity anchor'
    Assert-Equal $true $legacyState.SettingsValid 'valid legacy settings must be eligible for migration'
    Assert-Equal $true $legacyState.SettingsPresent 'the one-time migration must recognize legacy settings'
    Assert-Equal $true $legacyState.LogPresent 'the one-time migration must recognize the legacy log'
    Assert-Equal $true $legacyState.OldLogPresent 'the one-time migration must recognize the rotated legacy log'
    Assert-Equal $true $legacyState.StartupEnabled 'the one-time migration must capture an owned legacy startup entry'
    Assert-Equal $true $legacyState.DesktopShortcutOwned 'the one-time migration must capture the legacy Desktop choice'

    $disabledChoiceParameters = $legacyStateParameters.Clone()
    $disabledChoiceParameters.StartupCommand = $null
    $disabledChoiceParameters.DesktopShortcutPath = Join-Path $migrationTestRoot 'No legacy Desktop shortcut.lnk'
    $disabledChoiceState = Get-LegacyMigrationState @disabledChoiceParameters
    Assert-Equal $false $disabledChoiceState.StartupEnabled 'a disabled legacy startup choice must remain distinguishable'
    Assert-Equal $false $disabledChoiceState.DesktopShortcutOwned 'an absent legacy Desktop shortcut must remain distinguishable'
    Assert-Equal $true $disabledChoiceState.IdentityRecognized 'a valid legacy script must independently anchor migration'
    $legacyChoice = Resolve-InstallationChoices -MigrationPerformed $true -LegacyStartupEnabled $true -LegacyDesktopShortcutOwned $true -NewIdentityRecognized $false -NewStartupEnabled $false -NewDesktopShortcutOwned $false -DesktopShortcutRequested $false
    Assert-Equal $true $legacyChoice.StartupEnabled 'legacy startup choice must be used for a first migration'
    Assert-Equal $true $legacyChoice.DesktopShortcutEnabled 'legacy Desktop choice must be used for a first migration'
    $currentChoice = Resolve-InstallationChoices -MigrationPerformed $true -LegacyStartupEnabled $true -LegacyDesktopShortcutOwned $true -NewIdentityRecognized $true -NewStartupEnabled $false -NewDesktopShortcutOwned $false -DesktopShortcutRequested $false
    Assert-Equal $false $currentChoice.StartupEnabled 'a recognized current installation must override stale legacy startup residue'
    Assert-Equal $false $currentChoice.DesktopShortcutEnabled 'a recognized current installation must override stale legacy Desktop residue'
    $requestedCurrentChoice = Resolve-InstallationChoices -MigrationPerformed $true -LegacyStartupEnabled $false -LegacyDesktopShortcutOwned $false -NewIdentityRecognized $true -NewStartupEnabled $false -NewDesktopShortcutOwned $false -DesktopShortcutRequested $true
    Assert-Equal $true $requestedCurrentChoice.DesktopShortcutEnabled 'an explicit Desktop request must override preserved choices'


    $unrecognizedDirectory = Join-Path (Join-Path $migrationTestRoot 'unrecognized') 'AnyConnectTray'
    [void][IO.Directory]::CreateDirectory($unrecognizedDirectory)
    $unrecognizedScriptPath = Join-Path $unrecognizedDirectory 'AnyConnectTray.ps1'
    $unrecognizedSettingsPath = Join-Path $unrecognizedDirectory 'settings.json'
    $unrecognizedLogPath = Join-Path $unrecognizedDirectory 'AnyConnectTray.log'
    $unrecognizedStartShortcut = Join-Path $migrationTestRoot 'Unrecognized Start.lnk'
    $unrecognizedDesktopShortcut = Join-Path $migrationTestRoot 'Unrecognized Desktop.lnk'
    [IO.File]::WriteAllText($unrecognizedScriptPath, 'unrelated application')
    [IO.File]::WriteAllText($unrecognizedSettingsPath, $validSettingsJson)
    [IO.File]::WriteAllText($unrecognizedLogPath, 'unrelated log')
    $unrecognizedParameters = @{
        InstallDirectory      = $unrecognizedDirectory
        InstalledScriptPath   = $unrecognizedScriptPath
        SettingsPath          = $unrecognizedSettingsPath
        LogPath               = $unrecognizedLogPath
        StartMenuShortcutPath = $unrecognizedStartShortcut
        DesktopShortcutPath   = $unrecognizedDesktopShortcut
        StartupCommand        = $null
    }
    $unrecognizedState = Get-LegacyMigrationState @unrecognizedParameters
    Assert-Equal $true $unrecognizedState.HasArtifacts 'exact legacy paths may contain artifacts without proving ownership'
    Assert-Equal $false $unrecognizedState.IdentityRecognized 'unrecognized exact-path files must not authorize migration'
    Assert-Throws -Because 'migration cleanup must refuse an unrecognized exact-path identity' -MessagePattern '*identity was not recognized*' -Operation {
        Remove-LegacyMigrationArtifacts -State $unrecognizedState -SkipStartupEntry
    }
    Assert-Throws -Because 'uninstall-equivalent cleanup must also refuse an unrecognized identity' -MessagePattern '*identity was not recognized*' -Operation {
        Remove-LegacyMigrationArtifacts -State $unrecognizedState -SkipStartupEntry
    }
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedScriptPath -PathType Leaf) 'refused cleanup must preserve an unrecognized script'
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedSettingsPath -PathType Leaf) 'refused cleanup must preserve unrecognized settings'
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedLogPath -PathType Leaf) 'refused cleanup must preserve an unrecognized log'

    New-AppShortcut -ShortcutPath $unrecognizedStartShortcut -ScriptPath $unrecognizedScriptPath
    $startAnchoredState = Get-LegacyMigrationState @unrecognizedParameters
    Assert-Equal $true $startAnchoredState.StartMenuShortcutOwned 'the exact legacy Start Menu shortcut must be detected'
    Assert-Equal $true $startAnchoredState.IdentityRecognized 'an exact-owned legacy Start Menu shortcut may anchor migration'
    New-AppShortcut -ShortcutPath $unrecognizedDesktopShortcut -ScriptPath $unrecognizedScriptPath
    $desktopAnchoredState = Get-LegacyMigrationState @unrecognizedParameters
    Assert-Equal $true $desktopAnchoredState.IdentityRecognized 'an exact-owned legacy Desktop shortcut may anchor migration'
    $anchorShell = New-Object -ComObject WScript.Shell
    $changedAnchor = $anchorShell.CreateShortcut($unrecognizedStartShortcut)
    $changedAnchor.Arguments = '-NoProfile'
    $changedAnchor.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($changedAnchor)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($anchorShell)
    Assert-Throws -Because 'changed anchor ownership must surface partial cleanup' -MessagePattern '*only partially completed*' -Operation {
        Remove-LegacyMigrationArtifacts -State $desktopAnchoredState -SkipStartupEntry
    }
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedStartShortcut -PathType Leaf) 'a changed Start Menu anchor must be preserved'
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedDesktopShortcut -PathType Leaf) 'another recognized anchor must remain for retry'
    Assert-Equal $true (Test-Path -LiteralPath $unrecognizedScriptPath -PathType Leaf) 'an unrecognized installed script must survive cleanup even when shortcuts identify the legacy installation'


    $settingsCaseDirectory = Join-Path $migrationTestRoot 'settings-cases'
    [void][IO.Directory]::CreateDirectory($settingsCaseDirectory)
    $caseLegacySettings = Join-Path $settingsCaseDirectory 'legacy.json'
    $caseNewSettings = Join-Path $settingsCaseDirectory 'new.json'
    [IO.File]::WriteAllText($caseLegacySettings, $validSettingsJson)
    foreach ($invalidSettingsText in @('', '{not-json', '{"SchemaVersion":2}', '{"SchemaVersion":"1"}')) {
        [IO.File]::WriteAllText($caseNewSettings, $invalidSettingsText)
        Assert-Throws -Because 'invalid pre-existing new settings must stop migration before cleanup' -MessagePattern '*must be non-empty UTF-8 JSON with SchemaVersion 1*' -Operation {
            Copy-LegacySettingsIfNeeded -LegacySettingsPath $caseLegacySettings -NewSettingsPath $caseNewSettings
        }
        Assert-Equal $validSettingsJson ([IO.File]::ReadAllText($caseLegacySettings)) 'invalid new settings must leave valid legacy settings untouched'
    }
    [IO.File]::WriteAllBytes($caseNewSettings, [byte[]]@(0xC3, 0x28))
    Assert-Throws -Because 'invalid UTF-8 new settings must stop migration before cleanup' -MessagePattern '*must be non-empty UTF-8 JSON with SchemaVersion 1*' -Operation {
        Copy-LegacySettingsIfNeeded -LegacySettingsPath $caseLegacySettings -NewSettingsPath $caseNewSettings
    }
    Assert-Equal $validSettingsJson ([IO.File]::ReadAllText($caseLegacySettings)) 'invalid UTF-8 new settings must preserve legacy settings'

    $validCurrentSettings = '{"SchemaVersion":1,"VpnAddress":"current.example.com"}'
    [IO.File]::WriteAllText($caseNewSettings, $validCurrentSettings)
    Assert-Equal $false (Copy-LegacySettingsIfNeeded -LegacySettingsPath $caseLegacySettings -NewSettingsPath $caseNewSettings) 'valid current settings must win without being overwritten'
    Assert-Equal $validCurrentSettings ([IO.File]::ReadAllText($caseNewSettings)) 'valid current settings content must remain unchanged'
    [IO.File]::Delete($caseNewSettings)
    [IO.File]::WriteAllText($caseLegacySettings, '{corrupt')
    Assert-Equal $false (Copy-LegacySettingsIfNeeded -LegacySettingsPath $caseLegacySettings -NewSettingsPath $caseNewSettings) 'invalid legacy settings must not be copied'
    Assert-Equal $false (Test-Path -LiteralPath $caseNewSettings) 'invalid legacy settings must not create new settings'

    $invalidLegacyDirectory = Join-Path (Join-Path $migrationTestRoot 'invalid-legacy') 'AnyConnectTray'
    [void][IO.Directory]::CreateDirectory($invalidLegacyDirectory)
    $invalidLegacyScript = Join-Path $invalidLegacyDirectory 'AnyConnectTray.ps1'
    $invalidLegacySettings = Join-Path $invalidLegacyDirectory 'settings.json'
    [IO.File]::WriteAllText($invalidLegacyScript, $validLegacyScript)
    [IO.File]::WriteAllText($invalidLegacySettings, '{corrupt')
    $invalidLegacyState = Get-LegacyMigrationState -InstallDirectory $invalidLegacyDirectory -InstalledScriptPath $invalidLegacyScript -SettingsPath $invalidLegacySettings -LogPath (Join-Path $invalidLegacyDirectory 'AnyConnectTray.log') -StartMenuShortcutPath (Join-Path $migrationTestRoot 'Invalid legacy Start.lnk') -DesktopShortcutPath (Join-Path $migrationTestRoot 'Invalid legacy Desktop.lnk') -StartupCommand $null
    Assert-Equal $true $invalidLegacyState.IdentityRecognized 'a valid legacy script must identify an installation with corrupt settings'
    Assert-Equal $false $invalidLegacyState.SettingsValid 'corrupt legacy settings must be marked ineligible'
    Remove-LegacyMigrationArtifacts -State $invalidLegacyState -SkipStartupEntry
    Assert-Equal $true (Test-Path -LiteralPath $invalidLegacySettings -PathType Leaf) 'corrupt legacy settings must survive cleanup'
    Assert-Equal $false (Test-Path -LiteralPath $invalidLegacyScript) 'other recognized legacy artifacts may still be cleaned'

    $settingsCopied = Copy-LegacySettingsIfNeeded -LegacySettingsPath $legacySettingsPath -NewSettingsPath $newSettingsPath
    Assert-Equal $true $settingsCopied 'legacy settings must be copied when the new settings file is absent'
    Assert-Equal ([IO.File]::ReadAllText($legacySettingsPath)) ([IO.File]::ReadAllText($newSettingsPath)) 'the settings migration must preserve exact content'

    [IO.File]::WriteAllText($legacySettingsPath, '{"SchemaVersion":1,"VpnAddress":"changed.example.com"}')
    $settingsCopiedAgain = Copy-LegacySettingsIfNeeded -LegacySettingsPath $legacySettingsPath -NewSettingsPath $newSettingsPath
    Assert-Equal $false $settingsCopiedAgain 'an existing new settings file must never be overwritten by legacy state'
    Assert-True (-not ([IO.File]::ReadAllText($newSettingsPath)).Contains('changed.example.com')) 'the existing new settings content must win on retry'
    [IO.File]::WriteAllText($legacySettingsPath, [IO.File]::ReadAllText($newSettingsPath))

    Copy-FileAtomically -SourcePath $scriptPath -DestinationPath $newInstalledScriptPath
    New-AppShortcut -ShortcutPath $newStartMenuShortcutPath -ScriptPath $newInstalledScriptPath
    New-AppShortcut -ShortcutPath $newDesktopShortcutPath -ScriptPath $newInstalledScriptPath
    $newStartupCommand = Get-StartupCommand -ScriptPath $newInstalledScriptPath
    $validationParameters = @{
        SourceScriptPath       = $scriptPath
        InstalledScriptPath    = $newInstalledScriptPath
        StartMenuShortcutPath  = $newStartMenuShortcutPath
        DesktopShortcutPath    = $newDesktopShortcutPath
        StartupEnabled         = $true
        DesktopShortcutEnabled = $true
        SettingsRequired       = $true
        SettingsCopied         = $true
        LegacySettingsPath     = $legacySettingsPath
        NewSettingsPath        = $newSettingsPath
        StartupCommand         = $newStartupCommand
    }
    Assert-Equal $null (Assert-NewInstallationValid @validationParameters) 'a complete new identity must validate before legacy cleanup'

    [IO.File]::WriteAllText($newInstalledScriptPath, 'incomplete new application')
    Assert-Throws -Because 'a partial new install must fail validation before legacy cleanup' -MessagePattern '*installed application script could not be verified*' -Operation {
        Assert-NewInstallationValid @validationParameters
    }
    Assert-Equal $true (Test-Path -LiteralPath $legacyInstalledScriptPath -PathType Leaf) 'failed validation must leave the legacy script intact'
    Assert-Equal $true (Test-Path -LiteralPath $legacySettingsPath -PathType Leaf) 'failed validation must leave legacy settings intact'
    Assert-Equal $true (Test-Path -LiteralPath $legacyStartMenuShortcutPath -PathType Leaf) 'failed validation must leave the legacy shortcut intact'

    Copy-FileAtomically -SourcePath $scriptPath -DestinationPath $newInstalledScriptPath
    Assert-Equal $null (Assert-NewInstallationValid @validationParameters) 'the repaired new identity must validate before cleanup'

    $unrelatedLegacyFile = Join-Path $legacyInstallDirectory 'user-note.txt'
    [IO.File]::WriteAllText($unrelatedLegacyFile, 'keep')
    $heldLegacyLog = [IO.File]::Open($legacyLogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $heldOldLegacyLog = [IO.File]::Open("$legacyLogPath.old", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $cleanupError = $null
        try {
            Remove-LegacyMigrationArtifacts -State $legacyState -SkipStartupEntry
        }
        catch {
            $cleanupError = $_.Exception.Message
        }
        Assert-True (-not [string]::IsNullOrWhiteSpace($cleanupError)) 'partial legacy cleanup must surface a terminating failure'
        Assert-True ($cleanupError.Contains($legacyLogPath)) 'aggregated cleanup failure must identify the locked legacy log'
        Assert-True ($cleanupError.Contains("$legacyLogPath.old")) 'aggregated cleanup failure must identify every locked legacy log'
        Assert-Equal $true (Test-Path -LiteralPath $legacyInstalledScriptPath -PathType Leaf) 'cleanup failure must retain the valid legacy script identity anchor'
        Assert-Equal $true (Test-Path -LiteralPath $legacyStartMenuShortcutPath -PathType Leaf) 'cleanup failure must retain the legacy Start Menu identity anchor'
        Assert-Equal $true (Test-Path -LiteralPath $legacyDesktopShortcutPath -PathType Leaf) 'cleanup failure must retain the legacy Desktop identity anchor'
    }
    finally {
        $heldOldLegacyLog.Dispose()
        $heldLegacyLog.Dispose()
    }

    $retryLegacyState = Get-LegacyMigrationState @legacyStateParameters
    Remove-LegacyMigrationArtifacts -State $retryLegacyState -SkipStartupEntry
    Assert-Equal $false (Test-Path -LiteralPath $legacyInstalledScriptPath) 'a successful retry must remove the exact recognized legacy script'
    Assert-Equal $false (Test-Path -LiteralPath $legacySettingsPath) 'validated migration must remove copied valid legacy settings'
    Assert-Equal $false (Test-Path -LiteralPath $legacyLogPath) 'a successful retry must remove the exact legacy log'
    Assert-Equal $false (Test-Path -LiteralPath $legacyStartMenuShortcutPath) 'a successful retry must remove an exact-owned legacy Start Menu shortcut'
    Assert-Equal $false (Test-Path -LiteralPath $legacyDesktopShortcutPath) 'a successful retry must remove an exact-owned legacy Desktop shortcut'
    Assert-Equal $true (Test-Path -LiteralPath $unrelatedLegacyFile -PathType Leaf) 'legacy cleanup must preserve unrelated files'
}
finally {
    if (Test-Path -LiteralPath $migrationTestRoot -PathType Container) {
        [IO.Directory]::Delete($migrationTestRoot, $true)
    }
}

. (Join-Path $PSScriptRoot 'Test-Upgrades.ps1')

Write-Host "Passed $script:Passed offline assertions."

if ($IncludeLocalHealthCheck) {
    & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $scriptPath `
        -HealthCheck
    if ($LASTEXITCODE -ne 0) {
        throw 'The read-only local health check failed.'
    }
}
