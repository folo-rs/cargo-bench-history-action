#Requires -Version 7.6
# Release-owned entry point remains usable when workflow-tools preparation fails.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Import-Module (Join-Path $PSScriptRoot 'WorkflowResults.psm1')

$inputs = $env:CBH_RESULT_INPUTS | ConvertFrom-Json -AsHashtable
$runtime = @{
    repository = $env:GITHUB_REPOSITORY
    run_id = $env:GITHUB_RUN_ID
    run_attempt = $env:GITHUB_RUN_ATTEMPT
    server_url = $env:GITHUB_SERVER_URL
    job_status = $env:CBH_JOB_STATUS
    event_name = $env:GITHUB_EVENT_NAME
    event_action = $env:CBH_EVENT_ACTION
    fork = $env:CBH_FORK -ceq 'true'
}
Invoke-WorkflowResult -Inputs $inputs -Runtime $runtime -TempDirectory $env:RUNNER_TEMP `
    -OutputPath $env:GITHUB_OUTPUT -SummaryPath $env:GITHUB_STEP_SUMMARY
