#Requires -Version 7.6
# Mock only native boundaries; exercise the real structural handoff, fallback and
# immutable artifact association without reimplementing Rust report verdicts.
Import-Module (Join-Path $PSScriptRoot '..\scripts\WorkflowResults.psm1') -Force

Describe 'Workflow result adapters' {
    InModuleScope WorkflowResults {
        BeforeAll {
            function Invoke-ResultFixture {
                if ($script:inputs.stage -ceq 'backfill') {
                    $null = New-Item -ItemType Directory -Path $script:artifacts -Force
                    $script:selection | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:artifacts 'jobs.json')
                }
                $script:inputs.needs = $script:needs | ConvertTo-Json -Depth 10
                $script:inputs.steps = $script:steps | ConvertTo-Json -Depth 10
                Invoke-WorkflowResult $script:inputs $script:runtime $TestDrive `
                    -OutputPath $script:output -SummaryPath $script:summary
            }

            function Add-CompletionFixture {
                param([string] $Platform = 'linux', [int] $Attempt = 1)
                $path = Join-Path $script:artifacts "cbh-backfill-completion-project-$Platform-$Attempt"
                $null = New-Item -ItemType Directory -Path $path -Force
                $identity = @{
                    version = 1; repository = 'owner/project'; instance = 'project'
                    run_id = '42'; run_attempt = "$Attempt"; platform = $Platform
                    from = 'a' * 40; to = 'b' * 40
                }
                $identity | ConvertTo-Json | Set-Content (Join-Path $path 'identity.json')
                '{"opaque":"Rust validates these bytes"}' | Set-Content (Join-Path $path 'completion.json')
                return $path
            }
        }
        BeforeEach {
            $script:summary = Join-Path $TestDrive "$([guid]::NewGuid()).md"
            $script:output = Join-Path $TestDrive "$([guid]::NewGuid()).outputs"
            $script:artifacts = Join-Path $TestDrive "$([guid]::NewGuid())"
            $script:runtime = @{
                repository = 'owner/project'; run_id = '42'; run_attempt = '3'
                server_url = 'https://github.com'; job_status = 'success'
                event_name = 'push'; event_action = ''; fork = $false
            }
            $script:needs = @{
                prepare = @{ result = 'success'; outputs = @{
                        head = 'b' * 40; instance = 'project'; 'expected-platforms' = 'linux,windows'
                        packages = "crate; '`$literal',other"; 'skip-all' = 'false'; skipped = 'false'
                        from = 'a' * 40; to = 'b' * 40; 'has-work' = 'true'
                    } }
                collect = @{ result = 'success'; outputs = @{} }
                preflight = @{ result = 'success'; outputs = @{ 'publication-result' = 'success' } }
            }
            $script:steps = @{
                context = @{ outcome = 'success'; outputs = @{} }
                collection = @{ outcome = 'success'; outputs = @{ 'completed-platforms' = 'linux,windows' } }
                analyze = @{ outcome = 'success'; outputs = @{ 'report-json' = "a report; 'literal'.json" } }
                reports = @{ outcome = 'success'; outputs = @{ 'artifact-url' = 'https://github.com/owner/project/actions/runs/42/artifacts/7' } }
                publish = @{ outcome = 'skipped'; outputs = @{} }
                selection = @{ outcome = 'success'; outputs = @{} }
            }
            $script:inputs = @{
                stage = 'analysis'; publish = 'false'; companion = 'companion fixture'
                'artifacts-directory' = $script:artifacts
            }
            $script:selection = @{
                version = 1; repository = 'owner/project'; instance = 'project'; run_id = 42
                platforms = @(@{ platform = 'linux'; execution = 'success'; run_attempt = 1; job_id = 10 })
            }
            $script:request = $null
            Mock Invoke-WorkflowProcess {
                if ($Arguments -contains 'backfill-jobs') {
                    $script:selection | ConvertTo-Json -Depth 10 | Set-Content $Arguments[-1]
                } else {
                    $Arguments[0] | Should -BeExactly 'workflow-summary'
                    $script:request = Get-Content $Arguments[2] -Raw | ConvertFrom-Json -AsHashtable
                    "# Rust result`nopaque rendered card" | Set-Content $Arguments[4]
                }
            }
        }

        It 'appends exactly the Rust card and preserves data/coverage with publication disabled' {
            Invoke-ResultFixture
            $script:request.publication | Should -BeExactly 'disabled'
            $script:request.result.report_file | Should -BeExactly $script:steps.analyze.outputs['report-json']
            $script:request.result.packages | Should -Be @("crate; '`$literal'", 'other')
            $script:request.result.ContainsKey('observed_head') | Should -BeFalse
            $script:request.artifact_url | Should -BeExactly $script:steps.reports.outputs['artifact-url']
            (Get-Content $script:summary -Raw).Trim() | Should -BeExactly "# Rust result`nopaque rendered card"
            Should -Invoke Invoke-WorkflowProcess -Exactly 1
        }

        It 'keeps <failed> failure independent of valid partial analysis' -ForEach @(
            @{ failed = 'collect' }, @{ failed = 'preflight' }, @{ failed = 'reports' }, @{ failed = 'publish' }
        ) {
            $script:inputs.publish = 'true'
            if ($script:needs.ContainsKey($failed)) { $script:needs[$failed].result = 'failure' }
            else { $script:steps[$failed].outcome = 'failure' }
            $script:steps.collection.outputs['completed-platforms'] = 'linux'
            Invoke-ResultFixture
            $script:request.execution | Should -BeExactly 'failure'
            $script:request.result.kind | Should -BeExactly 'analysis'
            $script:request.result.completed_platforms | Should -BeExactly 'linux'
            if ($failed -ceq 'reports') { $script:request.ContainsKey('artifact_url') | Should -BeFalse }
            if ($failed -ceq 'publish') { $script:request.publication | Should -BeExactly 'failed' }
        }

        It 'does not treat a successful preflight as completed report publication' {
            $script:inputs.publish = 'true'
            Invoke-ResultFixture
            $script:request.publication | Should -BeExactly 'not_attempted'
            $script:steps.publish.outcome = 'success'
            Invoke-ResultFixture
            $script:request.publication | Should -BeExactly 'completed'
        }

        It 'uses explicit <reason> without inventing an analysis verdict' -ForEach @(
            @{ reason = 'empty_scope'; key = 'skip-all'; value = 'true' }
            @{ reason = 'no_eligible_commit'; key = 'no-work-reason'; value = 'no-eligible-commit' }
            @{ reason = 'reports_unavailable'; key = 'skip-all'; value = 'false' }
        ) {
            $script:inputs.stage = 'terminal'
            $script:needs.prepare.outputs[$key] = $value
            Invoke-ResultFixture
            $script:request.result.Count | Should -Be 2
            $script:request.result.reason | Should -BeExactly $reason
        }

        It 'writes an execution-only fallback for preparation <execution> without a companion' -ForEach @(
            @{ execution = 'failure' }, @{ execution = 'cancelled' }, @{ execution = 'skipped' }
        ) {
            $script:inputs.stage = 'terminal'
            $script:inputs.companion = ''
            $script:needs.prepare.result = $execution
            $script:steps = @{}
            Invoke-ResultFixture
            $card = Get-Content $script:summary -Raw
            $card | Should -Match ([regex]::Escape("**Execution:** $execution"))
            $card | Should -Match 'no validated analysis'
            $card | Should -Match 'https://github.com/owner/project/actions/runs/42'
            Should -Invoke Invoke-WorkflowProcess -Exactly 0
        }

        It 'retains one fallback card and the diagnostic when Rust rejects missing/corrupt evidence' {
            Mock Invoke-WorkflowProcess { throw 'invalid report evidence' }
            { Invoke-ResultFixture } | Should -Throw '*invalid report evidence*'
            $card = Get-Content $script:summary -Raw
            ([regex]::Matches($card, '## Benchmark workflow result')).Count | Should -Be 1
            $card | Should -Match 'projection or evidence reconciliation failed'
            $card | Should -Not -Match 'Rust result'
        }

        It 'rejects an empty successful renderer response and still appends a visible fallback' {
            Mock Invoke-WorkflowProcess { Set-Content -LiteralPath $Arguments[4] -Value ' ' }
            { Invoke-ResultFixture } | Should -Throw '*empty card*'
            (Get-Content $script:summary -Raw) | Should -Match 'no validated analysis'
        }

        It 'retains completion bytes after a failed backfill without a success-shaped command output' {
            $script:inputs.stage = 'backfill-evidence'
            $script:inputs.platform = 'linux'
            $script:inputs['completion-file'] = Join-Path $TestDrive 'failed-completion.json'
            $bytes = '{"stop_reason":"benchmark_failure"}'
            Set-Content $script:inputs['completion-file'] $bytes -NoNewline
            $script:runtime.job_status = 'failure'
            Invoke-ResultFixture
            $path = (Get-Content $script:output).Substring('evidence-directory='.Length)
            Get-Content (Join-Path $path 'completion.json') -Raw | Should -BeExactly $bytes
            $identity = Get-Content (Join-Path $path 'identity.json') -Raw | ConvertFrom-Json -AsHashtable
            $identity.run_attempt | Should -BeExactly '3'
            $identity.platform | Should -BeExactly 'linux'
            Test-Path $script:summary | Should -BeFalse
        }

        It 'uses normalized untouched success while omitting a newer <execution> completion' -ForEach @(
            @{ execution = 'failure' }, @{ execution = 'cancelled' }, @{ execution = 'skipped' }
        ) {
            $script:inputs.stage = 'backfill'
            $null = Add-CompletionFixture linux 1
            $null = Add-CompletionFixture windows 1
            $script:selection.platforms += @{ platform = 'windows'; execution = $execution; run_attempt = 3; job_id = 30 }
            Invoke-ResultFixture
            $script:request.publication | Should -BeExactly 'not_requested'
            $script:request.result.platforms[0].completion_file | Should -BeLike '*linux-1*'
            $script:request.result.platforms[1].ContainsKey('completion_file') | Should -BeFalse
            $script:request.result.platforms[1].execution | Should -BeExactly $execution
            if ($execution -cne 'skipped') { $script:request.execution | Should -BeExactly $execution }
        }

        It 'never fabricates zero accounting for a missing platform or completion file' {
            $script:inputs.stage = 'backfill'
            Invoke-ResultFixture
            $script:request.result.platforms.Count | Should -Be 1
            $script:request.result.platforms[0].ContainsKey('completion_file') | Should -BeFalse
            ($script:request | ConvertTo-Json -Depth 10) | Should -Not -Match '"counts"|"total"'
            Should -Invoke Invoke-WorkflowProcess -Exactly 1 -ParameterFilter { $Arguments[0] -ceq 'workflow-summary' }
            Should -Invoke Invoke-WorkflowProcess -Exactly 0 -ParameterFilter { $Arguments -contains 'backfill-jobs' }
        }

        It 'retains authenticated job selection before upload without appending a card' {
            $script:inputs.stage = 'backfill-selection'
            $null = New-Item -ItemType Directory -Path $script:artifacts
            Invoke-ResultFixture
            Test-Path (Join-Path $script:artifacts 'jobs.json') | Should -BeTrue
            Test-Path $script:summary | Should -BeFalse
            Should -Invoke Invoke-WorkflowProcess -Exactly 1 -ParameterFilter {
                ($Arguments -join '|') -ceq (@('--repository', 'owner/project', '--instance', 'project',
                    'backfill-jobs', '--run-id', '42', '--expected-platforms', 'linux,windows',
                    '--output-file', (Join-Path $script:artifacts 'jobs.json')) -join '|')
            }
        }

        It 'never renders a leftover selection when the authenticated step failed' {
            $script:inputs.stage = 'backfill'
            $script:steps.selection.outcome = 'failure'
            { Invoke-ResultFixture } | Should -Throw '*selection did not succeed*'
            Should -Invoke Invoke-WorkflowProcess -Exactly 0
            (Get-Content $script:summary -Raw) | Should -Match 'Execution:\*\* failure'
        }

        It 'rejects mismatched artifact <key> rather than selecting older or unrelated evidence' -ForEach @(
            @{ key = 'repository' }, @{ key = 'instance' }, @{ key = 'run_id' }
            @{ key = 'run_attempt' }, @{ key = 'platform' }, @{ key = 'from' }, @{ key = 'to' }
        ) {
            $script:inputs.stage = 'backfill'
            $directory = Add-CompletionFixture
            $path = Join-Path $directory 'identity.json'
            $identity = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
            $identity[$key] = 'wrong'
            $identity | ConvertTo-Json | Set-Content $path
            { Invoke-ResultFixture } | Should -Throw "*mismatched $key*"
            (Get-Content $script:summary -Raw) | Should -Match 'no validated analysis'
        }
    }
}

