#Requires -Version 7.6
# Structural cross-file checks validate real workflow/action relationships, not
# copied documentation wording. Real job execution and platform permission behavior
# remain covered by paired Folo canaries; local evaluation is limited to the
# explicit boolean selection predicates.
Set-StrictMode -Version Latest

BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Tools.psm1') -ErrorAction Stop
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:rootAction = Get-Content (Join-Path $root 'action.yml') -Raw | ConvertFrom-Yaml
    $script:contextAction = Get-Content (Join-Path $root '.github\actions\workflow-tools\action.yml') -Raw | ConvertFrom-Yaml
    $script:manifest = Read-ActionManifest (Join-Path $root 'release.json')

    function Test-SelectionCondition {
        param([string] $Condition, [bool] $Skipped, [bool] $SkipAll, [bool] $Publish)
        # These selection gates use only string equality and boolean conjunction.
        # Evaluate their actual YAML expressions over the producer's wire values;
        # this does not emulate the rest of GitHub's expression language.
        $expression = $Condition.Replace('needs.prepare.outputs.skipped', "'$($Skipped.ToString().ToLowerInvariant())'")
        $expression = $expression.Replace('needs.prepare.outputs.skip-all', "'$($SkipAll.ToString().ToLowerInvariant())'")
        $expression = $expression.Replace('inputs.publish', "`$$($Publish.ToString().ToLowerInvariant())")
        $expression = $expression.Replace('&&', ' -and ').Replace('!=', ' -ne ').Replace('==', ' -eq ')
        if ($expression -match 'needs\.|inputs\.|\|\||\$\{\{') { throw 'Unsupported selection expression.' }
        return & ([scriptblock]::Create($expression))
    }
}

