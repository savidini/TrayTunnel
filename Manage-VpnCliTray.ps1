#requires -Version 5.1

<#
.SYNOPSIS
    Installs, updates, checks, or removes VPN CLI Tray for the current user.

.DESCRIPTION
    This script is designed to be usable both from disk and as a small HTTPS
    bootstrap. It downloads a versioned release manifest and application script,
    verifies the declared size and SHA-256 hash, checks that the script parses,
    and delegates lifecycle changes to VpnCliTray.ps1.

    VPN CLI Tray is a per-user tray application, not a Windows service. This
    manager never requests elevation and never installs, removes, or changes Cisco
    AnyConnect, Cisco Secure Client, or Cisco VPN agent services.
#>

[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Install', 'Update', 'Uninstall', 'Status')]
    [string]$Action = 'Menu',

    [switch]$DesktopShortcut,

    [switch]$NoLaunch,

    [string]$Version,

    [ValidatePattern('^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$')]
    [string]$Repository = 'savidini/VpnCliTray',

    [uri]$ReleaseBaseUri,

    [string]$PublisherThumbprint
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProductName = 'VPN CLI Tray'
$script:AppId = 'VpnCliTray'
$script:ApplicationAssetName = 'VpnCliTray.ps1'
$script:ManifestAssetName = 'VpnCliTray.release.json'
$script:ManifestSchemaVersion = 1
$script:MaximumManifestBytes = 65536
$script:MaximumApplicationBytes = 1048576
$script:InstalledScriptPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'VpnCliTray\VpnCliTray.ps1'
$script:LegacyAppId = 'AnyConnectTray'
$script:LegacyInstalledScriptPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AnyConnectTray\AnyConnectTray.ps1'
$script:RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

function Test-IsProcessElevated {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }

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

function Assert-ProcessNotElevated {
    param(
        [bool]$IsElevated = (Test-IsProcessElevated)
    )

    if ($IsElevated) {
        throw (
            'VPN CLI Tray is a per-user application and refuses to run with administrator rights. ' +
            'Open a normal (non-Administrator) Windows PowerShell window and try again.'
        )
    }
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "The release manifest is missing '$Name'."
    }
    return $property.Value
}

function Assert-HttpsUri {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri
    )

    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ine [Uri]::UriSchemeHttps) {
        throw "Only absolute HTTPS download addresses are allowed: $Uri"
    }
}

function Get-ReleaseRootUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepositoryName,

        [string]$ReleaseVersion,

        [uri]$CustomReleaseBaseUri
    )

    if ($null -ne $CustomReleaseBaseUri) {
        Assert-HttpsUri -Uri $CustomReleaseBaseUri
        if (-not [string]::IsNullOrWhiteSpace($ReleaseVersion)) {
            throw '-Version and -ReleaseBaseUri cannot be used together. Point -ReleaseBaseUri at the exact release directory.'
        }
        if (-not [string]::IsNullOrEmpty($CustomReleaseBaseUri.Query) -or -not [string]::IsNullOrEmpty($CustomReleaseBaseUri.Fragment)) {
            throw '-ReleaseBaseUri must not contain a query string or fragment.'
        }

        $customAddress = $CustomReleaseBaseUri.AbsoluteUri
        if (-not $customAddress.EndsWith('/')) {
            $customAddress += '/'
        }
        return [uri]$customAddress
    }

    if ($RepositoryName -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw "Invalid GitHub repository name: $RepositoryName"
    }

    $releasePath = if ([string]::IsNullOrWhiteSpace($ReleaseVersion)) {
        'latest/download/'
    }
    else {
        $releaseTag = if ($ReleaseVersion.StartsWith('v', [StringComparison]::Ordinal)) {
            $ReleaseVersion
        }
        else {
            'v' + $ReleaseVersion
        }
        'download/{0}/' -f [Uri]::EscapeDataString($releaseTag)
    }

    return [uri]("https://github.com/{0}/releases/{1}" -f $RepositoryName, $releasePath)
}

function Get-ReleaseAssetUri {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ReleaseRootUri,

        [Parameter(Mandatory = $true)]
        [string]$AssetName
    )

    Assert-HttpsUri -Uri $ReleaseRootUri
    if ($AssetName -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "Invalid release asset name: $AssetName"
    }
    return [uri]::new($ReleaseRootUri, $AssetName)
}

