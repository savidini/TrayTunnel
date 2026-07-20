#requires -Version 5.1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$managerPath = Join-Path $repositoryRoot 'Manage-VpnCliTray.ps1'
$applicationPath = Join-Path $repositoryRoot 'VpnCliTray.ps1'
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
        [scriptblock]$Operation,
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

. $managerPath
Assert-Equal 'VPN CLI Tray' $script:ProductName 'the manager must expose the renamed product name'
Assert-Equal 'VpnCliTray' $script:AppId 'the manager must use the renamed application identifier'
Assert-Equal 'VpnCliTray.ps1' $script:ApplicationAssetName 'the manager must request the renamed application asset'
Assert-Equal 'VpnCliTray.release.json' $script:ManifestAssetName 'the manager must request the renamed manifest asset'
Assert-Equal 'VpnCliTray.ps1' ([IO.Path]::GetFileName($script:InstalledScriptPath)) 'the manager must target the renamed installed script'
Assert-Equal $false (Test-Path -LiteralPath (Join-Path $repositoryRoot 'Manage-AnyConnectTray.ps1')) 'the obsolete manager filename must not remain in the repository'
Assert-Equal $null (Assert-ProcessNotElevated -IsElevated $false) 'ordinary per-user manager execution must be allowed'
Assert-Throws -Because 'the manager must stop before any action when elevated' -MessagePattern '*refuses to run with administrator rights*' -Operation {
    Assert-ProcessNotElevated -IsElevated $true
}

$latestRoot = Get-ReleaseRootUri -RepositoryName 'savidini/VpnCliTray'
Assert-Equal 'https://github.com/savidini/VpnCliTray/releases/latest/download/' $latestRoot.AbsoluteUri 'the default source must use the latest GitHub Release without an API call'

$pinnedPayloadRoot = Get-PayloadReleaseRootUri -ManifestReleaseRootUri $latestRoot -ManifestVersion '0.2.0'
Assert-Equal 'https://github.com/savidini/VpnCliTray/releases/download/v0.2.0/' $pinnedPayloadRoot.AbsoluteUri 'the payload must be pinned after resolving the latest manifest'

$unprefixedVersionRoot = Get-ReleaseRootUri -RepositoryName 'savidini/VpnCliTray' -ReleaseVersion '0.2.0'
Assert-Equal 'https://github.com/savidini/VpnCliTray/releases/download/v0.2.0/' $unprefixedVersionRoot.AbsoluteUri 'an unprefixed version must resolve to its v-prefixed immutable release tag'

$prefixedVersionRoot = Get-ReleaseRootUri -RepositoryName 'savidini/VpnCliTray' -ReleaseVersion 'v0.2.0'
Assert-Equal 'https://github.com/savidini/VpnCliTray/releases/download/v0.2.0/' $prefixedVersionRoot.AbsoluteUri 'a v-prefixed version must retain its immutable release tag'

$customRoot = Get-ReleaseRootUri -RepositoryName 'unused/repository' -CustomReleaseBaseUri ([uri]'https://downloads.example.com/vpnclitray/latest')
Assert-Equal 'https://downloads.example.com/vpnclitray/latest/' $customRoot.AbsoluteUri 'a custom HTTPS release root must gain a trailing slash'

$assetUri = Get-ReleaseAssetUri -ReleaseRootUri $customRoot -AssetName 'VpnCliTray.ps1'
Assert-Equal 'https://downloads.example.com/vpnclitray/latest/VpnCliTray.ps1' $assetUri.AbsoluteUri 'release assets must stay below the release root'

