# Included by Invoke-Tests.ps1. All installation paths, startup entries, and
# mutexes below are isolated fixtures; the real installation is never changed.

Assert-Equal 3 @(Get-AppMutexNames).Count 'TrayTunnel must coordinate with both previous application identities'
Assert-True (@(Get-AppMutexNames)[1] -like 'Local\VpnCliTray-*') 'the intermediate application identity must remain locked for compatibility'
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $repositoryRoot 'VpnCliTray.ps1')) 'the old application entry point must be renamed'
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $repositoryRoot 'Manage-VpnCliTray.ps1')) 'the old manager entry point must be renamed'

$upgradeRoot = Join-Path ([IO.Path]::GetTempPath()) ('TrayTunnel.Upgrades.' + [Guid]::NewGuid().ToString('N'))
$upgradeSavedVariables = @{}
foreach ($name in @('InstallDirectory', 'InstalledScriptPath', 'SettingsPath', 'LogPath', 'StartMenuShortcutPath', 'DesktopShortcutPath', 'RunKeyPath')) {
    $upgradeSavedVariables[$name] = (Get-Variable -Name $name -Scope Script).Value
}
$upgradeSavedFunctions = @{}
foreach ($name in @('Get-LegacyMigrationStates', 'Get-AppMutexNames', 'Get-StartWithWindowsCommand', 'Set-StartWithWindows', 'Assert-NewInstallationValid', 'Stop-RunningInstalledTrays')) {
    $upgradeSavedFunctions[$name] = (Get-Item -LiteralPath "Function:\$name").ScriptBlock
}
try {
    function Get-LegacyMigrationStates {
        foreach ($parameters in $script:UpgradeLegacyParameters) {
            Get-LegacyMigrationState @parameters
        }
    }
    function Get-AppMutexNames { return $script:UpgradeMutexNames }
    function Get-StartWithWindowsCommand {
        param($ValueName)
        return $script:UpgradeStartup[$ValueName]
    }
    function Set-StartWithWindows {
        param([bool]$Enabled, [string]$ScriptPath)
        if ($Enabled) {
            $script:UpgradeStartup[$script:AppId] = Get-StartupCommand -ScriptPath $ScriptPath
        }
        else { $script:UpgradeStartup.Remove($script:AppId) }
    }
    function Remove-ItemProperty {
        param($Path, $Name, $ErrorAction)
        if ($Path -ne 'UpgradeTests:') { throw 'Upgrade test attempted a real registry write.' }
        $script:UpgradeStartup.Remove($Name)
    }
    function Assert-NewInstallationValid {
        if ($script:UpgradeValidationFails) { throw 'Simulated installation validation failure.' }
        & $upgradeSavedFunctions['Assert-NewInstallationValid'] @args
    }
    function Stop-RunningInstalledTrays {
        param($LegacyStates)
        $script:UpgradeStopCalls++
        if ($script:UpgradeMayStop) {
            $script:UpgradeHeldMutex.ReleaseMutex()
            $script:UpgradeHeldMutex.Dispose()
            $script:UpgradeHeldMutex = $null
        }
    }

    foreach ($scenario in @('VpnCliTray', 'AnyConnectTray', 'Both', 'Existing', 'Fresh', 'InvalidNew', 'Interrupted', 'RunningLegacy', 'UnknownRunning', 'Unrecognized')) {
        $scenarioRoot = Join-Path $upgradeRoot $scenario
        [void][IO.Directory]::CreateDirectory($scenarioRoot)
        $script:InstallDirectory = Join-Path $scenarioRoot 'TrayTunnel'
        $script:InstalledScriptPath = Join-Path $script:InstallDirectory 'TrayTunnel.ps1'
        $script:SettingsPath = Join-Path $script:InstallDirectory 'settings.json'
        $script:LogPath = Join-Path $script:InstallDirectory 'TrayTunnel.log'
        $script:StartMenuShortcutPath = Join-Path $scenarioRoot 'TrayTunnel Start.lnk'
        $script:DesktopShortcutPath = Join-Path $scenarioRoot 'TrayTunnel Desktop.lnk'
        $script:RunKeyPath = 'UpgradeTests:'
        $script:UpgradeStartup = @{}
        $script:UpgradeValidationFails = $false
        $script:UpgradeStopCalls = 0
        $script:UpgradeMayStop = $scenario -eq 'RunningLegacy'
        $script:UpgradeHeldMutex = $null
        $script:UpgradeMutexNames = @('new', 'previous', 'oldest') | ForEach-Object { 'Local\TrayTunnel.UpgradeTests.{0}.{1}' -f [Guid]::NewGuid().ToString('N'), $_ }
        $script:UpgradeLegacyParameters = @()
        $legacyDocuments = @{}
        foreach ($identity in @('VpnCliTray', 'AnyConnectTray')) {
            $legacyDirectory = Join-Path $scenarioRoot $identity
            $fixtureProductName = if ($identity -eq 'VpnCliTray') { 'VPN CLI Tray' } else { 'AnyConnect Tray' }
            $parameters = @{
                AppId = $identity
                ProductName = $fixtureProductName
                InstalledFileName = "$identity.ps1"
                InstallDirectory = $legacyDirectory
                InstalledScriptPath = Join-Path $legacyDirectory "$identity.ps1"
                SettingsPath = Join-Path $legacyDirectory 'settings.json'
                LogPath = Join-Path $legacyDirectory "$identity.log"
                StartMenuShortcutPath = Join-Path $scenarioRoot "$fixtureProductName Start.lnk"
                DesktopShortcutPath = Join-Path $scenarioRoot "$fixtureProductName Desktop.lnk"
            }
            $script:UpgradeLegacyParameters += $parameters
            if ($scenario -eq 'Fresh' -or
                ($scenario -eq 'VpnCliTray' -and $identity -ne 'VpnCliTray') -or
                ($scenario -eq 'AnyConnectTray' -and $identity -ne 'AnyConnectTray')) { continue }

            [void][IO.Directory]::CreateDirectory($legacyDirectory)
            $legacySource = @'
param([switch]$Uninstall)
$script:ProductName = 'PRODUCT_NAME'
$script:AppId = 'APP_ID'
$script:Version = '0.2.1'
$script:InstallDirectory = Join-Path $env:LOCALAPPDATA $script:AppId
$script:InstalledScriptPath = Join-Path $script:InstallDirectory 'APP_ID.ps1'
function Uninstall-App { }
if ($Uninstall) { Uninstall-App }
'@
            $legacySource = $legacySource.Replace('PRODUCT_NAME', $fixtureProductName).Replace('APP_ID', $identity)
            $legacyDocuments[$identity] = [ordered]@{
                SchemaVersion = 1
                VpnAddress = "$identity.example.com"
                Username = 'test-user'
                PasswordEncrypted = $ciphertext
                AutoDisconnectOnCompanyNetwork = $true
                CompanyDnsSuffix = 'office.example.com'
            } | ConvertTo-Json
            [IO.File]::WriteAllText($parameters.InstalledScriptPath, $legacySource)
            [IO.File]::WriteAllText($parameters.SettingsPath, $legacyDocuments[$identity])
            [IO.File]::WriteAllText($parameters.LogPath, 'fixture log')
            [IO.File]::WriteAllText((Join-Path $legacyDirectory "$identity.install.fixture.tmp"), 'fixture temporary file')
            if ($scenario -eq 'Unrecognized') {
                [IO.File]::WriteAllText($parameters.InstalledScriptPath, 'unrecognized file')
                continue
            }
            New-AppShortcut -ShortcutPath $parameters.StartMenuShortcutPath -ScriptPath $parameters.InstalledScriptPath
            if ($identity -eq 'VpnCliTray') {
                New-AppShortcut -ShortcutPath $parameters.DesktopShortcutPath -ScriptPath $parameters.InstalledScriptPath
            }
            else {
                $script:UpgradeStartup[$identity] = Get-StartupCommand -ScriptPath $parameters.InstalledScriptPath
            }
        }

        if ($scenario -eq 'Existing') {
            [void][IO.Directory]::CreateDirectory($script:InstallDirectory)
            Copy-Item -LiteralPath $scriptPath -Destination $script:InstalledScriptPath
            $existingDocument = '{"SchemaVersion":1,"VpnAddress":"existing.example.com"}'
            [IO.File]::WriteAllText($script:SettingsPath, $existingDocument)
            $script:UpgradeStartup['TrayTunnel'] = Get-StartupCommand -ScriptPath $script:InstalledScriptPath
        }
        if ($scenario -eq 'InvalidNew') {
            [void][IO.Directory]::CreateDirectory($script:InstallDirectory)
            [IO.File]::WriteAllText($script:SettingsPath, '{corrupt')
            Assert-Throws -Because 'an invalid destination settings file must abort migration' -MessagePattern '*existing TrayTunnel settings file*' -Operation {
                Install-App -CreateDesktopShortcut $false -SkipLaunch $true
            }
            foreach ($parameters in $script:UpgradeLegacyParameters) {
                Assert-Equal $true (Test-Path -LiteralPath $parameters.InstalledScriptPath) 'failed migration must preserve every old script'
                Assert-Equal $legacyDocuments[$parameters.AppId] ([IO.File]::ReadAllText($parameters.SettingsPath)) 'failed migration must preserve every old settings file'
            }
            continue
        }
        if ($scenario -eq 'UnknownRunning') {
            $script:UpgradeHeldMutex = New-Object Threading.Mutex($true, $script:UpgradeMutexNames[1])
            try {
                Assert-Throws -Because 'migration must refuse to stop an unrecognized lock owner' -MessagePattern '*could not be safely closed automatically*' -Operation {
                    Install-App -CreateDesktopShortcut $false -SkipLaunch $true
                }
                Assert-Equal $false (Test-Path -LiteralPath $script:InstalledScriptPath) 'a running old tray must prevent migration before copying files'
            }
            finally { $script:UpgradeHeldMutex.ReleaseMutex(); $script:UpgradeHeldMutex.Dispose(); $script:UpgradeHeldMutex = $null }
            continue
        }
        if ($scenario -eq 'RunningLegacy') {
            $script:UpgradeHeldMutex = New-Object Threading.Mutex($true, $script:UpgradeMutexNames[1])
        }
        if ($scenario -eq 'Interrupted') {
            $script:UpgradeValidationFails = $true
            Assert-Throws -Because 'new installation validation must precede all old cleanup' -MessagePattern '*Simulated installation validation failure*' -Operation {
                Install-App -CreateDesktopShortcut $false -SkipLaunch $true
            }
            foreach ($parameters in $script:UpgradeLegacyParameters) {
                Assert-Equal $true (Test-Path -LiteralPath $parameters.InstalledScriptPath) 'validation failure must retain both old identities for retry'
                Assert-Equal $true (Test-Path -LiteralPath $parameters.SettingsPath) 'validation failure must retain both original settings files'
            }
            $script:UpgradeValidationFails = $false
        }

        Install-App -CreateDesktopShortcut $false -SkipLaunch $true
        Assert-Equal ([int]($scenario -eq 'RunningLegacy')) $script:UpgradeStopCalls 'installation must close a recognized running tray only when a lock prevents the upgrade'
        Assert-Equal $true (Test-FileContentsEqual -FirstPath $scriptPath -SecondPath $script:InstalledScriptPath) 'installation must publish the TrayTunnel application script'
        Assert-Equal $true (Test-AppShortcutOwned -ShortcutPath $script:StartMenuShortcutPath -ScriptPath $script:InstalledScriptPath) 'installation must create a TrayTunnel Start Menu shortcut'
        if ($scenario -eq 'Unrecognized') {
            foreach ($parameters in $script:UpgradeLegacyParameters) {
                Assert-Equal $true (Test-Path -LiteralPath $parameters.InstalledScriptPath) 'unrecognized scripts at old paths must survive installation'
            }
            Assert-Equal $false (Test-Path -LiteralPath $script:SettingsPath) 'settings from an unrecognized application must not be imported'
            continue
        }
        if ($scenario -eq 'Fresh') {
            Assert-True $script:UpgradeStartup.ContainsKey('TrayTunnel') 'fresh installs must use the new startup entry'
            $upgradePreviousLease = $script:MutexLease
            $script:MutexLease = Enter-AppMutexSet
            try {
                Enable-StartupFromTray
                Assert-Equal 0 $script:UpgradeStopCalls 'the tray startup action must reuse its locks without stopping itself'
                Assert-Equal $true (Test-AppMutexExists) 'the tray startup action must keep its existing locks alive'
            }
            finally {
                Exit-AppMutexSet -Lease $script:MutexLease
                $script:MutexLease = $upgradePreviousLease
            }
            continue
        }
        if ($scenario -eq 'Existing') {
            Assert-Equal $existingDocument ([IO.File]::ReadAllText($script:SettingsPath)) 'existing TrayTunnel settings must win over both previous names'
        }
        else {
            $sourceIdentity = if ($scenario -eq 'AnyConnectTray') { 'AnyConnectTray' } else { 'VpnCliTray' }
            Assert-Equal $legacyDocuments[$sourceIdentity] ([IO.File]::ReadAllText($script:SettingsPath)) 'upgrades must preserve the selected settings byte for byte'
            $upgradedSettings = Read-AppSettings
            Assert-Equal $true $upgradedSettings.AutoDisconnectOnCompanyNetwork 'the company-network preference must survive the rename'
            Assert-Equal 'office.example.com' $upgradedSettings.CompanyDnsSuffix 'the company DNS suffix must survive the rename'
            Assert-Equal (Unprotect-Password -EncryptedPassword $ciphertext) (Unprotect-Password -EncryptedPassword $upgradedSettings.PasswordEncrypted) 'saved credentials must still decrypt after moving the settings file'
        }
        $expectedStartup = $scenario -in @('AnyConnectTray', 'Existing')
        Assert-Equal $expectedStartup $script:UpgradeStartup.ContainsKey('TrayTunnel') 'upgrades must preserve enabled and disabled startup choices'
        Assert-Equal (-not $expectedStartup) (Test-AppShortcutOwned -ShortcutPath $script:DesktopShortcutPath -ScriptPath $script:InstalledScriptPath) 'upgrades must preserve Desktop shortcut choices'
        foreach ($parameters in $script:UpgradeLegacyParameters) {
            Assert-Equal $false (Test-Path -LiteralPath $parameters.InstallDirectory) 'verified upgrades must remove old scripts, settings, logs, temporary files, and the empty old directory'
            Assert-Equal $false (Test-Path -LiteralPath $parameters.StartMenuShortcutPath) 'verified upgrades must remove old Start Menu shortcuts'
            Assert-Equal $false (Test-Path -LiteralPath $parameters.DesktopShortcutPath) 'verified upgrades must remove old Desktop shortcuts'
            Assert-Equal $false $script:UpgradeStartup.ContainsKey($parameters.AppId) 'verified upgrades must remove old startup entries'
        }
        Uninstall-App
        Assert-Equal $false (Test-Path -LiteralPath $script:InstallDirectory) 'uninstall must remove the new application directory'
        Assert-Equal $false $script:UpgradeStartup.ContainsKey('TrayTunnel') 'uninstall must remove the new startup entry'
    }
}
finally {
    foreach ($name in $upgradeSavedFunctions.Keys) { Set-Item -LiteralPath "Function:\$name" -Value $upgradeSavedFunctions[$name] }
    Remove-Item -LiteralPath 'Function:\Remove-ItemProperty'
    foreach ($name in $upgradeSavedVariables.Keys) { Set-Variable -Name $name -Scope Script -Value $upgradeSavedVariables[$name] }
    $temporaryPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not [IO.Path]::GetFullPath($upgradeRoot).StartsWith($temporaryPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Upgrade fixture path is outside the temporary directory.' }
    if (Test-Path -LiteralPath $upgradeRoot -PathType Container) { [IO.Directory]::Delete($upgradeRoot, $true) }
}
