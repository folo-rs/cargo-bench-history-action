#Requires -Version 7.6
# Action-owned execution/file wiring; report verdicts and completion accounting
# remain in the offline Rust projection. Ref: docs/implementation.md, "Workflow result cards".
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Import-Module (Join-Path $PSScriptRoot 'Workflow.psm1')

# Combine observed execution conclusions without interpreting analysis outcomes.
function Get-ResultExecution {
    param([hashtable] $Needs, [hashtable] $Steps, [string] $JobStatus)
    $states = @($JobStatus) + @($Needs.Values | ForEach-Object { $_['result'] }) +
        @($Steps.Values | ForEach-Object { $_['outcome'] })
    if ($states -ccontains 'failure') { return 'failure' }
    if ($states -ccontains 'cancelled') { return 'cancelled' }
    if ($Needs['prepare']['result'] -ceq 'skipped') { return 'skipped' }
    return 'success'
}

# Publication outcomes are process results, not proof that a lifecycle write created a post.
function Get-ResultPublication {
    param([hashtable] $Needs, [hashtable] $Steps, [bool] $Publish, [bool] $Backfill)
    if ($Backfill) { return 'not_requested' }
    if (-not $Publish) { return 'disabled' }
    $outcomes = @()
    if ($Steps['publish']) { $outcomes += $Steps['publish']['outcome'] }
    foreach ($name in @('empty-scope', 'failed')) {
        if ($Needs[$name]) { $outcomes += $Needs[$name]['outputs']['publication-result'] }
    }
    if ($Needs['preflight'] -and $Needs['preflight']['outputs']['publication-result'] -cin @('failure', 'cancelled')) {
        $outcomes += 'failure'
    }
    if ($outcomes -ccontains 'failure' -or $outcomes -ccontains 'cancelled') { return 'failed' }
    if ($outcomes -ccontains 'success') { return 'completed' }
    return 'not_attempted'
}

# Only explicit orchestration outputs establish no-work reasons; absent evidence never does.
function Get-ResultUnavailableReason {
    param([hashtable] $Needs, [hashtable] $Runtime)
    $prepare = $Needs['prepare']
    if ($Runtime.fork) { return 'fork_pull_request' }
    if ($prepare['result'] -ceq 'success' -and $prepare['outputs']['skipped'] -cne 'true') {
        if ($prepare['outputs']['skip-all'] -ceq 'true') { return 'empty_scope' }
        if ($prepare['outputs']['no-work-reason'] -ceq 'no-eligible-commit') { return 'no_eligible_commit' }
    }
    return 'reports_unavailable'
}

# Bind opaque completion bytes to the execution that produced them, including failed commands.
function Save-BackfillEvidence {
    param([hashtable] $Inputs, [hashtable] $Runtime, [hashtable] $Preparation, [string] $Directory)
    $identity = @{
        version = 1
        repository = $Runtime.repository
        instance = $Preparation['instance']
        run_id = $Runtime.run_id
        run_attempt = $Runtime.run_attempt
        platform = $Inputs['platform']
        from = $Preparation['from']
        to = $Preparation['to']
    }
    $identity | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Directory 'identity.json') -Encoding utf8
    if ($Inputs['completion-file'] -and (Test-Path -LiteralPath $Inputs['completion-file'] -PathType Leaf)) {
        Copy-Item -LiteralPath $Inputs['completion-file'] -Destination (Join-Path $Directory 'completion.json')
    }
}

