#Requires -Version 7.6
# Exercise the installed-tool probe's real local Git and child-process boundaries.
# A companion fixture captures the command contract; the published installation
# gate runs the same probe with its real, already verified companion executable.
BeforeAll {
    $script:entry = Join-Path $PSScriptRoot 'Assert-BackfillPreparation.ps1'
}

Describe 'Offline backfill preparation canary' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "$([guid]::NewGuid()) preparation"
        $script:companion = Join-Path $TestDrive 'companion.ps1'
        $script:environment = @{}
        foreach ($key in @('GITHUB_EVENT_NAME', 'GITHUB_EVENT_PATH', 'GITHUB_SHA',
                'GITHUB_REPOSITORY', 'GITHUB_TOKEN', 'GITHUB_OUTPUT', 'CBH_PREPARATION_PROBE_FAILURE')) {
            $script:environment[$key] = [Environment]::GetEnvironmentVariable($key)
        }
        $env:GITHUB_EVENT_NAME = 'pull_request'
        $env:GITHUB_EVENT_PATH = Join-Path $TestDrive 'unrelated-event.json'
        $env:GITHUB_SHA = 'f' * 40
        $env:GITHUB_REPOSITORY = 'owner/action-repository'
        $env:GITHUB_TOKEN = 'fixture-token'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'parent-output'
        $env:CBH_PREPARATION_PROBE_FAILURE = ''
        @'
$ErrorActionPreference = 'Stop'
if (($args[0..2] -join '|') -cne 'prepare-workflow|--flow|backfill' -or $args.Count -ne 7) {
    throw 'Unexpected installed-tool probe arguments.'
}
$inputs = Get-Content $args[4] -Raw | ConvertFrom-Json -AsHashtable
if (Test-Path -LiteralPath (Join-Path $inputs['working-directory'] 'Cargo.toml')) {
    throw 'The fixture head still has a Cargo workspace.'
}
if ($env:GITHUB_EVENT_NAME -or $env:GITHUB_EVENT_PATH -or $env:GITHUB_SHA -or
    $env:GITHUB_REPOSITORY -or $env:GITHUB_TOKEN) {
    throw 'Unrelated calling-event context leaked into the fixture.'
}
if ($env:CBH_PREPARATION_PROBE_FAILURE -eq 'exit') { exit 7 }
$from = & git -C $inputs['working-directory'] rev-parse --verify --end-of-options "$($inputs.from)^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Fixture from lookup failed.' }
$to = & git -C $inputs['working-directory'] rev-parse --verify --end-of-options "$($inputs.to)^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Fixture to lookup failed.' }
@(
    'instance=fixture'
    'matrix={"platform":["ubuntu-latest","windows-latest"]}'
    'expected-platforms=ubuntu-latest,windows-latest'
    'skipped=false'
    "from=$from"
) | Set-Content $args[6]
if ($env:CBH_PREPARATION_PROBE_FAILURE -ne 'missing-to') { "to=$to" | Add-Content $args[6] }
$inputs | ConvertTo-Json | Set-Content (Join-Path (Split-Path $args[6]) 'captured-inputs.json')
exit 0
'@ | Set-Content -LiteralPath $script:companion
    }

    AfterEach {
        foreach ($key in $script:environment.Keys) {
            [Environment]::SetEnvironmentVariable($key, $script:environment[$key])
        }
    }

    It 'isolates fixture event provenance in the child and freezes real historical commits' {
        & $entry -Companion $companion -Root $root
        $inputs = Get-Content (Join-Path $root 'captured-inputs.json') -Raw | ConvertFrom-Json -AsHashtable
        $inputs.Keys | Sort-Object | Should -Be @('config', 'exclude', 'from', 'platforms', 'to', 'working-directory')
        $inputs.from | Should -BeExactly 'main~1'
        $inputs.to | Should -BeExactly 'refs/heads/main'
        $env:GITHUB_EVENT_NAME | Should -BeExactly 'pull_request'
        $env:GITHUB_SHA | Should -BeExactly ('f' * 40)
        $env:GITHUB_TOKEN | Should -BeExactly 'fixture-token'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does not accept failed or incomplete installed-tool preparation: <failure>' -ForEach @(
        @{ failure = 'exit' }, @{ failure = 'missing-to' }
    ) {
        $env:CBH_PREPARATION_PROBE_FAILURE = $failure
        { & $entry -Companion $companion -Root $root } | Should -Throw
    }
}
