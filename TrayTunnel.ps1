#requires -Version 5.1

<#
.SYNOPSIS
    Minimal notification-area wrapper for Cisco Secure Client and legacy Cisco AnyConnect.

.DESCRIPTION
    Run without arguments to start the tray application. Use -Install to install it
    for the current user, -Uninstall to remove it, or -HealthCheck for a read-only
    local compatibility check.
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(ParameterSetName = 'Run')]
    [switch]$NoConsoleHost,

    [Parameter(Mandatory = $true, ParameterSetName = 'Install')]
    [switch]$Install,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$DesktopShortcut,

    [Parameter(ParameterSetName = 'Install')]
    [switch]$NoLaunch,

    [Parameter(Mandatory = $true, ParameterSetName = 'Uninstall')]
    [switch]$Uninstall,

    [Parameter(Mandatory = $true, ParameterSetName = 'HealthCheck')]
    [switch]$HealthCheck
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProductName = 'TrayTunnel'
$script:AppId = 'TrayTunnel'
$script:Version = '0.3.1'
$script:SettingsSchemaVersion = 1
$script:RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:LocalAppData = [Environment]::GetFolderPath('LocalApplicationData')
$script:InstallDirectory = Join-Path $script:LocalAppData $script:AppId
$script:InstalledScriptPath = Join-Path $script:InstallDirectory 'TrayTunnel.ps1'
$script:SettingsPath = Join-Path $script:InstallDirectory 'settings.json'
$script:LogPath = Join-Path $script:InstallDirectory 'TrayTunnel.log'
$script:SettingsMenuItem = $null
$script:CompanyNetworkDetected = $false
$script:NextCompanyNetworkCheck = [DateTime]::MinValue
$script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
$script:MutexLease = $null
$script:ExitRequest = $null
$script:ExitMenuItem = $null
$script:StartMenuShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'TrayTunnel.lnk'
$script:DesktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'TrayTunnel.lnk'

# Exact historical identifiers are used only to recognize and migrate old installs.
$script:LegacyAppId = 'AnyConnectTray'
$script:LegacyInstallDirectory = Join-Path $script:LocalAppData $script:LegacyAppId
$script:LegacyInstalledScriptPath = Join-Path $script:LegacyInstallDirectory 'AnyConnectTray.ps1'
$script:LegacySettingsPath = Join-Path $script:LegacyInstallDirectory 'settings.json'
$script:LegacyLogPath = Join-Path $script:LegacyInstallDirectory 'AnyConnectTray.log'
$script:LegacyStartMenuShortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'AnyConnect Tray.lnk'
$script:LegacyDesktopShortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'AnyConnect Tray.lnk'

function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found at: $path"
    }

    return $path
}

function Test-ProcessIsElevated {
    $identity = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }
}

function Assert-NonElevatedExecution {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IsElevated
    )

    if ($IsElevated) {
        throw "$($script:ProductName) is a per-user application and must not run as administrator. Open a normal, non-elevated Windows PowerShell window and try again."
    }
}

function Get-AppArguments {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [switch]$NoConsoleHost
    )

    if ($ScriptPath.IndexOf('"') -ge 0) {
        throw 'The application path cannot contain a quotation mark.'
    }

    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "{0}"' -f $ScriptPath
    if ($NoConsoleHost) {
        $arguments += ' -NoConsoleHost'
    }

    return $arguments
}

function Test-AppRehostRequired {
    param(
        [bool]$IsNoConsoleHost,
        [Threading.ApartmentState]$ApartmentState
    )

    return (-not $IsNoConsoleHost) -or $ApartmentState -ne [Threading.ApartmentState]::STA
}

function Get-StartupCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $powerShellPath = Get-WindowsPowerShellPath
    return '"{0}" {1}' -f $powerShellPath, (Get-AppArguments -ScriptPath $ScriptPath)
}

function Get-UserMutexName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationId
    )

    $identity = $null
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $userId = $identity.User.Value
    }
    catch {
        $userId = [Environment]::UserName
    }
    finally {
        if ($null -ne $identity) {
            $identity.Dispose()
        }
    }

    return 'Local\{0}-{1}' -f $ApplicationId, ($userId -replace '[^A-Za-z0-9_.-]', '_')
}

function Get-MutexName {
    return Get-UserMutexName -ApplicationId $script:AppId
}

function Get-LegacyMutexName {
    return Get-UserMutexName -ApplicationId $script:LegacyAppId
}

function Get-AppMutexNames {
    return @((Get-MutexName), (Get-UserMutexName -ApplicationId 'VpnCliTray'), (Get-LegacyMutexName))
}

function Get-TrustedProgramFilesRoots {
    $roots = @()

    foreach ($specialFolder in @(
            [Environment+SpecialFolder]::ProgramFilesX86,
            [Environment+SpecialFolder]::ProgramFiles
        )) {
        $knownFolderPath = [Environment]::GetFolderPath($specialFolder)
        if (-not [string]::IsNullOrWhiteSpace($knownFolderPath)) {
            $roots += $knownFolderPath
        }
    }

    foreach ($registryView in @(
            [Microsoft.Win32.RegistryView]::Registry64,
            [Microsoft.Win32.RegistryView]::Registry32
        )) {
        $baseKey = $null
        $currentVersionKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine,
                $registryView
            )
            $currentVersionKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion')
            if ($null -eq $currentVersionKey) {
                continue
            }

            foreach ($valueName in @('ProgramFilesDir (x86)', 'ProgramFilesDir')) {
                $machinePath = [string]$currentVersionKey.GetValue(
                    $valueName,
                    $null,
                    [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
                )
                if (-not [string]::IsNullOrWhiteSpace($machinePath) -and
                    $machinePath.IndexOf('%') -lt 0) {
                    $roots += $machinePath
                }
            }
        }
        catch {
            # Known-folder paths remain authoritative if a registry view is unavailable.
        }
        finally {
            if ($null -ne $currentVersionKey) {
                $currentVersionKey.Dispose()
            }
            if ($null -ne $baseKey) {
                $baseKey.Dispose()
            }
        }
    }

    $canonicalRoots = foreach ($root in $roots) {
        try {
            [IO.Path]::GetFullPath($root)
        }
        catch {
            # Ignore malformed machine configuration rather than trusting it.
        }
    }

    return $canonicalRoots | Select-Object -Unique
}

function Get-CiscoExecutablePaths {
    param(
        [ValidateSet('vpncli.exe', 'vpnui.exe')]
        [string]$ExecutableName = 'vpncli.exe',

        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $roots = if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        @($ProgramFilesRoots)
    }
    else {
        @(Get-TrustedProgramFilesRoots)
    }
    $roots = $roots |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { [IO.Path]::GetFullPath($_) } |
        Select-Object -Unique
    $productDirectories = @(
        'Cisco\Cisco Secure Client'
        'Cisco\Cisco AnyConnect Secure Mobility Client'
    )

    $paths = foreach ($productDirectory in $productDirectories) {
        foreach ($root in $roots) {
            Join-Path $root (Join-Path $productDirectory $ExecutableName)
        }
    }

    return $paths | Select-Object -Unique
}

function Resolve-VpnCliPath {
    param(
        [AllowEmptyString()]
        [string]$ConfiguredPath,

        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $candidateParameters = @{ ExecutableName = 'vpncli.exe' }
    if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        $candidateParameters.ProgramFilesRoots = $ProgramFilesRoots
    }
    $candidates = @(Get-CiscoExecutablePaths @candidateParameters)
    if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
        Assert-SingleLineValue -Name 'VPN CLI path' -Value $ConfiguredPath
        $configuredFullPath = [IO.Path]::GetFullPath($ConfiguredPath)
        foreach ($candidate in $candidates) {
            $candidateFullPath = [IO.Path]::GetFullPath($candidate)
            if ($configuredFullPath -ieq $candidateFullPath -and
                $candidateFullPath -match '(?i)[\\/]Cisco[\\/]Cisco Secure Client[\\/]vpncli\.exe$' -and
                (Test-Path -LiteralPath $candidateFullPath -PathType Leaf)) {
                return $candidateFullPath
            }
        }
    }

    # VpnCliPath is cached detected state, not a manual executable override.
    # Candidate order deliberately prefers Secure Client 5.x over legacy AnyConnect.
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Get-CiscoVpnUiExecutablePaths {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $candidateParameters = @{ ExecutableName = 'vpncli.exe' }
    if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        $candidateParameters.ProgramFilesRoots = $ProgramFilesRoots
    }
    $candidates = foreach ($cliCandidate in (Get-CiscoExecutablePaths @candidateParameters)) {
        $productDirectory = Split-Path -Parent $cliCandidate
        if ($cliCandidate -match '(?i)[\\/]Cisco[\\/]Cisco Secure Client[\\/]vpncli\.exe$') {
            Join-Path $productDirectory 'UI\csc_ui.exe'
        }
        Join-Path $productDirectory 'vpnui.exe'
    }

    return $candidates | Select-Object -Unique
}

function Resolve-CiscoIconPath {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $candidateParameters = @{}
    if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        $candidateParameters.ProgramFilesRoots = $ProgramFilesRoots
    }
    foreach ($candidate in (Get-CiscoVpnUiExecutablePaths @candidateParameters)) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }

    return $null
}

function Test-CiscoVpnUiExecutablePath {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ProcessPath,

        [Parameter(Mandatory = $true)]
        [string[]]$CandidatePaths
    )

    if ([string]::IsNullOrWhiteSpace($ProcessPath)) {
        return $false
    }

    try {
        $processFullPath = [IO.Path]::GetFullPath($ProcessPath)
    }
    catch {
        return $false
    }

    foreach ($candidatePath in $CandidatePaths) {
        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
            continue
        }

        try {
            if ($processFullPath -ieq [IO.Path]::GetFullPath($candidatePath)) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Get-RunningCiscoVpnUiProcesses {
    $candidatePaths = @(Get-CiscoVpnUiExecutablePaths)
    foreach ($process in @(Get-Process -Name 'csc_ui', 'vpnui' -ErrorAction SilentlyContinue)) {
        try {
            $processPath = [string]$process.Path
        }
        catch {
            continue
        }

        if (Test-CiscoVpnUiExecutablePath -ProcessPath $processPath -CandidatePaths $candidatePaths) {
            Write-Output $process
        }
    }
}

function Get-CiscoPreferenceDefaults {
    $result = [ordered]@{
        VpnAddress = ''
        Username   = [Environment]::UserName
    }

    $preferencePaths = @(
        (Join-Path $script:LocalAppData 'Cisco\Cisco Secure Client\VPN\preferences.xml')
        (Join-Path $script:LocalAppData 'Cisco\Cisco AnyConnect Secure Mobility Client\preferences.xml')
    )

    foreach ($path in $preferencePaths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }

        try {
            $readerSettings = New-Object Xml.XmlReaderSettings
            $readerSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
            $readerSettings.XmlResolver = $null
            $reader = [Xml.XmlReader]::Create($path, $readerSettings)
            try {
                $preferences = New-Object Xml.XmlDocument
                $preferences.XmlResolver = $null
                $preferences.Load($reader)
            }
            finally {
                $reader.Dispose()
            }
            $hostNode = $preferences.SelectSingleNode('//DefaultHostName')
            $userNode = $preferences.SelectSingleNode('//DefaultUser')

            if ($null -ne $hostNode -and -not [string]::IsNullOrWhiteSpace($hostNode.InnerText)) {
                $result.VpnAddress = $hostNode.InnerText.Trim()
            }
            if ($null -ne $userNode -and -not [string]::IsNullOrWhiteSpace($userNode.InnerText)) {
                $result.Username = $userNode.InnerText.Trim()
            }
            break
        }
        catch {
            # Preferences are only a convenience; malformed Cisco data is ignored.
        }
    }

    return [pscustomobject]$result
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }

    return $property.Value
}

function New-DefaultSettings {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $defaults = Get-CiscoPreferenceDefaults
    $resolveParameters = @{ ConfiguredPath = '' }
    if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        $resolveParameters.ProgramFilesRoots = $ProgramFilesRoots
    }
    $vpnCliPath = Resolve-VpnCliPath @resolveParameters

    return [pscustomobject][ordered]@{
        SchemaVersion      = $script:SettingsSchemaVersion
        VpnAddress        = $defaults.VpnAddress
        Username          = $defaults.Username
        PasswordEncrypted = ''
        AcceptLoginBanner = $false
        AutoDisconnectOnCompanyNetwork = $false
        CompanyDnsSuffix  = ''
        VpnCliPath        = if ($null -eq $vpnCliPath) { '' } else { $vpnCliPath }
        Configured        = $false
        LoadError         = ''
    }
}

function Read-AppSettings {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $defaultParameters = @{}
    if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
        $defaultParameters.ProgramFilesRoots = $ProgramFilesRoots
    }
    $settings = New-DefaultSettings @defaultParameters
    if (-not (Test-Path -LiteralPath $script:SettingsPath -PathType Leaf)) {
        return $settings
    }

    try {
        $utf8WithoutBom = New-Object Text.UTF8Encoding($false)
        $stored = [IO.File]::ReadAllText($script:SettingsPath, $utf8WithoutBom) | ConvertFrom-Json
        $storedSchemaVersion = Get-ObjectPropertyValue -InputObject $stored -Name 'SchemaVersion' -DefaultValue $null
        if ($null -eq $storedSchemaVersion) {
            throw 'The settings file has no schema version.'
        }
        $parsedSchemaVersion = [int]$storedSchemaVersion
        if ($parsedSchemaVersion -ne $script:SettingsSchemaVersion) {
            throw "Unsupported settings schema version: $parsedSchemaVersion"
        }
        $settings.SchemaVersion = $parsedSchemaVersion

        $settings.VpnAddress = [string](Get-ObjectPropertyValue -InputObject $stored -Name 'VpnAddress' -DefaultValue '')
        $settings.Username = [string](Get-ObjectPropertyValue -InputObject $stored -Name 'Username' -DefaultValue '')
        $settings.PasswordEncrypted = [string](Get-ObjectPropertyValue -InputObject $stored -Name 'PasswordEncrypted' -DefaultValue '')
        $storedBannerValue = Get-ObjectPropertyValue -InputObject $stored -Name 'AcceptLoginBanner' -DefaultValue $false
        $settings.AcceptLoginBanner = if ($storedBannerValue -is [bool]) { $storedBannerValue } else { $false }
        $storedAutoDisconnect = Get-ObjectPropertyValue -InputObject $stored -Name 'AutoDisconnectOnCompanyNetwork' -DefaultValue $false
        $settings.CompanyDnsSuffix = ConvertTo-CompanyDnsSuffix -Value ([string](Get-ObjectPropertyValue -InputObject $stored -Name 'CompanyDnsSuffix' -DefaultValue ''))
        $settings.AutoDisconnectOnCompanyNetwork = $storedAutoDisconnect -is [bool] -and $storedAutoDisconnect -and
            -not [string]::IsNullOrEmpty($settings.CompanyDnsSuffix)
        $storedVpnCliPath = [string](Get-ObjectPropertyValue -InputObject $stored -Name 'VpnCliPath' -DefaultValue '')
        $resolveParameters = @{ ConfiguredPath = $storedVpnCliPath }
        if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
            $resolveParameters.ProgramFilesRoots = $ProgramFilesRoots
        }
        $detectedVpnCliPath = Resolve-VpnCliPath @resolveParameters
        $settings.VpnCliPath = if ($null -eq $detectedVpnCliPath) { '' } else { $detectedVpnCliPath }
        $settings.Configured = -not [string]::IsNullOrWhiteSpace($settings.VpnAddress) -and
            -not [string]::IsNullOrWhiteSpace($settings.Username) -and
            -not [string]::IsNullOrWhiteSpace($settings.PasswordEncrypted)
    }
    catch {
        $settings.LoadError = 'The settings file could not be read. Open Settings and save it again.'
        $settings.Configured = $false
        $settings.AutoDisconnectOnCompanyNetwork = $false
    }

    return $settings
}

function Save-AppSettings {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Settings
    )

    $companyDnsSuffix = ConvertTo-CompanyDnsSuffix -Value ([string](Get-ObjectPropertyValue -InputObject $Settings -Name 'CompanyDnsSuffix' -DefaultValue ''))
    $autoDisconnect = Get-ObjectPropertyValue -InputObject $Settings -Name 'AutoDisconnectOnCompanyNetwork' -DefaultValue $false
    $autoDisconnect = $autoDisconnect -is [bool] -and $autoDisconnect
    if ($autoDisconnect -and [string]::IsNullOrEmpty($companyDnsSuffix)) {
        throw 'Enter a company DNS suffix to enable automatic disconnect.'
    }

    if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:InstallDirectory -Force | Out-Null
    }

    $document = [ordered]@{
        SchemaVersion      = $script:SettingsSchemaVersion
        VpnAddress        = [string]$Settings.VpnAddress
        Username          = [string]$Settings.Username
        PasswordEncrypted = [string]$Settings.PasswordEncrypted
        AcceptLoginBanner = [bool]$Settings.AcceptLoginBanner
        AutoDisconnectOnCompanyNetwork = $autoDisconnect
        CompanyDnsSuffix  = $companyDnsSuffix
        VpnCliPath        = [string]$Settings.VpnCliPath
    }

    $json = $document | ConvertTo-Json -Depth 3
    $temporaryPath = Join-Path $script:InstallDirectory ('settings.{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    $utf8WithoutBom = New-Object Text.UTF8Encoding($false)

    try {
        [IO.File]::WriteAllText($temporaryPath, $json, $utf8WithoutBom)
        Move-Item -LiteralPath $temporaryPath -Destination $script:SettingsPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Protect-Password {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Password
    )

    $securePassword = $null
    try {
        $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
        return ConvertFrom-SecureString -SecureString $securePassword
    }
    finally {
        if ($null -ne $securePassword) {
            $securePassword.Dispose()
        }
    }
}

function Unprotect-Password {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EncryptedPassword
    )

    $securePassword = $null
    $bstr = [IntPtr]::Zero
    try {
        $securePassword = ConvertTo-SecureString -String $EncryptedPassword
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        if ($null -ne $securePassword) {
            $securePassword.Dispose()
        }
    }
}

