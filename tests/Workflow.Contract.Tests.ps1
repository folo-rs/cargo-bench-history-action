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
        param([string] $Condition, [bool] $Skipped, [bool] $SkipAll, [bool] $Publish,
            [string] $HasWork = 'true')
        # These selection gates use only string equality and boolean conjunction.
        # Evaluate their actual YAML expressions over the producer's wire values;
        # this does not emulate the rest of GitHub's expression language.
        $expression = $Condition.Replace('needs.prepare.outputs.skipped', "'$($Skipped.ToString().ToLowerInvariant())'")
        $expression = $expression.Replace('needs.prepare.outputs.skip-all', "'$($SkipAll.ToString().ToLowerInvariant())'")
        $expression = $expression.Replace('needs.prepare.outputs.has-work', "'$HasWork'")
        $expression = $expression.Replace('inputs.publish', "`$$($Publish.ToString().ToLowerInvariant())")
        $expression = $expression.Replace('&&', ' -and ').Replace('!=', ' -ne ').Replace('==', ' -eq ')
        if ($expression -match 'needs\.|inputs\.|\|\||\$\{\{') { throw 'Unsupported selection expression.' }
        return & ([scriptblock]::Create($expression))
    }

    function Resolve-ContractExpression {
        param([string] $Expression, [hashtable] $Context)
        # Only path lookup and fallback are needed for the workflow's data wiring.
        foreach ($reference in $Expression -split '\|\|') {
            $value = $Context
            foreach ($part in $reference.Trim().Split('.')) {
                if ($null -eq $value) { break }
                if ($value -isnot [System.Collections.IDictionary]) { throw 'Unsupported workflow expression.' }
                $value = $value[$part]
            }
            if ($value) { return $value }
        }
        return $value
    }

    function Expand-ContractValue {
        param($Value, [hashtable] $Context)
        if ($Value -isnot [string]) { return $Value }
        if ($Value -match '^\$\{\{\s*(.*?)\s*\}\}$') {
            return Resolve-ContractExpression $Matches[1] $Context
        }
        return [regex]::Replace($Value, '\$\{\{\s*(.*?)\s*\}\}', {
                param($match)
                [string] (Resolve-ContractExpression $match.Groups[1].Value $Context)
            })
    }

    function Test-EventSelectionCondition {
        param([string] $Condition, [string] $EventName, [bool] $PullRequest, [bool] $SameRepository, [string] $Action)
        $expression = ($Condition -replace '[\r\n]+', ' ').Replace('github.event_name', "'$EventName'")
        $expression = $expression.Replace('github.event.pull_request.head.repo.full_name',
            "'$(if ($SameRepository) { 'owner/project' } else { 'fork/project' })'")
        $expression = $expression.Replace('github.repository', "'owner/project'")
        $expression = $expression.Replace('github.event.pull_request', "`$$($PullRequest.ToString().ToLowerInvariant())")
        $expression = $expression.Replace('github.event.action', "'$Action'")
        $expression = $expression.Replace('!=', ' -ne ').Replace('==', ' -eq ')
        $expression = $expression.Replace('&&', ' -and ').Replace('||', ' -or ').Replace('!', ' -not ')
        if ($expression -match 'github\.|\$\{\{') { throw 'Unsupported event expression.' }
        return & ([scriptblock]::Create($expression))
    }
}