function Get-PayloadReleaseRootUri {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ManifestReleaseRootUri,

        [Parameter(Mandatory = $true)]
        [string]$ManifestVersion
    )

    $latestPattern = '^https://github\.com/(?<repository>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/releases/latest/download/$'
    $latestMatch = [regex]::Match($ManifestReleaseRootUri.AbsoluteUri, $latestPattern)
    if (-not $latestMatch.Success) {
        return $ManifestReleaseRootUri
    }

    # Pin the payload to the release described by the manifest. If "latest"
    # changes between the two requests, the manager still downloads one release.
    $repositoryName = $latestMatch.Groups['repository'].Value
    return Get-ReleaseRootUri `
        -RepositoryName $repositoryName `
        -ReleaseVersion ('v' + $ManifestVersion)
}

function Get-ResponseUri {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WebResponse,

        [Parameter(Mandatory = $true)]
        [uri]$FallbackUri
    )

    $directResponseUriProperty = $WebResponse.PSObject.Properties['ResponseUri']
    if ($null -ne $directResponseUriProperty -and $null -ne $directResponseUriProperty.Value) {
        return [uri]$directResponseUriProperty.Value
    }

    $baseResponseProperty = $WebResponse.PSObject.Properties['BaseResponse']
    if ($null -eq $baseResponseProperty -or $null -eq $baseResponseProperty.Value) {
        return $FallbackUri
    }

    $baseResponse = $baseResponseProperty.Value
    $responseUriProperty = $baseResponse.PSObject.Properties['ResponseUri']
    if ($null -ne $responseUriProperty -and $null -ne $responseUriProperty.Value) {
        return [uri]$responseUriProperty.Value
    }

    $requestMessageProperty = $baseResponse.PSObject.Properties['RequestMessage']
    if ($null -ne $requestMessageProperty -and $null -ne $requestMessageProperty.Value) {
        $requestUriProperty = $requestMessageProperty.Value.PSObject.Properties['RequestUri']
        if ($null -ne $requestUriProperty -and $null -ne $requestUriProperty.Value) {
            return [uri]$requestUriProperty.Value
        }
    }

    return $FallbackUri
}