function Assert-SingleLineValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.IndexOf([char]0) -ge 0 -or $Value.IndexOf("`r") -ge 0 -or $Value.IndexOf("`n") -ge 0) {
        throw "$Name cannot contain a newline or NUL character."
    }
}

function New-VpnCliInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$VpnAddress,

        [Parameter(Mandatory = $true)]
        [string]$Username,

        [Parameter(Mandatory = $true)]
        [string]$Password,

        [bool]$AcceptLoginBanner = $false
    )

    Assert-SingleLineValue -Name 'VPN address' -Value $VpnAddress
    Assert-SingleLineValue -Name 'Username' -Value $Username
    Assert-SingleLineValue -Name 'Password' -Value $Password

    $lines = @(
        "connect $VpnAddress"
        $Username
        $Password
    )

    if ($AcceptLoginBanner) {
        $lines += 'y'
    }

    return ($lines -join "`r`n") + "`r`n"
}

function Test-NetworkEvidenceAvailable {
    param(
        [AllowNull()]
        [object]$InternetConnected = $null,

        [AllowNull()]
        [object]$PhysicalRouteAvailable = $null
    )

    # Only report offline when both independent Windows signals say no. Any
    # unavailable probe fails open so enterprise-specific routing is not blocked.
    if ($null -eq $InternetConnected -or $null -eq $PhysicalRouteAvailable) {
        return $true
    }

    return [bool]$InternetConnected -or [bool]$PhysicalRouteAvailable
}

function ConvertTo-CompanyDnsSuffix {
    param([AllowEmptyString()][string]$Value = '')

    $suffix = $Value.Trim().ToLowerInvariant()
    if ($suffix.EndsWith('.')) {
        $suffix = $suffix.Substring(0, $suffix.Length - 1)
    }
    if ([string]::IsNullOrEmpty($suffix) -and [string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }
    if ($suffix.Length -gt 253 -or
        $suffix -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$') {
        throw 'Enter a valid DNS suffix, such as office.example.com, without wildcards or spaces.'
    }
    return $suffix
}

function Test-PhysicalNetworkInterfaceUp {
    param(
        [AllowNull()]
        [object]$Snapshot
    )

    $eligibleTypes = @(
        'Ethernet'
        'Ethernet3Megabit'
        'FastEthernetFx'
        'FastEthernetT'
        'GigabitEthernet'
        'Wireless80211'
        'Wman'
        'Wwanpp'
        'Wwanpp2'
    )
    $virtualPattern = '(?i)(Cisco|AnyConnect|Secure Client|Tailscale|Hyper-V|vSwitch|Virtual|VPN|TAP|Wintun|WireGuard|Mullvad|Npcap|WFP|QoS|Packet Scheduler)'

    if ($null -eq $Snapshot -or
        [string]$Snapshot.OperationalStatus -ne 'Up' -or
        [string]$Snapshot.NetworkInterfaceType -notin $eligibleTypes) {
        return $false
    }

    $identity = '{0} {1}' -f [string]$Snapshot.Name, [string]$Snapshot.Description
    return $identity -notmatch $virtualPattern
}

function Test-NetworkInterfaceSnapshotAvailable {
    param([AllowNull()][object[]]$Snapshots)

    foreach ($snapshot in @($Snapshots)) {
        if (-not (Test-PhysicalNetworkInterfaceUp -Snapshot $snapshot)) {
            continue
        }

        foreach ($gateway in @($snapshot.GatewayAddresses)) {
            $address = [string]$gateway
            if (-not [string]::IsNullOrWhiteSpace($address) -and
                $address -notin @('0.0.0.0', '::')) {
                return $true
            }
        }
    }

    return $false
}

function Test-CompanyNetworkSnapshot {
    param(
        [AllowNull()][object[]]$Snapshots,
        [AllowEmptyString()][string]$DnsSuffix
    )

    try {
        $expectedSuffix = ConvertTo-CompanyDnsSuffix -Value $DnsSuffix
    }
    catch {
        return $false
    }
    if ([string]::IsNullOrEmpty($expectedSuffix)) {
        return $false
    }
    foreach ($snapshot in @($Snapshots)) {
        if (-not (Test-PhysicalNetworkInterfaceUp -Snapshot $snapshot)) {
            continue
        }
        try {
            $actualSuffix = ConvertTo-CompanyDnsSuffix -Value ([string](Get-ObjectPropertyValue -InputObject $snapshot -Name 'DnsSuffix' -DefaultValue ''))
        }
        catch {
            continue
        }
        if ($actualSuffix -eq $expectedSuffix) {
            return $true
        }
    }
    return $false
}

function Get-NetworkInterfaceSnapshot {
    $snapshots = foreach ($networkInterface in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        try {
            $properties = $networkInterface.GetIPProperties()
            [pscustomobject]@{
                Name                 = [string]$networkInterface.Name
                Description          = [string]$networkInterface.Description
                OperationalStatus    = [string]$networkInterface.OperationalStatus
                NetworkInterfaceType = [string]$networkInterface.NetworkInterfaceType
                DnsSuffix            = [string]$properties.DnsSuffix
                GatewayAddresses     = @(
                    $properties.GatewayAddresses |
                        ForEach-Object { [string]$_.Address }
                )
            }
        }
        catch {
            # One unusable adapter must not hide another usable adapter.
        }
    }

    return @($snapshots)
}

function Get-NetworkListInternetConnected {
    $networkListManager = $null
    try {
        $managerType = [Type]::GetTypeFromCLSID(
            [Guid]'DCB00C01-570F-4A9B-8D69-199FDBA5723B'
        )
        if ($null -eq $managerType) {
            throw 'Windows Network List Manager is unavailable.'
        }

        $networkListManager = [Activator]::CreateInstance($managerType)
        return [bool]$networkListManager.IsConnectedToInternet
    }
    finally {
        if ($null -ne $networkListManager -and
            [Runtime.InteropServices.Marshal]::IsComObject($networkListManager)) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($networkListManager)
        }
    }
}

function Test-BasicNetworkAvailable {
    $internetConnected = $null
    $physicalRouteAvailable = $null

    try {
        $internetConnected = Get-NetworkListInternetConnected
    }
    catch {
        # Network List Manager can be disabled by enterprise policy; fail open.
    }

    try {
        $physicalRouteAvailable = Test-NetworkInterfaceSnapshotAvailable -Snapshots (Get-NetworkInterfaceSnapshot)
    }
    catch {
        # Adapter enumeration can fail under a restricted token; fail open.
    }

    return Test-NetworkEvidenceAvailable `
        -InternetConnected $internetConnected `
        -PhysicalRouteAvailable $physicalRouteAvailable
}

function ConvertTo-CanonicalConnectionState {
    param(
        [AllowNull()]
        [string]$State
    )

    if ([string]::IsNullOrWhiteSpace($State)) {
        return $null
    }

    switch ($State.Trim().ToLowerInvariant()) {
        'connected'                  { return 'Connected' }
        'disconnected'               { return 'Disconnected' }
        'connecting'                 { return 'Connecting' }
        'disconnecting'              { return 'Disconnecting' }
        'reconnecting'               { return 'Reconnecting' }
        'verbunden'                  { return 'Connected' }
        'verbindung getrennt'        { return 'Disconnected' }
        'wird verbunden'             { return 'Connecting' }
        'wird getrennt'              { return 'Disconnecting' }
        'wird erneut verbunden mit'  { return 'Reconnecting' }
    }

    return $null
}

function Test-TrayPrimaryClick {
    param(
        [AllowNull()]
        [object]$EventArgs
    )

    if ($null -eq $EventArgs) {
        return $false
    }

    try {
        # NotifyIcon.MouseClick reports Clicks as zero on .NET Framework;
        # the mouse button is the authoritative primary-click signal.
        return [string]$EventArgs.Button -eq 'Left'
    }
    catch {
        return $false
    }
}

function Get-ConnectionStateFromText {
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $matches = [regex]::Matches(
        $Text,
        "(?im)^\s*(?:VPN>\s*)?(?:(?:>>\s*)?state|Connection\s+State)\s*:\s*(.+?)\s*$"
    )

    if ($matches.Count -gt 0) {
        return ConvertTo-CanonicalConnectionState -State $matches[$matches.Count - 1].Groups[1].Value
    }

    return $null
}

function Get-TrayActionKind {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State,

        [AllowEmptyString()]
        [string]$ActiveOperationName = '',

        [bool]$DisconnectPending = $false,

        [AllowEmptyString()]
        [string]$StateDetail = ''
    )

    if ($State -eq 'CompanyNetwork') {
        return 'Ignore'
    }
    if ($State -eq 'DisconnectedError' -and (Test-StateDetailUncertain -Detail $StateDetail)) {
        return 'Ignore'
    }

    if ($DisconnectPending -or
        $State -eq 'Disconnecting' -or
        $ActiveOperationName -eq 'Disconnect') {
        return 'Ignore'
    }

    if ($State -eq 'Connecting' -or $ActiveOperationName -eq 'Connect') {
        return 'CancelConnect'
    }

    if ($State -eq 'Connected') {
        return 'Disconnect'
    }

    if ($ActiveOperationName -notin @('', 'Status')) {
        return 'Ignore'
    }

    return 'Connect'
}

function Test-TraySettingsEnabled {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State
    )

    return $State -notin @('Connecting', 'Disconnecting')
}

function Test-SettingsSaveAllowed {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State,

        [AllowEmptyString()]
        [string]$ActiveOperationName = '',

        [bool]$DisconnectPending = $false
    )

    return (Test-TraySettingsEnabled -State $State) -and
        [string]::IsNullOrEmpty($ActiveOperationName) -and
        -not $DisconnectPending
}

function Test-StateDetailUncertain {
    param(
        [AllowEmptyString()]
        [string]$Detail = ''
    )

    return $Detail -in @(
        'VPN state unavailable'
        'Disconnect result unavailable'
        'Cancellation result unavailable'
    )
}
function Get-TrayPresentation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $presentation = switch ($State) {
        'InitialDisconnected' {
            [ordered]@{ Color = '#7A7A7A'; Status = 'Disconnected'; Action = 'Connect' }
        }
        'CompanyNetwork' {
            [ordered]@{ Color = '#7A7A7A'; Status = 'Company network; VPN off'; Action = 'VPN not needed' }
        }
        'Connecting' {
            [ordered]@{ Color = '#F5A623'; Status = 'Connecting'; Action = 'Cancel connection' }
        }
        'Disconnecting' {
            [ordered]@{ Color = '#F5A623'; Status = 'Disconnecting'; Action = 'Disconnecting...' }
        }
        'Connected' {
            [ordered]@{ Color = '#B1CB21'; Status = 'Connected'; Action = 'Disconnect' }
        }
        'DisconnectedError' {
            [ordered]@{ Color = '#E04B4F'; Status = 'Disconnected'; Action = 'Connect' }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $presentation.Status = $Detail
    }
    if ($State -eq 'DisconnectedError' -and (Test-StateDetailUncertain -Detail $Detail)) {
        $presentation.Action = 'State unavailable'
    }

    return [pscustomobject]$presentation
}

function Write-AppLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    try {
        if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $script:InstallDirectory -Force | Out-Null
        }

        if ((Test-Path -LiteralPath $script:LogPath -PathType Leaf) -and
            (Get-Item -LiteralPath $script:LogPath).Length -gt 524288) {
            $oldLog = "$($script:LogPath).old"
            Move-Item -LiteralPath $script:LogPath -Destination $oldLog -Force
        }

        $line = '{0:u} [{1}] {2}' -f [DateTime]::UtcNow, $Level, $Message
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never prevent connection management or application exit.
    }
}

function Set-StartWithWindows {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled,

        [string]$ScriptPath = $script:InstalledScriptPath
    )

    if ($Enabled) {
        if (-not (Test-Path -LiteralPath $script:RunKeyPath)) {
            New-Item -Path $script:RunKeyPath -Force | Out-Null
        }
        $command = Get-StartupCommand -ScriptPath $ScriptPath
        New-ItemProperty -Path $script:RunKeyPath -Name $script:AppId -Value $command -PropertyType String -Force | Out-Null
    }
    else {
        Remove-ItemProperty -Path $script:RunKeyPath -Name $script:AppId -ErrorAction SilentlyContinue
    }
}

function Test-StartWithWindows {
    try {
        $value = (Get-ItemProperty -Path $script:RunKeyPath -Name $script:AppId -ErrorAction Stop).$($script:AppId)
        return -not [string]::IsNullOrWhiteSpace([string]$value)
    }
    catch {
        return $false
    }
}

function Test-AppShortcutOwned {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [string]$ScriptPath = $script:InstalledScriptPath
    )

    if (-not (Test-Path -LiteralPath $ShortcutPath -PathType Leaf)) {
        return $false
    }

    $wshShell = $null
    $shortcut = $null
    try {
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($ShortcutPath)
        $expectedTarget = [IO.Path]::GetFullPath((Get-WindowsPowerShellPath))
        $actualTarget = [IO.Path]::GetFullPath($shortcut.TargetPath)
        $expectedArguments = Get-AppArguments -ScriptPath $ScriptPath
        return $actualTarget -ieq $expectedTarget -and $shortcut.Arguments -eq $expectedArguments
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        if ($null -ne $wshShell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshShell)
        }
    }
}

function New-AppShortcut {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [string]$ScriptPath = $script:InstalledScriptPath
    )

    if ((Test-Path -LiteralPath $ShortcutPath -PathType Leaf) -and
        -not (Test-AppShortcutOwned -ShortcutPath $ShortcutPath -ScriptPath $ScriptPath)) {
        throw "Refusing to overwrite an unrelated shortcut: $ShortcutPath"
    }

    $parent = Split-Path -Parent $ShortcutPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $wshShell = $null
    $shortcut = $null
    try {
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = Get-WindowsPowerShellPath
        $shortcut.Arguments = Get-AppArguments -ScriptPath $ScriptPath
        $shortcut.WorkingDirectory = Split-Path -Parent $ScriptPath
        $shortcut.Description = 'Start the TrayTunnel application'

        $iconPath = Resolve-CiscoIconPath
        if ($null -ne $iconPath) {
            $shortcut.IconLocation = "$iconPath,0"
        }

        $shortcut.Save()
    }
    finally {
        if ($null -ne $shortcut) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shortcut)
        }
        if ($null -ne $wshShell) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshShell)
        }
    }
}

function Start-AppProcess {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    $startInfo = New-Object Diagnostics.ProcessStartInfo
    $startInfo.FileName = Get-WindowsPowerShellPath
    $startInfo.Arguments = Get-AppArguments -ScriptPath $ScriptPath -NoConsoleHost
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    [Diagnostics.Process]::Start($startInfo) | Out-Null
}

function Test-NamedMutexExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $existing = $null
    try {
        $existing = [Threading.Mutex]::OpenExisting($Name)
        return $true
    }
    catch [Threading.WaitHandleCannotBeOpenedException] {
        return $false
    }
    finally {
        if ($null -ne $existing) {
            $existing.Dispose()
        }
    }
}

function Test-AppMutexExists {
    foreach ($mutexName in (Get-AppMutexNames)) {
        if (Test-NamedMutexExists -Name $mutexName) {
            return $true
        }
    }

    return $false
}

function Get-TrayExitEventName {
    param([string]$ApplicationId = $script:AppId)
    return Get-UserMutexName -ApplicationId ($ApplicationId + '-Exit')
}

function Send-TrayExitRequest {
    param([Parameter(Mandatory = $true)][string]$ApplicationId)

    $exitEvent = $null
    try {
        $exitEvent = [Threading.EventWaitHandle]::OpenExisting((Get-TrayExitEventName -ApplicationId $ApplicationId))
        [void]$exitEvent.Set()
        return $true
    }
    catch [Threading.WaitHandleCannotBeOpenedException] {
        # Releases before 0.3.1 do not have a cooperative exit channel.
        return $false
    }
    finally {
        if ($null -ne $exitEvent) { $exitEvent.Dispose() }
    }
}

function Test-InstalledTrayProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][string]$PowerShellPath,
        [Parameter(Mandatory = $true)][int]$SessionId,
        [int]$InstallerProcessId = $PID
    )

    if ([int]$Snapshot.ProcessId -eq $InstallerProcessId -or
        [int]$Snapshot.SessionId -ne $SessionId -or
        [string]$Snapshot.ExecutablePath -ine $PowerShellPath -or
        $null -eq $Snapshot.CreationDate) { return $false }

    # Match only the exact run-mode command lines emitted by our launchers.
    # A console, installer, health check, or another script must never be stopped.
    foreach ($noConsole in @($true, $false)) {
        $arguments = Get-AppArguments -ScriptPath $ScriptPath -NoConsoleHost:$noConsole
        foreach ($executable in @(('"{0}"' -f $PowerShellPath), $PowerShellPath)) {
            if ([string]$Snapshot.CommandLine -ieq "$executable $arguments") { return $true }
        }
    }
    return $false
}

function Test-TrayChildCliProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][object]$Parent,
        [Parameter(Mandatory = $true)][string[]]$CliPaths
    )
    return [int]$Snapshot.ParentProcessId -eq [int]$Parent.ProcessId -and
        [int]$Snapshot.SessionId -eq [int]$Parent.SessionId -and
        $null -ne $Snapshot.CreationDate -and
        $Snapshot.CreationDate -ge $Parent.CreationDate -and
        [string]$Snapshot.ExecutablePath -in $CliPaths
}

function Test-ProcessOwnedByCurrentUser {
    param([Parameter(Mandatory = $true)][object]$Snapshot)

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $owner = Invoke-CimMethod -InputObject $Snapshot -MethodName GetOwnerSid -ErrorAction Stop
        return $owner.ReturnValue -eq 0 -and $owner.Sid -eq $identity.User.Value
    }
    finally { $identity.Dispose() }
}