Assert-Throws -Because 'plain HTTP release roots must be rejected' -MessagePattern '*Only absolute HTTPS*' -Operation {
    Get-ReleaseRootUri -RepositoryName 'unused/repository' -CustomReleaseBaseUri ([uri]'http://downloads.example.com/latest/') | Out-Null
}
Assert-Throws -Because 'a version and an exact custom release root are ambiguous' -MessagePattern '*cannot be used together*' -Operation {
    Get-ReleaseRootUri -RepositoryName 'unused/repository' -ReleaseVersion 'v0.2.0' -CustomReleaseBaseUri ([uri]'https://downloads.example.com/v0.2.0/') | Out-Null
}
Assert-Throws -Because 'custom release roots must not hide path data in a query string' -MessagePattern '*query string or fragment*' -Operation {
    Get-ReleaseRootUri -RepositoryName 'unused/repository' -CustomReleaseBaseUri ([uri]'https://downloads.example.com/latest/?channel=test') | Out-Null
}
Assert-Throws -Because 'asset names must not permit path traversal' -MessagePattern '*Invalid release asset name*' -Operation {
    Get-ReleaseAssetUri -ReleaseRootUri $customRoot -AssetName '../VpnCliTray.ps1' | Out-Null
}
$originalElevationProbe = ${function:Test-IsProcessElevated}
$originalInstallOrUpdate = ${function:Invoke-InstallOrUpdate}
try {
    function Test-IsProcessElevated {
        return $true
    }
    function Invoke-InstallOrUpdate {
        param(
            [uri]$ReleaseRootUri,
            [string]$RequestedVersion,
            [string]$ExpectedPublisherThumbprint,
            [bool]$CreateDesktopShortcut,
            [bool]$SkipLaunch
        )
        $script:ElevatedInstallAttempted = $true
    }

    $script:ElevatedInstallAttempted = $false
    Assert-Throws -Because 'invalid optional versions must be rejected before downloading, including on elevated runners' -MessagePattern '*Invalid release version*' -Operation {
        Invoke-VpnCliTrayManager -RequestedAction 'Install' -RepositoryName 'savidini/VpnCliTray' -RequestedVersion 'latest please' -CreateDesktopShortcut $false -SkipLaunch $false
    }
    Assert-Throws -Because 'an uppercase V version prefix must be rejected before downloading, including on elevated runners' -MessagePattern '*Invalid release version*' -Operation {
        Invoke-VpnCliTrayManager -RequestedAction 'Install' -RepositoryName 'savidini/VpnCliTray' -RequestedVersion 'V0.2.0' -CreateDesktopShortcut $false -SkipLaunch $false
    }
    Assert-Throws -Because 'invalid optional publisher fingerprints must be rejected before downloading, including on elevated runners' -MessagePattern '*40 or 64 hexadecimal*' -Operation {
        Invoke-VpnCliTrayManager -RequestedAction 'Install' -RepositoryName 'savidini/VpnCliTray' -ExpectedPublisherThumbprint 'not-a-thumbprint' -CreateDesktopShortcut $false -SkipLaunch $false
    }

    function Read-Host {
        param([string]$Prompt)
        return 'q'
    }
    try {
        Assert-Equal $null (Invoke-VpnCliTrayManager -RequestedAction 'Menu' -RepositoryName 'savidini/VpnCliTray' -CreateDesktopShortcut $false -SkipLaunch $false) 'an elevated user must be able to cancel without taking action'
    }
    finally {
        Remove-Item -LiteralPath 'Function:\Read-Host' -Force -ErrorAction SilentlyContinue
    }

    Assert-Throws -Because 'a valid elevated install must remain blocked before lifecycle code runs' -MessagePattern '*refuses to run with administrator rights*' -Operation {
        Invoke-VpnCliTrayManager -RequestedAction 'Install' -RepositoryName 'savidini/VpnCliTray' -RequestedVersion '0.2.0' -CreateDesktopShortcut $false -SkipLaunch $false
    }
    Assert-Equal $false $script:ElevatedInstallAttempted 'the elevated guard must run before installation lifecycle code'
}
finally {
    Set-Item -LiteralPath 'Function:\Test-IsProcessElevated' -Value $originalElevationProbe
    Set-Item -LiteralPath 'Function:\Invoke-InstallOrUpdate' -Value $originalInstallOrUpdate
    Remove-Variable -Name ElevatedInstallAttempted -Scope Script -ErrorAction SilentlyContinue
}