# Match artifact transport identities to Rust-selected executed attempts, never an older success.
function Get-BackfillResult {
    param([hashtable] $Selection, [hashtable] $Preparation, [hashtable] $Runtime,
        [string] $ArtifactsDirectory)
    foreach ($pair in @(
            @('repository', $Runtime.repository), @('instance', $Preparation['instance']),
            @('run_id', $Runtime.run_id), @('version', 1)
        )) {
        if ([string] $Selection[$pair[0]] -cne [string] $pair[1]) {
            throw "Backfill job selection has a mismatched $($pair[0])."
        }
    }
    $directories = if (Test-Path -LiteralPath $ArtifactsDirectory -PathType Container) {
        @(Get-ChildItem -LiteralPath $ArtifactsDirectory -Directory)
    } else { @() }
    $platforms = @(foreach ($job in $Selection.platforms) {
            $platform = @{ platform = $job.platform; execution = $job.execution }
            $name = "cbh-backfill-completion-$($Preparation.instance)-$($job.platform)-$($job.run_attempt)"
            $matches = @($directories | Where-Object Name -CEQ $name)
            if ($matches.Count -gt 1) { throw "Ambiguous completion bundle: $name" }
            if ($matches.Count -eq 1) {
                $directory = $matches[0].FullName
                $identity = Get-Content -LiteralPath (Join-Path $directory 'identity.json') -Raw |
                    ConvertFrom-Json -AsHashtable
                foreach ($pair in @(
                        @('version', 1), @('repository', $Runtime.repository),
                        @('instance', $Preparation['instance']), @('run_id', $Runtime.run_id),
                        @('run_attempt', $job.run_attempt), @('platform', $job.platform),
                        @('from', $Preparation['from']), @('to', $Preparation['to'])
                    )) {
                    if ([string] $identity[$pair[0]] -cne [string] $pair[1]) {
                        throw "Completion bundle $name has a mismatched $($pair[0])."
                    }
                }
                $completion = Join-Path $directory 'completion.json'
                if (Test-Path -LiteralPath $completion -PathType Leaf) {
                    $platform.completion_file = $completion
                }
            }
            $platform
        })
    return @{
        kind = 'backfill'; from = $Preparation['from']; to = $Preparation['to']
        expected_platforms = $Preparation['expected-platforms']; platforms = $platforms
    }
}

# No-tool/error cards deliberately carry no benchmark verdict, coverage or completion counts.
function New-ExecutionFallback {
    param([string] $Execution, [string] $Publication, [string] $RunUrl, [string] $Reason,
        [hashtable] $Needs, [hashtable] $Steps, [hashtable] $Runtime, [bool] $ProjectionFailed)
    $stages = @(
        foreach ($name in $Needs.Keys | Sort-Object) {
            if ($Needs[$name]['result'] -cin @('failure', 'cancelled')) { "job $name" }
        }
        foreach ($name in $Steps.Keys | Sort-Object) {
            if ($Steps[$name]['outcome'] -cin @('failure', 'cancelled')) { "step $name" }
        }
    )
    $detail = if ($ProjectionFailed) { 'Result projection or evidence reconciliation failed.' }
    elseif ($Execution -ceq 'skipped') {
        "Work was not selected for event $($Runtime.event_name) / $($Runtime.event_action)."
    } else { 'Preparation or tool installation did not provide the result renderer.' }
    $detail += " Recorded no-analysis reason: $Reason."
    $detail = [System.Net.WebUtility]::HtmlEncode($detail)
    $stageText = [System.Net.WebUtility]::HtmlEncode(($stages -join ', '))
    return @"
## Benchmark workflow result

**Execution:** $Execution  
**GitHub publication:** $Publication  
**Analysis:** unavailable; no validated analysis or final completion accounting.

<p>$detail</p>
<p>Stage diagnostics: $stageText</p>

Next: inspect the [workflow run and job logs]($RunUrl) before retrying. Missing evidence is not a clean result or zero work.
"@
}

