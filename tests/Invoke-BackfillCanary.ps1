#Requires -Version 7.6
<#
Source and published-method canaries call this after ordinary root-action collection
and before analysis. It reuses that collection's installed main executable and the
fixture's existing faker, fills the older Git commit, then proves skip-existing
resumption with a nonexistent benchmark target and unchanged storage hashes.
It performs no installation, wall-clock measurement or network operation.
#>
[CmdletBinding()]
param(
    [string] $Workspace,
    [string] $Store,
    [string] $MachineKey,
    [string] $Tool,
    [string] $TemporaryDirectory = $env:RUNNER_TEMP
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Assert-Canary.ps1') -Workspace $Workspace -Store $Store -MachineKey $MachineKey

function Get-CanaryCollectionTool {
    param([string] $Workspace, [string] $TemporaryDirectory)
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Tools.psm1')
    $manifest = Read-ActionManifest (Join-Path $PSScriptRoot '..\release.json')
    $main = @($manifest.tools | Where-Object role -CEQ tool)[0].name
    $workspacePath = (Get-Item -LiteralPath $Workspace).FullName
    # This is a CI-only consumer of the bootstrap's existing state, not a public
    # root-action output or a second installation. Ambiguity must fail the probe.
    $tools = @(foreach ($directory in Get-ChildItem -LiteralPath $TemporaryDirectory -Directory -Filter cbh-action-*) {
            $statePath = Join-Path $directory.FullName 'state.json'
            if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { continue }
            $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $inputs = Get-Content -LiteralPath $state.inputPath -Raw | ConvertFrom-Json -AsHashtable
            if ($inputs.command -ceq 'collect' -and $inputs['working-directory'] -ceq $workspacePath) {
                (Get-Item -LiteralPath $state.executables[$main] -ErrorAction Stop).FullName
            }
        })
    if ($tools.Count -ne 1) { throw 'Expected exactly one installed root-action collector for this fixture.' }
    return $tools[0]
}

function Invoke-CanaryBackfill {
    param([string] $Tool, [string] $Workspace, [string] $Store, [string] $Bench)
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    & $Tool backfill --repo $Workspace "--local=$Store" `
        --config (Join-Path $Workspace '.cargo\bench_history.toml') --bench $Bench 'HEAD~1' HEAD | Out-Host
    if ($global:LASTEXITCODE -ne 0) { throw "Backfill canary failed ($global:LASTEXITCODE)." }
}

function Invoke-BackfillCanary {
    param([string] $Workspace, [string] $Store, [string] $MachineKey, [string] $Tool,
        [string] $TemporaryDirectory)
    if (-not $Tool) { $Tool = Get-CanaryCollectionTool -Workspace $Workspace -TemporaryDirectory $TemporaryDirectory }
    $PSNativeCommandUseErrorActionPreference = $false
    $head = & git -C $Workspace rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify fixture tip.' }
    $parent = & git -C $Workspace rev-parse 'HEAD~1'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify historical fixture commit.' }
    $collected = Get-CanaryStoreEvidence -Store $Store -MachineKey $MachineKey -Commits @($head)
    $oldOffline = $env:CARGO_NET_OFFLINE
    try {
        $env:CARGO_NET_OFFLINE = 'true'
        Invoke-CanaryBackfill -Tool $Tool -Workspace $Workspace -Store $Store -Bench synthetic
        $filled = Get-CanaryStoreEvidence -Store $Store -MachineKey $MachineKey -Commits @($parent, $head)
        Assert-CanaryStorePreserved -Before $collected -After $filled -AllowAdditional
        # The target name is valid but absent from both committed manifests.
        # Any attempted benchmark execution must therefore fail, not merely write nothing.
        Invoke-CanaryBackfill -Tool $Tool -Workspace $Workspace -Store $Store -Bench canary_target_must_not_execute
        $resumed = Get-CanaryStoreEvidence -Store $Store -MachineKey $MachineKey -Commits @($parent, $head)
        Assert-CanaryStorePreserved -Before $filled -After $resumed
    }
    finally { $env:CARGO_NET_OFFLINE = $oldOffline }
    Write-Information 'Verified historical backfill and same-runner resumption against stored commit identities and hashes.' -InformationAction Continue
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-BackfillCanary -Workspace $Workspace -Store $Store -MachineKey $MachineKey `
        -Tool $Tool -TemporaryDirectory $TemporaryDirectory
}
