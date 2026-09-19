#Requires -Version 7.6
# Real root-action canaries use this to verify stored measurements and report
# evidence. A one-point history must not claim an all-clear or invented findings.
[CmdletBinding()]
param(
    [string] $Workspace,
    [string] $Store,
    [string] $MachineKey,
    [string] $CollectionJson,
    [string] $AnalysisJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CanaryForkSkip {
    param($EventData, $Collection, $Analysis)
    $pr = $EventData['pull_request']
    if (-not $pr) { throw 'A non-PR invocation must execute the behavioral canary.' }
    $headRepo = $pr['head']['repo']
    $baseRepo = $pr['base']['repo']
    if ($headRepo -and $baseRepo -and $headRepo['full_name'] -ieq $baseRepo['full_name']) {
        throw 'A same-repository PR must execute the behavioral canary.'
    }
    if ($Collection['skipped'] -cne 'true' -or $Analysis['skipped'] -cne 'true' -or
        $Collection['machine-key'] -or $Analysis['outcome']) {
        throw 'Fork canaries must explicitly skip both commands without claiming benchmark evidence.'
    }
}

function Assert-CanaryAnalysis {
    param($Report, $Outputs, [string] $Commit)
    if ($Report.tip_commit -cne $Commit -or $Report.tip_dirty -or $Report.mode -cne 'history') {
        throw 'Analysis did not describe the committed fixture history.'
    }
    if ($Report.census.in_scope -le 0 -or $Report.census.judged -ne 0 -or
        $Report.census.coverage -cne 'nothing_judged' -or
        $Report.outcome -cne 'insufficient_baseline' -or $Report.notable) {
        throw 'One stored synthetic point must yield an honest insufficient-baseline report.'
    }
    if ($Outputs['outcome'] -cne $Report.outcome -or $Outputs['publication-state'] -cne 'no-data' -or
        $Outputs['can-clear'] -cne 'false' -or $Outputs['partial-platform-coverage'] -cne 'false') {
        throw 'Action outputs disagree with the report or the complete fixture platform evidence.'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $collection = $CollectionJson | ConvertFrom-Json -AsHashtable
    $outputs = $AnalysisJson | ConvertFrom-Json -AsHashtable
    if ($collection['skipped'] -eq 'true' -or $outputs['skipped'] -eq 'true') {
        $workflowEvent = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable
        Assert-CanaryForkSkip $workflowEvent $collection $outputs
        Write-Information 'Verified explicit fork policy: no collection/report evidence is claimed. Published availability is checked independently before these invocations.' -InformationAction Continue
        return
    }
    if ([string]::IsNullOrWhiteSpace($MachineKey) -or $MachineKey.Contains("`n")) {
        throw 'Collection must emit one real machine key.'
    }
    $objects = @(Get-ChildItem -LiteralPath $Store -Recurse -Filter clean.json -File |
        Where-Object {
            $_.Length -gt 0 -and $MachineKey -cin ($_.FullName -split '[\\/]')
        })
    if ($objects.Count -ne 1) { throw 'Collection must store one nonempty clean object in its machine-key partition.' }
    foreach ($name in @('report-json', 'report-markdown', 'report-summary')) {
        if (-not $outputs.Contains($name) -or -not (Test-Path -LiteralPath $outputs[$name] -PathType Leaf) -or
            (Get-Item -LiteralPath $outputs[$name]).Length -eq 0) {
            throw "Analysis did not emit a nonempty $name file."
        }
    }
    $report = Get-Content -LiteralPath $outputs['report-json'] -Raw | ConvertFrom-Json -AsHashtable
    $commit = & git -C $Workspace rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify fixture commit.' }
    Assert-CanaryAnalysis -Report $report -Outputs $outputs -Commit $commit
    Write-Information 'Verified collected storage, real machine key and parseable insufficient-baseline reports.' -InformationAction Continue
}