# The only final append point: renderer errors retain a minimal card and still fail the step.
function Invoke-WorkflowResult {
    [CmdletBinding()]
    param([hashtable] $Inputs, [hashtable] $Runtime, [string] $TempDirectory,
        [string] $OutputPath, [string] $SummaryPath)
    $needs = $Inputs['needs'] | ConvertFrom-Json -AsHashtable
    $steps = $Inputs['steps'] | ConvertFrom-Json -AsHashtable
    $prepare = $needs['prepare']['outputs']
    $stage = $Inputs['stage']
    if ($stage -cnotin @('analysis', 'terminal', 'backfill-evidence', 'backfill')) {
        throw "Unknown workflow result stage: $stage"
    }
    $root = Join-Path $TempDirectory "cbh-result-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $root
    if ($stage -ceq 'backfill-evidence') {
        Save-BackfillEvidence -Inputs $Inputs -Runtime $Runtime -Preparation $prepare -Directory $root
        "evidence-directory=$root" | Add-Content -LiteralPath $OutputPath -Encoding utf8
        return
    }
    $execution = Get-ResultExecution -Needs $needs -Steps $steps -JobStatus $Runtime.job_status
    $publication = Get-ResultPublication -Needs $needs -Steps $steps `
        -Publish ($Inputs['publish'] -ceq 'true') -Backfill ($stage -ceq 'backfill')
    $reason = Get-ResultUnavailableReason -Needs $needs -Runtime $Runtime
    $runUrl = "$($Runtime.server_url)/$($Runtime.repository)/actions/runs/$($Runtime.run_id)"
    $request = @{
        execution = $execution; publication = $publication; run_url = $runUrl
        result = @{ kind = 'unavailable'; reason = $reason }
    }
    $failure = $null
    $card = $null
    try {
        if ($stage -ceq 'analysis' -and $steps['analyze']['outcome'] -ceq 'success') {
            $request.result = @{
                kind = 'analysis'; report_file = $steps['analyze']['outputs']['report-json']
                analyzed_sha = $prepare['head']; expected_platforms = $prepare['expected-platforms']
                completed_platforms = $steps['collection']['outputs']['completed-platforms']
            }
            if ($prepare['packages']) { $request.result.packages = @($prepare['packages'].Split(',')) }
            if ($steps['reports']['outcome'] -ceq 'success') {
                $request.artifact_url = $steps['reports']['outputs']['artifact-url']
            }
        }
        if ($Inputs['companion']) {
            if ($stage -ceq 'backfill' -and $prepare['has-work'] -ceq 'true') {
                $selectionPath = Join-Path $root 'jobs.json'
                Invoke-WorkflowProcess -FilePath $Inputs['companion'] -Arguments @(
                    '--repository', $Runtime.repository, '--instance', $prepare['instance'],
                    'backfill-jobs', '--run-id', $Runtime.run_id,
                    '--expected-platforms', $prepare['expected-platforms'], '--output-file', $selectionPath)
                $selection = Get-Content -LiteralPath $selectionPath -Raw | ConvertFrom-Json -AsHashtable
                $request.result = Get-BackfillResult -Selection $selection -Preparation $prepare `
                    -Runtime $Runtime -ArtifactsDirectory $Inputs['artifacts-directory']
                if ($steps['bundle'] -and $steps['bundle']['outcome'] -ceq 'success') {
                    $request.artifact_url = $steps['bundle']['outputs']['artifact-url']
                }
            }
            $inputPath = Join-Path $root 'inputs.json'
            $cardPath = Join-Path $root 'card.md'
            $request | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $inputPath -Encoding utf8
            Invoke-WorkflowProcess -FilePath $Inputs['companion'] -Arguments @(
                'workflow-summary', '--inputs-file', $inputPath, '--output-file', $cardPath)
            $card = Get-Content -LiteralPath $cardPath -Raw
            if ([string]::IsNullOrWhiteSpace($card)) { throw 'The workflow result renderer emitted an empty card.' }
        }
        elseif ($execution -ceq 'success') { throw 'No verified workflow result renderer is available.' }
    }
    catch {
        # Never convert a renderer failure into a successful summary step. The
        # fallback preserves visibility, while the original diagnostic remains an error.
        $failure = $_
    }
    if ($null -eq $card) {
        $card = New-ExecutionFallback -Execution $execution -Publication $publication -RunUrl $runUrl `
            -Reason $reason -Needs $needs -Steps $steps -Runtime $Runtime -ProjectionFailed ($null -ne $failure)
    }
    $card | Add-Content -LiteralPath $SummaryPath -Encoding utf8
    if ($null -ne $failure) { throw $failure }
}

Export-ModuleMember -Function Invoke-WorkflowResult