Describe 'Installation-independent result entry point' {
    BeforeAll {
        $script:entry = Join-Path $PSScriptRoot '..\scripts\Run-WorkflowResults.ps1'
    }
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in @('CBH_RESULT_INPUTS', 'CBH_JOB_STATUS', 'CBH_EVENT_ACTION', 'CBH_FORK',
                'GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_SERVER_URL',
                'GITHUB_EVENT_NAME', 'GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'RUNNER_TEMP')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_REPOSITORY = 'owner/project'
        $env:GITHUB_RUN_ID = '42'
        $env:GITHUB_RUN_ATTEMPT = '3'
        $env:GITHUB_SERVER_URL = 'https://github.com'
        $env:GITHUB_EVENT_NAME = 'pull_request'
        $env:CBH_EVENT_ACTION = 'opened'
        $env:CBH_FORK = 'false'
        $env:CBH_JOB_STATUS = 'success'
        $env:RUNNER_TEMP = $TestDrive
        $env:GITHUB_OUTPUT = Join-Path $TestDrive "$([guid]::NewGuid()).outputs"
        $env:GITHUB_STEP_SUMMARY = Join-Path $TestDrive "$([guid]::NewGuid()).summary"
    }
    AfterEach {
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }

    It 'writes a preparation-failure card without a checkout, state file or executable' {
        $env:CBH_RESULT_INPUTS = @{
            stage = 'terminal'; publish = 'false'; companion = ''
            needs = @{ prepare = @{ result = 'failure'; outputs = @{} } } | ConvertTo-Json -Depth 5
            steps = '{}'
        } | ConvertTo-Json
        & $script:entry
        $card = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        $card | Should -Match 'Execution:\*\* failure'
        $card | Should -Match 'job prepare'
        $card | Should -Match 'GitHub publication:\*\* disabled'
    }

    It 'keeps a policy-skip explanation literal in the no-tool card' {
        $env:CBH_FORK = 'true'
        $env:CBH_EVENT_ACTION = '<unsafe>; $(throw)'
        $env:CBH_RESULT_INPUTS = @{
            stage = 'terminal'; publish = 'true'; companion = ''
            needs = @{ prepare = @{ result = 'skipped'; outputs = @{} } } | ConvertTo-Json -Depth 5
            steps = '{}'
        } | ConvertTo-Json
        & $script:entry
        $card = Get-Content $env:GITHUB_STEP_SUMMARY -Raw
        $card | Should -Match 'Execution:\*\* skipped'
        $card | Should -Match 'fork_pull_request'
        $card | Should -Match '&lt;unsafe&gt;'
        $card | Should -Not -Match '<unsafe>'
    }
}
