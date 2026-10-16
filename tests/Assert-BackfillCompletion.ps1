#Requires -Version 7.6
# Exercise root-companion completion forwarding and real bounded/failed replay.
# The committed canary workspace uses the faker, not real-time benchmarks.
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Tool,
    [Parameter(Mandatory)] [string] $Companion,
    [Parameter(Mandatory)] [string] $Workspace,
    [Parameter(Mandatory)] [string] $Directory
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$null = New-Item -ItemType Directory -Path $Directory
$from = & git -C $Workspace rev-parse 'HEAD~1'
if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze canary range start.' }
$to = & git -C $Workspace rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'Cannot freeze canary range end.' }
# The parent/tip fixture and a budget below its range prove deferred work without
# starting the next replay. A missing target makes the failure case deterministic.
foreach ($case in @('bounded', 'failed')) {
    $completion = Join-Path $Directory "$case-completion.json"
    $inputs = @{
        command = 'backfill'; 'working-directory' = $Workspace
        'local-path' = Join-Path $Directory "$case-store"
        from = $from; to = $to; 'max-commits' = '1'; 'completion-output' = $completion
        'on-existing' = 'skip'
        bench = if ($case -ceq 'bounded') { 'synthetic' } else { 'canary_target_must_not_execute' }
    }
    $inputPath = Join-Path $Directory "$case-inputs.json"
    $inputs | ConvertTo-Json | Set-Content -LiteralPath $inputPath
    $arguments = @('action', '--inputs-file', $inputPath, '--github-output',
        (Join-Path $Directory "$case.outputs"), '--temp-dir', $Directory, '--tool', $Tool)
    & $Companion @arguments | Out-Host
    $code = $LASTEXITCODE
    if (($case -ceq 'bounded') -ne ($code -eq 0)) { throw "Unexpected $case backfill exit code: $code" }
    $evidence = Get-Content -LiteralPath $completion -Raw | ConvertFrom-Json -AsHashtable
    $stop = if ($case -ceq 'bounded') { 'commit_limit' } else { 'benchmark_failure' }
    if ($evidence.version -ne 1 -or $evidence.from -cne $from -or $evidence.to -cne $to -or
        $evidence.total -ne 2 -or $evidence.stop_reason -cne $stop -or
        $evidence.counts.deferred -ne 1 -or $evidence.overwrite) {
        throw "Invalid $case completion accounting."
    }
    $counted = if ($case -ceq 'bounded') { 'stored' } else { 'failed' }
    if ($evidence.counts[$counted] -ne 1) { throw "Missing $counted attempt in completion." }
    $summary = @{
        execution = if ($case -ceq 'bounded') { 'success' } else { 'failure' }
        publication = 'not_requested'; run_url = 'https://github.com/example/project/actions/runs/42'
        result = @{
            kind = 'backfill'; from = $from; to = $to; expected_platforms = 'linux,windows'
            platforms = @(@{ platform = 'linux'; execution = if ($case -ceq 'bounded') { 'success' } else { 'failure' }
                    completion_file = $completion })
        }
    }
    $summaryPath = Join-Path $Directory "$case-summary.json"
    $cardPath = Join-Path $Directory "$case.md"
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath
    $arguments = @('workflow-summary', '--inputs-file', $summaryPath, '--output-file', $cardPath)
    & $Companion @arguments
    if ($LASTEXITCODE -ne 0) { throw "Cannot render $case completion." }
    $card = Get-Content -LiteralPath $cardPath -Raw
    $stopLabel = if ($case -ceq 'bounded') { 'Commit limit reached' } else { 'Stopped on benchmark failure' }
    if (-not $card.Contains('collection-only backfill has no benchmark verdict') -or
        -not $card.Contains('windows | Unavailable') -or -not $card.Contains($stopLabel)) {
        throw "Backfill card hides $case or unavailable accounting."
    }
}
Write-Information 'Verified bounded/failure completion and unavailable platform accounting.' -InformationAction Continue
