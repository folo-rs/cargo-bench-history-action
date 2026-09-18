#Requires -Version 7.6
<#
The shared install-tools workflow calls this fresh-root availability probe before
release publication. It uses the consumer installer, never a second installer.
Dot-sourcing exposes the verification helpers to mocked Pester tests without I/O.
#>
[CmdletBinding()]
param(
    [ValidateSet('install', 'binstall')] [string] $Method,
    [string] $RustTarget,
    [string] $Root,
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\release.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CanaryAsset {
    param($Tool, [string] $RustTarget)
    $name = "$($Tool.name)-v$($Tool.version)-$RustTarget.zip"
    return [pscustomobject] @{
        Name = $name
        Url = "https://github.com/folo-rs/folo/releases/download/$($Tool.name)-v$($Tool.version)/$name"
        ChecksumUrl = "https://github.com/folo-rs/folo/releases/download/$($Tool.name)-v$($Tool.version)/$($name -replace '\.zip$', '.sha256')"
    }
}

function Assert-CanaryChecksum {
    param([string] $Sidecar, [string] $FileName, [string] $Hash)
    # Verify the downloaded sidecar ourselves. cargo-binstall does not promise to
    # authenticate these monorepo sidecars automatically.
    if ($Sidecar.Trim() -cnotmatch '^([a-fA-F0-9]{64})\s+\*?(.+)$' -or
        $Matches[2] -cne $FileName -or $Matches[1] -ine $Hash) {
        throw "Checksum sidecar does not match $FileName."
    }
}

function Invoke-CanaryExecutable {
    param([string] $Executable, [string[]] $Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Executable failed ($LASTEXITCODE)." }
    return ($output -join "`n")
}

function Invoke-InstallationCanary {
    param([string] $Method, [string] $RustTarget, [string] $Root, [string] $ManifestPath)
    Import-Module (Join-Path $PSScriptRoot 'Tools.psm1') -Force
    $manifest = Read-ActionManifest -Path $ManifestPath
    if ($Method -notin @('install', 'binstall')) { throw 'Select an actual published installation method.' }
    if ($RustTarget -cnotin $manifest.targets.rust_target) { throw "Unsupported target $RustTarget." }
    if (-not $Root -or (Test-Path -LiteralPath $Root)) { throw 'The canary requires an absent, explicit root.' }
    $compiler = Invoke-CanaryExecutable rustc @('-vV')
    if ($compiler -cnotmatch '(?m)^host: ([^\r\n]+)\r?$' -or $Matches[1] -cne $RustTarget) {
        throw "The runner's native Rust host must match the promised target $RustTarget."
    }
    $null = New-Item -ItemType Directory -Path $Root
    $installRoot = Join-Path $Root 'installed'
    $archiveRoot = Join-Path $Root 'archives'
    $null = New-Item -ItemType Directory -Path $archiveRoot

    foreach ($tool in $manifest.tools) {
        $asset = Get-CanaryAsset $tool $RustTarget
        $archive = Join-Path $archiveRoot $asset.Name
        Write-Information "Checking promised $($tool.name) $($tool.version) archive for $RustTarget at $($asset.Url)." -InformationAction Continue
        Invoke-WebRequest -Uri $asset.Url -OutFile $archive
        $sidecar = (Invoke-WebRequest -Uri $asset.ChecksumUrl).Content
        # Some HTTP content types produce bytes rather than text.
        if ($sidecar -is [byte[]]) { $sidecar = [Text.Encoding]::UTF8.GetString($sidecar) }
        Assert-CanaryChecksum -Sidecar $sidecar -FileName $asset.Name -Hash (Get-FileHash $archive -Algorithm SHA256).Hash
    }

    $parameters = @{
        Manifest = $manifest
        Method = $Method
        Root = $installRoot
        Packages = @($manifest.tools.name)
    }
    if ($Method -eq 'binstall') { $parameters.RequirePrebuilt = $true }
    $null = Install-ActionTools @parameters
    # The shared verifier owns exact crates.io identity and Cargo receipt validation.
    # Fresh installation plus contract smoke is the evidence for tools without --version.
    foreach ($tool in $manifest.tools) {
        $executable = Get-ActionToolPath -Manifest $manifest -Root $installRoot -Package $tool.name
        if (-not (Test-ActionToolInstallation -Manifest $manifest -Root $installRoot -Package $tool.name)) {
            throw "Unverified executable or Cargo receipt: $executable."
        }
        if ($tool.role -eq 'companion') {
            $reported = Invoke-CanaryExecutable $executable @('--version')
            if ($reported.Trim() -cne "$($tool.binary) $($tool.version)") {
                throw "Companion version query disagrees with the manifest: $reported"
            }
            Write-Information "$($tool.name): exact Cargo receipt and dedicated version query verified." -InformationAction Continue
        }
        else {
            Write-Information "$($tool.name): exact fresh Cargo receipt verified; no dedicated version interface." -InformationAction Continue
        }
        if ($tool.role -eq 'tool') {
            $key = Invoke-CanaryExecutable $executable @('machine-key')
            if ([string]::IsNullOrWhiteSpace($key)) { throw 'Main tool did not emit a machine key.' }
        }
    }
    # The workflow's fixture executes scope/faker contracts from this installation,
    # followed by fresh root-action collect/analyze invocations.
    if ($env:GITHUB_OUTPUT) {
        "tool-root=$installRoot" >> $env:GITHUB_OUTPUT
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-InstallationCanary -Method $Method -RustTarget $RustTarget -Root $Root -ManifestPath $ManifestPath
}