function Copy-DownloadStreamToFile {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNull()]
        [IO.Stream]$SourceStream,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [long]$MaximumBytes
    )

    if ($MaximumBytes -le 0) {
        throw 'The download byte limit must be greater than zero.'
    }

    $destinationStream = $null
    $destinationCreated = $false
    $completed = $false
    try {
        $destinationStream = [IO.File]::Open(
            $DestinationPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $destinationCreated = $true

        $buffer = New-Object byte[] 81920
        [long]$totalBytes = 0
        while ($true) {
            $bytesRead = $SourceStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) {
                break
            }
            if ([long]$bytesRead -gt ($MaximumBytes - $totalBytes)) {
                throw "The download exceeded the $MaximumBytes byte limit."
            }
            $destinationStream.Write($buffer, 0, $bytesRead)
            $totalBytes += $bytesRead
        }

        if ($totalBytes -le 0) {
            throw 'The download was empty.'
        }
        $destinationStream.Flush()
        $completed = $true
    }
    finally {
        if ($null -ne $destinationStream) {
            $destinationStream.Dispose()
        }
        if (-not $completed -and $destinationCreated -and
            (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) {
            [IO.File]::Delete($DestinationPath)
        }
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $true)]
        [long]$MaximumBytes,

        [ValidateRange(1, 5)]
        [int]$Attempts = 3,

        [ValidateRange(5, 120)]
        [int]$TimeoutSeconds = 45
    )

    Assert-HttpsUri -Uri $Uri

    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $request = $null
        $response = $null
        $responseStream = $null
        try {
            try {
                if (Test-Path -LiteralPath $DestinationPath) {
                    [IO.File]::Delete($DestinationPath)
                }

                # HttpWebRequest uses the Windows/.NET system proxy by default.
                # Reading the response stream directly keeps that compatibility
                # while enforcing the byte cap before excess data reaches disk.
                $request = [Net.HttpWebRequest][Net.WebRequest]::Create($Uri)
                $request.Method = 'GET'
                $request.AllowAutoRedirect = $true
                $request.MaximumAutomaticRedirections = 8
                $request.Timeout = $TimeoutSeconds * 1000
                $request.ReadWriteTimeout = $TimeoutSeconds * 1000
                $request.UserAgent = 'VpnCliTray-Manager'

                $response = [Net.HttpWebResponse]$request.GetResponse()
                $finalUri = Get-ResponseUri -WebResponse $response -FallbackUri $Uri
                Assert-HttpsUri -Uri $finalUri

                if ($response.ContentLength -gt $MaximumBytes) {
                    throw "The download exceeded the $MaximumBytes byte limit: $Uri"
                }

                $responseStream = $response.GetResponseStream()
                Copy-DownloadStreamToFile `
                    -SourceStream $responseStream `
                    -DestinationPath $DestinationPath `
                    -MaximumBytes $MaximumBytes
            }
            finally {
                if ($null -ne $responseStream) {
                    $responseStream.Dispose()
                }
                if ($null -ne $response) {
                    $response.Dispose()
                }
                if ($null -ne $request) {
                    $request.Abort()
                }
            }
            return
        }
        catch {
            if (Test-Path -LiteralPath $DestinationPath) {
                [IO.File]::Delete($DestinationPath)
            }
            if ($attempt -ge $Attempts) {
                throw "Download failed after $Attempts attempts ($Uri): $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
}

function Read-ReleaseManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    try {
        $document = [IO.File]::ReadAllText($Path, $utf8) | ConvertFrom-Json
    }
    catch {
        throw "The release manifest is not valid UTF-8 JSON: $($_.Exception.Message)"
    }

    $schemaVersion = Get-ObjectPropertyValue -InputObject $document -Name 'schemaVersion'
    if ([int]$schemaVersion -ne $script:ManifestSchemaVersion) {
        throw "Unsupported release manifest schema: $schemaVersion"
    }

    $product = [string](Get-ObjectPropertyValue -InputObject $document -Name 'product')
    if ($product -cne $script:AppId) {
        throw "The release manifest is for an unexpected product: $product"
    }

    $releaseVersion = [string](Get-ObjectPropertyValue -InputObject $document -Name 'version')
    if ($releaseVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "The release manifest contains an invalid version: $releaseVersion"
    }

    $asset = Get-ObjectPropertyValue -InputObject $document -Name 'asset'
    if ($null -eq $asset) {
        throw 'The release manifest has no application asset.'
    }

    $assetName = [string](Get-ObjectPropertyValue -InputObject $asset -Name 'name')
    if ($assetName -cne $script:ApplicationAssetName) {
        throw "The release manifest contains an unexpected asset: $assetName"
    }

    $sha256 = [string](Get-ObjectPropertyValue -InputObject $asset -Name 'sha256')
    if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'The release manifest contains an invalid SHA-256 hash.'
    }

    try {
        $size = [long](Get-ObjectPropertyValue -InputObject $asset -Name 'size')
    }
    catch {
        throw 'The release manifest contains an invalid asset size.'
    }
    if ($size -le 0 -or $size -gt $script:MaximumApplicationBytes) {
        throw "The release manifest contains an unsafe asset size: $size"
    }

    return [pscustomobject]@{
        Version = $releaseVersion
        Name    = $assetName
        Sha256  = $sha256.ToUpperInvariant()
        Size    = $size
    }
}

function Get-ScriptVersion {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $utf8 = New-Object Text.UTF8Encoding($false, $true)
    $content = [IO.File]::ReadAllText($Path, $utf8)
    $matches = [regex]::Matches($content, '(?m)^\s*\$script:Version\s*=\s*''([^'']+)''\s*$')
    if ($matches.Count -ne 1) {
        throw "Could not determine exactly one application version from: $Path"
    }
    return $matches[0].Groups[1].Value
}

function Assert-ScriptParses {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        throw "The downloaded application is not valid PowerShell: $($parseErrors[0].Message)"
    }
}

function Assert-PublisherSignature {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$ExpectedThumbprint
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($ExpectedThumbprint)) {
        if ($signature.Status -notin @('Valid', 'NotSigned')) {
            throw "The application has an invalid Authenticode signature: $($signature.StatusMessage)"
        }
        return
    }

    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate) {
        throw "A valid signature from publisher $ExpectedThumbprint is required. Signature status: $($signature.Status)"
    }

    $normalizedExpectedThumbprint = $ExpectedThumbprint.Replace(' ', '').ToUpperInvariant()
    if ($normalizedExpectedThumbprint.Length -eq 40) {
        $actualThumbprint = $signature.SignerCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
    }
    else {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $actualThumbprint = [BitConverter]::ToString(
                $sha256.ComputeHash($signature.SignerCertificate.RawData)
            ).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
    }

    if ($actualThumbprint -cne $normalizedExpectedThumbprint) {
        throw "The application was signed by an unexpected publisher: $actualThumbprint"
    }
}

function Assert-ReleasePayload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Manifest,

        [string]$ExpectedPublisherThumbprint
    )

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -ne [long]$Manifest.Size) {
        throw "Application size mismatch. Expected $($Manifest.Size) bytes, received $($item.Length)."
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actualHash -cne [string]$Manifest.Sha256) {
        throw "Application SHA-256 mismatch. Expected $($Manifest.Sha256), received $actualHash."
    }

    Assert-ScriptParses -Path $Path
    $applicationVersion = Get-ScriptVersion -Path $Path
    if ($applicationVersion -cne [string]$Manifest.Version) {
        throw "Application version $applicationVersion does not match manifest version $($Manifest.Version)."
    }
    Assert-PublisherSignature -Path $Path -ExpectedThumbprint $ExpectedPublisherThumbprint
}

function New-ManagerTemporaryDirectory {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('VpnCliTray.Manager.' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Remove-ManagerTemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$KnownFiles
    )

    foreach ($knownFile in $KnownFiles) {
        if (-not [string]::IsNullOrWhiteSpace($knownFile) -and (Test-Path -LiteralPath $knownFile -PathType Leaf)) {
            [IO.File]::Delete($knownFile)
        }
    }

    if (Test-Path -LiteralPath $Path -PathType Container) {
        try {
            [IO.Directory]::Delete($Path, $false)
        }
        catch {
            Write-Warning "Temporary directory was left in place because it was not empty: $Path"
        }
    }
}

function Get-VerifiedReleasePayload {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ReleaseRootUri,

        [string]$RequestedVersion,

        [string]$ExpectedPublisherThumbprint
    )

    $temporaryDirectory = New-ManagerTemporaryDirectory
    $manifestPath = Join-Path $temporaryDirectory $script:ManifestAssetName
    $applicationPath = Join-Path $temporaryDirectory $script:ApplicationAssetName
    try {
        $manifestUri = Get-ReleaseAssetUri -ReleaseRootUri $ReleaseRootUri -AssetName $script:ManifestAssetName
        Write-Host "Downloading release information from $manifestUri"
        Invoke-DownloadFile -Uri $manifestUri -DestinationPath $manifestPath -MaximumBytes $script:MaximumManifestBytes
        $manifest = Read-ReleaseManifest -Path $manifestPath

        if (-not [string]::IsNullOrWhiteSpace($RequestedVersion)) {
            $normalizedRequestedVersion = $RequestedVersion.TrimStart('v')
            if ($manifest.Version -cne $normalizedRequestedVersion) {
                throw "Requested version $normalizedRequestedVersion, but the release manifest describes $($manifest.Version)."
            }
        }

        $payloadReleaseRoot = Get-PayloadReleaseRootUri -ManifestReleaseRootUri $ReleaseRootUri -ManifestVersion $manifest.Version
        $applicationUri = Get-ReleaseAssetUri -ReleaseRootUri $payloadReleaseRoot -AssetName $manifest.Name
        Write-Host "Downloading $($script:ProductName) $($manifest.Version) from $applicationUri"
        Invoke-DownloadFile -Uri $applicationUri -DestinationPath $applicationPath -MaximumBytes $script:MaximumApplicationBytes
        Assert-ReleasePayload `
            -Path $applicationPath `
            -Manifest $manifest `
            -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint

        return [pscustomobject]@{
            Path               = $applicationPath
            Version            = $manifest.Version
            TemporaryDirectory = $temporaryDirectory
            TemporaryFiles     = @($manifestPath, $applicationPath)
        }
    }
    catch {
        Remove-ManagerTemporaryDirectory `
            -Path $temporaryDirectory `
            -KnownFiles @($manifestPath, $applicationPath)
        throw
    }
}