function Stop-VerifiedProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [switch]$ExitRequested
    )

    try { $process = [Diagnostics.Process]::GetProcessById([int]$Snapshot.ProcessId) }
    catch [ArgumentException] { return }
    try {
        # Open a handle before validation so PID reuse cannot change the target.
        [void]$process.Handle
        if ($process.HasExited) { return }
        if ($process.MainModule.FileName -ine [string]$Snapshot.ExecutablePath -or
            [Math]::Abs(($process.StartTime.ToUniversalTime() - $Snapshot.CreationDate.ToUniversalTime()).TotalMilliseconds) -ge 1) {
            throw 'The running tray process changed during upgrade; no process was stopped.'
        }
        if ($ExitRequested -and $process.WaitForExit(5000)) { return }
        # Closing only these client processes does not disconnect Cisco's agent.
        $process.Kill()
        if (-not $process.WaitForExit(5000)) { throw 'The previous tray process did not exit in time.' }
    }
    catch {
        # A cooperative exit can finish while the process is being inspected.
        if ($process.HasExited) { return }
        throw
    }
    finally { $process.Dispose() }
}

function Stop-RunningInstalledTrays {
    param([Parameter(Mandatory = $true)][object[]]$LegacyStates)

    $installations = @([pscustomobject]@{
        AppId = $script:AppId
        ProductName = $script:ProductName
        InstalledFileName = 'TrayTunnel.ps1'
        InstalledScriptPath = $script:InstalledScriptPath
    }) + @($LegacyStates)
    $snapshots = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'vpncli.exe'" -ErrorAction Stop)
    $powerShellPath = Get-WindowsPowerShellPath
    $currentProcess = [Diagnostics.Process]::GetCurrentProcess()
    try { $sessionId = $currentProcess.SessionId }
    finally { $currentProcess.Dispose() }
    $cliPaths = @(Get-CiscoExecutablePaths)

    foreach ($installation in $installations) {
        if (-not (Test-ApplicationScriptIdentity -Path $installation.InstalledScriptPath -ExpectedAppId $installation.AppId -ExpectedProductName $installation.ProductName -ExpectedInstalledFileName $installation.InstalledFileName)) { continue }
        foreach ($snapshot in $snapshots) {
            if (-not (Test-InstalledTrayProcess -Snapshot $snapshot -ScriptPath $installation.InstalledScriptPath -PowerShellPath $powerShellPath -SessionId $sessionId)) { continue }
            if (-not (Test-ProcessOwnedByCurrentUser -Snapshot $snapshot)) { continue }

            $children = @($snapshots | Where-Object {
                (Test-TrayChildCliProcess -Snapshot $_ -Parent $snapshot -CliPaths $cliPaths) -and
                (Test-ProcessOwnedByCurrentUser -Snapshot $_)
            })
            Write-Host "Closing $($installation.ProductName) to install TrayTunnel. Cisco's VPN service stays running."
            $requested = Send-TrayExitRequest -ApplicationId $installation.AppId
            Stop-VerifiedProcessSnapshot -Snapshot $snapshot -ExitRequested:$requested
            # Older trays cannot clean up their hidden listener after termination.
            foreach ($child in $children) { Stop-VerifiedProcessSnapshot -Snapshot $child }
        }
    }
}

function Exit-AppMutexSet {
    param(
        [AllowNull()]
        [object]$Lease
    )

    if ($null -eq $Lease -or -not $Lease.Acquired) {
        return
    }

    $mutexes = @($Lease.Mutexes)
    for ($index = $mutexes.Count - 1; $index -ge 0; $index--) {
        $mutex = $mutexes[$index]
        try {
            $mutex.ReleaseMutex()
        }
        catch {
        }
        finally {
            $mutex.Dispose()
        }
    }
}

function Enter-AppMutexSet {
    param(
        [string[]]$MutexNames = (Get-AppMutexNames)
    )

    $ownedMutexes = @()
    try {
        foreach ($mutexName in $MutexNames) {
            $createdNew = $false
            $mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
            if (-not $createdNew) {
                $mutex.Dispose()
                Exit-AppMutexSet -Lease ([pscustomobject]@{
                    Acquired = $true
                    Mutexes  = $ownedMutexes
                })
                return [pscustomobject]@{
                    Acquired = $false
                    Mutexes  = @()
                }
            }
            $ownedMutexes += $mutex
        }

        return [pscustomobject]@{
            Acquired = $true
            Mutexes  = $ownedMutexes
        }
    }
    catch {
        Exit-AppMutexSet -Lease ([pscustomobject]@{
            Acquired = $true
            Mutexes  = $ownedMutexes
        })
        throw
    }
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    $sourceFullPath = [IO.Path]::GetFullPath($SourcePath)
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)
    if ($sourceFullPath -ieq $destinationFullPath) {
        return
    }
    if (-not (Test-Path -LiteralPath $sourceFullPath -PathType Leaf)) {
        throw "The source file was not found: $sourceFullPath"
    }

    $destinationDirectory = Split-Path -Parent $destinationFullPath
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        throw "The destination directory was not found: $destinationDirectory"
    }
    if (Test-Path -LiteralPath $destinationFullPath) {
        if (-not (Test-Path -LiteralPath $destinationFullPath -PathType Leaf)) {
            throw "The destination is not a file: $destinationFullPath"
        }
        $destinationItem = Get-Item -LiteralPath $destinationFullPath -Force
        if (($destinationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to replace a reparse-point file: $destinationFullPath"
        }
    }

    $operationId = [Guid]::NewGuid().ToString('N')
    $stagingPath = Join-Path $destinationDirectory ('TrayTunnel.install.{0}.tmp' -f $operationId)
    $backupPath = Join-Path $destinationDirectory ('TrayTunnel.install.{0}.bak' -f $operationId)
    try {
        [IO.File]::Copy($sourceFullPath, $stagingPath, $false)
        if (Test-Path -LiteralPath $destinationFullPath -PathType Leaf) {
            [IO.File]::Replace($stagingPath, $destinationFullPath, $backupPath, $true)
        }
        else {
            [IO.File]::Move($stagingPath, $destinationFullPath)
        }
    }
    finally {
        foreach ($temporaryPath in @($stagingPath, $backupPath)) {
            if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
                [IO.File]::Delete($temporaryPath)
            }
        }
    }
}

function Get-StartWithWindowsCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ValueName
    )

    try {
        $item = Get-ItemProperty -Path $script:RunKeyPath -Name $ValueName -ErrorAction Stop
        $property = $item.PSObject.Properties[$ValueName]
        if ($null -eq $property) {
            return $null
        }
        return [string]$property.Value
    }
    catch {
        return $null
    }
}

function Test-StartupCommandOwned {
    param(
        [AllowNull()]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath
    )

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return $false
    }

    return $Command -ieq (Get-StartupCommand -ScriptPath $ScriptPath)
}

function Assert-LegacyMigrationPathsSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$FilePaths
    )

    $installFullPath = [IO.Path]::GetFullPath($InstallDirectory)
    if (Test-Path -LiteralPath $installFullPath) {
        if (-not (Test-Path -LiteralPath $installFullPath -PathType Container)) {
            throw "The legacy application path is not a directory: $installFullPath"
        }
        $installItem = Get-Item -LiteralPath $installFullPath -Force
        if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to migrate through a reparse-point legacy directory: $installFullPath"
        }
    }

    $installPrefix = $installFullPath.TrimEnd([IO.Path]::DirectorySeparatorChar) +
        [IO.Path]::DirectorySeparatorChar
    foreach ($filePath in $FilePaths) {
        $fileFullPath = [IO.Path]::GetFullPath($filePath)
        if (-not $fileFullPath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The legacy file path is outside the legacy application directory: $fileFullPath"
        }
        if (-not (Test-Path -LiteralPath $fileFullPath)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $fileFullPath -PathType Leaf)) {
            throw "The legacy application path is not a file: $fileFullPath"
        }
        $fileItem = Get-Item -LiteralPath $fileFullPath -Force
        if (($fileItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing to migrate a reparse-point legacy file: $fileFullPath"
        }
    }
}

function Test-ApplicationScriptIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedAppId,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedProductName,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedInstalledFileName
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return $false
        }

        $item = Get-Item -LiteralPath $Path -Force
        $directory = Get-Item -LiteralPath $item.DirectoryName -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or
            $item.Length -gt 2097152) {
            return $false
        }

        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $content = [IO.File]::ReadAllText($item.FullName, $strictUtf8)
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            $content,
            $item.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -ne 0) {
            return $false
        }

        $statements = @($ast.EndBlock.Statements)
        $literalAssignments = @(
            [pscustomobject]@{ Name = 'script:ProductName'; Expected = $ExpectedProductName; SemVer = $false }
            [pscustomobject]@{ Name = 'script:AppId'; Expected = $ExpectedAppId; SemVer = $false }
            [pscustomobject]@{ Name = 'script:Version'; Expected = $null; SemVer = $true }
        )
        foreach ($definition in $literalAssignments) {
            $matches = @($statements | Where-Object {
                $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
                $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
                [string]::Equals(
                    $_.Left.VariablePath.UserPath,
                    $definition.Name,
                    [StringComparison]::OrdinalIgnoreCase
                )
            })
            if ($matches.Count -ne 1) {
                return $false
            }

            $assignment = $matches[0]
            if ($assignment.Operator -ne [Management.Automation.Language.TokenKind]::Equals -or
                $assignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
                $assignment.Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
                return $false
            }

            $value = $assignment.Right.Expression.Value
            if ($definition.SemVer) {
                $semVerPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
                if ($value -notmatch $semVerPattern) {
                    return $false
                }
            }
            elseif (-not [string]::Equals($value, $definition.Expected, [StringComparison]::Ordinal)) {
                return $false
            }
        }

        $installedAssignments = @($statements | Where-Object {
            $_ -is [Management.Automation.Language.AssignmentStatementAst] -and
            $_.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]::Equals(
                $_.Left.VariablePath.UserPath,
                'script:InstalledScriptPath',
                [StringComparison]::OrdinalIgnoreCase
            )
        })
        if ($installedAssignments.Count -ne 1) {
            return $false
        }

        $installedAssignment = $installedAssignments[0]
        if ($installedAssignment.Operator -ne [Management.Automation.Language.TokenKind]::Equals -or
            $installedAssignment.Right -isnot [Management.Automation.Language.PipelineAst] -or
            $installedAssignment.Right.PipelineElements.Count -ne 1) {
            return $false
        }

        $joinCommand = $installedAssignment.Right.PipelineElements[0]
        if ($joinCommand -isnot [Management.Automation.Language.CommandAst] -or
            $joinCommand.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -or
            $joinCommand.CommandElements.Count -ne 3 -or
            $joinCommand.Redirections.Count -ne 0 -or
            -not [string]::Equals($joinCommand.GetCommandName(), 'Join-Path', [StringComparison]::OrdinalIgnoreCase) -or
            $joinCommand.CommandElements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $joinCommand.CommandElements[1] -isnot [Management.Automation.Language.VariableExpressionAst] -or
            $joinCommand.CommandElements[2] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            -not [string]::Equals($joinCommand.CommandElements[1].VariablePath.UserPath, 'script:InstallDirectory', [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals($joinCommand.CommandElements[2].Value, $ExpectedInstalledFileName, [StringComparison]::Ordinal)) {
            return $false
        }

        $uninstallFunctions = @($statements | Where-Object {
            $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
            -not $_.IsFilter -and
            [string]::Equals($_.Name, 'Uninstall-App', [StringComparison]::OrdinalIgnoreCase)
        })
        if ($uninstallFunctions.Count -ne 1) {
            return $false
        }

        $uninstallDispatches = @($statements | Where-Object {
            if ($_ -isnot [Management.Automation.Language.IfStatementAst] -or
                $_.Clauses.Count -ne 1 -or
                $null -ne $_.ElseClause) {
                return $false
            }

            $condition = $_.Clauses[0].Item1
            if ($condition -isnot [Management.Automation.Language.PipelineAst] -or
                $condition.PipelineElements.Count -ne 1 -or
                $condition.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or
                $condition.PipelineElements[0].Expression -isnot [Management.Automation.Language.VariableExpressionAst] -or
                -not [string]::Equals($condition.PipelineElements[0].Expression.VariablePath.UserPath, 'Uninstall', [StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }

            $body = $_.Clauses[0].Item2
            $bodyStatements = @($body.Statements)
            if ($null -ne $body.Traps -or
                $bodyStatements.Count -lt 1 -or
                $bodyStatements.Count -gt 2 -or
                $bodyStatements[0] -isnot [Management.Automation.Language.PipelineAst] -or
                $bodyStatements[0].PipelineElements.Count -ne 1) {
                return $false
            }

            $command = $bodyStatements[0].PipelineElements[0]
            if ($command -isnot [Management.Automation.Language.CommandAst] -or
                $command.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -or
                $command.CommandElements.Count -ne 1 -or
                $command.Redirections.Count -ne 0 -or
                $command.CommandElements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
                -not [string]::Equals($command.CommandElements[0].Value, 'Uninstall-App', [StringComparison]::OrdinalIgnoreCase)) {
                return $false
            }

            if ($bodyStatements.Count -eq 2) {
                $exitStatement = $bodyStatements[1]
                if ($exitStatement -isnot [Management.Automation.Language.ExitStatementAst] -or
                    $exitStatement.Pipeline -isnot [Management.Automation.Language.PipelineAst] -or
                    $exitStatement.Pipeline.PipelineElements.Count -ne 1 -or
                    $exitStatement.Pipeline.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or
                    $exitStatement.Pipeline.PipelineElements[0].Expression -isnot [Management.Automation.Language.ConstantExpressionAst] -or
                    [int]$exitStatement.Pipeline.PipelineElements[0].Expression.Value -ne 0) {
                    return $false
                }
            }

            return $true
        })
        if ($uninstallDispatches.Count -ne 1) {
            return $false
        }

        return $true
    }
    catch {
        # Identity probing must fail closed across IO, decoding, and parse races.
        return $false
    }
}
function Test-MigrationSettingsFileValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $item.Length -le 0 -or
            $item.Length -gt 1048576) {
            return $false
        }

        $strictUtf8 = New-Object Text.UTF8Encoding($false, $true)
        $json = [IO.File]::ReadAllText($item.FullName, $strictUtf8)
        if ([string]::IsNullOrWhiteSpace($json)) {
            return $false
        }

        $document = $json | ConvertFrom-Json
        if ($null -eq $document -or $document -is [Array] -or $document -is [string]) {
            return $false
        }

        $schemaProperty = $document.PSObject.Properties['SchemaVersion']
        if ($null -eq $schemaProperty) {
            return $false
        }

        $schemaVersion = $schemaProperty.Value
        $isIntegral = $schemaVersion -is [int] -or $schemaVersion -is [long]
        return $isIntegral -and [long]$schemaVersion -eq $script:SettingsSchemaVersion
    }
    catch {
        return $false
    }
}

function Assert-MigrationSettingsFileValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$Description = 'settings file'
    )

    if (-not (Test-MigrationSettingsFileValid -Path $Path)) {
        throw "The $Description must be non-empty UTF-8 JSON with SchemaVersion $($script:SettingsSchemaVersion): $Path"
    }
}

function Resolve-InstallationChoices {
    param(
        [bool]$MigrationPerformed,
        [bool]$LegacyStartupEnabled,
        [bool]$LegacyDesktopShortcutOwned,
        [bool]$NewIdentityRecognized,
        [bool]$NewStartupEnabled,
        [bool]$NewDesktopShortcutOwned,
        [bool]$DesktopShortcutRequested
    )

    if ($NewIdentityRecognized) {
        return [pscustomobject]@{
            StartupEnabled         = $NewStartupEnabled
            DesktopShortcutEnabled = $DesktopShortcutRequested -or $NewDesktopShortcutOwned
        }
    }

    if ($MigrationPerformed) {
        return [pscustomobject]@{
            StartupEnabled         = $LegacyStartupEnabled
            DesktopShortcutEnabled = $DesktopShortcutRequested -or $LegacyDesktopShortcutOwned
        }
    }

    return [pscustomobject]@{
        StartupEnabled         = $true
        DesktopShortcutEnabled = $DesktopShortcutRequested
    }
}

function Get-LegacyMigrationState {
    param(
        [string]$AppId = $script:LegacyAppId,
        [string]$ProductName = 'AnyConnect Tray',
        [string]$InstalledFileName = 'AnyConnectTray.ps1',
        [string]$InstallDirectory = $script:LegacyInstallDirectory,
        [string]$InstalledScriptPath = $script:LegacyInstalledScriptPath,
        [string]$SettingsPath = $script:LegacySettingsPath,
        [string]$LogPath = $script:LegacyLogPath,
        [string]$StartMenuShortcutPath = $script:LegacyStartMenuShortcutPath,
        [string]$DesktopShortcutPath = $script:LegacyDesktopShortcutPath,
        [AllowNull()]
        [string]$StartupCommand
    )

    $legacyFilePaths = @(
        $InstalledScriptPath
        $SettingsPath
        $LogPath
        "$LogPath.old"
    )
    Assert-LegacyMigrationPathsSafe -InstallDirectory $InstallDirectory -FilePaths $legacyFilePaths

    if (-not $PSBoundParameters.ContainsKey('StartupCommand')) {
        $StartupCommand = Get-StartWithWindowsCommand -ValueName $AppId
    }

    $startupOwned = Test-StartupCommandOwned -Command $StartupCommand -ScriptPath $InstalledScriptPath
    $startMenuOwned = Test-AppShortcutOwned -ShortcutPath $StartMenuShortcutPath -ScriptPath $InstalledScriptPath
    $desktopOwned = Test-AppShortcutOwned -ShortcutPath $DesktopShortcutPath -ScriptPath $InstalledScriptPath
    $installScriptPresent = Test-Path -LiteralPath $InstalledScriptPath -PathType Leaf
    $installScriptRecognized = Test-ApplicationScriptIdentity -Path $InstalledScriptPath -ExpectedAppId $AppId -ExpectedProductName $ProductName -ExpectedInstalledFileName $InstalledFileName
    $settingsPresent = Test-Path -LiteralPath $SettingsPath -PathType Leaf
    $settingsValid = $settingsPresent -and (Test-MigrationSettingsFileValid -Path $SettingsPath)
    $logPresent = Test-Path -LiteralPath $LogPath -PathType Leaf
    $oldLogPresent = Test-Path -LiteralPath "$LogPath.old" -PathType Leaf
    $identityRecognized = $installScriptRecognized -or $startupOwned -or $startMenuOwned -or $desktopOwned

    return [pscustomobject]@{
        AppId                     = $AppId
        ProductName               = $ProductName
        InstalledFileName         = $InstalledFileName
        HasArtifacts              = [bool](
            $installScriptPresent -or
            $settingsPresent -or
            $logPresent -or
            $oldLogPresent -or
            $startupOwned -or
            $startMenuOwned -or
            $desktopOwned
        )
        IdentityRecognized        = [bool]$identityRecognized
        InstallDirectory          = [IO.Path]::GetFullPath($InstallDirectory)
        InstalledScriptPath       = [IO.Path]::GetFullPath($InstalledScriptPath)
        SettingsPath              = [IO.Path]::GetFullPath($SettingsPath)
        LogPath                   = [IO.Path]::GetFullPath($LogPath)
        StartMenuShortcutPath     = [IO.Path]::GetFullPath($StartMenuShortcutPath)
        DesktopShortcutPath       = [IO.Path]::GetFullPath($DesktopShortcutPath)
        InstallScriptPresent      = [bool]$installScriptPresent
        InstallScriptRecognized   = [bool]$installScriptRecognized
        SettingsPresent           = [bool]$settingsPresent
        SettingsValid             = [bool]$settingsValid
        LogPresent                = [bool]$logPresent
        OldLogPresent             = [bool]$oldLogPresent
        StartupEnabled            = [bool]$startupOwned
        StartMenuShortcutOwned    = [bool]$startMenuOwned
        DesktopShortcutOwned      = [bool]$desktopOwned
    }
}

