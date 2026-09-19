#Requires -Version 7.6
<#
Real method/path canaries call this to create an isolated, committed Cargo fixture
and execute the manifest's scope/faker contracts. Cargo bench uses the tiny Rust
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
if (Test-Path -LiteralPath $Root) { throw 'Fixture root must be absent.' }
$null = New-Item -ItemType Directory -Path $Root
$workspace = Join-Path $Root 'workspace'
$null = New-Item -ItemType Directory -Path $workspace
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixture') -Force |
    Copy-Item -Destination $workspace -Recurse
$keys = Join-Path $Root 'machine-keys'
$null = New-Item -ItemType Directory -Path $keys

$toolRoot = $ExistingToolRoot
if (-not $toolRoot) {
    $toolRoot = Join-Path $Root 'fixture-tools'
    $packages = @($manifest.tools | Where-Object role -In @('fixture', 'scope') | ForEach-Object name)
    $parameters = @{ Manifest = $manifest; Method = $Method; Root = $toolRoot; Packages = $packages }
    if ($Method -eq 'path') { $parameters.SourcePath = $SourcePath }
    $null = Install-ActionTools @parameters
}
$fakerTool = @($manifest.tools | Where-Object role -EQ fixture)
$scopeTool = @($manifest.tools | Where-Object role -EQ scope)
if ($fakerTool.Count -ne 1 -or $scopeTool.Count -ne 1) { throw 'Fixture and scope tools must be declared.' }
$faker = Get-ActionToolPath -Manifest $manifest -Root $toolRoot -Package $fakerTool[0].name
$detector = Get-ActionToolPath -Manifest $manifest -Root $toolRoot -Package $scopeTool[0].name

$oldTarget = $env:CARGO_TARGET_DIR
$oldGlobal = $env:GIT_CONFIG_GLOBAL
$oldSystem = $env:GIT_CONFIG_NOSYSTEM
try {
    # Do not inherit personal aliases, signing, hooks or shared build outputs.
    $env:GIT_CONFIG_GLOBAL = Join-Path $Root 'gitconfig'
    Set-Content -LiteralPath $env:GIT_CONFIG_GLOBAL -Value '' -NoNewline
    $env:GIT_CONFIG_NOSYSTEM = '1'
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
        & $detector --path (Join-Path $workspace 'packages\action_canary\benches\synthetic.rs') --via-env ACTION_CANARY_PACKAGE `
            pwsh -NoProfile -Command 'if ($env:ACTION_CANARY_PACKAGE -cne "action_canary") { throw "Wrong detected package" }'
        if ($LASTEXITCODE -ne 0) { throw "Package detection smoke failed ($LASTEXITCODE)." }
        & git -c init.defaultBranch=main init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git initialization failed.' }
        & git -c gc.auto=0 add .
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git staging failed.' }
        & git -c user.name=Canary -c user.email=canary@example.invalid -c commit.gpgsign=false `
            -c gc.auto=0 commit --quiet -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Git commit failed.' }
    }
    finally { Pop-Location }
}
finally {
    $env:CARGO_TARGET_DIR = $oldTarget
    $env:GIT_CONFIG_GLOBAL = $oldGlobal
    $env:GIT_CONFIG_NOSYSTEM = $oldSystem
}
if ($env:GITHUB_ENV) {
    "ACTION_CANARY_FAKER=$faker" >> $env:GITHUB_ENV
    "CARGO_TARGET_DIR=$(Join-Path $Root 'target')" >> $env:GITHUB_ENV
}
if ($env:GITHUB_OUTPUT) {
    "workspace=$workspace" >> $env:GITHUB_OUTPUT
    "store=$(Join-Path $Root 'store')" >> $env:GITHUB_OUTPUT
    "root=$Root" >> $env:GITHUB_OUTPUT
    "machine-keys=$keys" >> $env:GITHUB_OUTPUT
}