function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Windows PowerShell 5.1 was not found at: $path"
    }
    return $path
}

function Invoke-WindowsPowerShellFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$Arguments
    )

    $powerShellPath = Get-WindowsPowerShellPath
    & $powerShellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments
    $childExitCode = $LASTEXITCODE
    if ($childExitCode -ne 0) {
        throw "$($script:ProductName) returned exit code $childExitCode."
    }
}

function Get-TopLevelAssignmentAst {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.ScriptBlockAst]$ScriptAst,

        [Parameter(Mandatory = $true)]
        [string]$VariablePath
    )

    foreach ($statement in @($ScriptAst.EndBlock.Statements)) {
        if ($statement -is [Management.Automation.Language.AssignmentStatementAst] -and
            $statement.Left -is [Management.Automation.Language.VariableExpressionAst] -and
            [string]::Equals(
                $statement.Left.VariablePath.UserPath,
                $VariablePath,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $statement
        }
    }
}

function Test-StringAssignmentAst {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.AssignmentStatementAst]$Assignment,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedValue
    )

    return (
        $Assignment.Operator -eq [Management.Automation.Language.TokenKind]::Equals -and
        $Assignment.Right -is [Management.Automation.Language.CommandExpressionAst] -and
        $Assignment.Right.Expression -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $Assignment.Right.Expression.Value -ceq $ExpectedValue
    )
}

