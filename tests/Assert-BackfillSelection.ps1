#Requires -Version 7.6
# Hosted source canaries exercise authenticated discovery separately from offline
# rendering. The probe namespace has no backfill jobs, so counts must stay unknown.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Companion,
    [Parameter(Mandatory)] [string] $Directory,
    [Parameter(Mandatory)] [string] $Platform,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $RunId = $env:GITHUB_RUN_ID
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\WorkflowResults.psm1')
$null = New-Item -ItemType Directory -Path $Directory
# Distinct from the source collector's project namespace; no completion evidence
# belongs to this range, and successful discovery must not manufacture any.
$instance = 'action-result-probe'
$needs = @{
    prepare = @{ result = 'success'; outputs = @{
            instance = $instance; from = 'a' * 40; to = 'b' * 40
            'expected-platforms' = $Platform; 'has-work' = 'true'; skipped = 'false'
        } }
    backfill = @{ result = 'success'; outputs = @{} }
}
$runtime = @{
    repository = $Repository; run_id = $RunId; run_attempt = '1'
    server_url = 'https://github.com'; job_status = 'success'
    event_name = 'workflow_dispatch'; event_action = ''; fork = $false
}
$inputs = @{
    stage = 'backfill-selection'; needs = $needs | ConvertTo-Json -Depth 10; steps = '{}'
    companion = $Companion; 'artifacts-directory' = $Directory; publish = 'false'
}
$summary = Join-Path $Directory 'card.md'
$parameters = @{
    Inputs = $inputs; Runtime = $runtime; TempDirectory = $Directory
    OutputPath = Join-Path $Directory 'outputs'; SummaryPath = $summary
}
Invoke-WorkflowResult @parameters
$selection = Get-Content -LiteralPath (Join-Path $Directory 'jobs.json') -Raw | ConvertFrom-Json -AsHashtable
if ($selection.version -ne 1 -or $selection.repository -cne $Repository -or
    $selection.instance -cne $instance -or [string] $selection.run_id -cne $RunId -or
    $selection.platforms.Count -ne 0 -or (Test-Path -LiteralPath $summary)) {
    throw 'Authenticated discovery did not preserve the empty probe namespace and no-summary boundary.'
}
$inputs.stage = 'backfill'
$inputs.steps = @{ selection = @{ outcome = 'success'; outputs = @{} } } | ConvertTo-Json -Depth 5
$oldGhToken = $env:GH_TOKEN
$oldGithubToken = $env:GITHUB_TOKEN
try {
    $env:GH_TOKEN = $null
    $env:GITHUB_TOKEN = $null
    Invoke-WorkflowResult @parameters
}
finally {
    $env:GH_TOKEN = $oldGhToken
    $env:GITHUB_TOKEN = $oldGithubToken
}
$card = Get-Content -LiteralPath $summary -Raw
if (-not $card.Contains("| $Platform | Unavailable | - | - | - | - | - | No platform result |") -or
    -not $card.Contains('collection-only backfill has no benchmark verdict') -or
    [regex]::Matches($card, '## Benchmark workflow results').Count -ne 1) {
    throw 'Unavailable backfill evidence must produce one no-verdict card with unknown counts.'
}
Write-Information 'Verified authenticated job discovery and offline unavailable-accounting projection.' -InformationAction Continue