function Get-LegacyMigrationStates {
    $previousDirectory = Join-Path $script:LocalAppData 'VpnCliTray'
    Get-LegacyMigrationState `
        -AppId 'VpnCliTray' `
        -ProductName 'VPN CLI Tray' `
        -InstalledFileName 'VpnCliTray.ps1' `
        -InstallDirectory $previousDirectory `
        -InstalledScriptPath (Join-Path $previousDirectory 'VpnCliTray.ps1') `
        -SettingsPath (Join-Path $previousDirectory 'settings.json') `
        -LogPath (Join-Path $previousDirectory 'VpnCliTray.log') `
        -StartMenuShortcutPath (Join-Path ([Environment]::GetFolderPath('Programs')) 'VPN CLI Tray.lnk') `
        -DesktopShortcutPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'VPN CLI Tray.lnk')
    Get-LegacyMigrationState
}

function Select-LegacyMigrationSource {
    param([Parameter(Mandatory = $true)][object[]]$States)

    # States are ordered newest identity first. Prefer usable settings, then the
    # newest recognized installation for startup and shortcut preferences.
    foreach ($state in $States) {
        if ($state.IdentityRecognized -and $state.SettingsValid) { return $state }
    }
    foreach ($state in $States) {
        if ($state.IdentityRecognized) { return $state }
    }
    return $States[0]
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $stream = $null
    $algorithm = $null
    try {
        $stream = [IO.File]::Open(
            [IO.Path]::GetFullPath($Path),
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::Read
        )
        $algorithm = [Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        if ($null -ne $algorithm) {
            $algorithm.Dispose()
        }
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Test-FileContentsEqual {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirstPath,

        [Parameter(Mandatory = $true)]
        [string]$SecondPath
    )

    if (-not (Test-Path -LiteralPath $FirstPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $SecondPath -PathType Leaf)) {
        return $false
    }

    $firstItem = Get-Item -LiteralPath $FirstPath -Force
    $secondItem = Get-Item -LiteralPath $SecondPath -Force
    if ($firstItem.Length -ne $secondItem.Length) {
        return $false
    }

    return (Get-FileSha256 -Path $FirstPath) -ceq (Get-FileSha256 -Path $SecondPath)
}

function Copy-LegacySettingsIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LegacySettingsPath,

        [Parameter(Mandatory = $true)]
        [string]$NewSettingsPath
    )

    if (Test-Path -LiteralPath $NewSettingsPath) {
        Assert-MigrationSettingsFileValid -Path $NewSettingsPath -Description 'existing TrayTunnel settings file'
        return $false
    }

    if (-not (Test-MigrationSettingsFileValid -Path $LegacySettingsPath)) {
        return $false
    }

    Copy-FileAtomically -SourcePath $LegacySettingsPath -DestinationPath $NewSettingsPath
    Assert-MigrationSettingsFileValid -Path $NewSettingsPath -Description 'migrated TrayTunnel settings file'
    if (-not (Test-FileContentsEqual -FirstPath $LegacySettingsPath -SecondPath $NewSettingsPath)) {
        throw 'The migrated settings could not be verified.'
    }

    return $true
}

function Assert-NewInstallationValid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceScriptPath,

        [string]$InstalledScriptPath = $script:InstalledScriptPath,
        [string]$StartMenuShortcutPath = $script:StartMenuShortcutPath,
        [string]$DesktopShortcutPath = $script:DesktopShortcutPath,

        [Parameter(Mandatory = $true)]
        [bool]$StartupEnabled,

        [Parameter(Mandatory = $true)]
        [bool]$DesktopShortcutEnabled,

        [bool]$SettingsRequired,
        [bool]$SettingsCopied,
        [string]$LegacySettingsPath,
        [string]$NewSettingsPath = $script:SettingsPath,

        [AllowNull()]
        [string]$StartupCommand
    )

    if (-not (Test-FileContentsEqual -FirstPath $SourceScriptPath -SecondPath $InstalledScriptPath)) {
        throw 'The installed application script could not be verified.'
    }

    if (-not $PSBoundParameters.ContainsKey('StartupCommand')) {
        $StartupCommand = Get-StartWithWindowsCommand -ValueName $script:AppId
    }
    $startupOwned = Test-StartupCommandOwned -Command $StartupCommand -ScriptPath $InstalledScriptPath
    if ($StartupEnabled -ne $startupOwned) {
        throw 'The Start with Windows setting could not be verified.'
    }

    if (-not (Test-AppShortcutOwned -ShortcutPath $StartMenuShortcutPath -ScriptPath $InstalledScriptPath)) {
        throw 'The Start Menu shortcut could not be verified.'
    }

    $desktopOwned = Test-AppShortcutOwned -ShortcutPath $DesktopShortcutPath -ScriptPath $InstalledScriptPath
    if ($DesktopShortcutEnabled -ne $desktopOwned) {
        throw 'The Desktop shortcut setting could not be verified.'
    }

    if ($SettingsRequired) {
        Assert-MigrationSettingsFileValid -Path $NewSettingsPath -Description 'validated TrayTunnel settings file'
        if ($SettingsCopied -and
            -not (Test-FileContentsEqual -FirstPath $LegacySettingsPath -SecondPath $NewSettingsPath)) {
            throw 'The migrated settings content could not be verified.'
        }
    }
}

function Remove-LegacyIdentityAnchor {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Anchor,

        [Parameter(Mandatory = $true)]
        [object]$State
    )

    switch ($Anchor.Kind) {
        'Startup' {
            $command = Get-StartWithWindowsCommand -ValueName $State.AppId
            if ([string]::IsNullOrWhiteSpace($command)) {
                return
            }
            if (-not (Test-StartupCommandOwned -Command $command -ScriptPath $State.InstalledScriptPath)) {
                throw "The legacy startup identity anchor no longer matches its recognized owner: $($State.AppId)"
            }
            Remove-ItemProperty -Path $script:RunKeyPath -Name $State.AppId -ErrorAction Stop
        }
        'StartMenu' {
            if (-not (Test-Path -LiteralPath $Anchor.Path)) {
                return
            }
            if (-not (Test-AppShortcutOwned -ShortcutPath $Anchor.Path -ScriptPath $State.InstalledScriptPath)) {
                throw "The legacy Start Menu identity anchor no longer matches its recognized owner: $($Anchor.Path)"
            }
            Remove-Item -LiteralPath $Anchor.Path -Force -ErrorAction Stop
        }
        'Desktop' {
            if (-not (Test-Path -LiteralPath $Anchor.Path)) {
                return
            }
            if (-not (Test-AppShortcutOwned -ShortcutPath $Anchor.Path -ScriptPath $State.InstalledScriptPath)) {
                throw "The legacy Desktop identity anchor no longer matches its recognized owner: $($Anchor.Path)"
            }
            Remove-Item -LiteralPath $Anchor.Path -Force -ErrorAction Stop
        }
        'Script' {
            if (-not (Test-Path -LiteralPath $Anchor.Path)) {
                return
            }
            $scriptRecognized = Test-ApplicationScriptIdentity -Path $Anchor.Path -ExpectedAppId $State.AppId -ExpectedProductName $State.ProductName -ExpectedInstalledFileName $State.InstalledFileName
            if (-not $scriptRecognized) {
                throw "The legacy script identity anchor no longer matches its recognized owner: $($Anchor.Path)"
            }
            Remove-Item -LiteralPath $Anchor.Path -Force -ErrorAction Stop
        }
        default {
            throw "Unknown legacy identity anchor kind: $($Anchor.Kind)"
        }
    }
}

function Remove-LegacyMigrationArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State,

        [switch]$SkipStartupEntry
    )

    if (-not $State.IdentityRecognized) {
        throw 'Refusing legacy cleanup because the application identity was not recognized.'
    }

    Assert-LegacyMigrationPathsSafe -InstallDirectory $State.InstallDirectory -FilePaths @(
        $State.InstalledScriptPath
        $State.SettingsPath
        $State.LogPath
        "$($State.LogPath).old"
    )

    $failures = New-Object 'Collections.Generic.List[string]'

    if ($State.SettingsPresent -and $State.SettingsValid -and
        (Test-Path -LiteralPath $State.SettingsPath -PathType Leaf)) {
        if (Test-MigrationSettingsFileValid -Path $State.SettingsPath) {
            try {
                Remove-Item -LiteralPath $State.SettingsPath -Force -ErrorAction Stop
            }
            catch {
                [void]$failures.Add("$($State.SettingsPath): $($_.Exception.Message)")
            }
        }
        else {
            Write-Warning "The legacy settings became invalid and were left unchanged: $($State.SettingsPath)"
        }
    }

    $nonAnchorFiles = @()
    if ($State.LogPresent) {
        $nonAnchorFiles += $State.LogPath
    }
    if ($State.OldLogPresent) {
        $nonAnchorFiles += "$($State.LogPath).old"
    }
    foreach ($legacyFile in $nonAnchorFiles) {
        try {
            if (Test-Path -LiteralPath $legacyFile -PathType Leaf) {
                Remove-Item -LiteralPath $legacyFile -Force -ErrorAction Stop
            }
        }
        catch {
            [void]$failures.Add("$($legacyFile): $($_.Exception.Message)")
        }
    }

    if (Test-Path -LiteralPath $State.InstallDirectory -PathType Container) {
        foreach ($filter in @('settings.*.tmp', "$($State.AppId).install.*.tmp", "$($State.AppId).install.*.bak")) {
            try {
                $temporaryFiles = @(Get-ChildItem -LiteralPath $State.InstallDirectory -Filter $filter -File -ErrorAction Stop)
                foreach ($temporaryFile in $temporaryFiles) {
                    try {
                        Remove-Item -LiteralPath $temporaryFile.FullName -Force -ErrorAction Stop
                    }
                    catch {
                        [void]$failures.Add("$($temporaryFile.FullName): $($_.Exception.Message)")
                    }
                }
            }
            catch {
                [void]$failures.Add("$($State.InstallDirectory) [$filter]: $($_.Exception.Message)")
            }
        }
    }

    if ($failures.Count -gt 0) {
        $summary = $failures -join '; '
        throw "Legacy cleanup was only partially completed; identity anchors were retained for a safe retry. Failed items: $summary"
    }

    $identityAnchors = @()
    if (-not $SkipStartupEntry -and $State.StartupEnabled) {
        $identityAnchors += [pscustomobject]@{ Kind = 'Startup'; Path = $State.AppId }
    }
    if ($State.StartMenuShortcutOwned) {
        $identityAnchors += [pscustomobject]@{ Kind = 'StartMenu'; Path = $State.StartMenuShortcutPath }
    }
    if ($State.DesktopShortcutOwned) {
        $identityAnchors += [pscustomobject]@{ Kind = 'Desktop'; Path = $State.DesktopShortcutPath }
    }
    if ($State.InstallScriptRecognized) {
        $identityAnchors += [pscustomobject]@{ Kind = 'Script'; Path = $State.InstalledScriptPath }
    }

    # Remove every anchor except the last while another recognized anchor remains.
    # If any deletion fails, retain the final anchor so the operation is retryable.
    for ($index = 0; $index -lt ($identityAnchors.Count - 1); $index++) {
        $anchor = $identityAnchors[$index]
        try {
            Remove-LegacyIdentityAnchor -Anchor $anchor -State $State
        }
        catch {
            [void]$failures.Add("$($anchor.Path): $($_.Exception.Message)")
        }
    }

    if ($failures.Count -eq 0 -and $identityAnchors.Count -gt 0) {
        $anchor = $identityAnchors[$identityAnchors.Count - 1]
        try {
            Remove-LegacyIdentityAnchor -Anchor $anchor -State $State
        }
        catch {
            [void]$failures.Add("$($anchor.Path): $($_.Exception.Message)")
        }
    }

    if ($failures.Count -gt 0) {
        $summary = $failures -join '; '
        throw "Legacy cleanup was only partially completed; a recognized identity anchor remains for a safe retry. Failed items: $summary"
    }

    if (Test-Path -LiteralPath $State.InstallDirectory -PathType Container) {
        $remainingItem = Get-ChildItem -LiteralPath $State.InstallDirectory -Force | Select-Object -First 1
        if ($null -eq $remainingItem) {
            try {
                Remove-Item -LiteralPath $State.InstallDirectory -Force -ErrorAction Stop
            }
            catch {
                Write-Warning "The empty legacy application directory could not be removed: $($State.InstallDirectory)"
            }
        }
        else {
            Write-Warning "Left the non-empty legacy application directory in place: $($State.InstallDirectory)"
        }
    }
}

function Install-App {
    param(
        [bool]$CreateDesktopShortcut,
        [bool]$SkipLaunch
    )

    if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
        -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
        throw 'The source script path could not be determined.'
    }

    $sourcePath = [IO.Path]::GetFullPath($PSCommandPath)
    $destinationPath = [IO.Path]::GetFullPath($script:InstalledScriptPath)
    $migrationStates = @(Get-LegacyMigrationStates)
    $recognizedStates = @($migrationStates | Where-Object { $_.HasArtifacts -and $_.IdentityRecognized })
    $migrationState = Select-LegacyMigrationSource -States $migrationStates
    $migrationLease = $null
    $releaseMigrationLease = $false
    $migrationPerformed = $false
    $startupEnabled = $true
    $effectiveDesktopShortcut = [bool]$CreateDesktopShortcut

    try {
        if ($null -ne $script:MutexLease -and $script:MutexLease.Acquired) {
            # The tray's Start with Windows action already owns these locks.
            $migrationLease = $script:MutexLease
        }
        else {
            $releaseMigrationLease = $true
            $migrationLease = Enter-AppMutexSet
            if (-not $migrationLease.Acquired) {
                Stop-RunningInstalledTrays -LegacyStates $migrationStates
                $migrationLease = Enter-AppMutexSet
            }
        }
        if (-not $migrationLease.Acquired) {
            throw 'A running tray could not be safely closed automatically. Choose Exit from that tray, then retry the installation.'
        }

        if ($recognizedStates.Count -gt 0) {
            # Re-read only after holding all identity mutexes so an old tray cannot
            # start or mutate its per-user state during the transition.
            $migrationStates = @(Get-LegacyMigrationStates)
            $recognizedStates = @($migrationStates | Where-Object { $_.HasArtifacts -and $_.IdentityRecognized })
            $migrationState = Select-LegacyMigrationSource -States $migrationStates
            $migrationPerformed = $recognizedStates.Count -gt 0
        }

        $existingStartupCommand = Get-StartWithWindowsCommand -ValueName $script:AppId
        $newScriptRecognized = Test-ApplicationScriptIdentity -Path $destinationPath -ExpectedAppId $script:AppId -ExpectedProductName $script:ProductName -ExpectedInstalledFileName 'TrayTunnel.ps1'
        $newStartupEnabled = Test-StartupCommandOwned -Command $existingStartupCommand -ScriptPath $destinationPath
        $newDesktopShortcutOwned = Test-AppShortcutOwned -ShortcutPath $script:DesktopShortcutPath -ScriptPath $destinationPath
        $newStartMenuShortcutOwned = Test-AppShortcutOwned -ShortcutPath $script:StartMenuShortcutPath -ScriptPath $destinationPath
        $newIdentityRecognized = $newScriptRecognized -or $newStartupEnabled -or $newStartMenuShortcutOwned -or $newDesktopShortcutOwned
        $choiceParameters = @{
            MigrationPerformed          = $migrationPerformed
            LegacyStartupEnabled        = [bool]$migrationState.StartupEnabled
            LegacyDesktopShortcutOwned  = [bool]$migrationState.DesktopShortcutOwned
            NewIdentityRecognized       = [bool]$newIdentityRecognized
            NewStartupEnabled           = [bool]$newStartupEnabled
            NewDesktopShortcutOwned     = [bool]$newDesktopShortcutOwned
            DesktopShortcutRequested    = [bool]$CreateDesktopShortcut
        }
        $installationChoices = Resolve-InstallationChoices @choiceParameters
        $startupEnabled = [bool]$installationChoices.StartupEnabled
        $effectiveDesktopShortcut = [bool]$installationChoices.DesktopShortcutEnabled

        if (-not [string]::IsNullOrWhiteSpace($existingStartupCommand) -and
            -not $newStartupEnabled) {
            throw "Installation stopped because an unrelated startup entry already uses the name '$($script:AppId)'."
        }

        $shortcutPaths = @($script:StartMenuShortcutPath)
        if ($effectiveDesktopShortcut) {
            $shortcutPaths += $script:DesktopShortcutPath
        }
        foreach ($shortcutPath in $shortcutPaths) {
            if ((Test-Path -LiteralPath $shortcutPath -PathType Leaf) -and
                -not (Test-AppShortcutOwned -ShortcutPath $shortcutPath -ScriptPath $destinationPath)) {
                throw "Installation stopped because an unrelated shortcut already exists: $shortcutPath"
            }
        }

        if (Test-Path -LiteralPath $script:InstallDirectory) {
            if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
                throw "The installation path is not a directory: $($script:InstallDirectory)"
            }
            $installItem = Get-Item -LiteralPath $script:InstallDirectory -Force
            if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to install through a reparse-point directory: $($script:InstallDirectory)"
            }
        }
        else {
            New-Item -ItemType Directory -Path $script:InstallDirectory -Force | Out-Null
        }

        Copy-FileAtomically -SourcePath $sourcePath -DestinationPath $destinationPath

        $settingsCopied = $false
        if ($migrationPerformed) {
            $settingsCopied = Copy-LegacySettingsIfNeeded -LegacySettingsPath $migrationState.SettingsPath -NewSettingsPath $script:SettingsPath
        }

        Set-StartWithWindows -Enabled $startupEnabled -ScriptPath $destinationPath
        New-AppShortcut -ShortcutPath $script:StartMenuShortcutPath -ScriptPath $destinationPath

        if ($effectiveDesktopShortcut) {
            New-AppShortcut -ShortcutPath $script:DesktopShortcutPath -ScriptPath $destinationPath
        }
        elseif (($migrationPerformed -or $newIdentityRecognized) -and
            (Test-AppShortcutOwned -ShortcutPath $script:DesktopShortcutPath -ScriptPath $destinationPath)) {
            Remove-Item -LiteralPath $script:DesktopShortcutPath -Force
        }

        $validationParameters = @{
            SourceScriptPath       = $sourcePath
            InstalledScriptPath    = $destinationPath
            StartupEnabled         = $startupEnabled
            DesktopShortcutEnabled = $effectiveDesktopShortcut
            SettingsRequired       = [bool]($migrationPerformed -and $migrationState.SettingsValid)
            SettingsCopied         = [bool]$settingsCopied
            LegacySettingsPath     = $migrationState.SettingsPath
            NewSettingsPath        = $script:SettingsPath
        }
        Assert-NewInstallationValid @validationParameters

        # No legacy artifact is touched before every new artifact above validates.
        foreach ($recognizedState in $recognizedStates) {
            Remove-LegacyMigrationArtifacts -State $recognizedState
        }
    }
    finally {
        if ($releaseMigrationLease) { Exit-AppMutexSet -Lease $migrationLease }
    }

    Write-Host "Installed $($script:ProductName) $($script:Version) at: $destinationPath"
    if ($startupEnabled) {
        Write-Host 'Startup entry enabled for the current user.'
    }
    else {
        Write-Host 'The existing disabled Start with Windows choice was preserved.'
    }
    Write-Host "Start Menu shortcut created at: $($script:StartMenuShortcutPath)"
    if ($effectiveDesktopShortcut) {
        Write-Host "Desktop shortcut created at: $($script:DesktopShortcutPath)"
    }
    if ($migrationPerformed) {
        Write-Host 'Migrated recognized previous per-user installations to TrayTunnel.'
    }
    foreach ($legacyState in $migrationStates) {
        if ($legacyState.HasArtifacts -and -not $legacyState.IdentityRecognized) {
            Write-Warning "Unrecognized files at a previous installation path were left unchanged: $($legacyState.InstallDirectory)"
        }
    }

    if ($null -ne $script:MutexLease -and $script:MutexLease.Acquired) { return }
    if (Test-AppMutexExists) {
        Write-Warning 'A tray instance is already running. Exit and relaunch it to load this installed version.'
        return
    }

    if (-not $SkipLaunch) {
        Start-AppProcess -ScriptPath $destinationPath
        Write-Host 'The tray application was started.'
    }
}

function Uninstall-App {
    $uninstallLease = Enter-AppMutexSet
    if (-not $uninstallLease.Acquired) {
        throw 'A current or previous tray version is running. Choose Exit from its menu, then run uninstall again.'
    }

    try {
        # Inspect every old root before removing anything. Unsafe paths leave all
        # identities unchanged so the user can resolve the issue explicitly.
        $legacyStates = @(Get-LegacyMigrationStates)

        if (Test-Path -LiteralPath $script:InstallDirectory) {
            if (-not (Test-Path -LiteralPath $script:InstallDirectory -PathType Container)) {
                throw "The application path is not a directory: $($script:InstallDirectory)"
            }
            $installItem = Get-Item -LiteralPath $script:InstallDirectory -Force
            if (($installItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Refusing to remove files through a reparse-point install directory: $($script:InstallDirectory)"
            }
        }

        $startupCommand = Get-StartWithWindowsCommand -ValueName $script:AppId
        if (Test-StartupCommandOwned -Command $startupCommand -ScriptPath $script:InstalledScriptPath) {
            Remove-ItemProperty -Path $script:RunKeyPath -Name $script:AppId -ErrorAction Stop
        }
        elseif (-not [string]::IsNullOrWhiteSpace($startupCommand)) {
            Write-Warning "Left an unrelated startup entry unchanged: $($script:AppId)"
        }

        foreach ($shortcutPath in @($script:StartMenuShortcutPath, $script:DesktopShortcutPath)) {
            if (Test-AppShortcutOwned -ShortcutPath $shortcutPath -ScriptPath $script:InstalledScriptPath) {
                Remove-Item -LiteralPath $shortcutPath -Force
            }
            elseif (Test-Path -LiteralPath $shortcutPath -PathType Leaf) {
                Write-Warning "Left an unrelated shortcut unchanged: $shortcutPath"
            }
        }

        if (Test-Path -LiteralPath $script:InstallDirectory -PathType Container) {
            $ownedFiles = @(
                $script:InstalledScriptPath
                $script:SettingsPath
                $script:LogPath
                "$($script:LogPath).old"
            )
            foreach ($ownedFile in $ownedFiles) {
                if (Test-Path -LiteralPath $ownedFile -PathType Leaf) {
                    Remove-Item -LiteralPath $ownedFile -Force
                }
            }

            foreach ($filter in @('settings.*.tmp', 'TrayTunnel.install.*.tmp', 'TrayTunnel.install.*.bak')) {
                foreach ($temporaryFile in @(Get-ChildItem -LiteralPath $script:InstallDirectory -Filter $filter -File -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $temporaryFile.FullName -Force
                }
            }

            $remainingItem = Get-ChildItem -LiteralPath $script:InstallDirectory -Force | Select-Object -First 1
            if ($null -eq $remainingItem) {
                Remove-Item -LiteralPath $script:InstallDirectory -Force
            }
            else {
                Write-Warning "Left the non-empty application directory in place: $($script:InstallDirectory)"
            }
        }

        foreach ($legacyState in $legacyStates) {
            if ($legacyState.HasArtifacts -and $legacyState.IdentityRecognized) {
                Remove-LegacyMigrationArtifacts -State $legacyState
            }
            elseif ($legacyState.HasArtifacts) {
                Write-Warning "Unrecognized files at a previous installation path were left unchanged: $($legacyState.InstallDirectory)"
            }
        }
    }
    finally {
        Exit-AppMutexSet -Lease $uninstallLease
    }

    Write-Host "$($script:ProductName) and exact-owned legacy artifacts were removed for the current user."
}

function Invoke-ReadOnlyHealthCheck {
    param(
        [AllowEmptyCollection()]
        [string[]]$ProgramFilesRoots
    )

    $result = [ordered]@{
        ApplicationVersion = $script:Version
        PowerShellHost     = $null
        VpnCliPath         = $null
        VpnCliVersion      = $null
        ConnectionState    = $null
        AgentService       = $null
        Success            = $false
        Error              = $null
    }

    $process = $null
    try {
        $result.PowerShellHost = [string]$PSVersionTable.PSVersion
        $resolveParameters = @{ ConfiguredPath = '' }
        if ($PSBoundParameters.ContainsKey('ProgramFilesRoots')) {
            $resolveParameters.ProgramFilesRoots = $ProgramFilesRoots
        }
        $vpnCliPath = Resolve-VpnCliPath @resolveParameters
        if ($null -eq $vpnCliPath) {
            throw 'Cisco vpncli.exe was not found in a supported installation directory.'
        }

        $result.VpnCliPath = $vpnCliPath
        $result.VpnCliVersion = (Get-Item -LiteralPath $vpnCliPath).VersionInfo.FileVersion

        $service = $null
        foreach ($serviceName in @('csc_vpnagent', 'vpnagent')) {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($null -ne $service) {
                break
            }
        }
        $result.AgentService = if ($null -eq $service) { 'Not found' } else { [string]$service.Status }

        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $vpnCliPath
        $startInfo.Arguments = 'state'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'Cisco vpncli.exe did not start.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit(10000)) {
            $process.Kill()
            throw 'Cisco vpncli.exe did not answer the read-only state query within 10 seconds.'
        }
        if ($process.ExitCode -ne 0) {
            throw "Cisco vpncli.exe returned exit code $($process.ExitCode) for the state query."
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $state = Get-ConnectionStateFromText -Text ($stdout + "`n" + $stderr)
        if ($null -eq $state) {
            throw 'The Cisco CLI answered, but its connection state could not be parsed.'
        }

        $result.ConnectionState = $state
        $result.Success = $true
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }
            catch {
            }
            $process.Dispose()
        }
    }

    return [pscustomobject]$result
}