function Test-LegacyInstalledPathAssignmentAst {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.AssignmentStatementAst]$Assignment
    )

    if ($Assignment.Operator -ne [Management.Automation.Language.TokenKind]::Equals -or
        $Assignment.Right -isnot [Management.Automation.Language.PipelineAst] -or
        $Assignment.Right.PipelineElements.Count -ne 1) {
        return $false
    }

    $command = $Assignment.Right.PipelineElements[0]
    if ($command -isnot [Management.Automation.Language.CommandAst] -or
        $command.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -or
        $command.CommandElements.Count -ne 3 -or
        $command.Redirections.Count -ne 0) {
        return $false
    }

    $commandName = $command.CommandElements[0]
    $installDirectory = $command.CommandElements[1]
    $installedFileName = $command.CommandElements[2]
    return (
        $commandName -is [Management.Automation.Language.StringConstantExpressionAst] -and
        [string]::Equals($command.GetCommandName(), 'Join-Path', [StringComparison]::OrdinalIgnoreCase) -and
        $installDirectory -is [Management.Automation.Language.VariableExpressionAst] -and
        [string]::Equals(
            $installDirectory.VariablePath.UserPath,
            'script:InstallDirectory',
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        $installedFileName -is [Management.Automation.Language.StringConstantExpressionAst] -and
        $installedFileName.Value -ceq 'AnyConnectTray.ps1'
    )
}

