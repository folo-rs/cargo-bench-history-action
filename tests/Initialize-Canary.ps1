#Requires -Version 7.6
<#
Real method/path canaries call this to create an isolated, committed Cargo fixture
and execute the manifest-pinned faker. Cargo bench uses the tiny Rust
bridge to the faker, never real-time performance measurement.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Root,
    [Parameter(Mandatory)] [ValidateSet('path', 'install', 'binstall')] [string] $Method,
    [string] $SourcePath,
    [string] $ExistingToolRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot '..\scripts\Tools.psm1') -Force
$manifest = Read-ActionManifest -Path (Join-Path $PSScriptRoot '..\release.json')
$fakerTool = @($manifest.tools | Where-Object role -EQ fixture)
if ($fakerTool.Count -ne 1) { throw 'The fixture tool must be declared uniquely.' }
if (Test-Path -LiteralPath $Root) { throw 'Fixture root must be absent.' }
$null = New-Item -ItemType Directory -Path $Root
$workspace = Join-Path $Root 'workspace'
$null = New-Item -ItemType Directory -Path $workspace
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixture') -Force |
    Copy-Item -Destination $workspace -Recurse
$collections = Join-Path $Root 'current-collections'
$null = New-Item -ItemType Directory -Path $collections

$toolRoot = $ExistingToolRoot
if (-not $toolRoot) {
    $toolRoot = Join-Path $Root 'fixture-tools'
    $packages = @($fakerTool[0].name)
    $parameters = @{ Manifest = $manifest; Method = $Method; Root = $toolRoot; Packages = $packages }
    if ($Method -eq 'path') { $parameters.SourcePath = $SourcePath }
    $null = Install-ActionTools @parameters
}
$faker = Get-ActionToolPath -Manifest $manifest -Root $toolRoot -Package $fakerTool[0].name

$oldTarget = $env:CARGO_TARGET_DIR
$oldGlobal = $env:GIT_CONFIG_GLOBAL
$oldSystem = $env:GIT_CONFIG_NOSYSTEM
$oldAuthorDate = $env:GIT_AUTHOR_DATE
$oldCommitterDate = $env:GIT_COMMITTER_DATE
try {
    # Do not inherit personal aliases, signing, hooks or shared build outputs.
    $env:GIT_CONFIG_GLOBAL = Join-Path $Root 'gitconfig'
    Set-Content -LiteralPath $env:GIT_CONFIG_GLOBAL -Value '' -NoNewline
    $env:GIT_CONFIG_NOSYSTEM = '1'
    # A rerun must retain the same frozen fixture head when reconciling all attempts.
    # Analysis explicitly includes this fixed synthetic history.
    $env:GIT_AUTHOR_DATE = '2020-01-01T00:00:00Z'
    $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
    $env:CARGO_TARGET_DIR = Join-Path $Root 'faker-smoke'
    & $faker --criterion 'probe|synthetic=100@1/99:101' --chdir $workspace
    if ($LASTEXITCODE -ne 0) { throw "Faker smoke failed ($LASTEXITCODE)." }
    $estimates = @(Get-ChildItem $env:CARGO_TARGET_DIR -Recurse -Filter estimates.json)
    if ($estimates.Count -ne 1) { throw 'Faker must emit one synthetic estimate.' }
    $estimate = Get-Content $estimates[0].FullName -Raw | ConvertFrom-Json
    if ($estimate.mean.point_estimate -ne 100) { throw 'Faker did not preserve the requested measurement.' }
    Push-Location $workspace
    try {
        & cargo generate-lockfile --offline
        if ($LASTEXITCODE -ne 0) { throw "Fixture lockfile generation failed ($LASTEXITCODE)." }
        & git -c init.defaultBranch=main init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git initialization failed.' }
        & git -c gc.auto=0 add .
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git staging failed.' }
        & git -c user.name=Canary -c user.email=canary@example.invalid -c commit.gpgsign=false `
            -c gc.auto=0 commit --quiet -m 'fixture start'
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git commit failed.' }
        # Both commits retain the same working synthetic benchmark. Collection
        # records the tip; backfill must fill the older point on this same runner.
        & git -c user.name=Canary -c user.email=canary@example.invalid -c commit.gpgsign=false `
            -c gc.auto=0 commit --quiet --allow-empty -m 'fixture tip'
        if ($LASTEXITCODE -ne 0) { throw 'Fixture tip commit failed.' }
    }
    finally { Pop-Location }
}
finally {
    $env:CARGO_TARGET_DIR = $oldTarget
    $env:GIT_CONFIG_GLOBAL = $oldGlobal
    $env:GIT_CONFIG_NOSYSTEM = $oldSystem
    $env:GIT_AUTHOR_DATE = $oldAuthorDate
    $env:GIT_COMMITTER_DATE = $oldCommitterDate
}
if ($env:GITHUB_ENV) {
    "ACTION_CANARY_FAKER=$faker" >> $env:GITHUB_ENV
    "CARGO_TARGET_DIR=$(Join-Path $Root 'target')" >> $env:GITHUB_ENV
}
if ($env:GITHUB_OUTPUT) {
    "workspace=$workspace" >> $env:GITHUB_OUTPUT
    "store=$(Join-Path $Root 'store')" >> $env:GITHUB_OUTPUT
    "root=$Root" >> $env:GITHUB_OUTPUT
    "current-collections=$collections" >> $env:GITHUB_OUTPUT
}