function Initialize-WindowsForms {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if (-not ('TrayTunnel.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace TrayTunnel {
    public static class NativeMethods {
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool DestroyIcon(IntPtr handle);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool ShowWindow(IntPtr handle, int command);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetForegroundWindow(IntPtr handle);
    }
}
'@
    }

    [System.Windows.Forms.Application]::EnableVisualStyles()
    [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)
}

function New-StatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ColorHtml
    )

    $bitmap = New-Object Drawing.Bitmap 32, 32
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fill = New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($ColorHtml))
    $border = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(100, 0, 0, 0)), 2

    try {
        $graphics.Clear([Drawing.Color]::Transparent)
        $graphics.FillEllipse($fill, 3, 3, 26, 26)
        $graphics.DrawEllipse($border, 3, 3, 26, 26)
        $handle = $bitmap.GetHicon()
        try {
            return ([Drawing.Icon]::FromHandle($handle)).Clone()
        }
        finally {
            [TrayTunnel.NativeMethods]::DestroyIcon($handle) | Out-Null
        }
    }
    finally {
        $border.Dispose()
        $fill.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Set-ApplicationState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State,

        [AllowEmptyString()]
        [string]$Detail = ''
    )

    $script:ApplicationState = $State
    $script:StateDetail = $Detail

    if ($null -eq $script:NotifyIcon) {
        return
    }

    $presentation = Get-TrayPresentation -State $State -Detail $Detail
    $script:NotifyIcon.Icon = $script:Icons[$presentation.Color]
    $tooltip = "$($script:ProductName) - $($presentation.Status)"
    if ($tooltip.Length -gt 63) {
        $tooltip = $tooltip.Substring(0, 63)
    }
    $script:NotifyIcon.Text = $tooltip
    $script:StatusMenuItem.Text = "Status: $($presentation.Status)"
    $script:ActionMenuItem.Text = $presentation.Action
    $script:ActionMenuItem.Enabled = $State -notin @('Disconnecting', 'CompanyNetwork') -and
        -not ($State -eq 'DisconnectedError' -and (Test-StateDetailUncertain -Detail $Detail))

    if ($null -ne $script:SettingsMenuItem) {
        $script:SettingsMenuItem.Enabled = Test-TraySettingsEnabled -State $State
    }
    if ($null -ne $script:ExitMenuItem) {
        # Exit must remain an escape hatch during Cisco-owned reconnects.
        $script:ExitMenuItem.Enabled = $true
    }
}

function Get-VpnCliArguments {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Status', 'Connect', 'Disconnect', 'NotificationListener')]
        [string]$Operation
    )

    switch ($Operation) {
        'Status' { return 'state' }
        'Connect' { return '-s' }
        'Disconnect' { return 'disconnect' }
        'NotificationListener' { return '-s' }
    }
}

function Test-VpnCliUsesStandardInput {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Status', 'Connect', 'Disconnect', 'NotificationListener')]
        [string]$Operation
    )

    return $Operation -in @('Connect', 'NotificationListener')
}

function Get-CliOperationTransport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Status', 'Connect', 'Disconnect')]
        [string]$Operation,

        [bool]$NotificationListenerAvailable = $false,

        [bool]$NotificationListenerRunning = $false
    )

    if ($Operation -eq 'Status') {
        if ($NotificationListenerAvailable) {
            return 'NotificationListener'
        }
        if ($NotificationListenerRunning) {
            return 'Defer'
        }
    }

    return 'Process'
}

function Get-CiscoCliNotificationFromLine {
    param(
        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }

    $payload = $Line -replace '^\s*(?:VPN>\s*)?', ''
    $match = [regex]::Match($payload, '^\s*>>\s*(error|notice)\s*:\s*(.+?)\s*$', 'IgnoreCase')
    if (-not $match.Success) {
        return $null
    }

    return [pscustomobject]@{
        Kind    = $match.Groups[1].Value.ToLowerInvariant()
        Message = $match.Groups[2].Value.Trim()
    }
}

function Test-CiscoCliRegistrationLine {
    param(
        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    return [regex]::IsMatch(
        $Line,
        '^\s*(?:VPN>\s*)?(?:>>\s*)?registered\s+with\s+local\s+VPN\s+subsystem\.?\s*$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
}

function Test-CliNotificationListenerRequired {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State
    )

    return $State -in @('Connecting', 'Disconnecting', 'Connected')
}

function Get-CliNotificationListenerRetentionAction {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('InitialDisconnected', 'CompanyNetwork', 'Connecting', 'Disconnecting', 'Connected', 'DisconnectedError')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [DateTime]$Now,

        [Parameter(Mandatory = $true)]
        [DateTime]$StopAfter
    )

    if (Test-CliNotificationListenerRequired -State $State) {
        return 'Keep'
    }
    if ($StopAfter -eq [DateTime]::MaxValue) {
        return 'StartGrace'
    }
    if ($Now -ge $StopAfter) {
        return 'Stop'
    }

    return 'Keep'
}

function Test-CliNotificationListenerRunning {
    if ($null -eq $script:CliNotificationListener) {
        return $false
    }

    try {
        return -not $script:CliNotificationListener.Process.HasExited
    }
    catch {
        return $false
    }
}

function Test-CliNotificationListenerAvailable {
    if (-not (Test-CliNotificationListenerRunning)) {
        return $false
    }

    return [bool]$script:CliNotificationListener.Registered -and
        -not [bool]$script:CliNotificationListener.ReadFailed
}

function Test-CliNotificationListenerRegistrationTimedOut {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Listener,

        [Parameter(Mandatory = $true)]
        [DateTime]$Now
    )

    return -not [bool]$Listener.Registered -and
        $Now -ge [DateTime]$Listener.RegistrationDeadline
}

function Test-CliNotificationStatusOperationSucceeded {
    param(
        [AllowNull()]
        [object]$Operation
    )

    if ($null -eq $Operation -or
        [string](Get-ObjectPropertyValue -InputObject $Operation -Name 'Transport' -DefaultValue 'Process') -ne 'NotificationListener' -or
        -not [bool](Get-ObjectPropertyValue -InputObject $Operation -Name 'Completed' -DefaultValue $false)) {
        return $false
    }

    $reportedState = [string](Get-ObjectPropertyValue -InputObject $Operation -Name 'ReportedState' -DefaultValue '')
    return $reportedState -in @('Connected', 'Disconnected', 'Connecting', 'Disconnecting', 'Reconnecting')
}