function Test-UninstallDispatchAst {
    param(
        [Parameter(Mandatory = $true)]
        [Management.Automation.Language.ScriptBlockAst]$ScriptAst
    )

    $matchingDispatches = 0
    foreach ($statement in @($ScriptAst.EndBlock.Statements)) {
        if ($statement -isnot [Management.Automation.Language.IfStatementAst] -or
            $statement.Clauses.Count -ne 1 -or
            $null -ne $statement.ElseClause) {
            continue
        }

        $clause = $statement.Clauses[0]
        $condition = $clause.Item1
        if ($condition -isnot [Management.Automation.Language.PipelineAst] -or
            $condition.PipelineElements.Count -ne 1 -or
            $condition.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst]) {
            continue
        }

        $conditionExpression = $condition.PipelineElements[0].Expression
        if ($conditionExpression -isnot [Management.Automation.Language.VariableExpressionAst] -or
            -not [string]::Equals(
                $conditionExpression.VariablePath.UserPath,
                'Uninstall',
                [StringComparison]::OrdinalIgnoreCase
            )) {
            continue
        }

        $body = $clause.Item2
        $bodyStatements = @($body.Statements)
        if ($null -ne $body.Traps -or $bodyStatements.Count -lt 1 -or $bodyStatements.Count -gt 2) {
            continue
        }

        $uninstallPipeline = $bodyStatements[0]
        if ($uninstallPipeline -isnot [Management.Automation.Language.PipelineAst] -or
            $uninstallPipeline.PipelineElements.Count -ne 1) {
            continue
        }

        $uninstallCommand = $uninstallPipeline.PipelineElements[0]
        if ($uninstallCommand -isnot [Management.Automation.Language.CommandAst] -or
            $uninstallCommand.InvocationOperator -ne [Management.Automation.Language.TokenKind]::Unknown -or
            $uninstallCommand.CommandElements.Count -ne 1 -or
            $uninstallCommand.Redirections.Count -ne 0 -or
            $uninstallCommand.CommandElements[0] -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            -not [string]::Equals($uninstallCommand.GetCommandName(), 'Uninstall-App', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        if ($bodyStatements.Count -eq 2) {
            $exitStatement = $bodyStatements[1]
            if ($exitStatement -isnot [Management.Automation.Language.ExitStatementAst] -or
                $exitStatement.Pipeline -isnot [Management.Automation.Language.PipelineAst] -or
                $exitStatement.Pipeline.PipelineElements.Count -ne 1 -or
                $exitStatement.Pipeline.PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or
                $exitStatement.Pipeline.PipelineElements[0].Expression -isnot [Management.Automation.Language.ConstantExpressionAst] -or
                [int]$exitStatement.Pipeline.PipelineElements[0].Expression.Value -ne 0) {
                continue
            }
        }

        $matchingDispatches++
    }

    return ($matchingDispatches -eq 1)
}

function Test-LegacyApplicationScriptOwned {
    if (-not (Test-Path -LiteralPath $script:LegacyInstalledScriptPath -PathType Leaf)) {
        return $false
    }

    try {
        $legacyFile = Get-Item -LiteralPath $script:LegacyInstalledScriptPath -Force
        $legacyDirectory = Get-Item -LiteralPath $legacyFile.DirectoryName -Force
        if (($legacyFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            ($legacyDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $legacyFile.Length -le 0 -or
            $legacyFile.Length -gt $script:MaximumApplicationBytes) {
            return $false
        }

        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $content = [IO.File]::ReadAllText($legacyFile.FullName, $utf8)
        $tokens = $null
        $parseErrors = $null
        $syntaxTree = [Management.Automation.Language.Parser]::ParseInput(
            $content,
            $legacyFile.FullName,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -ne 0 -or $null -eq $syntaxTree.EndBlock) {
            return $false
        }

        $productAssignments = @(Get-TopLevelAssignmentAst -ScriptAst $syntaxTree -VariablePath 'script:ProductName')
        $appIdAssignments = @(Get-TopLevelAssignmentAst -ScriptAst $syntaxTree -VariablePath 'script:AppId')
        $versionAssignments = @(Get-TopLevelAssignmentAst -ScriptAst $syntaxTree -VariablePath 'script:Version')
        $installedPathAssignments = @(Get-TopLevelAssignmentAst -ScriptAst $syntaxTree -VariablePath 'script:InstalledScriptPath')
        if ($productAssignments.Count -ne 1 -or
            $appIdAssignments.Count -ne 1 -or
            $versionAssignments.Count -ne 1 -or
            $installedPathAssignments.Count -ne 1) {
            return $false
        }

        if (-not (Test-StringAssignmentAst -Assignment $productAssignments[0] -ExpectedValue 'AnyConnect Tray') -or
            -not (Test-StringAssignmentAst -Assignment $appIdAssignments[0] -ExpectedValue 'AnyConnectTray') -or
            -not (Test-LegacyInstalledPathAssignmentAst -Assignment $installedPathAssignments[0])) {
            return $false
        }

        $versionAssignment = $versionAssignments[0]
        if ($versionAssignment.Operator -ne [Management.Automation.Language.TokenKind]::Equals -or
            $versionAssignment.Right -isnot [Management.Automation.Language.CommandExpressionAst] -or
            $versionAssignment.Right.Expression -isnot [Management.Automation.Language.StringConstantExpressionAst]) {
            return $false
        }
        $legacyVersion = [string]$versionAssignment.Right.Expression.Value
        $semVerPattern = '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$'
        if ($legacyVersion -cnotmatch $semVerPattern) {
            return $false
        }

        $uninstallFunctions = @(
            $syntaxTree.EndBlock.Statements | Where-Object {
                $_ -is [Management.Automation.Language.FunctionDefinitionAst] -and
                -not $_.IsFilter -and
                [string]::Equals($_.Name, 'Uninstall-App', [StringComparison]::OrdinalIgnoreCase)
            }
        )
        if ($uninstallFunctions.Count -ne 1 -or -not (Test-UninstallDispatchAst -ScriptAst $syntaxTree)) {
            return $false
        }

        return $true
    }
    catch {
        return $false
    }
}

function Show-InstallationStatus {
    $installedScriptPath = $script:InstalledScriptPath
    $installedProductName = $script:ProductName
    $startupValueName = $script:AppId
    $legacyInstallation = $false

    if (-not (Test-Path -LiteralPath $installedScriptPath -PathType Leaf)) {
        if (Test-LegacyApplicationScriptOwned) {
            $installedScriptPath = $script:LegacyInstalledScriptPath
            $installedProductName = 'AnyConnect Tray (legacy)'
            $startupValueName = $script:LegacyAppId
            $legacyInstallation = $true
        }
        else {
            Write-Host "$($script:ProductName) is not installed for the current user."
            if (Test-Path -LiteralPath $script:LegacyInstalledScriptPath -PathType Leaf) {
                Write-Warning "An unrecognized file exists at the legacy path and was not treated as an installation: $($script:LegacyInstalledScriptPath)"
            }
            return
        }
    }

    try {
        $installedVersion = Get-ScriptVersion -Path $installedScriptPath
    }
    catch {
        $installedVersion = 'unknown'
    }

    $startupEnabled = $false
    try {
        $runValue = (Get-ItemProperty -Path $script:RunKeyPath -Name $startupValueName -ErrorAction Stop).$startupValueName
        $startupEnabled = -not [string]::IsNullOrWhiteSpace([string]$runValue)
    }
    catch {
    }

    Write-Host "$installedProductName $installedVersion is installed at: $installedScriptPath"
    Write-Host ('Start with Windows: {0}' -f $(if ($startupEnabled) { 'enabled' } else { 'disabled' }))
    if ($legacyInstallation) {
        Write-Host "Install or update $($script:ProductName) to migrate this legacy installation."
    }
}

function Read-ManagerAction {
    Write-Host ''
    Write-Host $script:ProductName
    Write-Host 'This manages only the current-user tray application; it does not change Cisco software.'
    Write-Host ''
    Write-Host '[1] Install or update'
    Write-Host '[2] Uninstall'
    Write-Host '[3] Show installation status'
    Write-Host '[Q] Cancel'
    Write-Host ''

    $selection = (Read-Host 'Choose an action').Trim()
    switch -Regex ($selection) {
        '^(1|i|install|update)$' { return 'Install' }
        '^(2|u|uninstall|remove)$' {
            Write-Warning 'Uninstall deletes VPN CLI Tray settings, including the encrypted saved password, and its logs. It also removes a recognized legacy AnyConnect Tray installation.'
            $confirmation = (Read-Host "Type 'uninstall' to continue").Trim()
            if ($confirmation -ceq 'uninstall') { return 'Uninstall' }
            return 'Cancel'
        }
        '^(3|s|status)$' { return 'Status' }
        '^(q|quit|cancel)$' { return 'Cancel' }
        default { throw "Unknown menu selection: $selection" }
    }
}

function Invoke-InstallOrUpdate {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ReleaseRootUri,

        [string]$RequestedVersion,

        [string]$ExpectedPublisherThumbprint,

        [bool]$CreateDesktopShortcut,

        [bool]$SkipLaunch
    )

    $payload = Get-VerifiedReleasePayload `
        -ReleaseRootUri $ReleaseRootUri `
        -RequestedVersion $RequestedVersion `
        -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint
    try {
        $applicationArguments = @('-Install')
        if ($CreateDesktopShortcut) {
            $applicationArguments += '-DesktopShortcut'
        }
        if ($SkipLaunch) {
            $applicationArguments += '-NoLaunch'
        }

        Invoke-WindowsPowerShellFile -Path $payload.Path -Arguments $applicationArguments
        Write-Host "$($script:ProductName) $($payload.Version) passed release verification and was installed."
    }
    finally {
        Remove-ManagerTemporaryDirectory `
            -Path $payload.TemporaryDirectory `
            -KnownFiles $payload.TemporaryFiles
    }
}

function Invoke-Uninstall {
    param(
        [Parameter(Mandatory = $true)]
        [uri]$ReleaseRootUri,

        [string]$RequestedVersion,

        [string]$ExpectedPublisherThumbprint
    )

    if (Test-Path -LiteralPath $script:InstalledScriptPath -PathType Leaf) {
        $installedScriptIsUsable = $true
        try {
            Assert-ScriptParses -Path $script:InstalledScriptPath
            Assert-PublisherSignature `
                -Path $script:InstalledScriptPath `
                -ExpectedThumbprint $ExpectedPublisherThumbprint
        }
        catch {
            $installedScriptIsUsable = $false
            Write-Warning "The installed application script failed validation: $($_.Exception.Message)"
        }

        if ($installedScriptIsUsable) {
            Invoke-WindowsPowerShellFile -Path $script:InstalledScriptPath -Arguments @('-Uninstall')
            return
        }
    }

    if (Test-LegacyApplicationScriptOwned) {
        Write-Host 'A recognized legacy AnyConnect Tray installation was found.'
    }
    Write-Host 'Downloading a verified VPN CLI Tray application copy for cleanup.'
    $payload = Get-VerifiedReleasePayload `
        -ReleaseRootUri $ReleaseRootUri `
        -RequestedVersion $RequestedVersion `
        -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint
    try {
        Invoke-WindowsPowerShellFile -Path $payload.Path -Arguments @('-Uninstall')
    }
    finally {
        Remove-ManagerTemporaryDirectory `
            -Path $payload.TemporaryDirectory `
            -KnownFiles $payload.TemporaryFiles
    }
}

function Invoke-VpnCliTrayManager {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedAction,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryName,

        [string]$RequestedVersion,

        [uri]$CustomReleaseBaseUri,

        [string]$ExpectedPublisherThumbprint,

        [bool]$CreateDesktopShortcut,

        [bool]$SkipLaunch
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "$($script:ProductName) can be managed only on Windows."
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedVersion) -and $RequestedVersion -cnotmatch '^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "Invalid release version: $RequestedVersion"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPublisherThumbprint) -and $ExpectedPublisherThumbprint -notmatch '^[A-Fa-f0-9]{40}$|^[A-Fa-f0-9]{64}$') {
        throw 'Publisher thumbprint must contain exactly 40 or 64 hexadecimal characters.'
    }

    $resolvedAction = $RequestedAction
    if ($resolvedAction -ceq 'Menu') {
        $resolvedAction = Read-ManagerAction
    }
    if ($resolvedAction -ceq 'Cancel') {
        Write-Host 'No changes were made.'
        return
    }

    Assert-ProcessNotElevated

    if ($resolvedAction -ceq 'Status') {
        Show-InstallationStatus
        return
    }

    $releaseRoot = Get-ReleaseRootUri `
        -RepositoryName $RepositoryName `
        -ReleaseVersion $RequestedVersion `
        -CustomReleaseBaseUri $CustomReleaseBaseUri

    $previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

        switch ($resolvedAction) {
            'Install' {
                Invoke-InstallOrUpdate `
                    -ReleaseRootUri $releaseRoot `
                    -RequestedVersion $RequestedVersion `
                    -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint `
                    -CreateDesktopShortcut $CreateDesktopShortcut `
                    -SkipLaunch $SkipLaunch
            }
            'Update' {
                Invoke-InstallOrUpdate `
                    -ReleaseRootUri $releaseRoot `
                    -RequestedVersion $RequestedVersion `
                    -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint `
                    -CreateDesktopShortcut $CreateDesktopShortcut `
                    -SkipLaunch $SkipLaunch
            }
            'Uninstall' {
                Invoke-Uninstall `
                    -ReleaseRootUri $releaseRoot `
                    -RequestedVersion $RequestedVersion `
                    -ExpectedPublisherThumbprint $ExpectedPublisherThumbprint
            }
            default {
                throw "Unsupported action: $resolvedAction"
            }
        }
    }
    finally {
        [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    }
}

# Dot-sourcing exposes validation helpers to the offline tests without taking action.
if ($MyInvocation.InvocationName -eq '.') {
    return
}

Invoke-VpnCliTrayManager `
    -RequestedAction $Action `
    -RepositoryName $Repository `
    -RequestedVersion $Version `
    -CustomReleaseBaseUri $ReleaseBaseUri `
    -ExpectedPublisherThumbprint $PublisherThumbprint `
    -CreateDesktopShortcut ([bool]$DesktopShortcut) `
    -SkipLaunch ([bool]$NoLaunch)