Describe 'Reusable <flow> workflow contracts' -ForEach @(
    @{ flow = 'history' }, @{ flow = 'pr' }, @{ flow = 'backfill' }
) {
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
            foreach ($reference in [regex]::Matches($text, 'needs\.([a-zA-Z0-9_-]+)\.outputs\.([a-zA-Z0-9_-]+)')) {
                $producer = $reference.Groups[1].Value
                $output = $reference.Groups[2].Value
                @($job.needs) | Should -Contain $producer
                $workflow.jobs[$producer].outputs.ContainsKey($output) | Should -BeTrue
            }
            foreach ($reference in [regex]::Matches($text, 'inputs\.([a-zA-Z0-9_-]+)')) {
                $workflow.on.workflow_call.inputs.ContainsKey($reference.Groups[1].Value) | Should -BeTrue
            }
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

    It 'forwards compiler flags only to measurement root actions without changing job environments' {
        $flags = "-Cllvm-args=-align-all-functions=6`t--cfg='literal; `$value'"
        $workflow.on.workflow_call.inputs.rustflags.type | Should -BeExactly 'string'
        $workflow.on.workflow_call.inputs.rustflags.default | Should -BeExactly $rootAction.inputs.rustflags.default
        $rootAction.inputs.rustflags.default | Should -BeExactly ''
        foreach ($job in $workflow.jobs.Values) {
            foreach ($step in $job.steps) {
                if ($step['uses'] -ceq '$/' -and $step.with.command -cin @('collect', 'backfill')) {
                    Expand-ContractValue $step.with.rustflags @{ inputs = @{ rustflags = $flags } } |
                        Should -BeExactly $flags
                }
                elseif ($step['with']) { $step.with.ContainsKey('rustflags') | Should -BeFalse }
                if ($step['env']) {
                    foreach ($value in $step.env.Values) {
                        # Only direct runtime inputs carry these flags, not preparation
                        # or installer environment assignments.
                        @([regex]::Matches([string] $value, 'inputs\.rustflags')).Count | Should -Be 0
                    }
                }
            }
            if ($job['env']) {
                $job.env.ContainsKey('RUSTFLAGS') | Should -BeFalse
                $job.env.ContainsKey('CARGO_ENCODED_RUSTFLAGS') | Should -BeFalse
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

    It 'accepts a commit budget only for backfill execution, not other flows or preparation' {
        $workflow.on.workflow_call.inputs.ContainsKey('max-commits') | Should -Be ($flow -eq 'backfill')
        foreach ($job in $workflow.jobs.Values) {
            foreach ($step in $job.steps) {
                $isBackfill = $step['uses'] -ceq '$/' -and $step.with.command -ceq 'backfill'
                if ($step['with']) { $step.with.ContainsKey('max-commits') | Should -Be $isBackfill }
                if ($step['env']) {
                    foreach ($value in $step.env.Values) {
                        @([regex]::Matches([string] $value, 'inputs\.max-commits')).Count | Should -Be 0
                    }
                }
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
                    if ($flow -eq 'backfill') {
                        Test-SelectionCondition $workflow.jobs.backfill.if $skipped $skipAll $publish |
                            Should -Be (-not $skipped)
                        continue
                    }
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

Describe 'Historical backfill graph behavior' {
    BeforeAll {
        $script:backfill = Get-Content (Join-Path $root '.github\workflows\backfill.yml') -Raw | ConvertFrom-Yaml
        $script:history = Get-Content (Join-Path $root '.github\workflows\history.yml') -Raw | ConvertFrom-Yaml
        $script:prepare = $backfill.jobs.prepare
        $script:work = $backfill.jobs.backfill
    }

    It 'retains common input defaults without accepting history-only or package-scope controls' {
        $common = @($history.on.workflow_call.inputs.Keys | Where-Object { $_ -notin @('since', 'publish') })
        foreach ($key in $common) {
            $actual = $backfill.on.workflow_call.inputs[$key]
            $expected = $history.on.workflow_call.inputs[$key]
            foreach ($field in @('type', 'required', 'default')) {
                $actual[$field] | Should -Be $expected[$field]
            }
        }
        $backfill.on.workflow_call.inputs.Keys | Sort-Object |
            Should -Be (@($common + @('from', 'to', 'lookback', 'minimum-age', 'max-commits', 'ignore-errors')) | Sort-Object)
        foreach ($key in @('from', 'to', 'lookback', 'minimum-age', 'max-commits')) {
            [bool] $backfill.on.workflow_call.inputs[$key]['required'] | Should -BeFalse
            $backfill.on.workflow_call.inputs[$key].type | Should -BeExactly 'string'
            $backfill.on.workflow_call.inputs[$key].default | Should -BeExactly ''
        }
    }

    It 'preserves the exact commit budget string and leaves omitted input unlimited' {
        [bool] $rootAction.inputs['max-commits']['required'] | Should -BeFalse
        $rootAction.inputs['max-commits'].default | Should -BeExactly ''
        $default = $backfill.on.workflow_call.inputs['max-commits'].default
        $default | Should -BeExactly $rootAction.inputs['max-commits'].default
        $command = @($work.steps | Where-Object { $_['uses'] -ceq '$/' })[0]
        # The largest supported native integer also detects lossy JSON-number conversion.
        foreach ($limit in @($default, '1', [uint64]::MaxValue.ToString())) {
            $actual = Expand-ContractValue $command.with['max-commits'] @{ inputs = @{ 'max-commits' = $limit } }
            $actual | Should -BeOfType ([string])
            $actual | Should -BeExactly $limit
        }
        $bootstrap = @($rootAction.runs.steps | Where-Object { $_['id'] -ceq 'prepare' })[0]
        $bootstrap.env.CBH_INPUTS_JSON | Should -BeExactly '${{ toJSON(inputs) }}'
    }

    It 'hands scheduling choices to preparation but gives execution only a frozen range' -ForEach @(
        @{ from = 'main~2'; to = 'main'; lookback = ''; age = '' }
        @{ from = ''; to = ''; lookback = '14 days ago'; age = 'PT24H' }
        @{ from = ''; to = 'release'; lookback = 'P14D'; age = '0 seconds' }
    ) {
        $inputs = @{ from = $from; to = $to; lookback = $lookback; 'minimum-age' = $age }
        $preparation = @($prepare.steps | Where-Object { $_['id'] -ceq 'prepare' })[0]
        $preparation.env.CBH_FLOW | Should -BeExactly 'backfill'
        foreach ($binding in @(
                @{ environment = 'CBH_FROM'; input = 'from' }
                @{ environment = 'CBH_TO'; input = 'to' }
                @{ environment = 'CBH_LOOKBACK'; input = 'lookback' }
                @{ environment = 'CBH_MINIMUM_AGE'; input = 'minimum-age' }
            )) {
            Expand-ContractValue $preparation.env[$binding.environment] @{ inputs = $inputs } |
                Should -BeExactly $inputs[$binding.input]
        }
        $command = @($work.steps | Where-Object { $_['uses'] -ceq '$/' })[0]
        foreach ($key in @('lookback', 'minimum-age')) {
            $command.with.ContainsKey($key) | Should -BeFalse
            $rootAction.inputs.ContainsKey($key) | Should -BeFalse
        }
        $frozen = @{ from = 'a' * 40; to = 'b' * 40 }
        foreach ($key in @('from', 'to')) {
            Expand-ContractValue $command.with[$key] @{
                inputs = $inputs; needs = @{ prepare = @{ outputs = $frozen } }
            } | Should -BeExactly $frozen[$key]
        }
    }

    It 'starts no matrix for no-work, fork skips or absent work-selection output' {
        foreach ($skipped in @($false, $true)) {
            foreach ($hasWork in @('true', 'false', '', 'invalid')) {
                Test-SelectionCondition $work.if $skipped $false $false -HasWork $hasWork |
                    Should -Be (-not $skipped -and $hasWork -ceq 'true')
            }
        }
        $missingSkip = $work.if.Replace('needs.prepare.outputs.skipped', "''")
        Test-SelectionCondition $missingSkip $false $false $false -HasWork true | Should -BeFalse
    }

    It 'selects the real calling head and rejects fork, target and closed PR work' -ForEach @(
        @{ event = 'push'; pr = $false; same = $true; action = ''; selected = $true }
        @{ event = 'schedule'; pr = $false; same = $true; action = ''; selected = $true }
        @{ event = 'workflow_dispatch'; pr = $false; same = $true; action = ''; selected = $true }
        @{ event = 'pull_request'; pr = $true; same = $true; action = 'synchronize'; selected = $true }
        @{ event = 'pull_request'; pr = $true; same = $false; action = 'synchronize'; selected = $false }
        @{ event = 'pull_request'; pr = $true; same = $true; action = 'closed'; selected = $false }
        @{ event = 'pull_request_target'; pr = $true; same = $true; action = 'opened'; selected = $false }
        @{ event = 'pull_request_target'; pr = $true; same = $false; action = 'opened'; selected = $false }
    ) {
        Test-EventSelectionCondition $prepare.if $event $pr $same $action | Should -Be $selected
        Test-EventSelectionCondition $history.jobs.prepare.if $event $pr $same $action | Should -Be $selected
        $eventContext = @{ github = @{ sha = 'a' * 40; event = @{} } }
        if ($pr) { $eventContext.github.event.pull_request = @{ head = @{ sha = 'b' * 40 } } }
        $contextStep = @($prepare.steps | Where-Object { $_['id'] -ceq 'context' })[0]
        Expand-ContractValue $contextStep.with.head $eventContext |
            Should -BeExactly $(if ($pr) { 'b' * 40 } else { 'a' * 40 })
    }

    It 'forwards frozen ranges rather than live caller refs and keeps invocation-owned paths' {
        $resolved = @{ from = 'a' * 40; to = 'b' * 40; skipped = 'false' }
        $paths = @{
            'source-path' = 'invocation/tool-sources'
            'working-directory' = 'measurement/nested'
            config = 'invocation/nested/shared.toml'
        }
        $values = @{
            inputs = @{ from = 'mutable-from'; to = 'mutable-to'; 'install-method' = 'path' }
            needs = @{ prepare = @{ outputs = $resolved } }
            steps = @{ context = @{ outputs = $paths } }
        }
        $contextStep = @($work.steps | Where-Object { $_['id'] -ceq 'context' })[0]
        $command = @($work.steps | Where-Object { $_['uses'] -ceq '$/' })[0]
        Expand-ContractValue $contextStep.with.head $values | Should -BeExactly $resolved.to
        foreach ($key in @('from', 'to')) {
            Expand-ContractValue $command.with[$key] $values | Should -BeExactly $resolved[$key]
        }
        foreach ($key in $paths.Keys) {
            Expand-ContractValue $command.with[$key] $values | Should -BeExactly $paths[$key]
        }
        $contextStep.with['benchmark-setup'] | Should -BeExactly 'true'
        $checkouts = @($contextAction.runs.steps | Where-Object { $_['uses'] -like 'actions/checkout@*' })
        foreach ($checkout in $checkouts) { $checkout.with['fetch-depth'] | Should -Be 0 }
        $checkoutInputs = @{ inputs = @{ head = $resolved.to }; github = @{ sha = 'c' * 40 } }
        $measurementCheckout = @($checkouts | Where-Object { $_.with.ContainsKey('path') })[0]
        Expand-ContractValue $measurementCheckout.with.ref $checkoutInputs | Should -BeExactly $resolved.to
        $invocationCheckout = @($checkouts | Where-Object { -not $_.with.ContainsKey('path') })[0]
        Expand-ContractValue $invocationCheckout.with.ref $checkoutInputs | Should -BeExactly $checkoutInputs.github.sha
    }

    It 'queues repeated events and aliases without a workflow waiting on its own work queue' {
        $values = @{
            github = @{ repository = 'owner/project'; sha = 'a' * 40; event_name = 'push'; run_id = '1' }
            inputs = @{ 'working-directory' = '.'; config = '.cargo/bench_history.toml' }
            needs = @{ prepare = @{ outputs = @{ instance = 'canonical-project' } } }
            matrix = @{ platform = 'ubuntu-latest' }
        }
        $runGroup = Expand-ContractValue $backfill.concurrency.group $values
        $workGroup = Expand-ContractValue $work.concurrency.group $values
        $runGroup | Should -Not -BeExactly $workGroup
        $values.github.sha = 'b' * 40
        $values.github.event_name = 'workflow_dispatch'
        $values.github.run_id = '2'
        Expand-ContractValue $backfill.concurrency.group $values | Should -BeExactly $runGroup
        Expand-ContractValue $work.concurrency.group $values | Should -BeExactly $workGroup
        $values.inputs.config = 'alias.toml'
        Expand-ContractValue $work.concurrency.group $values | Should -BeExactly $workGroup
        $values.matrix.platform = 'windows-latest'
        Expand-ContractValue $work.concurrency.group $values | Should -Not -BeExactly $workGroup
        $values.matrix.platform = 'ubuntu-latest'
        $values.needs.prepare.outputs.instance = 'another-project'
        Expand-ContractValue $work.concurrency.group $values | Should -Not -BeExactly $workGroup
        foreach ($queue in @($backfill.concurrency, $work.concurrency)) {
            $queue['cancel-in-progress'] | Should -BeFalse
            $queue.queue | Should -BeExactly 'max'
        }
    }

    It 'keeps job failures visible independently of the per-commit error policy' {
        $defaults = @{}
        foreach ($key in $backfill.on.workflow_call.inputs.Keys) {
            $defaults[$key] = $backfill.on.workflow_call.inputs[$key]['default']
        }
        $command = @($work.steps | Where-Object { $_['uses'] -ceq '$/' })[0]
        $backfill.on.workflow_call.inputs['ignore-errors'].type | Should -BeExactly 'boolean'
        Expand-ContractValue $command.with['ignore-errors'] @{ inputs = $defaults } | Should -BeFalse
        foreach ($ignoreErrors in @($false, $true)) {
            $values = @{ inputs = @{ 'ignore-errors' = $ignoreErrors } }
            Expand-ContractValue $command.with['ignore-errors'] $values | Should -Be $ignoreErrors
        }
        foreach ($job in $backfill.jobs.Values) {
            $job.ContainsKey('continue-on-error') | Should -BeFalse
            foreach ($step in $job.steps) {
                $step.ContainsKey('continue-on-error') | Should -BeFalse
            }
        }
        foreach ($step in $rootAction.runs.steps) {
            $step.ContainsKey('continue-on-error') | Should -BeFalse
        }
        $work['timeout-minutes'] | Should -Be $history.jobs.collect['timeout-minutes']
        $work.strategy['fail-fast'] | Should -BeFalse
    }

    It 'exposes only a preparation and historical collection graph without reporting contracts' {
        $backfill.jobs.Keys | Sort-Object | Should -Be @('backfill', 'prepare')
        $backfill.on.workflow_call.ContainsKey('outputs') | Should -BeFalse
        foreach ($job in $backfill.jobs.Values) {
            foreach ($permission in $job.permissions.Keys) {
                $permission | Should -BeIn @('contents', 'id-token')
            }
            foreach ($step in $job.steps) {
                if ($step['uses']) {
                    $step.uses | Should -BeIn @('$/', '$/.github/actions/workflow-tools')
                }
            }
        }
        $commands = @($work.steps | Where-Object { $_['uses'] -ceq '$/' })
        $commands.Count | Should -Be 1
        $commands[0].with.command | Should -BeExactly 'backfill'
        $commands[0].with['on-existing'] | Should -BeExactly 'skip'
        $commands[0].with.ContainsKey('packages') | Should -BeFalse
        $commands[0].with.ContainsKey('context') | Should -BeFalse
        $prepare.outputs.Keys | Sort-Object |
            Should -Be @('expected-platforms', 'from', 'has-work', 'instance', 'matrix', 'skipped', 'to')
    }
}

Describe 'Same-runner backfill canary wiring in <file>' -ForEach @(
    @{ file = 'test'; jobName = 'path-smoke' }
    @{ file = 'install-tools'; jobName = 'published' }
) {
    BeforeAll {
        $script:canaryWorkflow = Get-Content (Join-Path $root ".github\workflows\$file.yml") -Raw | ConvertFrom-Yaml
        $script:canaryJob = $canaryWorkflow.jobs[$jobName]
        $script:canarySteps = @{}
        foreach ($step in $canaryJob.steps) {
            if ($step['id']) { $canarySteps[$step.id] = $step }
        }
    }

    It 'backfills between collection and analysis without another root-action installation' {
        $ids = @($canaryJob.steps | ForEach-Object { $_['id'] })
        [array]::IndexOf($ids, 'backfill') | Should -BeGreaterThan ([array]::IndexOf($ids, 'collect'))
        [array]::IndexOf($ids, 'backfill') | Should -BeLessThan ([array]::IndexOf($ids, 'analyze'))
        $actions = @($canaryJob.steps | Where-Object { $_['uses'] -ceq './' })
        @($actions | ForEach-Object { $_.with.command }) | Should -Be @('collect', 'analyze-history')
        $canarySteps.backfill.ContainsKey('continue-on-error') | Should -BeFalse
        $canarySteps.backfill.env.CANARY_WORKSPACE | Should -BeExactly $canarySteps.collect.with['working-directory']
        $canarySteps.backfill.env.CANARY_STORE | Should -BeExactly $canarySteps.collect.with['local-path']
        $reference = [regex]::Match($canarySteps.backfill.env.CANARY_KEY, 'steps\.([^.]+)\.outputs\.([^. ]+)')
        $canarySteps.ContainsKey($reference.Groups[1].Value) | Should -BeTrue
        $rootAction.outputs.ContainsKey($reference.Groups[2].Value) | Should -BeTrue
    }

    It 'runs no direct core backfill when ordinary collection was policy-skipped' {
        foreach ($skipped in @($true, $false)) {
            $condition = $canarySteps.backfill.if.Replace('steps.collect.outputs.skipped', 'needs.prepare.outputs.skipped')
            Test-SelectionCondition $condition $skipped $false $false | Should -Be (-not $skipped)
        }
    }
}
