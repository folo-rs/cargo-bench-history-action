#Requires -Version 7.6
# Called by the release-owned workflow-tools composite and its workflows through
# github.action_path-derived script paths. Only installation and file/argument
# wiring live here; the installed companion owns workflow decisions.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('layout', 'install', 'prepare', 'receipt', 'reconcile')] [string] $Stage,
    [string] $StatePath = $env:CBH_WORKFLOW_STATE
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Workflow.psm1')
Import-Module (Join-Path $PSScriptRoot 'Tools.psm1')

function Add-WorkflowOutput {
    param([string] $Name, [string] $Value)
    if ($Value.Contains("`n") -or $Value.Contains("`r")) { throw "Workflow output $Name must be single-line." }
    "$Name=$Value" | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
}

if ($Stage -eq 'layout') {
    $inputs = $env:CBH_WORKFLOW_INPUTS | ConvertFrom-Json -AsHashtable
    $method = if ($inputs['install-method']) { $inputs['install-method'] } else { 'binstall' }
    $context = Initialize-WorkflowContext -Workspace $env:GITHUB_WORKSPACE -TempDirectory $env:RUNNER_TEMP `
        -Repository $env:GITHUB_REPOSITORY -Method $method -WorkingDirectory $inputs['working-directory'] `
        -Config $inputs['config'] -SourcePath $inputs['source-path'] -Base $inputs['base'] -Instance $inputs['instance']
    $context | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $context['state-path'] -Encoding utf8
    foreach ($key in @('state-path', 'scripts-path', 'checkout-path', 'working-directory', 'config',
            'source-path', 'receipt-file', 'receipts-directory', 'machine-key-directory', 'cache-directory')) {
        Add-WorkflowOutput $key $context[$key]
    }
    return
}

$context = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable
if ($Stage -eq 'install') {
    $manifest = Read-ActionManifest -Path (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'release.json')
    $tools = Install-WorkflowTool -Context $context -Manifest $manifest
    foreach ($key in $tools.Keys) {
        $context[$key] = $tools[$key]
        Add-WorkflowOutput $key $tools[$key]
    }
    $context | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $StatePath -Encoding utf8
    return
}

$parameters = @{ Operation = $Stage; Context = $context }
switch ($Stage) {
    'prepare' {
        $parameters.Flow = $env:CBH_FLOW
        $parameters.Platforms = $env:CBH_PLATFORMS
        $parameters.Exclude = $env:CBH_EXCLUDE
        if ($parameters.Flow -eq 'backfill') {
            $parameters.From = $env:CBH_FROM
            $parameters.To = $env:CBH_TO
        }
    }
    'receipt' {
        $parameters.Instance = $env:CBH_INSTANCE
        $parameters.Head = $env:CBH_HEAD
        $parameters.Platform = $env:CBH_PLATFORM
        $parameters.MachineKey = $env:CBH_MACHINE_KEY
    }
    'reconcile' {
        $parameters.Instance = $env:CBH_INSTANCE
        $parameters.Head = $env:CBH_HEAD
        $parameters.Platforms = $env:CBH_PLATFORMS
    }
}
Invoke-WorkflowOperation @parameters
