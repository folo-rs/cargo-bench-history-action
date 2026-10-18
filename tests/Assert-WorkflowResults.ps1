#Requires -Version 7.6
# Source canaries exercise the production adapter with the real offline renderer.
# Synthetic schema fixtures cover dispositions; the original analyzer report is
# also passed unchanged when supplied. No publication or performance measurement.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Companion,
    [Parameter(Mandatory)] [string] $Directory,
    [string] $AnalysisJson,
    [string] $AnalyzedSha,
    [string] $Platform = 'linux'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\scripts\WorkflowResults.psm1')
$null = New-Item -ItemType Directory -Path $Directory
$runtime = @{
    repository = 'example/project'; run_id = '42'; run_attempt = '1'
    server_url = 'https://github.com'; job_status = 'success'
    event_name = 'push'; event_action = ''; fork = $false
}
$head = 'a' * 40
$needs = @{
    prepare = @{ result = 'success'; outputs = @{
            head = $head; packages = 'fixture'; 'expected-platforms' = 'linux,windows'
            skipped = 'false'; 'skip-all' = 'false'
        } }
    collect = @{ result = 'success'; outputs = @{} }
}
$steps = @{
    collection = @{ outcome = 'success'; outputs = @{ 'completed-platforms' = 'linux,windows' } }
    analyze = @{ outcome = 'success'; outputs = @{} }
    reports = @{ outcome = 'success'; outputs = @{ 'artifact-url' = 'https://github.com/example/project/actions/runs/42/artifacts/7' } }
    publish = @{ outcome = 'skipped'; outputs = @{} }
}

# Assertions check claims in the rendered card rather than convenience action flags.
function Assert-ResultCard {
    param([string] $Name, [string] $Stage, [string[]] $Expected)
    $inputs = @{
        stage = $Stage; publish = 'false'; companion = $Companion
        needs = $needs | ConvertTo-Json -Depth 10; steps = $steps | ConvertTo-Json -Depth 10
    }
    $path = Join-Path $Directory "$Name.md"
    Invoke-WorkflowResult $inputs $runtime $Directory -OutputPath (Join-Path $Directory "$Name.outputs") -SummaryPath $path
    $card = Get-Content -LiteralPath $path -Raw
    foreach ($text in $Expected) {
        if (-not $card.Contains($text, [StringComparison]::Ordinal)) {
            throw "Result canary $Name did not contain: $text"
        }
    }
    if ([regex]::Matches($card, '## Benchmark workflow results').Count -ne 1) {
        throw "Result canary $Name must append exactly one card."
    }
}

# These are the minimal successful-report census combinations in the Rust contract.
$cases = @(
    @{ outcome = 'findings'; coverage = 'full'; judged = 1; scope = 1; disposition = 'findings' }
    @{ outcome = 'clean'; coverage = 'full'; judged = 1; scope = 1; disposition = 'clean' }
    @{ outcome = 'partial'; coverage = 'partial'; judged = 1; scope = 2; disposition = 'inconclusive' }
    @{ outcome = 'insufficient_baseline'; coverage = 'nothing_judged'; judged = 0; scope = 1; disposition = 'inconclusive' }
    @{ outcome = 'nothing_in_scope'; coverage = 'no_series'; judged = 0; scope = 0; disposition = 'inconclusive' }
)
foreach ($case in $cases) {
    $report = @{
        mode = 'history'; tip_commit = $head; tip_dirty = $false
        outcome = $case.outcome; notable = $case.outcome -ceq 'findings'
        census = @{ coverage = $case.coverage; judged = $case.judged; in_scope = $case.scope }
    }
    $path = Join-Path $Directory "$($case.outcome).json"
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
    $steps.analyze.outputs['report-json'] = $path
    Assert-ResultCard $case.outcome analysis @(
        "| Report disposition | $($case.disposition) |",
        "| Judged coverage | $($case.judged) / $($case.scope) in-scope metric series |",
        '| GitHub publication | Disabled;', 'Freshness | Live-head freshness not checked'
    )
}
$steps.analyze.outputs['report-json'] = Join-Path $Directory 'clean.json'
$steps.collection.outputs['completed-platforms'] = 'linux'
$needs.collect.result = 'failure'
Assert-ResultCard missing-platform analysis @(
    '| Execution | Failed |', '| Report disposition | inconclusive |', '| Missing platforms | <code>windows</code> |'
)
$steps.analyze.outcome = 'failure'
Assert-ResultCard failed analysis @('| Analysis | Not available; no benchmark verdict |', '| Execution | Failed |')
$needs.collect.result = 'skipped'
$needs.prepare.outputs['skip-all'] = 'true'
$steps = @{}
Assert-ResultCard empty-scope terminal @('No benchmarkable package was selected', 'no benchmark verdict')
$needs.prepare.outputs['skip-all'] = 'false'
$runtime.fork = $true
$needs.prepare.result = 'skipped'
Assert-ResultCard fork terminal @('| Execution | Skipped |', 'Fork pull-request policy')
$runtime.fork = $false
$needs.prepare.result = 'success'
$needs.prepare.outputs['no-work-reason'] = 'no-eligible-commit'
Assert-ResultCard no-work terminal @('No commit met the backfill endpoint age policy')

# A rejected report must leave one execution-only card and a failing invocation,
# rather than silently converting missing evidence to an empty or clean analysis.
$needs.prepare.outputs.Remove('no-work-reason')
$steps = @{
    analyze = @{ outcome = 'success'; outputs = @{ 'report-json' = Join-Path $Directory 'absent.json' } }
    collection = @{ outcome = 'success'; outputs = @{ 'completed-platforms' = 'linux,windows' } }
    reports = @{ outcome = 'skipped'; outputs = @{} }
}
$rejected = $false
try { Assert-ResultCard missing-report analysis @() }
catch { $rejected = $true }
$fallback = Get-Content -LiteralPath (Join-Path $Directory 'missing-report.md') -Raw
if (-not $rejected -or -not $fallback.Contains('no validated analysis') -or
    [regex]::Matches($fallback, '## Benchmark workflow result').Count -ne 1) {
    throw 'Missing report must fail and retain exactly one execution-only fallback.'
}
# GitHub's pwsh wrapper forwards the last native exit code. The expected rejection
# above is evidence of success only after its error and fallback assertions pass.
$global:LASTEXITCODE = 0

if ($AnalysisJson) {
    $needs.prepare.outputs.head = $AnalyzedSha
    $needs.prepare.outputs['expected-platforms'] = $Platform
    $needs.collect.result = 'success'
    $steps = @{
        analyze = @{ outcome = 'success'; outputs = $AnalysisJson | ConvertFrom-Json -AsHashtable }
        collection = @{ outcome = 'success'; outputs = @{ 'completed-platforms' = $Platform } }
        reports = @{ outcome = 'skipped'; outputs = @{} }
    }
    Assert-ResultCard real-report analysis @('Insufficient evidence', 'distinct comparable commits', $AnalyzedSha)
}
Write-Information 'Verified offline result cards through the production adapter.' -InformationAction Continue
