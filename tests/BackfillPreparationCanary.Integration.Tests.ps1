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
$case = (Split-Path $args[6] -Leaf).Replace('preparation-output-', '')
$fromRef, $toRef = switch ($case) {
    'exact-short' { 'main~1'; 'main' }
    'exact-qualified' { 'main~1'; 'refs/heads/main' }
    'rolling' { 'HEAD'; 'HEAD' }
    'rolling-override' { 'release'; 'release' }
    'no-work' { ''; '' }
    default { throw 'Unexpected probe case.' }
}
$base = @(
    'instance=fixture'
    'matrix={"platform":["ubuntu-latest","windows-latest"]}'
    'expected-platforms=ubuntu-latest,windows-latest'
    'skipped=false'
)
if ($case -eq 'no-work') {
    if ($env:CBH_PREPARATION_PROBE_FAILURE -eq 'wrong-no-work') {
        $head = & git -C $inputs['working-directory'] rev-parse --verify HEAD
        if ($LASTEXITCODE -ne 0) { throw 'Fixture head lookup failed.' }
        $base + @('has-work=true', "from=$head", "to=$head") | Set-Content $args[6]
    }
    else { $base + @('has-work=false', 'no-work-reason=no-eligible-commit') | Set-Content $args[6] }
    exit 0
}
if ($case -eq 'rolling' -and $env:CBH_PREPARATION_PROBE_FAILURE -eq 'wrong-rolling-range') {
    $fromRef = 'HEAD~1'
}
$from = & git -C $inputs['working-directory'] rev-parse --verify --end-of-options "$fromRef^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Fixture from lookup failed.' }
$to = & git -C $inputs['working-directory'] rev-parse --verify --end-of-options "$toRef^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Fixture to lookup failed.' }
$base + @(
    'has-work=true'
    "from=$from"
) | Set-Content $args[6]
if ($env:CBH_PREPARATION_PROBE_FAILURE -ne 'missing-to') { "to=$to" | Add-Content $args[6] }
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
        $results = Get-Content (Join-Path $root 'preparation-results.json') -Raw | ConvertFrom-Json -AsHashtable
        @($results.case) | Should -Be @('exact-short', 'exact-qualified', 'rolling', 'rolling-override', 'no-work')
        foreach ($result in $results) {
            $inputs = Get-Content (Join-Path $root "preparation-input-$($result.case).json") -Raw | ConvertFrom-Json -AsHashtable
            $inputs.Keys | Sort-Object | Should -Be @('config', 'exclude', 'from', 'lookback', 'minimum-age', 'platforms', 'to', 'working-directory')
            if ($result.case -like 'exact-*') {
                $inputs.from | Should -BeExactly 'main~1'
                $inputs.lookback | Should -BeExactly ''
                $inputs['minimum-age'] | Should -BeExactly ''
            }
            else {
                $inputs.from | Should -BeExactly ''
                if ($result.case -ne 'rolling-override') { $inputs.to | Should -BeExactly '' }
                $inputs.lookback | Should -Not -BeNullOrEmpty
                $inputs['minimum-age'] | Should -Not -BeNullOrEmpty
            }
        }
        $env:GITHUB_EVENT_NAME | Should -BeExactly 'pull_request'
        $env:GITHUB_SHA | Should -BeExactly ('f' * 40)
        $env:GITHUB_TOKEN | Should -BeExactly 'fixture-token'
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'does not accept failed or incomplete installed-tool preparation: <failure>' -ForEach @(
        @{ failure = 'exit' }, @{ failure = 'missing-to' },
        @{ failure = 'wrong-rolling-range' }, @{ failure = 'wrong-no-work' }
    ) {
        $env:CBH_PREPARATION_PROBE_FAILURE = $failure
        { & $entry -Companion $companion -Root $root } | Should -Throw
    }
}