function Start-CliNotificationListener {
    if (Test-CliNotificationListenerRunning) {
        return $true
    }

    if ($null -ne $script:CliNotificationListener) {
        Stop-CliNotificationListener -Reason 'stale listener cleanup'
    }

    $vpnCliPath = Resolve-VpnCliPath -ConfiguredPath $script:Settings.VpnCliPath
    if ($null -eq $vpnCliPath) {
        $script:NextCliNotificationListenerStart = [DateTime]::UtcNow.AddSeconds(15)
        return $false
    }

    $process = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $vpnCliPath
        $startInfo.Arguments = Get-VpnCliArguments -Operation 'NotificationListener'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'vpncli.exe did not start.'
        }

        $process.StandardInput.AutoFlush = $true
        $startedAt = [DateTime]::UtcNow
        $listener = [pscustomobject]@{
            Process        = $process
            StandardInput  = $process.StandardInput
            OutputReader   = $process.StandardOutput
            ErrorReader    = $process.StandardError
            OutputReadTask = $null
            ErrorReadTask  = $null
            ReadFailed     = $false
            Registered     = $false
            StateSequence        = [long]0
            LastState            = $null
            StopAfter            = [DateTime]::MaxValue
            StartedAt            = $startedAt
            RegistrationDeadline = $startedAt.AddSeconds(10)
        }
        $listener.OutputReadTask = $listener.OutputReader.ReadLineAsync()
        $listener.ErrorReadTask = $listener.ErrorReader.ReadLineAsync()
        $script:CliNotificationListener = $listener
        $script:NextCliNotificationListenerStart = [DateTime]::MaxValue
        Write-AppLog -Message 'Cisco CLI notification listener process started; waiting for VPN subsystem registration.'
        return $true
    }
    catch {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                    $process.WaitForExit(2000) | Out-Null
                }
            }
            catch {
            }
            $process.Dispose()
        }

        $script:CliNotificationListener = $null
        $script:NextCliNotificationListenerStart = [DateTime]::UtcNow.AddSeconds(15)
        Write-AppLog -Level 'WARN' -Message ("Could not start the Cisco CLI notification listener: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Stop-CliNotificationListener {
    param(
        [string]$Reason = 'cleanup'
    )

    $listener = $script:CliNotificationListener
    $script:CliNotificationListener = $null
    $script:NextCliNotificationListenerStart = [DateTime]::UtcNow
    if ($null -eq $listener) {
        return
    }

    try {
        if (-not $listener.Process.HasExited) {
            try {
                $listener.StandardInput.WriteLine('quit')
                $listener.StandardInput.Flush()
                $listener.StandardInput.Close()
            }
            catch {
            }

            if (-not $listener.Process.WaitForExit(1500)) {
                $listener.Process.Kill()
                if (-not $listener.Process.WaitForExit(2000)) {
                    Write-AppLog -Level 'WARN' -Message ("The Cisco CLI notification listener did not exit promptly during {0}." -f $Reason)
                }
            }
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ("Could not stop the Cisco CLI notification listener during {0}: {1}" -f $Reason, $_.Exception.Message)
    }
    finally {
        try {
            $listener.Process.Dispose()
        }
        catch {
        }
    }
}

function Receive-CliNotificationListenerLine {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Listener,

        [AllowNull()]
        [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }

    if ((Test-CiscoCliRegistrationLine -Line $Line) -and -not [bool]$Listener.Registered) {
        $Listener.Registered = $true
        Write-AppLog -Message 'Cisco CLI notification listener registered with the local VPN subsystem.'
    }

    $state = Get-ConnectionStateFromText -Text $Line
    if ($null -ne $state) {
        $Listener.StateSequence = [long]$Listener.StateSequence + 1
        $Listener.LastState = $state

        $operation = $script:ActiveOperation
        if ($null -ne $operation -and
            [string](Get-ObjectPropertyValue -InputObject $operation -Name 'Transport' -DefaultValue 'Process') -eq 'NotificationListener' -and
            $Listener.StateSequence -gt [long]$operation.MinimumStateSequence) {
            $operation.ReportedState = $state
            $operation.Completed = $true
        }
        elseif ($null -eq $operation -and $Listener.Registered) {
            Set-ApplicationStateFromCiscoState -State $state
        }
        return
    }

    if (-not $Listener.Registered) {
        return
    }

    $notification = Get-CiscoCliNotificationFromLine -Line $Line
    if ($null -eq $notification) {
        return
    }

    $level = if ($notification.Kind -eq 'error') { 'ERROR' } else { 'INFO' }
    Write-AppLog -Level $level -Message ("Cisco CLI {0} received by the hidden notification listener." -f $notification.Kind)
}

function Receive-CliNotificationListenerStream {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Listener,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Output', 'Error')]
        [string]$StreamName
    )

    $readerProperty = $StreamName + 'Reader'
    $taskProperty = $StreamName + 'ReadTask'
    for ($lineCount = 0; $lineCount -lt 128; $lineCount++) {
        $task = $Listener.$taskProperty
        if ($null -eq $task -or -not $task.IsCompleted) {
            break
        }

        try {
            $line = $task.GetAwaiter().GetResult()
        }
        catch {
            $Listener.$taskProperty = $null
            $Listener.ReadFailed = $true
            Write-AppLog -Level 'WARN' -Message ("Could not read the Cisco CLI notification listener {0}: {1}" -f $StreamName.ToLowerInvariant(), $_.Exception.Message)
            break
        }

        if ($null -eq $line) {
            $Listener.$taskProperty = $null
            $Listener.ReadFailed = $true
            break
        }

        Receive-CliNotificationListenerLine -Listener $Listener -Line $line
        try {
            $Listener.$taskProperty = $Listener.$readerProperty.ReadLineAsync()
        }
        catch {
            $Listener.$taskProperty = $null
            $Listener.ReadFailed = $true
            Write-AppLog -Level 'WARN' -Message ("Could not continue reading the Cisco CLI notification listener {0}: {1}" -f $StreamName.ToLowerInvariant(), $_.Exception.Message)
            break
        }
    }
}

function Receive-CliNotificationListenerOutput {
    $listener = $script:CliNotificationListener
    if ($null -eq $listener) {
        return
    }

    Receive-CliNotificationListenerStream -Listener $listener -StreamName 'Output'
    Receive-CliNotificationListenerStream -Listener $listener -StreamName 'Error'
}

function Start-CliNotificationListenerStatus {
    param(
        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($null -ne $script:ActiveOperation -or -not (Test-CliNotificationListenerAvailable)) {
        return $false
    }

    Receive-CliNotificationListenerOutput
    $listener = $script:CliNotificationListener
    if ($null -eq $listener -or -not (Test-CliNotificationListenerAvailable)) {
        return $false
    }

    $operation = [pscustomobject]@{
        Name                 = 'Status'
        Transport            = 'NotificationListener'
        StartedAt            = [DateTime]::UtcNow
        TimeoutSeconds       = $TimeoutSeconds
        MinimumStateSequence = [long]$listener.StateSequence
        ReportedState        = $null
        Completed            = $false
    }
    $script:ActiveOperation = $operation

    try {
        $listener.StandardInput.WriteLine('state')
        $listener.StandardInput.Flush()
        return $true
    }
    catch {
        $script:ActiveOperation = $null
        Write-AppLog -Level 'WARN' -Message ("Could not query status through the Cisco CLI notification listener: {0}" -f $_.Exception.Message)
        Stop-CliNotificationListener -Reason 'status write failure'
        return $false
    }
}

function Update-CliNotificationListener {
    param(
        [Parameter(Mandatory = $true)]
        [DateTime]$Now
    )

    $listener = $script:CliNotificationListener
    if ($null -ne $listener) {
        Receive-CliNotificationListenerOutput
        $listenerExited = $false
        try {
            $listenerExited = $listener.Process.HasExited
        }
        catch {
            $listenerExited = $true
        }

        if ($listenerExited -or $listener.ReadFailed) {
            $listenerOperation = $script:ActiveOperation
            $listenerOperationPending = $null -ne $listenerOperation -and
                [string](Get-ObjectPropertyValue -InputObject $listenerOperation -Name 'Transport' -DefaultValue 'Process') -eq 'NotificationListener'
            $listenerOperationSucceeded = Test-CliNotificationStatusOperationSucceeded -Operation $listenerOperation
            $listenerReportedState = if ($listenerOperationSucceeded) { [string]$listenerOperation.ReportedState } else { $null }
            if ($listenerOperationPending) {
                $script:ActiveOperation = $null
            }

            Stop-CliNotificationListener -Reason 'listener exit'
            $script:NextCliNotificationListenerStart = $Now.AddSeconds(5)
            Write-AppLog -Level 'WARN' -Message 'The Cisco CLI notification listener exited unexpectedly.'
            if ($listenerOperationSucceeded) {
                Complete-StatusQuery -State $listenerReportedState -Succeeded $true -TimedOut $false
            }
            elseif ($listenerOperationPending) {
                Complete-StatusQuery -State $null -Succeeded $false -TimedOut $true
            }
            return
        }

        if (Test-CliNotificationListenerRegistrationTimedOut -Listener $listener -Now $Now) {
            Stop-CliNotificationListener -Reason 'registration timeout'
            $script:NextCliNotificationListenerStart = $Now.AddSeconds(15)
            Write-AppLog -Level 'WARN' -Message 'The Cisco CLI notification listener did not register with the VPN subsystem within 10 seconds; modal suppression is not active and will be retried.'
            return
        }

        if ($null -eq $script:ActiveOperation) {
            $retentionAction = Get-CliNotificationListenerRetentionAction -State $script:ApplicationState -Now $Now -StopAfter $listener.StopAfter
            switch ($retentionAction) {
                'StartGrace' {
                    # Cisco can emit the terminal error after its Disconnected state.
                    $listener.StopAfter = $Now.AddSeconds(5)
                }
                'Stop' {
                    Stop-CliNotificationListener -Reason 'terminal notification grace period ended'
                }
                'Keep' {
                    if (Test-CliNotificationListenerRequired -State $script:ApplicationState) {
                        $listener.StopAfter = [DateTime]::MaxValue
                    }
                }
            }
        }
        return
    }

    if ($null -eq $script:ActiveOperation -and
        (Test-CliNotificationListenerRequired -State $script:ApplicationState) -and
        $Now -ge $script:NextCliNotificationListenerStart) {
        [void](Start-CliNotificationListener)
    }
}

function Start-CliOperation {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Status', 'Connect', 'Disconnect')]
        [string]$Operation,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$InputText = '',

        [Parameter(Mandatory = $true)]
        [int]$TimeoutSeconds
    )

    if ($null -ne $script:ActiveOperation) {
        return $false
    }

    $listenerRunning = Test-CliNotificationListenerRunning
    $listenerAvailable = Test-CliNotificationListenerAvailable
    $transport = Get-CliOperationTransport -Operation $Operation -NotificationListenerAvailable $listenerAvailable -NotificationListenerRunning $listenerRunning
    if ($transport -eq 'Defer') {
        return $false
    }
    if ($transport -eq 'NotificationListener') {
        return Start-CliNotificationListenerStatus -TimeoutSeconds $TimeoutSeconds
    }

    if ($Operation -in @('Connect', 'Disconnect') -and $null -ne $script:CliNotificationListener) {
        Stop-CliNotificationListener -Reason ("starting {0}" -f $Operation.ToLowerInvariant())
    }

    $vpnCliPath = Resolve-VpnCliPath -ConfiguredPath $script:Settings.VpnCliPath
    if ($null -eq $vpnCliPath) {
        Set-ApplicationState -State 'DisconnectedError' -Detail 'Cisco VPN CLI not found'
        Write-AppLog -Level 'ERROR' -Message 'Cisco vpncli.exe was not found.'
        return $false
    }

    $process = $null
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $vpnCliPath
        $startInfo.Arguments = Get-VpnCliArguments -Operation $Operation
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.RedirectStandardInput = Test-VpnCliUsesStandardInput -Operation $Operation
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'vpncli.exe did not start.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (Test-VpnCliUsesStandardInput -Operation $Operation) {
            if ([string]::IsNullOrEmpty($InputText)) {
                throw 'Connect input was empty.'
            }
            $process.StandardInput.Write($InputText)
            $process.StandardInput.Close()
        }

        $script:ActiveOperation = [pscustomobject]@{
            Name           = $Operation
            Transport      = 'Process'
            Process        = $process
            StandardOutput = $stdoutTask
            StandardError  = $stderrTask
            StartedAt      = [DateTime]::UtcNow
            TimeoutSeconds = $TimeoutSeconds
        }

        return $true
    }
    catch {
        if ($null -ne $process) {
            try {
                if (-not $process.HasExited) {
                    $process.Kill()
                }
            }
            catch {
            }
            $process.Dispose()
        }
        Set-ApplicationState -State 'DisconnectedError' -Detail 'Cisco VPN CLI failed to start'
        Write-AppLog -Level 'ERROR' -Message ("Failed to start vpncli.exe for {0}: {1}" -f $Operation, $_.Exception.Message)
        return $false
    }
    finally {
        $InputText = $null
    }
}

function Stop-CliProcess {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation,

        [string]$Reason = 'cleanup'
    )

    try {
        if (-not $Operation.Process.HasExited) {
            $Operation.Process.Kill()
            if (-not $Operation.Process.WaitForExit(2000)) {
                Write-AppLog -Level 'WARN' -Message ("The {0} CLI process did not exit promptly during {1}." -f $Operation.Name, $Reason)
            }
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ("Could not stop the {0} CLI process during {1}: {2}" -f $Operation.Name, $Reason, $_.Exception.Message)
    }
    finally {
        try {
            $Operation.Process.Dispose()
        }
        catch {
        }
    }
}

function Stop-ActiveCliOperation {
    param(
        [string]$Reason = 'cancellation'
    )

    $operation = $script:ActiveOperation
    if ($null -eq $operation) {
        return $null
    }

    # Detach first. Timer and click handlers share the Forms thread, so the
    # detached operation can no longer complete and overwrite cancellation.
    $script:ActiveOperation = $null
    $transport = [string](Get-ObjectPropertyValue -InputObject $operation -Name 'Transport' -DefaultValue 'Process')
    if ($transport -eq 'Process') {
        Stop-CliProcess -Operation $operation -Reason $Reason
    }
    return [string]$operation.Name
}

function Update-CompanyNetworkStatus {
    param(
        [DateTime]$Now = [DateTime]::UtcNow,
        [switch]$Force
    )

    if (-not $Force -and $Now -lt $script:NextCompanyNetworkCheck) {
        return
    }
    $script:NextCompanyNetworkCheck = $Now.AddSeconds(5)
    $detected = $false
    if ($script:Settings.AutoDisconnectOnCompanyNetwork) {
        try {
            $detected = Test-CompanyNetworkSnapshot -Snapshots (Get-NetworkInterfaceSnapshot) -DnsSuffix $script:Settings.CompanyDnsSuffix
        }
        catch {
            # Missing network evidence must never trigger an automatic disconnect.
        }
    }
    if ($detected -ne $script:CompanyNetworkDetected) {
        $script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
    }
    $script:CompanyNetworkDetected = $detected
    if (-not $detected -and $script:ApplicationState -eq 'CompanyNetwork') {
        Set-ApplicationState -State 'InitialDisconnected'
    }
}

function Invoke-CompanyNetworkPolicy {
    param([DateTime]$Now = [DateTime]::UtcNow)

    if (-not $script:CompanyNetworkDetected -or
        $script:DisconnectDeadline -gt [DateTime]::MinValue -or
        $Now -lt $script:NextCompanyDisconnectAttempt) {
        return
    }

    $operationName = if ($null -eq $script:ActiveOperation) { '' } else { [string]$script:ActiveOperation.Name }
    if ($operationName -eq 'Disconnect') {
        return
    }
    if ($script:ApplicationState -in @('Connected', 'Connecting', 'Disconnecting') -or $operationName -eq 'Connect') {
        if ($operationName -notin @('', 'Connect', 'Status')) {
            return
        }
        [void](Stop-ActiveCliOperation -Reason 'company network detected')
        Write-AppLog -Message 'Company network detected; requesting automatic VPN disconnect.'
        [void](Start-VerifiedDisconnect -Reason 'CompanyNetwork')
    }
    elseif ($script:ApplicationState -eq 'InitialDisconnected') {
        Set-ApplicationState -State 'CompanyNetwork'
    }
}

function Get-DisconnectingDetail {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('UserDisconnect', 'UserCancel', 'ConnectTimeout', 'ConnectFailure', 'CompanyNetwork')]
        [string]$Reason
    )

    switch ($Reason) {
        'UserDisconnect' { return '' }
        'UserCancel' { return 'Cancelling connection' }
        'ConnectTimeout' { return 'Cancelling timed-out connection' }
        'ConnectFailure' { return 'Cancelling failed connection' }
        'CompanyNetwork' { return 'Disconnecting on company network' }
    }
}

function Set-NetworkUnavailableState {
    if ($script:ApplicationState -in @('Connected', 'Connecting')) {
        Set-ApplicationState -State 'Connecting' -Detail 'Waiting for network'
    }
    else {
        Set-ApplicationState -State 'DisconnectedError' -Detail 'No network connection'
    }
}

function Set-VpnStateUnavailableState {
    switch ($script:ApplicationState) {
        'Connected' {
            Set-ApplicationState -State 'Connected' -Detail 'VPN state unavailable'
        }
        'Connecting' {
            Set-ApplicationState -State 'Connecting' -Detail 'VPN state unavailable'
        }
        default {
            Set-ApplicationState -State 'DisconnectedError' -Detail 'VPN state unavailable'
        }
    }
}

function Complete-DisconnectVerification {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Connected', 'Active', 'Unavailable')]
        [string]$Outcome
    )

    $reason = [string]$script:DisconnectReason
    if ($reason -notin @('UserDisconnect', 'UserCancel', 'ConnectTimeout', 'ConnectFailure', 'CompanyNetwork')) {
        $reason = 'UserDisconnect'
    }

    $script:DisconnectDeadline = [DateTime]::MinValue
    $script:DisconnectReason = ''
    $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(5)
    if ($reason -eq 'CompanyNetwork' -and $Outcome -ne 'Success') {
        # Keep failures visible and avoid repeatedly issuing a failed command.
        $script:NextCompanyDisconnectAttempt = [DateTime]::UtcNow.AddSeconds(30)
    }

    switch ($Outcome) {
        'Success' {
            switch ($reason) {
                'UserDisconnect' {
                    Set-ApplicationState -State 'InitialDisconnected'
                    Write-AppLog -Message 'VPN disconnected by user request.'
                }
                'CompanyNetwork' {
                    if ($script:CompanyNetworkDetected) {
                        Set-ApplicationState -State 'CompanyNetwork'
                    }
                    else {
                        Set-ApplicationState -State 'InitialDisconnected'
                    }
                    Write-AppLog -Message 'VPN disconnected automatically on the company network.'
                }
                'UserCancel' {
                    Set-ApplicationState -State 'InitialDisconnected' -Detail 'Connection cancelled'
                    Write-AppLog -Message 'VPN connection attempt cancelled by user request.'
                }
                'ConnectTimeout' {
                    Set-ApplicationState -State 'DisconnectedError' -Detail 'Connection timed out'
                    Write-AppLog -Level 'ERROR' -Message 'Timed-out VPN connection attempt was cancelled.'
                }
                'ConnectFailure' {
                    Set-ApplicationState -State 'DisconnectedError' -Detail 'Connection failed'
                    Write-AppLog -Level 'ERROR' -Message 'Failed VPN connection attempt was cancelled.'
                }
            }
        }
        'Connected' {
            $detail = if ($reason -in @('UserDisconnect', 'CompanyNetwork')) {
                'Disconnect failed; still connected'
            }
            else {
                'Cancellation failed; VPN connected'
            }
            Set-ApplicationState -State 'Connected' -Detail $detail
            Write-AppLog -Level 'ERROR' -Message ("Cisco remained Connected after disconnect verification ({0})." -f $reason)
        }
        'Active' {
            $detail = if ($reason -in @('UserDisconnect', 'CompanyNetwork')) {
                'Disconnect failed; Cisco still active'
            }
            else {
                'Cancellation failed; Cisco still active'
            }
            Set-ApplicationState -State 'Connecting' -Detail $detail
            Write-AppLog -Level 'ERROR' -Message ("Cisco remained in a transitional state after disconnect verification ({0})." -f $reason)
        }
        'Unavailable' {
            $detail = if ($reason -in @('UserDisconnect', 'CompanyNetwork')) {
                'Disconnect result unavailable'
            }
            else {
                'Cancellation result unavailable'
            }
            Set-ApplicationState -State 'DisconnectedError' -Detail $detail
            Write-AppLog -Level 'ERROR' -Message ("Cisco state was unavailable when disconnect verification expired ({0})." -f $reason)
        }
    }
}