# Exercise the README's `& ([scriptblock]::Create((irm ...)))` shape without making changes.
# A local Read-Host shim selects Cancel so the test remains non-interactive.
try {
    function Read-Host {
        param([string]$Prompt)
        return 'q'
    }
    & ([scriptblock]::Create([IO.File]::ReadAllText($managerPath)))
    $script:Passed++
}
finally {
    Remove-Item -LiteralPath 'Function:\Read-Host' -Force -ErrorAction SilentlyContinue
}
$tempDirectory = Join-Path ([IO.Path]::GetTempPath()) ('VpnCliTray.ManagerTests.' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($tempDirectory)
$originalOutputVariable = $env:VPNCLITRAY_MANAGER_TEST_OUTPUT
$originalLegacyInstalledScriptPath = $script:LegacyInstalledScriptPath
try {
    $fixturePath = Join-Path $tempDirectory 'VpnCliTray.ps1'
    Copy-Item -LiteralPath $applicationPath -Destination $fixturePath
    $fixtureFile = Get-Item -LiteralPath $fixturePath
    $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash
    $fixtureVersion = Get-ScriptVersion -Path $fixturePath

    $manifestDocument = [ordered]@{
        schemaVersion = 1
        product       = 'VpnCliTray'
        version       = $fixtureVersion
        asset         = [ordered]@{
            name   = 'VpnCliTray.ps1'
            sha256 = $fixtureHash.ToLowerInvariant()
            size   = [long]$fixtureFile.Length
        }
    }
    $utf8NoBom = New-Object Text.UTF8Encoding($false)
    $legacyDirectory = Join-Path $tempDirectory 'AnyConnectTray'
    [void][IO.Directory]::CreateDirectory($legacyDirectory)
    $script:LegacyInstalledScriptPath = Join-Path $legacyDirectory 'AnyConnectTray.ps1'
    $legacyLines = @(
        '#requires -Version 5.1'
        '[CmdletBinding()]'
        'param([switch]$Uninstall)'
        '$script:ProductName = ''AnyConnect Tray'''
        '$script:AppId = ''AnyConnectTray'''
        '$script:Version = ''0.1.8'''
        '$script:InstallDirectory = Join-Path $env:LOCALAPPDATA $script:AppId'
        '$script:InstalledScriptPath = Join-Path $script:InstallDirectory ''AnyConnectTray.ps1'''
        'function Uninstall-App { }'
        'if ($Uninstall) { Uninstall-App }'
    )
    [IO.File]::WriteAllText($script:LegacyInstalledScriptPath, ($legacyLines -join "`r`n"), $utf8NoBom)
    Assert-Equal $true (Test-LegacyApplicationScriptOwned) 'the exact legacy path and semantic legacy identity must be recognized'

    $invalidSemVerLines = @($legacyLines | ForEach-Object { $_.Replace('0.1.8', '01.1.8') })
    [IO.File]::WriteAllText($script:LegacyInstalledScriptPath, ($invalidSemVerLines -join "`r`n"), $utf8NoBom)
    Assert-Equal $false (Test-LegacyApplicationScriptOwned) 'a legacy version with a leading-zero numeric identifier must fail semantic identity recognition'

    $deceptiveHereStringLines = @(
        ('$decoy = @' + [char]39)
    ) + $legacyLines + @(
        ([char]39 + '@')
    )
    [IO.File]::WriteAllText($script:LegacyInstalledScriptPath, ($deceptiveHereStringLines -join "`r`n"), $utf8NoBom)
    Assert-Equal $false (Test-LegacyApplicationScriptOwned) 'identity-like text inside a here-string must not be treated as executable legacy identity'

    $deceptiveBlockCommentLines = @('<#') + $legacyLines + @('#>')
    [IO.File]::WriteAllText($script:LegacyInstalledScriptPath, ($deceptiveBlockCommentLines -join "`r`n"), $utf8NoBom)
    Assert-Equal $false (Test-LegacyApplicationScriptOwned) 'identity-like text inside a block comment must not be treated as executable legacy identity'

    [IO.File]::WriteAllText($script:LegacyInstalledScriptPath, 'param([switch]$Uninstall)', $utf8NoBom)
    Assert-Equal $false (Test-LegacyApplicationScriptOwned) 'an arbitrary parseable file at the legacy path must not be treated as owned'

    $manifestPath = Join-Path $tempDirectory 'VpnCliTray.release.json'
    [IO.File]::WriteAllText($manifestPath, ($manifestDocument | ConvertTo-Json -Depth 3), $utf8NoBom)

    $manifest = Read-ReleaseManifest -Path $manifestPath
    Assert-Equal 1 $script:ManifestSchemaVersion 'the manager test must exercise the expected manifest schema'
    Assert-Equal $fixtureVersion $manifest.Version 'the manifest version must be read exactly'
    Assert-Equal $fixtureHash.ToUpperInvariant() $manifest.Sha256 'manifest hashes must be normalized'
    Assert-Equal ([long]$fixtureFile.Length) ([long]$manifest.Size) 'the manifest must retain the exact byte size'

    Assert-ReleasePayload -Path $fixturePath -Manifest $manifest
    $script:Passed++

    $exactLimitPath = Join-Path $tempDirectory 'exact-limit.bin'
    $exactLimitBytes = [Text.Encoding]::UTF8.GetBytes('12345678')
    $exactLimitStream = New-Object IO.MemoryStream(,$exactLimitBytes)
    try {
        Copy-DownloadStreamToFile `
            -SourceStream $exactLimitStream `
            -DestinationPath $exactLimitPath `
            -MaximumBytes $exactLimitBytes.Length
    }
    finally {
        $exactLimitStream.Dispose()
    }
    Assert-Equal '12345678' ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($exactLimitPath))) 'a download exactly at the byte limit must succeed without truncation'

    $overLimitPath = Join-Path $tempDirectory 'over-limit.bin'
    $overLimitBytes = [Text.Encoding]::UTF8.GetBytes('123456789')
    $overLimitStream = New-Object IO.MemoryStream(,$overLimitBytes)
    Assert-Throws -Because 'a streaming download must abort as soon as it exceeds the byte limit' -MessagePattern '*exceeded the 8 byte limit*' -Operation {
        try {
            Copy-DownloadStreamToFile `
                -SourceStream $overLimitStream `
                -DestinationPath $overLimitPath `
                -MaximumBytes 8
        }
        finally {
            $overLimitStream.Dispose()
        }
    }
    Assert-Equal $false (Test-Path -LiteralPath $overLimitPath) 'an over-limit streaming download must remove its partial destination'

    $emptyPath = Join-Path $tempDirectory 'empty.bin'
    $emptyStream = New-Object IO.MemoryStream
    Assert-Throws -Because 'an empty streaming download must be rejected' -MessagePattern '*download was empty*' -Operation {
        try {
            Copy-DownloadStreamToFile `
                -SourceStream $emptyStream `
                -DestinationPath $emptyPath `
                -MaximumBytes 8
        }
        finally {
            $emptyStream.Dispose()
        }
    }
    Assert-Equal $false (Test-Path -LiteralPath $emptyPath) 'an empty streaming download must not leave a destination file'

    $wrongHashManifest = [pscustomobject]@{
        Version = $fixtureVersion
        Name    = 'VpnCliTray.ps1'
        Sha256  = ('0' * 64)
        Size    = [long]$fixtureFile.Length
    }
    Assert-Throws -Because 'a payload hash mismatch must stop before execution' -MessagePattern '*SHA-256 mismatch*' -Operation {
        Assert-ReleasePayload -Path $fixturePath -Manifest $wrongHashManifest
    }

    $wrongVersionManifest = [pscustomobject]@{
        Version = '9.9.9'
        Name    = 'VpnCliTray.ps1'
        Sha256  = $fixtureHash.ToUpperInvariant()
        Size    = [long]$fixtureFile.Length
    }
    Assert-Throws -Because 'the script version must agree with the release manifest' -MessagePattern '*does not match manifest version*' -Operation {
        Assert-ReleasePayload -Path $fixturePath -Manifest $wrongVersionManifest
    }

    $malformedManifestPath = Join-Path $tempDirectory 'malformed.json'
    [IO.File]::WriteAllText($malformedManifestPath, '{not-json', $utf8NoBom)
    Assert-Throws -Because 'malformed release JSON must be rejected' -MessagePattern '*not valid UTF-8 JSON*' -Operation {
        Read-ReleaseManifest -Path $malformedManifestPath | Out-Null
    }

    $unsafeManifestPath = Join-Path $tempDirectory 'unsafe.json'
    $unsafeDocument = [ordered]@{
        schemaVersion = 1
        product       = 'DifferentProduct'
        version       = $fixtureVersion
        asset         = $manifestDocument.asset
    }
    [IO.File]::WriteAllText($unsafeManifestPath, ($unsafeDocument | ConvertTo-Json -Depth 3), $utf8NoBom)
    Assert-Throws -Because 'a manifest for another product must be rejected' -MessagePattern '*unexpected product*' -Operation {
        Read-ReleaseManifest -Path $unsafeManifestPath | Out-Null
    }

    $argumentOutputPath = Join-Path $tempDirectory 'arguments.txt'
    $env:VPNCLITRAY_MANAGER_TEST_OUTPUT = $argumentOutputPath
    $stubPath = Join-Path $tempDirectory 'argument-stub.ps1'
    $stubLines = @(
        '#requires -Version 5.1'
        'param([switch]$Install, [switch]$DesktopShortcut, [switch]$NoLaunch)'
        '$received = @([bool]$Install, [bool]$DesktopShortcut, [bool]$NoLaunch) -join '','''
        '[IO.File]::WriteAllText($env:VPNCLITRAY_MANAGER_TEST_OUTPUT, $received)'
    )
    [IO.File]::WriteAllText($stubPath, ($stubLines -join "`r`n"), $utf8NoBom)
    Invoke-WindowsPowerShellFile -Path $stubPath -Arguments @('-Install', '-DesktopShortcut', '-NoLaunch')
    Assert-Equal 'True,True,True' ([IO.File]::ReadAllText($argumentOutputPath)) 'manager flags must reach the child Windows PowerShell process'

    $failureStubPath = Join-Path $tempDirectory 'failure-stub.ps1'
    [IO.File]::WriteAllText($failureStubPath, 'exit 7', $utf8NoBom)
    Assert-Throws -Because 'a child failure must propagate to the manager' -MessagePattern '*exit code 7*' -Operation {
        Invoke-WindowsPowerShellFile -Path $failureStubPath -Arguments @()
    }
}
finally {
    $env:VPNCLITRAY_MANAGER_TEST_OUTPUT = $originalOutputVariable
    $script:LegacyInstalledScriptPath = $originalLegacyInstalledScriptPath
    if (Test-Path -LiteralPath $tempDirectory -PathType Container) {
        [IO.Directory]::Delete($tempDirectory, $true)
    }
}

Write-Host "Passed $script:Passed manager assertions."