Describe 'Reusable <flow> workflow contracts' -ForEach @(@{ flow = 'history' }, @{ flow = 'pr' }) {
    BeforeAll {
        $script:workflow = Get-Content (Join-Path $root ".github\workflows\$flow.yml") -Raw | ConvertFrom-Yaml
    }

    It 'binds every supplied action input to its actual metadata declaration' {
        foreach ($job in $workflow.jobs.Values) {
            foreach ($step in $job['steps']) {
                $metadata = switch ($step['uses']) {
                    '$/' { $rootAction }
                    '$/.github/actions/workflow-tools' { $contextAction }
                }
                if ($null -eq $metadata) { continue }
                foreach ($key in $step.with.Keys) {
                    $metadata.inputs.ContainsKey($key) | Should -BeTrue -Because "input $key must exist in $($step.uses)"
                }
                foreach ($key in $metadata.inputs.Keys) {
                    if ($metadata.inputs[$key]['required']) {
                        $step.with.ContainsKey($key) | Should -BeTrue -Because "required input $key must be supplied"
                    }
                }
            }
        }
    }

    It 'resolves dependency and step-output references within their real graph' {
        foreach ($job in $workflow.jobs.Values) {
            foreach ($dependency in @($job['needs'])) {
                if ($null -ne $dependency) { $workflow.jobs.ContainsKey($dependency) | Should -BeTrue }
            }
            $steps = @{}
            foreach ($step in $job['steps']) { if ($step['id']) { $steps[$step.id] = $step } }
            $text = $job | ConvertTo-Json -Depth 15
            foreach ($reference in [regex]::Matches($text, 'steps\.([a-zA-Z0-9_-]+)\.outputs\.([a-zA-Z0-9_-]+)')) {
                $id = $reference.Groups[1].Value
                $output = $reference.Groups[2].Value
                $steps.ContainsKey($id) | Should -BeTrue
                $metadata = switch ($steps[$id]['uses']) {
                    '$/' { $rootAction }
                    '$/.github/actions/workflow-tools' { $contextAction }
                }
                if ($null -ne $metadata) { $metadata.outputs.ContainsKey($output) | Should -BeTrue }
            }
        }
    }

    It 'uses supported root commands and forwards the checked disposition from an analysis step' {
        foreach ($job in $workflow.jobs.Values) {
            $steps = @{}
            foreach ($step in $job['steps']) { if ($step['id']) { $steps[$step.id] = $step } }
            foreach ($step in $job['steps'] | Where-Object { $_['uses'] -ceq '$/' }) {
                $command = $step.with.command
                if ($command -match '\$\{\{') {
                    $command | Should -Match '^publish-(comment|issue)-\$\{\{ steps\.([a-zA-Z0-9_-]+)\.outputs\.publication-state \}\}$'
                    $producer = [regex]::Match($command, 'steps\.([a-zA-Z0-9_-]+)\.outputs\.publication-state').Groups[1].Value
                    $steps[$producer].uses | Should -BeExactly '$/'
                    $steps[$producer].with.command | Should -Match '^analyze-'
                    foreach ($state in @('findings', 'clean', 'inconclusive')) {
                        $expanded = $command -replace '\$\{\{.*?\}\}', $state
                        @(Get-RequiredTool $manifest $expanded).Count | Should -BeGreaterThan 0
                    }
                }
                else { @(Get-RequiredTool $manifest $command).Count | Should -BeGreaterThan 0 }
            }
        }
    }

    It 'queues serialized jobs without replacing an older pending invocation' {
        foreach ($job in $workflow.jobs.Values) {
            if ($job['concurrency'] -and -not $job.concurrency['cancel-in-progress']) {
                $job.concurrency.queue | Should -BeExactly 'max'
            }
        }
    }

    It 'preserves workspace and prepared-package collection as distinct root contracts' {
        foreach ($job in $workflow.jobs.Values) {
            foreach ($step in $job['steps'] | Where-Object { $_['uses'] -ceq '$/' -and $_.with.command -ceq 'collect' }) {
                if ($flow -eq 'history') {
                    $step.with.ContainsKey('packages') | Should -BeFalse
                    $step.with.exclude | Should -BeExactly '${{ inputs.exclude }}'
                    continue
                }
                $reference = [regex]::Match($step.with.packages, '^\$\{\{ needs\.([a-zA-Z0-9_-]+)\.outputs\.([a-zA-Z0-9_-]+) \}\}$')
                $reference.Success | Should -BeTrue
                $producer = $reference.Groups[1].Value
                $output = $reference.Groups[2].Value
                $workflow.jobs[$producer].outputs.ContainsKey($output) | Should -BeTrue
                @($job.needs) | Should -Contain $producer
                $step.with.ContainsKey('exclude') | Should -BeFalse
            }
        }
    }

    It 'separates policy skips, empty selections and collection for every publication setting' {
        foreach ($skipped in @($false, $true)) {
            foreach ($skipAll in @($false, $true)) {
                foreach ($publish in @($false, $true)) {
                    Test-SelectionCondition $workflow.jobs.collect.if $skipped $skipAll $publish |
                        Should -Be (-not $skipped -and -not $skipAll)
                    Test-SelectionCondition $workflow.jobs['empty-scope'].if $skipped $skipAll $publish |
                        Should -Be ($publish -and -not $skipped -and $skipAll)
                }
            }
        }
    }

    It 'binds Azure identifiers only to jobs requesting the OIDC capability' {
        foreach ($job in $workflow.jobs.Values) {
            if ($job.permissions['id-token'] -eq 'write') {
                $job.env.AZURE_CLIENT_ID | Should -BeExactly '${{ inputs.azure-client-id }}'
                $job.env.AZURE_TENANT_ID | Should -BeExactly '${{ inputs.azure-tenant-id }}'
            }
            elseif ($job['env']) {
                $job.env.ContainsKey('AZURE_CLIENT_ID') | Should -BeFalse
                $job.env.ContainsKey('AZURE_TENANT_ID') | Should -BeFalse
            }
        }
    }
}
