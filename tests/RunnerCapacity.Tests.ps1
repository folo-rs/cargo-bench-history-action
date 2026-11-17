#Requires -Version 7.6
BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Assert-RunnerCapacity.ps1')
    $script:manifestPath = Join-Path $PSScriptRoot '..\release.json'
    $script:manifestJson = Get-Content -LiteralPath $manifestPath -Raw
    $script:manifest = $manifestJson | ConvertFrom-Json -AsHashtable

    function New-CapacityJob {
        param([string] $Name, [string] $Runner = 'ubuntu-latest')
        @{
            id = ++$script:nextId; name = $Name; run_id = 42; run_attempt = 3
            head_sha = 'a' * 40; status = 'completed'; conclusion = 'success'
            steps = @(@{ name = 'Checkout'; conclusion = 'success' })
            runner_id = 123; labels = @($Runner)
        }
    }

    function Set-CapacityUnavailable {
        param($Job)
        $Job.conclusion = 'cancelled'
        $Job.steps = @()
        $Job.runner_id = 0
    }

    function Invoke-FixtureCapacity {
        [CmdletBinding()]
        param([string] $Scope = 'installation', [string] $Runner)
        Assert-RunnerCapacity -Scope $Scope -Runner $Runner -Repository owner/repo `
            -RunId 42 -RunAttempt 3 -ExpectedHead ('a' * 40) -ManifestPath $manifestPath
    }

    Describe 'Capacity-aware workflow boundaries' {
        BeforeAll {
            Import-Module powershell-yaml -RequiredVersion 0.4.12
            $root = Split-Path $PSScriptRoot -Parent
            $script:validationWorkflow = Get-Content (Join-Path $root '.github\workflows\test.yml') -Raw | ConvertFrom-Yaml
            $script:releaseWorkflow = Get-Content (Join-Path $root '.github\workflows\release.yml') -Raw | ConvertFrom-Yaml
        }

        It 'keeps test and publication installation gates on the same authenticated verifier' {
            foreach ($workflow in @($validationWorkflow, $releaseWorkflow)) {
                $gate = $workflow.jobs['install-tools']
                $gate.needs | Should -Be 'availability'
                $gate.if | Should -Match '^always\(\)'
                $gate.permissions.actions | Should -Be 'read'
                $gate.permissions.checks | Should -Be 'read'
                $step = @($gate.steps | Where-Object { $_['run'] })[0]
                $step.run | Should -Match 'Assert-RunnerCapacity\.ps1 -Scope installation'
                $step.env.GH_TOKEN | Should -BeExactly '${{ github.token }}'
            }
            $releaseWorkflow.jobs.publish.needs | Should -Be 'install-tools'
            $releaseWorkflow.jobs.publish.if | Should -Match "always\(\) && needs.install-tools.result == 'success'"
        }

        It 'does not skip other platforms analysis when the collection matrix contains a capacity cancellation' {
            $smoke = $validationWorkflow.jobs['path-smoke']
            $smoke.if | Should -BeExactly "always() && needs.setup.result == 'success'"
            $precheck = @($smoke.steps | Where-Object { $_['id'] -ceq 'collection-status' })[0]
            $precheck.run | Should -Match 'Assert-RunnerCapacity\.ps1 -Scope collection -Runner'
            $precheck.env.CANARY_RUNNER | Should -BeExactly '${{ matrix.runner }}'
            foreach ($step in @($smoke.steps | Select-Object -Skip 2)) {
                if ($step['id'] -cin @('upload-reports', 'upload-reports-retry', 'require-report-upload')) {
                    $step.if | Should -Match "steps.analyze.outcome == 'success'"
                } else {
                    $step.if | Should -Match "steps.collection-status.outputs.unavailable == 'false'"
                }
            }
            $gate = $validationWorkflow.jobs['macos-capacity']
            $gate.if | Should -Be 'always()'
            @($gate.needs) | Should -Be @('setup', 'pester', 'path-collect', 'path-smoke')
            @($gate.steps | Where-Object { $_['run'] })[0].run | Should -Match '-Scope validation'
        }
    }
}

Describe 'Narrow hosted macOS capacity acceptance' {
    BeforeEach {
        $script:nextId = 100
        $script:jobs = @(
            (New-CapacityJob 'availability / matrix')
            (New-CapacityJob 'setup')
        )
        foreach ($target in $manifest.targets) {
            foreach ($method in @('install', 'binstall')) {
                $script:jobs += New-CapacityJob "availability / $method ($($target.rust_target))" $target.runner
            }
            $script:jobs += New-CapacityJob "Pester ($($target.runner))" $target.runner
            $script:jobs += New-CapacityJob "cbh-collect:action-canary-$($target.runner):$($target.runner)" $target.runner
            $script:jobs += New-CapacityJob "Source path ($($target.runner))" $target.runner
        }
        $script:mac = @($script:jobs | Where-Object name -CEQ 'availability / install (aarch64-apple-darwin)')[0]
        $script:annotations = @(@{
            annotation_level = 'failure'
            message = 'The job was not acquired by Runner of type hosted even after multiple attempts'
        })
        $script:run = @{ id = 42; head_sha = 'a' * 40; run_attempt = 3; path = '.github/workflows/test.yml' }
        $script:remoteJson = $manifestJson
        Mock Invoke-CapacityApi {
            param($Endpoint)
            switch -Regex ($Endpoint) {
                '/jobs\?' { return @{ jobs = $script:jobs } }
                '/annotations\?' { return ,$script:annotations }
                '/contents/' {
                    return @{ encoding = 'base64'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:remoteJson)) }
                }
                '/actions/runs/42$' { return $script:run }
                default { throw "Unexpected fixture endpoint: $Endpoint" }
            }
        }
    }

    It 'accepts successful installations and retains untouched successes from older attempts' {
        $script:jobs[0].run_attempt = 1
        (Invoke-FixtureCapacity).Unavailable.Count | Should -Be 0
        Should -Invoke Invoke-CapacityApi -Times 1 -ParameterFilter {
            $Endpoint -clike '*/jobs?filter=all&per_page=20' -and $Paginate
        }
        Should -Invoke Invoke-CapacityApi -Times 0 -ParameterFilter { $Endpoint -like '*/annotations?*' }
    }

    It 'accepts only annotated no-step macOS capacity cancellation, explicitly without evidence' {
        Set-CapacityUnavailable $script:mac
        $warnings = @()
        $result = Invoke-FixtureCapacity -WarningVariable warnings -WarningAction SilentlyContinue
        $result.Unavailable | Should -Be @($script:mac.name)
        ($warnings -join "`n") | Should -Match 'NOT RUN:.*not passing installation or test evidence'
    }

    It 'does not reuse an older success after a failed retry' {
        $older = $script:mac.Clone()
        $older.run_attempt = 2
        $older.id = 99
        $script:jobs += $older
        $script:mac.conclusion = 'failure'
        { Invoke-FixtureCapacity } | Should -Throw '*Required job did not pass*'
    }

    It 'fails closed for missing or ambiguous newest matrix evidence' -ForEach @('missing', 'duplicate') {
        if ($_ -eq 'missing') { $script:jobs = @($script:jobs | Where-Object id -NE $script:mac.id) }
        else { $script:jobs += $script:mac.Clone() }
        { Invoke-FixtureCapacity } | Should -Throw
    }

    It 'does not exempt a job that started, failed, was skipped or lacks reliable capacity identity' -ForEach @(
        'failed', 'skipped', 'started', 'missing-steps', 'runner-assigned', 'wrong-label', 'pending'
    ) {
        Set-CapacityUnavailable $script:mac
        switch ($_) {
            'failed' { $script:mac.conclusion = 'failure' }
            'skipped' { $script:mac.conclusion = 'skipped' }
            'started' { $script:mac.steps = @(@{ name = 'Checkout'; conclusion = 'cancelled' }) }
            'missing-steps' { $script:mac.Remove('steps') }
            'runner-assigned' { $script:mac.runner_id = 1 }
            'wrong-label' { $script:mac.labels = @('self-hosted') }
            'pending' { $script:mac.status = 'queued' }
        }
        { Invoke-FixtureCapacity } | Should -Throw
    }

    It 'does not exempt Linux or Windows even with identical acquisition annotations' -ForEach @(
        'x86_64-unknown-linux-gnu', 'x86_64-pc-windows-msvc'
    ) {
        $job = @($script:jobs | Where-Object name -CEQ "availability / install ($_)")[0]
        Set-CapacityUnavailable $job
        $job.labels = @('macos-latest')
        { Invoke-FixtureCapacity } | Should -Throw '*Required job did not pass*'
    }

    It 'rejects absent, approximate or mixed failure annotations' -ForEach @('absent', 'approximate', 'mixed') {
        Set-CapacityUnavailable $script:mac
        switch ($_) {
            'absent' { $script:annotations = @() }
            'approximate' { $script:annotations[0].message += '.' }
            'mixed' { $script:annotations += @{ annotation_level = 'failure'; message = 'Fixture genuine failure' } }
        }
        { Invoke-FixtureCapacity } | Should -Throw '*No unambiguous hosted macOS acquisition evidence*'
    }

    It 'rejects job/run/head/manifest disagreement rather than using another revision' -ForEach @(
        'job-head', 'job-run', 'job-attempt', 'run-head', 'run-attempt', 'manifest', 'workflow'
    ) {
        switch ($_) {
            'job-head' { $script:mac.head_sha = 'b' * 40 }
            'job-run' { $script:mac.run_id = 43 }
            'job-attempt' { $script:mac.run_attempt = 4 }
            'run-head' { $script:run.head_sha = 'b' * 40 }
            'run-attempt' { $script:run.run_attempt = 4 }
            'manifest' { $script:remoteJson = $manifestJson.Replace('"schema_version": 1', '"schema_version": 2') }
            'workflow' { $script:run.path = '.github/workflows/history.yml' }
        }
        { Invoke-FixtureCapacity } | Should -Throw
    }

    It 'propagates unavailable API evidence as an error' {
        Mock Invoke-CapacityApi { throw 'Fixture unavailable API' }
        { Invoke-FixtureCapacity } | Should -Throw '*Fixture unavailable API*'
    }

    It 'checks all source/test jobs and never treats arbitrary dependent skips as capacity evidence' {
        $collector = @($script:jobs | Where-Object name -CEQ 'cbh-collect:action-canary-macos-latest:macos-latest')[0]
        Set-CapacityUnavailable $collector
        (Invoke-FixtureCapacity -Scope collection -Runner macos-latest).Unavailable | Should -Be @($collector.name)
        (Invoke-FixtureCapacity -Scope collection -Runner ubuntu-latest).Unavailable.Count | Should -Be 0
        (Invoke-FixtureCapacity -Scope validation).Unavailable | Should -Be @($collector.name)
        $source = @($script:jobs | Where-Object name -CEQ 'Source path (ubuntu-latest)')[0]
        $source.conclusion = 'skipped'
        { Invoke-FixtureCapacity -Scope validation } | Should -Throw '*Required job did not pass*'
    }

    It 'checks release publication with the same exact installation contract' {
        $script:run.path = '.github/workflows/release.yml'
        Set-CapacityUnavailable $script:mac
        (Invoke-FixtureCapacity).Unavailable | Should -Be @($script:mac.name)
        { Invoke-FixtureCapacity -Scope validation } | Should -Throw '*workflow does not match*'
    }
}
