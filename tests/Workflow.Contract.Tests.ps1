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

    function Test-CanaryUploadCondition {
        param([string] $Condition, [bool] $Cancelled, [string] $AnalysisOutcome,
            [string] $Skipped, [string] $UploadOutcome)
        # As with the selection helpers above, evaluate only the actual boolean
        # predicates, not GitHub's job execution or implicit status handling.
        $expression = $Condition.Trim() -replace '^\$\{\{\s*|\s*\}\}$', ''
        $expression = $expression.Replace('cancelled()', "`$$($Cancelled.ToString().ToLowerInvariant())")
        $expression = $expression.Replace('steps.analyze.outcome', "'$AnalysisOutcome'")
        $expression = $expression.Replace('steps.analyze.outputs.skipped', "'$Skipped'")
        $expression = $expression.Replace('steps.upload-reports.outcome', "'$UploadOutcome'")
        $expression = $expression.Replace('!=', ' -ne ').Replace('==', ' -eq ')
        $expression = $expression.Replace('&&', ' -and ').Replace('!', ' -not ')
        if ($expression -match 'steps\.|\(\)|\$\{\{|\|\|') { throw 'Unsupported canary upload expression.' }
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

Describe 'Scoped <flow> collection handoff' -ForEach @(
    @{ flow = 'history'; prefix = 'bench-history' }
    @{ flow = 'pr'; prefix = 'pr-bench-history' }
) {
    BeforeAll {
        $script:scopedWorkflow = Get-Content (Join-Path $root ".github\workflows\$flow.yml") -Raw | ConvertFrom-Yaml
        $script:collectionJob = $scopedWorkflow.jobs.collect
        $script:analysisJob = $scopedWorkflow.jobs.analyze
        $script:collector = @($collectionJob.steps | Where-Object { $_['id'] -ceq 'collect' })[0]
    }

    It 'selects fresh execution snapshots without replacing already-stored history' {
        $collector.with['collection-snapshot'] | Should -BeExactly 'true'
        $collector.with['on-existing'] | Should -BeExactly 'skip'
        $rootAction.inputs.ContainsKey('collection-snapshot') | Should -BeTrue
        $rootAction.outputs['collection-file'].value | Should -BeExactly '${{ steps.invoke.outputs.collection-file }}'
        $collectionJob.name | Should -BeExactly '${{ needs.prepare.outputs.collection-job-prefix }}:${{ matrix.platform }}'
        $collectionJob.strategy['fail-fast'] | Should -BeFalse
    }

    It 'passes the snapshot to receipt creation before uploading one self-contained file' {
        $receipt = @($collectionJob.steps | Where-Object { $_['env'] -and $_.env.ContainsKey('CBH_COLLECTION_FILE') })
        $receipt.Count | Should -Be 1
        $receipt[0].env.CBH_COLLECTION_FILE | Should -BeExactly '${{ steps.collect.outputs.collection-file }}'
        $receipt[0].env.ContainsKey('CBH_MACHINE_KEY') | Should -BeFalse
        $receipt[0].ContainsKey('continue-on-error') | Should -BeFalse
        $uploads = @($collectionJob.steps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' })
        $uploads.Count | Should -Be 1
        $uploads[0].with.path | Should -BeExactly '${{ steps.context.outputs.receipt-file }}'
        $uploads[0].with['if-no-files-found'] | Should -BeExactly 'error'
        $uploads[0].with.ContainsKey('overwrite') | Should -BeFalse
        [array]::IndexOf($collectionJob.steps, $uploads[0]) |
            Should -BeGreaterThan ([array]::IndexOf($collectionJob.steps, $receipt[0]))
    }

    It 'downloads all attempts for this flow from the authenticated run-wide view' {
        $upload = @($collectionJob.steps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' })[0]
        $download = @($analysisJob.steps | Where-Object { $_['uses'] -like 'actions/download-artifact@*' })[0]
        $download.with.pattern | Should -BeExactly ("$prefix-collection-" + '${{ needs.prepare.outputs.instance }}-*')
        $download.with['github-token'] | Should -BeExactly '${{ github.token }}'
        $download.with['run-id'] | Should -BeExactly '${{ github.run_id }}'
        $download.with.repository | Should -BeExactly '${{ github.repository }}'
        $download.with.ContainsKey('merge-multiple') | Should -BeFalse
        foreach ($attempt in @(1, 2)) {
            $values = @{
                needs = @{ prepare = @{ outputs = @{ instance = 'project' } } }
                matrix = @{ platform = 'windows-latest' }
                github = @{ run_attempt = $attempt }
            }
            $artifact = Expand-ContractValue $upload.with.name $values
            $pattern = Expand-ContractValue $download.with.pattern $values
            $artifact | Should -BeLike $pattern
            "$prefix-collection-another-project-windows-latest-$attempt" | Should -Not -BeLike $pattern
        }
    }

    It 'analyzes only reconciled snapshot output while retaining explicit platform coverage' {
        $analysis = @($analysisJob.steps | Where-Object { $_['id'] -ceq 'analyze' })[0]
        $analysis.with['current-collections'] | Should -BeExactly '${{ steps.collection.outputs.current-collections }}'
        $analysis.with.ContainsKey('machine-keys') | Should -BeFalse
        $analysis.with['expected-platforms'] | Should -BeExactly '${{ needs.prepare.outputs.expected-platforms }}'
        $analysis.with['completed-platforms'] | Should -BeExactly '${{ steps.collection.outputs.completed-platforms }}'
        $analysisJob.permissions['actions'] | Should -BeExactly 'read'
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

Describe 'Canary workflow wiring in <file>' -ForEach @(
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
        $script:canaryCollectionJob = if ($file -eq 'test') { $canaryWorkflow.jobs['path-collect'] } else { $canaryJob }
        $script:canaryCollectionSteps = @{}
        foreach ($step in $canaryCollectionJob.steps) {
            if ($step['id']) { $canaryCollectionSteps[$step.id] = $step }
        }
    }

    It 'pins the Rust bootstrap implementation while retaining the rolling stable compiler' {
        $bootstrap = @($canaryJob.steps | Where-Object { $_['uses'] -clike 'dtolnay/rust-toolchain@*' })
        $bootstrap.Count | Should -Be 1
        $bootstrap[0].uses | Should -Match '^dtolnay/rust-toolchain@[0-9a-f]{40}$'
        $bootstrap[0].with.toolchain | Should -BeExactly 'stable'
    }

    It 'backfills between collection and analysis without another root-action installation' {
        $steps = if ($file -eq 'test') { @($canaryCollectionJob.steps) + @($canaryJob.steps) } else { $canaryJob.steps }
        $ids = @($steps | ForEach-Object { $_['id'] })
        [array]::IndexOf($ids, 'backfill') | Should -BeGreaterThan ([array]::IndexOf($ids, 'collect'))
        [array]::IndexOf($ids, 'backfill') | Should -BeLessThan ([array]::IndexOf($ids, 'analyze'))
        $actions = @($steps | Where-Object { $_['uses'] -ceq './' })
        @($actions | ForEach-Object { $_.with.command }) | Should -Be @('collect', 'analyze-history')
        $canaryCollectionSteps.backfill.ContainsKey('continue-on-error') | Should -BeFalse
        $canaryCollectionSteps.backfill.env.CANARY_WORKSPACE | Should -BeExactly $canaryCollectionSteps.collect.with['working-directory']
        $canaryCollectionSteps.backfill.env.CANARY_STORE | Should -BeExactly $canaryCollectionSteps.collect.with['local-path']
        $reference = [regex]::Match($canaryCollectionSteps.backfill.env.CANARY_KEY, 'steps\.([^.]+)\.outputs\.([^. ]+)')
        $canaryCollectionSteps.ContainsKey($reference.Groups[1].Value) | Should -BeTrue
        $rootAction.outputs.ContainsKey($reference.Groups[2].Value) | Should -BeTrue
        if ($file -eq 'test') { $canaryJob.needs | Should -Contain 'path-collect' }
    }

    It 'runs no direct core backfill when ordinary collection was policy-skipped' {
        foreach ($skipped in @($true, $false)) {
            $condition = $canaryCollectionSteps.backfill.if.Replace('steps.collect.outputs.skipped', 'needs.prepare.outputs.skipped')
            Test-SelectionCondition $condition $skipped $false $false | Should -Be (-not $skipped)
        }
    }

    It 'uses exact current snapshots with ordinary stored history available for comparison' {
        $canaryCollectionSteps.collect.with['collection-snapshot'] | Should -BeExactly 'true'
        $canaryCollectionSteps.collect.with['on-existing'] | Should -BeExactly 'skip'
        $canarySteps.analyze.with.ContainsKey('machine-keys') | Should -BeFalse
        $canarySteps.analyze.with['current-collections'] | Should -Not -BeNullOrEmpty
        $canarySteps.analyze.with['local-path'] | Should -BeExactly '${{ steps.fixture.outputs.store }}'
        $canarySteps.analyze.with.since | Should -BeExactly '2000-01-01'
    }

    Context 'Bounded report upload retries' {
        BeforeAll {
            $script:upload = $canarySteps['upload-reports']
            $script:retry = $canarySteps['upload-reports-retry']
            $script:requireUpload = $canarySteps['require-report-upload']
        }

        It 'retries only the official uploader with distinct names and identical report paths' {
            $uploads = @($canaryJob.steps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' })
            @($uploads.id) | Should -Be @('upload-reports', 'upload-reports-retry')
            $retry.uses | Should -BeExactly $upload.uses
            $retry.with.name | Should -BeExactly "$($upload.with.name)-retry"
            $retry.with.path | Should -BeExactly $upload.with.path
            foreach ($attempt in $uploads) {
                $attempt.with['if-no-files-found'] | Should -BeExactly 'error'
                $attempt.with.ContainsKey('overwrite') | Should -BeFalse
                @($attempt.with.path.Trim() -split '\r?\n') | Should -Be @(
                    '${{ steps.analyze.outputs.report-markdown }}'
                    '${{ steps.analyze.outputs.report-json }}'
                    '${{ steps.analyze.outputs.report-summary }}'
                )
            }
        }

        It 'permits recovery only for the initial upload without suppressing other failures' {
            $canaryJob.ContainsKey('continue-on-error') | Should -BeFalse
            $upload['continue-on-error'] | Should -BeTrue
            foreach ($step in $canaryJob.steps) {
                if ($step['id'] -ceq $upload.id) { continue }
                $step.ContainsKey('continue-on-error') | Should -BeFalse
            }
            $ids = @($canaryJob.steps | ForEach-Object { $_['id'] })
            [array]::IndexOf($ids, $retry.id) | Should -BeGreaterThan ([array]::IndexOf($ids, $upload.id))
            [array]::IndexOf($ids, $requireUpload.id) | Should -BeGreaterThan ([array]::IndexOf($ids, $retry.id))
        }

        It 'preserves analysis, policy-skip and cancellation guards through both attempts and the assertion' {
            foreach ($step in @($upload, $retry, $requireUpload)) {
                # An explicit status function prevents GitHub's implicit success()
                # from hiding the diagnostic upload after report assertions fail.
                $step.if | Should -Match '!cancelled\(\)'
            }
            foreach ($cancelled in @($false, $true)) {
                foreach ($analysisOutcome in @('success', 'failure', 'skipped', 'cancelled')) {
                    foreach ($skipped in @('', 'false', 'true')) {
                        foreach ($uploadOutcome in @('success', 'failure', 'skipped', 'cancelled')) {
                            $eligible = -not $cancelled -and $analysisOutcome -eq 'success' -and $skipped -ne 'true'
                            Test-CanaryUploadCondition $upload.if $cancelled $analysisOutcome $skipped $uploadOutcome |
                                Should -Be $eligible
                            Test-CanaryUploadCondition $requireUpload.if $cancelled $analysisOutcome $skipped $uploadOutcome |
                                Should -Be $eligible
                            Test-CanaryUploadCondition $retry.if $cancelled $analysisOutcome $skipped $uploadOutcome |
                                Should -Be ($eligible -and $uploadOutcome -eq 'failure')
                        }
                    }
                }
            }
        }

        Context 'Required upload outcome' {
            BeforeEach {
                $script:savedUploadEnvironment = @{}
                foreach ($key in $requireUpload.env.Keys) {
                    $savedUploadEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
                }
            }

            AfterEach {
                foreach ($key in $savedUploadEnvironment.Keys) {
                    [Environment]::SetEnvironmentVariable($key, $savedUploadEnvironment[$key])
                }
            }

            It 'checks actual outcomes for <initial> then <retried>' -TestCases @(
                @{ initial = 'success'; retried = 'skipped'; accepted = $true; recovered = $false }
                @{ initial = 'failure'; retried = 'success'; accepted = $true; recovered = $true }
                @{ initial = 'failure'; retried = 'failure'; accepted = $false; recovered = $false }
                @{ initial = 'failure'; retried = 'skipped'; accepted = $false; recovered = $false }
                @{ initial = 'failure'; retried = 'cancelled'; accepted = $false; recovered = $false }
                @{ initial = 'skipped'; retried = 'skipped'; accepted = $false; recovered = $false }
                @{ initial = ''; retried = ''; accepted = $false; recovered = $false }
            ) {
                param($initial, $retried, $accepted, $recovered)
                $values = @{
                    steps = @{
                        'upload-reports' = @{ outcome = $initial; conclusion = 'success' }
                        'upload-reports-retry' = @{ outcome = $retried; conclusion = $retried }
                    }
                }
                foreach ($key in $requireUpload.env.Keys) {
                    [Environment]::SetEnvironmentVariable($key, (Expand-ContractValue $requireUpload.env[$key] $values))
                }
                $requireUpload.shell | Should -BeExactly 'pwsh'
                $assertion = [scriptblock]::Create($requireUpload.run)
                if ($accepted) {
                    $messages = @(& $assertion)
                    if ($recovered) {
                        $messages | Should -HaveCount 1
                        $messages[0] | Should -BeLike '::warning::*recovered on retry*'
                    } else {
                        $messages | Should -HaveCount 0
                    }
                } else {
                    { & $assertion } | Should -Throw '*Report upload did not succeed*'
                }
            }
        }
    }
}

Describe 'Hosted source collection reconciliation' {
    BeforeAll {
        $script:sourceWorkflow = Get-Content (Join-Path $root '.github\workflows\test.yml') -Raw | ConvertFrom-Yaml
        $script:sourceCollector = $sourceWorkflow.jobs['path-collect']
        $script:sourceAnalyzer = $sourceWorkflow.jobs['path-smoke']
    }

    It 'waits for real completed jobs with the companion collection identity' {
        $sourceAnalyzer.needs | Should -Contain 'path-collect'
        $sourceCollector.name | Should -BeExactly 'cbh-collect:action-canary-${{ matrix.runner }}:${{ matrix.runner }}'
        $sourceAnalyzer.permissions.actions | Should -BeExactly 'read'
        $reconcile = @($sourceAnalyzer.steps | Where-Object { $_['id'] -ceq 'collection' })[0]
        $reconcile.env.GH_TOKEN | Should -BeExactly '${{ github.token }}'
        $reconcile.run | Should -Match 'Invoke-WorkflowOperation reconcile'
        $reconcile.run | Should -Not -Match 'jobs-file|jobs-json'
        $reconcile.ContainsKey('continue-on-error') | Should -BeFalse
    }

    It 'transports immutable receipts separately from the replaceable supporting fixture' {
        $uploads = @($sourceCollector.steps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' })
        $receipt = @($uploads | Where-Object { $_.with.name -like 'canary-source-receipt-*' })[0]
        $fixture = @($uploads | Where-Object { $_.with.name -like 'canary-source-fixture-*' })[0]
        $receipt.with.ContainsKey('overwrite') | Should -BeFalse
        $receipt.with.path | Should -BeExactly '${{ steps.evidence.outputs.receipt }}'
        $receipt.with.name | Should -BeLike '*${{ github.run_attempt }}'
        $fixture.with.overwrite | Should -BeTrue
        $downloads = @($sourceAnalyzer.steps | Where-Object { $_['uses'] -like 'actions/download-artifact@*' })
        $receiptDownload = @($downloads | Where-Object { $_.with['pattern'] })[0]
        $receiptDownload.with.pattern | Should -BeExactly 'canary-source-receipt-${{ matrix.rust_target }}-*'
        $receiptDownload.with['run-id'] | Should -BeExactly '${{ github.run_id }}'
        $receiptDownload.with.ContainsKey('merge-multiple') | Should -BeFalse
        $fixtureDownload = @($downloads | Where-Object { $_.with['name'] })[0]
        $fixtureDownload.with.name | Should -BeExactly $fixture.with.name
    }

    It 'keeps collection and analysis on the same manifest-selected source revision' {
        foreach ($job in @($sourceCollector, $sourceAnalyzer)) {
            $source = @($job.steps | Where-Object { $_['with'] -and $_.with['repository'] -ceq 'folo-rs/folo' })
            $source.Count | Should -Be 1
            $source[0].with.ref | Should -BeExactly '${{ needs.setup.outputs.source }}'
        }
    }

    It 'keeps singleton coverage inputs valid even when fork policy skips reconciliation' {
        $analysis = @($sourceAnalyzer.steps | Where-Object { $_['id'] -ceq 'analyze' })[0]
        $analysis.with['expected-platforms'] | Should -BeExactly '${{ matrix.runner }}'
        $analysis.with['completed-platforms'] | Should -BeExactly $analysis.with['expected-platforms']
        $analysis.with['current-collections'] | Should -BeExactly '${{ steps.fixture.outputs.skipped == ''true'' && steps.fixture.outputs.skipped-collections || steps.collection.outputs.current-collections }}'
        $analysis.with.ContainsKey('machine-keys') | Should -BeFalse
    }

    It 'isolates every independent platform pair in the complete run-wide job inventory' {
        $prepare = @($sourceCollector.steps | Where-Object { $_['id'] -ceq 'fixture' })[0]
        $receipt = @($sourceCollector.steps | Where-Object { $_['id'] -ceq 'evidence' })[0]
        $reconcile = @($sourceAnalyzer.steps | Where-Object { $_['id'] -ceq 'collection' })[0]
        $prepare.run | Should -Match '-ProjectId \$env:CANARY_INSTANCE'
        $receipt.env.CANARY_INSTANCE | Should -BeExactly $prepare.env.CANARY_INSTANCE
        $reconcile.env.CANARY_INSTANCE | Should -BeExactly '${{ steps.fixture.outputs.instance }}'
        $reconcile.run | Should -Match '-Instance \$env:CANARY_INSTANCE'
        $jobs = @(foreach ($target in $manifest.targets) {
            $values = @{ matrix = @{ runner = $target.runner } }
            @{
                platform = $target.runner
                instance = Expand-ContractValue $prepare.env.CANARY_INSTANCE $values
                name = Expand-ContractValue $sourceCollector.name $values
            }
        })
        @($jobs.instance | Select-Object -Unique).Count | Should -Be $manifest.targets.Count
        foreach ($job in $jobs) {
            $matching = @($jobs | Where-Object { $_.name.StartsWith("cbh-collect:$($job.instance):", [StringComparison]::Ordinal) })
            $matching.Count | Should -Be 1
            $matching[0].platform | Should -BeExactly $job.platform
        }
    }

    It 'creates an empty scoped path only for an explicit policy skip' {
        $restore = @($sourceAnalyzer.steps | Where-Object { $_['id'] -ceq 'fixture' })[0]
        # Run the actual output branch independently of archive extraction and Git.
        $tokens = $null
        $errors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($restore.run, [ref] $tokens, [ref] $errors)
        $errors.Count | Should -Be 0
        $branch = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Extent.Text.Contains('skipped-current-collections')
        }, $true))
        $branch.Count | Should -Be 1
        $previousOutput = $env:GITHUB_OUTPUT
        try {
            foreach ($skipped in @('true', 'false')) {
                $root = Join-Path $TestDrive "fork-path-$skipped"
                $null = New-Item -ItemType Directory -Path $root
                $env:GITHUB_OUTPUT = Join-Path $root 'outputs'
                $metadata = @{ collection = @{ skipped = $skipped } }
                & ([scriptblock]::Create($branch[0].Extent.Text))
                Test-Path -LiteralPath (Join-Path $root 'skipped-current-collections') | Should -Be ($skipped -ceq 'true')
                Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -Be ($skipped -ceq 'true')
            }
        } finally { $env:GITHUB_OUTPUT = $previousOutput }
    }
}

Describe 'CI bootstrap update coverage' {
    It 'keeps both canaries on the same bootstrap implementation' {
        $references = foreach ($file in @('test', 'install-tools')) {
            $ciWorkflow = Get-Content (Join-Path $root ".github\workflows\$file.yml") -Raw | ConvertFrom-Yaml
            foreach ($job in $ciWorkflow.jobs.Values) {
                foreach ($step in $job['steps']) {
                    if ($step['uses'] -clike 'dtolnay/rust-toolchain@*') { $step.uses }
                }
            }
        }
        @($references | Select-Object -Unique).Count | Should -Be 1
    }

    It 'checks workflow action references weekly through Dependabot' {
        $dependabot = Get-Content (Join-Path $root '.github\dependabot.yml') -Raw | ConvertFrom-Yaml
        $dependabot.version | Should -Be 2
        $updates = @($dependabot.updates | Where-Object { $_['package-ecosystem'] -ceq 'github-actions' })
        $updates.Count | Should -Be 1
        $updates[0].directory | Should -BeExactly '/'
        $updates[0].schedule.interval | Should -BeExactly 'weekly'
    }
}