function Continue-DisconnectVerification {
    if ($script:DisconnectDeadline -le [DateTime]::MinValue) {
        return $false
    }

    if ([DateTime]::UtcNow -lt $script:DisconnectDeadline) {
        $reason = [string]$script:DisconnectReason
        if ($reason -notin @('UserDisconnect', 'UserCancel', 'ConnectTimeout', 'ConnectFailure', 'CompanyNetwork')) {
            $reason = 'UserDisconnect'
        }
        Set-ApplicationState -State 'Disconnecting' -Detail (Get-DisconnectingDetail -Reason $reason)
        $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(1)
        return $true
    }

    Complete-DisconnectVerification -Outcome 'Unavailable'
    return $false
}

function Start-VerifiedDisconnect {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('UserDisconnect', 'UserCancel', 'ConnectTimeout', 'ConnectFailure', 'CompanyNetwork')]
        [string]$Reason
    )

    if ($null -ne $script:ActiveOperation) {
        Write-AppLog -Level 'ERROR' -Message ("Could not start verified disconnect for {0}; another CLI operation is active." -f $Reason)
        return $false
    }

    $script:DisconnectReason = $Reason
    $script:DisconnectDeadline = [DateTime]::UtcNow.AddSeconds(30)
    Set-ApplicationState -State 'Disconnecting' -Detail (Get-DisconnectingDetail -Reason $Reason)

    $started = Start-CliOperation -Operation 'Disconnect' -TimeoutSeconds 10
    if (-not $started) {
        Write-AppLog -Level 'ERROR' -Message ("The direct disconnect command could not start for {0}; verifying Cisco state." -f $Reason)
        [void](Continue-DisconnectVerification)
    }

    return $started
}

function Set-ApplicationStateFromCiscoState {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Connected', 'Disconnected', 'Connecting', 'Disconnecting', 'Reconnecting')]
        [string]$State
    )

    switch ($State) {
        'Connected' {
            Set-ApplicationState -State 'Connected'
        }
        'Connecting' {
            Set-ApplicationState -State 'Connecting'
        }
        'Reconnecting' {
            if (Test-BasicNetworkAvailable) {
                Set-ApplicationState -State 'Connecting' -Detail 'Reconnecting'
            }
            else {
                Set-ApplicationState -State 'Connecting' -Detail 'Waiting for network'
            }
        }
        'Disconnecting' {
            Set-ApplicationState -State 'Disconnecting'
        }
        'Disconnected' {
            if ($script:CompanyNetworkDetected) {
                Set-ApplicationState -State 'CompanyNetwork'
            }
            elseif ($script:ApplicationState -eq 'Connected') {
                Set-ApplicationState -State 'DisconnectedError' -Detail 'Connection lost'
                Write-AppLog -Level 'WARN' -Message 'The VPN connection was lost.'
            }
            elseif ($script:ApplicationState -in @('Connecting', 'Disconnecting')) {
                Set-ApplicationState -State 'DisconnectedError'
            }
            elseif ($script:ApplicationState -ne 'DisconnectedError' -or
                (Test-StateDetailUncertain -Detail $script:StateDetail) -or
                $script:StateDetail -eq 'No network connection') {
                Set-ApplicationState -State 'InitialDisconnected'
            }
        }
    }
}

function Complete-StatusQuery {
    param(
        [AllowNull()]
        [string]$State,

        [bool]$Succeeded,

        [bool]$TimedOut,

        [AllowEmptyString()]
        [string]$FailureDescription = ''
    )

    $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(5)
    if ($TimedOut) {
        if ($script:DisconnectDeadline -gt [DateTime]::MinValue) {
            Write-AppLog -Level 'WARN' -Message 'The state query timed out during disconnect verification.'
            [void](Continue-DisconnectVerification)
        }
        elseif (-not (Test-BasicNetworkAvailable)) {
            Set-NetworkUnavailableState
        }
        else {
            Set-VpnStateUnavailableState
            Write-AppLog -Level 'ERROR' -Message 'The Status operation timed out.'
        }
        return
    }

    if ($script:DisconnectDeadline -gt [DateTime]::MinValue) {
        if ($Succeeded -and $State -eq 'Disconnected') {
            Complete-DisconnectVerification -Outcome 'Success'
            return
        }

        if ([DateTime]::UtcNow -lt $script:DisconnectDeadline) {
            [void](Continue-DisconnectVerification)
            return
        }

        if ($Succeeded -and $State -eq 'Connected') {
            Complete-DisconnectVerification -Outcome 'Connected'
        }
        elseif ($Succeeded -and $State -in @('Connecting', 'Reconnecting', 'Disconnecting')) {
            Complete-DisconnectVerification -Outcome 'Active'
        }
        else {
            Complete-DisconnectVerification -Outcome 'Unavailable'
        }
        return
    }

    if (-not $Succeeded -or $null -eq $State) {
        if (-not (Test-BasicNetworkAvailable)) {
            Set-NetworkUnavailableState
        }
        else {
            Set-VpnStateUnavailableState
            $failureSuffix = if ([string]::IsNullOrWhiteSpace($FailureDescription)) {
                ''
            }
            else {
                ' (' + $FailureDescription + ')'
            }
            Write-AppLog -Level 'WARN' -Message ("The state query returned no recognized state{0}." -f $failureSuffix)
        }
        return
    }

    Set-ApplicationStateFromCiscoState -State $State
}

function Complete-CliOperation {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Operation,

        [bool]$TimedOut
    )

    $stdout = ''
    $stderr = ''
    $exitCode = -1

    try {
        if ($TimedOut -and -not $Operation.Process.HasExited) {
            $Operation.Process.Kill()
            $Operation.Process.WaitForExit(2000) | Out-Null
        }

        if ($Operation.StandardOutput.IsCompleted) {
            $stdout = $Operation.StandardOutput.GetAwaiter().GetResult()
        }
        if ($Operation.StandardError.IsCompleted) {
            $stderr = $Operation.StandardError.GetAwaiter().GetResult()
        }
        if ($Operation.Process.HasExited) {
            $exitCode = $Operation.Process.ExitCode
        }
    }
    catch {
        Write-AppLog -Level 'WARN' -Message ("Could not finish the {0} CLI process cleanly: {1}" -f $Operation.Name, $_.Exception.Message)
    }
    finally {
        $Operation.Process.Dispose()
    }

    $state = Get-ConnectionStateFromText -Text ($stdout + [Environment]::NewLine + $stderr)
    if ($Operation.Name -ne 'Status') {
        $reportedState = if ($null -eq $state) { 'Unknown' } else { $state }
        Write-AppLog -Message ("Cisco CLI {0} completed with exit code {1} and state {2}." -f $Operation.Name, $exitCode, $reportedState)
    }
    $stdout = $null
    $stderr = $null

    if ($Operation.Name -eq 'Status') {
        Complete-StatusQuery -State $state -Succeeded ($exitCode -eq 0) -TimedOut $TimedOut -FailureDescription ("exit code {0}" -f $exitCode)
        return
    }

    $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(1)
    if ($TimedOut) {
        switch ($Operation.Name) {
            'Connect' {
                Write-AppLog -Level 'ERROR' -Message 'The connect operation timed out; cancelling it through Cisco.'
                [void](Start-VerifiedDisconnect -Reason 'ConnectTimeout')
            }
            'Disconnect' {
                Write-AppLog -Level 'WARN' -Message 'The direct disconnect command timed out; verifying Cisco state.'
                [void](Continue-DisconnectVerification)
            }
        }
        return
    }

    switch ($Operation.Name) {
        'Connect' {
            $script:DisconnectDeadline = [DateTime]::MinValue
            $script:DisconnectReason = ''
            if ($state -eq 'Connected') {
                Set-ApplicationState -State 'Connected'
                if ($exitCode -eq 0) {
                    Write-AppLog -Message 'VPN connected.'
                }
                else {
                    Write-AppLog -Level 'WARN' -Message ("Cisco reported Connected despite CLI exit code {0}." -f $exitCode)
                }
            }
            else {
                Write-AppLog -Level 'ERROR' -Message ("The connect operation did not report Connected (exit code {0}); cancelling it through Cisco." -f $exitCode)
                [void](Start-VerifiedDisconnect -Reason 'ConnectFailure')
            }
        }
        'Disconnect' {
            if ($exitCode -eq 0 -and $state -eq 'Disconnected') {
                Complete-DisconnectVerification -Outcome 'Success'
                return
            }

            if ($exitCode -ne 0) {
                Write-AppLog -Level 'WARN' -Message ("The direct disconnect command returned exit code {0}; verifying Cisco state." -f $exitCode)
            }
            else {
                Write-AppLog -Message 'Disconnect command accepted; waiting for Cisco to report Disconnected.'
            }

            if ([DateTime]::UtcNow -ge $script:DisconnectDeadline) {
                if ($state -eq 'Connected') {
                    Complete-DisconnectVerification -Outcome 'Connected'
                }
                elseif ($state -in @('Connecting', 'Reconnecting', 'Disconnecting')) {
                    Complete-DisconnectVerification -Outcome 'Active'
                }
                else {
                    Complete-DisconnectVerification -Outcome 'Unavailable'
                }
            }
            else {
                [void](Continue-DisconnectVerification)
            }
        }
    }
}
function Invoke-TrayAction {
    Update-CompanyNetworkStatus -Force
    Invoke-CompanyNetworkPolicy
    if ($script:CompanyNetworkDetected) {
        return
    }

    $activeOperationName = if ($null -eq $script:ActiveOperation) {
        ''
    }
    else {
        [string]$script:ActiveOperation.Name
    }
    $disconnectPending = $script:DisconnectDeadline -gt [DateTime]::MinValue
    $actionKind = Get-TrayActionKind `
        -State $script:ApplicationState `
        -ActiveOperationName $activeOperationName `
        -DisconnectPending $disconnectPending `
        -StateDetail $script:StateDetail

    if ($actionKind -eq 'Ignore') {
        return
    }

    if ($null -ne $script:ActiveOperation) {
        if ($script:ActiveOperation.Name -eq 'Status' -or
            ($actionKind -eq 'CancelConnect' -and $script:ActiveOperation.Name -eq 'Connect')) {
            [void](Stop-ActiveCliOperation -Reason 'tray action')
        }
        else {
            return
        }
    }

    switch ($actionKind) {
        'CancelConnect' {
            Write-AppLog -Message 'User requested connection cancellation.'
            [void](Start-VerifiedDisconnect -Reason 'UserCancel')
            return
        }
        'Disconnect' {
            Write-AppLog -Message 'User requested VPN disconnect.'
            [void](Start-VerifiedDisconnect -Reason 'UserDisconnect')
            return
        }
    }

    if (-not $script:Settings.Configured) {
        Show-SettingsDialog -FirstRun
        return
    }

    $runningCiscoVpnUi = @(Get-RunningCiscoVpnUiProcesses)
    if ($runningCiscoVpnUi.Count -gt 0) {
        Set-ApplicationState -State 'DisconnectedError' -Detail 'Quit Cisco Secure Client, then retry'
        Write-AppLog -Level 'WARN' -Message 'VPN connect was not started because the Cisco VPN UI owns the connect capability.'
        [Windows.Forms.MessageBox]::Show(
            'Cisco Secure Client is already running and has exclusive control of VPN connections. Fully exit the Cisco Secure Client UI from its notification-area icon, then try again. Do not stop the Cisco VPN agent service.',
            $script:ProductName,
            [Windows.Forms.MessageBoxButtons]::OK,
            [Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    if (-not (Test-BasicNetworkAvailable)) {
        Set-ApplicationState -State 'DisconnectedError' -Detail 'No network connection'
        $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(5)
        Write-AppLog -Level 'WARN' -Message 'VPN connect was not started because Windows reports no usable network.'
        return
    }

    $password = $null
    $inputText = $null
    try {
        $script:DisconnectDeadline = [DateTime]::MinValue
        $script:DisconnectReason = ''
        $password = Unprotect-Password -EncryptedPassword $script:Settings.PasswordEncrypted
        $connectInputParameters = @{
            VpnAddress        = $script:Settings.VpnAddress
            Username          = $script:Settings.Username
            Password          = $password
            AcceptLoginBanner = $script:Settings.AcceptLoginBanner
        }
        $inputText = New-VpnCliInput @connectInputParameters

        Write-AppLog -Message 'User requested VPN connect.'
        Set-ApplicationState -State 'Connecting'
        $script:NextNetworkCheck = [DateTime]::UtcNow
        if (-not (Start-CliOperation -Operation 'Connect' -InputText $inputText -TimeoutSeconds 180)) {
            Set-ApplicationState -State 'DisconnectedError' -Detail 'Connection could not start'
        }
    }
    catch {
        Set-ApplicationState -State 'DisconnectedError' -Detail 'Stored password is unavailable'
        Write-AppLog -Level 'ERROR' -Message ("Could not prepare the connection: {0}" -f $_.Exception.Message)
        Show-SettingsDialog
    }
    finally {
        $password = $null
        $inputText = $null
    }
}
function Show-SettingsDialog {
    param(
        [switch]$FirstRun
    )

    Write-AppLog -Message 'Initializing settings dialog.'

    if ($null -ne $script:SettingsForm -and -not $script:SettingsForm.IsDisposed) {
        $script:SettingsForm.Activate()
        return
    }

    $form = New-Object Windows.Forms.Form
    $script:SettingsForm = $form
    $form.Text = "$($script:ProductName) Settings"
    $form.ClientSize = New-Object Drawing.Size 650, 505
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.ShowInTaskbar = $true
    $form.TopMost = [bool]$FirstRun

    $intro = New-Object Windows.Forms.Label
    $intro.Location = New-Object Drawing.Point 18, 15
    $intro.Size = New-Object Drawing.Size 610, 36
    $intro.Text = if ($FirstRun) {
        'Enter the credentials used by the Cisco VPN CLI. Cisco host and username defaults were imported where available.'
    }
    else {
        'Update the connection settings. Leave Password blank to keep the currently saved password.'
    }
    $form.Controls.Add($intro)

    $labels = @('VPN address or profile', 'Username', 'Password', 'Cisco CLI (automatic)')
    $topValues = @(63, 103, 143, 183)
    for ($index = 0; $index -lt $labels.Count; $index++) {
        $label = New-Object Windows.Forms.Label
        $label.Location = New-Object Drawing.Point 18, $topValues[$index]
        $label.Size = New-Object Drawing.Size 155, 23
        $label.Text = $labels[$index]
        $form.Controls.Add($label)
    }

    $addressBox = New-Object Windows.Forms.TextBox
    $addressBox.Location = New-Object Drawing.Point 178, 60
    $addressBox.Size = New-Object Drawing.Size 450, 23
    $addressBox.Text = $script:Settings.VpnAddress
    $form.Controls.Add($addressBox)

    $usernameBox = New-Object Windows.Forms.TextBox
    $usernameBox.Location = New-Object Drawing.Point 178, 100
    $usernameBox.Size = New-Object Drawing.Size 450, 23
    $usernameBox.Text = $script:Settings.Username
    $form.Controls.Add($usernameBox)

    $passwordBox = New-Object Windows.Forms.TextBox
    $passwordBox.Location = New-Object Drawing.Point 178, 140
    $passwordBox.Size = New-Object Drawing.Size 450, 23
    $passwordBox.UseSystemPasswordChar = $true
    $form.Controls.Add($passwordBox)

    $cliBox = New-Object Windows.Forms.TextBox
    $cliBox.Location = New-Object Drawing.Point 178, 180
    $cliBox.Size = New-Object Drawing.Size 340, 23
    $detectedCliPath = Resolve-VpnCliPath -ConfiguredPath $script:Settings.VpnCliPath
    $cliBox.Text = if ($null -eq $detectedCliPath) { '' } else { $detectedCliPath }
    $cliBox.ReadOnly = $true
    $cliBox.TabStop = $false
    $form.Controls.Add($cliBox)

    $detectCliButton = New-Object Windows.Forms.Button
    $detectCliButton.Location = New-Object Drawing.Point 526, 178
    $detectCliButton.Size = New-Object Drawing.Size 102, 27
    $detectCliButton.Text = 'Detect again'
    $form.Controls.Add($detectCliButton)

    $clearPassword = New-Object Windows.Forms.CheckBox
    $clearPassword.Location = New-Object Drawing.Point 178, 211
    $clearPassword.Size = New-Object Drawing.Size 220, 24
    $clearPassword.Text = 'Clear the saved password'
    $clearPassword.Enabled = -not [string]::IsNullOrWhiteSpace($script:Settings.PasswordEncrypted)
    $form.Controls.Add($clearPassword)

    $acceptBanner = New-Object Windows.Forms.CheckBox
    $acceptBanner.Location = New-Object Drawing.Point 18, 242
    $acceptBanner.Size = New-Object Drawing.Size 610, 24
    $acceptBanner.Text = "Append 'y' after the password to accept the configured login banner"
    $acceptBanner.Checked = $script:Settings.AcceptLoginBanner
    $form.Controls.Add($acceptBanner)

    $warning = New-Object Windows.Forms.Label
    $warning.Location = New-Object Drawing.Point 37, 268
    $warning.Size = New-Object Drawing.Size 585, 45
    $warning.ForeColor = [Drawing.Color]::DarkRed
    $warning.Text = "Only enable banner acceptance if your known VPN login asks exactly this question. The CLI cannot distinguish it from another yes/no prompt."
    $form.Controls.Add($warning)

    $autoDisconnect = New-Object Windows.Forms.CheckBox
    $autoDisconnect.Location = New-Object Drawing.Point 18, 318
    $autoDisconnect.Size = New-Object Drawing.Size 610, 24
    $autoDisconnect.Text = 'Automatically disconnect VPN on the company network'
    $autoDisconnect.Checked = $script:Settings.AutoDisconnectOnCompanyNetwork
    $form.Controls.Add($autoDisconnect)

    $suffixLabel = New-Object Windows.Forms.Label
    $suffixLabel.Location = New-Object Drawing.Point 18, 355
    $suffixLabel.Size = New-Object Drawing.Size 155, 23
    $suffixLabel.Text = 'Company DNS suffix'
    $form.Controls.Add($suffixLabel)

    $suffixBox = New-Object Windows.Forms.TextBox
    $suffixBox.Location = New-Object Drawing.Point 178, 352
    $suffixBox.Size = New-Object Drawing.Size 450, 23
    $suffixBox.Text = $script:Settings.CompanyDnsSuffix
    $suffixBox.Enabled = $autoDisconnect.Checked
    $form.Controls.Add($suffixBox)
    $autoDisconnect.Add_CheckedChanged({ $suffixBox.Enabled = $autoDisconnect.Checked })

    $suffixHelp = New-Object Windows.Forms.Label
    $suffixHelp.Location = New-Object Drawing.Point 37, 386
    $suffixHelp.Size = New-Object Drawing.Size 585, 50
    $suffixHelp.Text = 'Use the connection-specific DNS suffix of your company Ethernet or Wi-Fi network. The VPN stays off with a grey icon while it matches. Disable this option to connect manually.'
    $form.Controls.Add($suffixHelp)

    $saveButton = New-Object Windows.Forms.Button
    $saveButton.Location = New-Object Drawing.Point 472, 454
    $saveButton.Size = New-Object Drawing.Size 75, 30
    $saveButton.Text = 'Save'
    $form.AcceptButton = $saveButton
    $form.Controls.Add($saveButton)

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Location = New-Object Drawing.Point 553, 454
    $cancelButton.Size = New-Object Drawing.Size 75, 30
    $cancelButton.Text = 'Cancel'
    $form.CancelButton = $cancelButton
    $form.Controls.Add($cancelButton)

    $clearPassword.Add_CheckedChanged({
        $passwordBox.Enabled = -not $clearPassword.Checked
        if ($clearPassword.Checked) {
            $passwordBox.Clear()
        }
    })

    $detectCliButton.Add_Click({
        $resolvedCli = Resolve-VpnCliPath -ConfiguredPath ''
        $cliBox.Text = if ($null -eq $resolvedCli) { '' } else { $resolvedCli }
        if ($null -eq $resolvedCli) {
            [Windows.Forms.MessageBox]::Show(
                $form,
                'Cisco vpncli.exe was not found in a supported Cisco Program Files location.',
                $script:ProductName,
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        }
    })

    $saveButton.Add_Click({
        try {
            $activeOperationName = if ($null -eq $script:ActiveOperation) {
                ''
            }
            else {
                [string]$script:ActiveOperation.Name
            }
            $saveAllowed = Test-SettingsSaveAllowed `
                -State $script:ApplicationState `
                -ActiveOperationName $activeOperationName `
                -DisconnectPending ($script:DisconnectDeadline -gt [DateTime]::MinValue)
            if (-not $saveAllowed) {
                throw 'Wait for the current VPN operation to finish before saving settings.'
            }

            $vpnAddress = $addressBox.Text.Trim()
            $username = $usernameBox.Text.Trim()
            $vpnCliPath = $cliBox.Text.Trim()
            $companyDnsSuffix = ConvertTo-CompanyDnsSuffix -Value $suffixBox.Text
            if ($autoDisconnect.Checked -and [string]::IsNullOrEmpty($companyDnsSuffix)) {
                throw 'Enter a company DNS suffix to enable automatic disconnect.'
            }

            if ([string]::IsNullOrWhiteSpace($vpnAddress)) {
                throw 'VPN address is required.'
            }
            if ([string]::IsNullOrWhiteSpace($username)) {
                throw 'Username is required.'
            }

            Assert-SingleLineValue -Name 'VPN address' -Value $vpnAddress
            Assert-SingleLineValue -Name 'Username' -Value $username
            Assert-SingleLineValue -Name 'VPN CLI path' -Value $vpnCliPath

            $resolvedCli = Resolve-VpnCliPath -ConfiguredPath $vpnCliPath
            if ($null -eq $resolvedCli) {
                throw 'Cisco vpncli.exe was not found in a supported Cisco Program Files location.'
            }

            $encryptedPassword = $script:Settings.PasswordEncrypted
            if ($clearPassword.Checked) {
                $encryptedPassword = ''
            }
            elseif (-not [string]::IsNullOrEmpty($passwordBox.Text)) {
                Assert-SingleLineValue -Name 'Password' -Value $passwordBox.Text
                $encryptedPassword = Protect-Password -Password $passwordBox.Text
            }

            if ([string]::IsNullOrWhiteSpace($encryptedPassword) -and -not $clearPassword.Checked) {
                throw 'Password is required.'
            }
            $isConfigured = -not [string]::IsNullOrWhiteSpace($encryptedPassword)

            $updated = [pscustomobject][ordered]@{
                SchemaVersion      = $script:SettingsSchemaVersion
                VpnAddress        = $vpnAddress
                Username          = $username
                PasswordEncrypted = $encryptedPassword
                AcceptLoginBanner = $acceptBanner.Checked
                AutoDisconnectOnCompanyNetwork = $autoDisconnect.Checked
                CompanyDnsSuffix  = $companyDnsSuffix
                VpnCliPath        = $resolvedCli
                Configured        = $isConfigured
                LoadError         = ''
            }

            Save-AppSettings -Settings $updated
            $script:Settings = $updated
            $script:NextCompanyNetworkCheck = [DateTime]::MinValue
            $script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
            $passwordBox.Clear()
            $form.DialogResult = [Windows.Forms.DialogResult]::OK
            $form.Close()
            # Refresh network policy and Cisco state on the next timer tick.
            $script:NextStatusPoll = [DateTime]::UtcNow
            Write-AppLog -Message 'Settings were saved.'
        }
        catch {
            [Windows.Forms.MessageBox]::Show(
                $form,
                $_.Exception.Message,
                $script:ProductName,
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    })

    $form.Add_FormClosed({
        $passwordBox.Clear()
        $script:SettingsForm = $null
        $form.Dispose()
    })

    $form.Add_Shown({
        Write-AppLog -Message 'Settings dialog shown.'
        [TrayTunnel.NativeMethods]::ShowWindow($form.Handle, 5) | Out-Null
        [TrayTunnel.NativeMethods]::SetForegroundWindow($form.Handle) | Out-Null
        $form.Activate()
    })

    Write-AppLog -Message 'Entering settings dialog.'
    $form.ShowDialog() | Out-Null
}

function Enable-StartupFromTray {
    # Reuse the installer's preflight, ownership, and reparse-point protections.
    Install-App -CreateDesktopShortcut $false -SkipLaunch $true
}

function Stop-TrayApplication {
    if ($script:Exiting) {
        return
    }
    $script:Exiting = $true

    try {
        if ($null -ne $script:PollTimer) {
            $script:PollTimer.Stop()
        }
        if ($null -ne $script:FirstRunTimer) {
            $script:FirstRunTimer.Stop()
            $script:FirstRunTimer.Dispose()
            $script:FirstRunTimer = $null
        }

        if ($null -ne $script:ActiveOperation) {
            [void](Stop-ActiveCliOperation -Reason 'tray exit')
        }
        if ($null -ne $script:CliNotificationListener) {
            Stop-CliNotificationListener -Reason 'tray exit'
        }

        if ($null -ne $script:NotifyIcon) {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }

        foreach ($icon in $script:Icons.Values) {
            $icon.Dispose()
        }

        Write-AppLog -Message 'Tray application exited. The VPN connection and startup setting were left unchanged.'
    }
    finally {
        if ($null -ne $script:ExitRequest) {
            $script:ExitRequest.Dispose()
            $script:ExitRequest = $null
        }
        Exit-AppMutexSet -Lease $script:MutexLease
        $script:MutexLease = $null
        $script:ApplicationContext.ExitThread()
    }
}

function Start-TrayApplication {
    Initialize-WindowsForms

    $script:MutexLease = Enter-AppMutexSet
    if (-not $script:MutexLease.Acquired) {
        return
    }

    $script:ExitRequest = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, (Get-TrayExitEventName))

    $script:Settings = Read-AppSettings
    $script:CompanyNetworkDetected = $false
    $script:NextCompanyNetworkCheck = [DateTime]::MinValue
    $script:NextCompanyDisconnectAttempt = [DateTime]::MinValue
    $script:ApplicationState = 'InitialDisconnected'
    $script:StateDetail = ''
    $script:ActiveOperation = $null
    $script:CliNotificationListener = $null
    $script:NextCliNotificationListenerStart = [DateTime]::UtcNow
    $script:DisconnectDeadline = [DateTime]::MinValue
    $script:DisconnectReason = ''
    $script:SettingsForm = $null
    $script:SettingsMenuItem = $null
    $script:ExitMenuItem = $null
    $script:Exiting = $false
    $script:NextStatusPoll = [DateTime]::UtcNow
    $script:NextNetworkCheck = [DateTime]::UtcNow
    $script:NotifyIcon = $null
    $script:PollTimer = $null
    $script:FirstRunTimer = $null
    $script:ApplicationContext = New-Object Windows.Forms.ApplicationContext

    $script:Icons = @{}
    foreach ($color in @('#7A7A7A', '#F5A623', '#B1CB21', '#E04B4F')) {
        $script:Icons[$color] = New-StatusIcon -ColorHtml $color
    }

    $contextMenu = New-Object Windows.Forms.ContextMenuStrip
    $script:StatusMenuItem = New-Object Windows.Forms.ToolStripMenuItem
    $script:StatusMenuItem.Enabled = $false
    [void]$contextMenu.Items.Add($script:StatusMenuItem)
    [void]$contextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

    $script:ActionMenuItem = New-Object Windows.Forms.ToolStripMenuItem
    $script:ActionMenuItem.Add_Click({ Invoke-TrayAction })
    [void]$contextMenu.Items.Add($script:ActionMenuItem)

    $script:SettingsMenuItem = New-Object Windows.Forms.ToolStripMenuItem
    $script:SettingsMenuItem.Text = 'Settings...'
    $script:SettingsMenuItem.Add_Click({ Show-SettingsDialog })
    [void]$contextMenu.Items.Add($script:SettingsMenuItem)

    $startupItem = New-Object Windows.Forms.ToolStripMenuItem
    $startupItem.Text = 'Start with Windows'
    $startupItem.CheckOnClick = $false
    $startupItem.Add_Click({
        try {
            if (Test-StartWithWindows) {
                Set-StartWithWindows -Enabled $false
            }
            else {
                Enable-StartupFromTray
            }
            $startupItem.Checked = Test-StartWithWindows
        }
        catch {
            [Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                $script:ProductName,
                [Windows.Forms.MessageBoxButtons]::OK,
                [Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })
    [void]$contextMenu.Items.Add($startupItem)
    [void]$contextMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))

    $script:ExitMenuItem = New-Object Windows.Forms.ToolStripMenuItem
    $script:ExitMenuItem.Text = 'Exit'
    $script:ExitMenuItem.Add_Click({ Stop-TrayApplication })
    [void]$contextMenu.Items.Add($script:ExitMenuItem)

    $contextMenu.Add_Opening({
        $startupItem.Checked = Test-StartWithWindows
    })

    $script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
    $script:NotifyIcon.ContextMenuStrip = $contextMenu
    $script:NotifyIcon.Visible = $true
    $script:NotifyIcon.Add_MouseClick({
        param($sender, $eventArgs)
        if (Test-TrayPrimaryClick -EventArgs $eventArgs) {
            Invoke-TrayAction
        }
    })

    Set-ApplicationState -State 'InitialDisconnected'

    $script:PollTimer = New-Object Windows.Forms.Timer
    $script:PollTimer.Interval = 250
    $script:PollTimer.Add_Tick({
        try {
            if ($null -ne $script:ExitRequest -and $script:ExitRequest.WaitOne(0)) {
                Stop-TrayApplication
                return
            }
            $now = [DateTime]::UtcNow
            Update-CompanyNetworkStatus -Now $now
            Update-CliNotificationListener -Now $now
            Invoke-CompanyNetworkPolicy -Now $now

            if ($null -ne $script:ActiveOperation) {
                $operation = $script:ActiveOperation
                $transport = [string](Get-ObjectPropertyValue -InputObject $operation -Name 'Transport' -DefaultValue 'Process')

                if ($operation.Name -eq 'Connect' -and $now -ge $script:NextNetworkCheck) {
                    $script:NextNetworkCheck = $now.AddSeconds(5)
                    if (-not (Test-BasicNetworkAvailable)) {
                        Set-ApplicationState -State 'Connecting' -Detail 'Waiting for network'
                    }
                    elseif ($script:StateDetail -eq 'Waiting for network') {
                        Set-ApplicationState -State 'Connecting'
                    }
                }

                $elapsed = ($now - $operation.StartedAt).TotalSeconds
                if ($transport -eq 'NotificationListener') {
                    if ($operation.Completed) {
                        $script:ActiveOperation = $null
                        Complete-StatusQuery -State $operation.ReportedState -Succeeded $true -TimedOut $false
                    }
                    elseif ($elapsed -ge $operation.TimeoutSeconds) {
                        $script:ActiveOperation = $null
                        Stop-CliNotificationListener -Reason 'status timeout'
                        $script:NextCliNotificationListenerStart = $now.AddSeconds(5)
                        Complete-StatusQuery -State $null -Succeeded $false -TimedOut $true
                    }
                }
                elseif ($elapsed -ge $operation.TimeoutSeconds) {
                    $script:ActiveOperation = $null
                    Complete-CliOperation -Operation $operation -TimedOut $true
                }
                elseif ($operation.Process.HasExited -and
                    $operation.StandardOutput.IsCompleted -and
                    $operation.StandardError.IsCompleted) {
                    $script:ActiveOperation = $null
                    Complete-CliOperation -Operation $operation -TimedOut $false
                }
            }
            elseif ($now -ge $script:NextStatusPoll) {
                # Status is a local vpnagent query. Once connected, the persistent
                # listener remains Cisco's registered CLI and receives modal errors.
                $disconnectPending = $script:DisconnectDeadline -gt [DateTime]::MinValue
                $script:NextStatusPoll = $now.AddSeconds(5)
                $statusStarted = Start-CliOperation -Operation 'Status' -TimeoutSeconds 10
                if (-not $statusStarted -and $disconnectPending) {
                    [void](Continue-DisconnectVerification)
                }
            }
        }
        catch {
            $failedOperation = $script:ActiveOperation
            $script:ActiveOperation = $null
            if ($null -ne $failedOperation) {
                $failedTransport = [string](Get-ObjectPropertyValue -InputObject $failedOperation -Name 'Transport' -DefaultValue 'Process')
                if ($failedTransport -eq 'Process') {
                    Stop-CliProcess -Operation $failedOperation -Reason 'polling error'
                }
                else {
                    Stop-CliNotificationListener -Reason 'polling error'
                }
            }
            if ($null -ne $script:CliNotificationListener) {
                Stop-CliNotificationListener -Reason 'polling error'
                $script:NextCliNotificationListenerStart = $now.AddSeconds(5)
            }

            Write-AppLog -Level 'ERROR' -Message ("Polling error: {0}" -f $_.Exception.Message)
            if ($null -ne $failedOperation -and $failedOperation.Name -eq 'Connect') {
                [void](Start-VerifiedDisconnect -Reason 'ConnectFailure')
            }
            elseif ($script:DisconnectDeadline -gt [DateTime]::MinValue) {
                [void](Continue-DisconnectVerification)
            }
            elseif (-not (Test-BasicNetworkAvailable)) {
                Set-NetworkUnavailableState
                $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(5)
            }
            else {
                Set-VpnStateUnavailableState
                $script:NextStatusPoll = [DateTime]::UtcNow.AddSeconds(5)
            }
        }
    })
    $script:PollTimer.Start()
    Write-AppLog -Message ("Tray application {0} started." -f $script:Version)

    if (-not $script:Settings.Configured) {
        $script:FirstRunTimer = New-Object Windows.Forms.Timer
        $script:FirstRunTimer.Interval = 350
        $script:FirstRunTimer.Add_Tick({
            try {
                $timer = $script:FirstRunTimer
                $script:FirstRunTimer = $null
                if ($null -ne $timer) {
                    $timer.Stop()
                    $timer.Dispose()
                }
                if (-not [string]::IsNullOrWhiteSpace($script:Settings.LoadError)) {
                    [Windows.Forms.MessageBox]::Show(
                        $script:Settings.LoadError,
                        $script:ProductName,
                        [Windows.Forms.MessageBoxButtons]::OK,
                        [Windows.Forms.MessageBoxIcon]::Warning
                    ) | Out-Null
                }
                Write-AppLog -Message 'Opening first-run settings.'
                Show-SettingsDialog -FirstRun
            }
            catch {
                Write-AppLog -Level 'ERROR' -Message ("Could not open first-run settings: {0}" -f $_.Exception.Message)
            }
        })
        $script:FirstRunTimer.Start()
    }

    try {
        [Windows.Forms.Application]::Run($script:ApplicationContext)
    }
    finally {
        if (-not $script:Exiting) {
            Stop-TrayApplication
        }
    }
}

# Dot-sourcing exposes the pure/testable functions without performing any action.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw "$($script:ProductName) runs only on Windows."
}
Assert-NonElevatedExecution -IsElevated (Test-ProcessIsElevated)

if ($Install) {
    Install-App -CreateDesktopShortcut ([bool]$DesktopShortcut) -SkipLaunch ([bool]$NoLaunch)
    exit 0
}

if ($Uninstall) {
    Uninstall-App
    exit 0
}

if ($HealthCheck) {
    $healthResult = Invoke-ReadOnlyHealthCheck
    $healthResult | ConvertTo-Json -Depth 3
    if ($healthResult.Success) { exit 0 } else { exit 1 }
}

if (Test-AppRehostRequired `
        -IsNoConsoleHost ([bool]$NoConsoleHost) `
        -ApartmentState ([Threading.Thread]::CurrentThread.ApartmentState)) {
    Start-AppProcess -ScriptPath ([IO.Path]::GetFullPath($PSCommandPath))
    exit 0
}

Start-TrayApplication
