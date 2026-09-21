#Requires -Version 7.6
# The release-owned workflow adapter uses these functions for checkout paths,
# installation and native argument/file wiring. The companion owns namespace,
# scope, receipt reconciliation and publication decisions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Tools.psm1')

function Initialize-WorkflowContext {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)] [string] $Workspace,
        [Parameter(Mandatory)] [string] $TempDirectory,
        [Parameter(Mandatory)] [string] $Repository,
        [ValidateSet('binstall', 'install', 'path')] [string] $Method = 'binstall',
        [string] $WorkingDirectory = '.',
        [string] $Config,
        [string] $SourcePath,
        [string] $Base,
        [string] $Instance
    )

    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/([A-Za-z0-9_.-]+)$' -or
        $Matches[1] -cin @('.', '..')) {
        throw 'Expected the calling repository in owner/name form.'
    }
    $repositoryName = $Matches[1]
    if ($Method -cnotin @('binstall', 'install', 'path')) { throw "Unsupported installation method: $Method" }
    $workspacePath = (Get-Item -LiteralPath $Workspace -ErrorAction Stop).FullName
    $tempPath = (Get-Item -LiteralPath $TempDirectory -ErrorAction Stop).FullName
    Assert-WorkflowTemporaryDirectory -Directory $tempPath -Checkout $workspacePath
    if ([string]::IsNullOrEmpty($WorkingDirectory)) { $WorkingDirectory = '.' }
    $configurationRoot = Resolve-WorkflowPath -Base $workspacePath -Path $WorkingDirectory -Within $workspacePath
    # Keep the measured repository's basename consistent with the caller checkout.
    # This preserves the core's directory-derived project identity when no ID is explicit.
    $checkoutPath = Join-Path '.bench-history' $repositoryName
    $measuredRoot = Join-Path $workspacePath $checkoutPath
    $workingPath = Resolve-WorkflowPath -Base $measuredRoot -Path $WorkingDirectory -Within $measuredRoot
    $configPath = if ([string]::IsNullOrEmpty($Config)) {
        Join-Path -Path $configurationRoot -ChildPath '.cargo' -AdditionalChildPath 'bench_history.toml'
    }
    else { Resolve-WorkflowPath -Base $configurationRoot -Path $Config -Within $workspacePath }
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        throw "Reusable workflows require a committed benchmark configuration: $configPath"
    }
    if ($Method -eq 'path') {
        if ([string]::IsNullOrWhiteSpace($SourcePath)) { throw 'Path installation requires source-path.' }
        $SourcePath = Resolve-WorkflowPath -Base $workspacePath -Path $SourcePath -Within $workspacePath
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
            throw "The selected tool source directory does not exist: $SourcePath"
        }
    }
    elseif (-not [string]::IsNullOrEmpty($SourcePath)) {
        throw 'source-path applies only to path installation.'
    }

    $runRoot = Join-Path $tempPath "cbh-workflow-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $runRoot
    $receiptDirectory = Join-Path $runRoot 'collection'
    $receiptsDirectory = Join-Path $runRoot 'receipts'
    $null = New-Item -ItemType Directory -Path $receiptDirectory, $receiptsDirectory
    $cacheDirectory = ''
    if ($Instance) {
        $cacheParent = Join-Path $tempPath 'cbh-history-cache'
        $cacheDirectory = Resolve-WorkflowPath -Base $cacheParent -Path $Instance -Within $cacheParent
        if ($cacheDirectory -eq $cacheParent -or $Instance -match '[\\/]') {
            throw 'The prepared instance must identify one cache directory.'
        }
    }
    return @{
        'install-method' = $Method
        'source-path' = $SourcePath
        'checkout-path' = $checkoutPath
        'workspace' = $workspacePath
        'measured-root' = $measuredRoot
        'base' = $Base
        'working-directory' = $workingPath
        'config' = $configPath
        'scripts-path' = $PSScriptRoot
        'run-root' = $runRoot
        'tools-root' = Join-Path $runRoot 'tools'
        'state-path' = Join-Path $runRoot 'workflow.json'
        'receipt-file' = Join-Path $receiptDirectory 'receipt.json'
        'receipts-directory' = $receiptsDirectory
        'machine-key-file' = Join-Path $runRoot 'machine-key.txt'
        'machine-key-directory' = Join-Path $runRoot 'keys'
        'cache-directory' = $cacheDirectory
    }
}

function Install-WorkflowTool {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)] $Manifest)

    if (-not (Test-Path -LiteralPath $Context['working-directory'] -PathType Container)) {
        throw "The measured checkout is unavailable: $($Context['working-directory'])"
    }
    if ($Context['base']) {
        # The invocation's full merge checkout owns the frozen base object even
        # if a remote branch moved. Local fetch needs no persisted Git credential.
        Invoke-WorkflowProcess -FilePath git -Arguments @(
            '-C', $Context['measured-root'], 'fetch', '--no-tags', '--no-write-fetch-head',
            '--', $Context['workspace'], $Context['base'])
    }
    $selected = @($Manifest.tools | Where-Object role -CEQ 'companion')
    if ($selected.Count -ne 1) { throw 'Workflow bootstrap requires one declared companion.' }
    $parameters = @{
        Manifest = $Manifest
        Method = $Context['install-method']
        Root = $Context['tools-root']
        Packages = @($selected.name)
    }
    if ($parameters.Method -eq 'path') { $parameters.SourcePath = $Context['source-path'] }
    $executables = Install-ActionTools @parameters
    return @{ companion = $executables[$selected[0].name] }
}

function Initialize-WorkflowBackfillBranch {
    param([string] $WorkingDirectory)
    # A SHA checkout leaves fetched branches under origin. Expose missing local
    # names without moving HEAD or changing ordinary Git ref resolution.
    # Ref: docs/implementation.md, "Reusable workflow orchestration".
    $lines = @(Invoke-WorkflowProcess -FilePath git -CaptureOutput -Arguments @(
            '-C', $WorkingDirectory, 'for-each-ref', '--format=%(refname)%09%(objectname)%09%(symref)',
            'refs/heads/', 'refs/remotes/origin/'))
    $references = @(foreach ($line in $lines) {
            if ($line -cnotmatch '^(refs/(?:heads|remotes/origin)/[^\t]+)\t([0-9a-f]+)\t(.*)$') {
                throw 'Malformed Git branch enumeration output.'
            }
            @{ name = $Matches[1]; object = $Matches[2]; symbolic = $Matches[3] }
        })
    $heads = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in $references) {
        if ($reference.name.StartsWith('refs/heads/', [StringComparison]::Ordinal)) {
            $null = $heads.Add($reference.name)
        }
    }
    $originPrefix = 'refs/remotes/origin/'
    foreach ($reference in $references) {
        if (-not $reference.name.StartsWith($originPrefix, [StringComparison]::Ordinal) -or
            $reference.name -ceq "${originPrefix}HEAD" -or $reference.symbolic) {
            continue
        }
        $head = 'refs/heads/' + $reference.name.Substring($originPrefix.Length)
        if ($heads.Contains($head)) { continue }
        # Requiring an absent old ref also protects refs created after enumeration.
        Invoke-WorkflowProcess -FilePath git -Arguments @(
            '-C', $WorkingDirectory, 'update-ref', '--no-deref', $head,
            $reference.object, ('0' * $reference.object.Length))
    }
}

function Invoke-WorkflowOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('prepare', 'receipt', 'reconcile')] [string] $Operation,
        [Parameter(Mandatory)] $Context,
        [ValidateSet('history', 'pr', 'backfill')] [string] $Flow,
        [string] $Platforms,
        [string] $Exclude,
        [string] $From,
        [string] $To,
        [string] $Instance,
        [string] $Head,
        [string] $Platform,
        [string] $MachineKey,
        [string] $RunId = $env:GITHUB_RUN_ID,
        [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
        [string] $OutputPath = $env:GITHUB_OUTPUT
    )

    $arguments = switch ($Operation) {
        'prepare' {
            $inputPath = Join-Path $Context['run-root'] 'preparation.json'
            $inputs = @{
                'working-directory' = $Context['working-directory']
                'config' = $Context['config']
                'platforms' = $Platforms
                'exclude' = $Exclude
            }
            if ($Flow -eq 'backfill') {
                Initialize-WorkflowBackfillBranch -WorkingDirectory $Context['working-directory']
                $inputs['from'] = $From
                $inputs['to'] = $To
            }
            $inputs | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $inputPath -Encoding utf8
            @('prepare-workflow', '--flow', $Flow, '--inputs-file', $inputPath,
                '--github-output', $OutputPath)
        }
        'receipt' {
            $MachineKey | Set-Content -LiteralPath $Context['machine-key-file'] -Encoding utf8 -NoNewline
            @('--instance', $Instance, 'collection-receipt', '--run-id', $RunId,
                '--run-attempt', $RunAttempt, '--head', $Head, '--platform', $Platform,
                '--machine-key-file', $Context['machine-key-file'], '--file', $Context['receipt-file'])
        }
        'reconcile' {
            @('--instance', $Instance, '--verbose', 'prepare-analysis', '--run-id', $RunId,
                '--head', $Head, '--expected-platforms', $Platforms,
                '--receipts-dir', $Context['receipts-directory'],
                '--machine-key-dir', $Context['machine-key-directory'], '--github-output', $OutputPath)
        }
    }
    Invoke-WorkflowProcess -FilePath $Context['companion'] -Arguments $arguments
    if ($Operation -eq 'prepare') {
        Assert-WorkflowPreparationOutput -Path $OutputPath -Flow $Flow
    }
}

function Assert-WorkflowPreparationOutput {
    param([string] $Path, [string] $Flow)
    # Validate the machine-readable handoff, not the Rust scope decision. Missing
    # output must fail preparation rather than silently skip every dependent job.
    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $Path) {
        if (-not $line) { continue }
        if ($line -cnotmatch '^([a-z][a-z0-9-]*)=(.*)$' -or $outputs.ContainsKey($Matches[1])) {
            throw 'Malformed or duplicate workflow preparation output.'
        }
        $outputs[$Matches[1]] = $Matches[2]
    }
    $commonKeys = @('instance', 'matrix', 'expected-platforms')
    foreach ($key in $commonKeys) {
        if (-not $outputs.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($outputs[$key])) {
            throw "Workflow preparation did not emit $key."
        }
    }
    if ($Flow -eq 'backfill') {
        if (-not $outputs.ContainsKey('skipped') -or $outputs['skipped'] -cnotin @('true', 'false')) {
            throw 'Backfill preparation did not emit an explicit work-selection output.'
        }
        $required = $commonKeys + @('skipped') + $(if ($outputs['skipped'] -ceq 'true') {
                @('skip-reason')
            }
            else { @('from', 'to') })
        foreach ($key in $required) {
            if (-not $outputs.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($outputs[$key])) {
                throw "Backfill preparation did not emit $key."
            }
        }
        foreach ($key in $outputs.Keys) {
            if ($key -cnotin $required) { throw "Unexpected backfill preparation output: $key." }
        }
        if ($outputs['skipped'] -ceq 'false') {
            # Only check the frozen wire representation. Git resolution and the
            # first-parent range policy belong to the Rust tools.
            foreach ($key in @('from', 'to')) {
                if ($outputs[$key] -cnotmatch '^[0-9a-f]{40}$') {
                    throw "Backfill preparation did not freeze $key to a full commit SHA."
                }
            }
        }
        return
    }
    if (-not $outputs.ContainsKey('collection-job-prefix') -or
        [string]::IsNullOrWhiteSpace($outputs['collection-job-prefix'])) {
        throw 'Workflow preparation did not emit collection-job-prefix.'
    }
    if (-not $outputs.ContainsKey('skipped') -or $outputs['skipped'] -cnotin @('true', 'false') -or
        -not $outputs.ContainsKey('skip-all') -or $outputs['skip-all'] -cnotin @('true', 'false') -or
        -not $outputs.ContainsKey('packages')) {
        throw 'Workflow preparation did not emit explicit scope-selection outputs.'
    }
    if (($outputs['skip-all'] -ceq 'false') -eq [string]::IsNullOrWhiteSpace($outputs['packages'])) {
        throw 'Package scope presence disagrees with its work-selection output.'
    }
    if ($outputs['skipped'] -ceq 'true') {
        if ($outputs['skip-all'] -cne 'true' -or
            -not $outputs.ContainsKey('skip-reason') -or [string]::IsNullOrWhiteSpace($outputs['skip-reason'])) {
            throw 'Policy skip must carry an explicit reason and no collection work.'
        }
        return
    }
    foreach ($key in @('head', 'base')) {
        if (-not $outputs.ContainsKey($key) -or [string]::IsNullOrWhiteSpace($outputs[$key])) {
            throw "Workflow preparation did not emit $key."
        }
    }
    if ($Flow -eq 'history' -and $outputs['base'] -cne $outputs['head']) {
        throw 'History preparation must select its frozen head as the analysis base.'
    }
}

function Resolve-WorkflowPath {
    param([string] $Base, [string] $Path, [string] $Within)
    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:|^[\\/]' -or
        $Path.Contains("`n") -or $Path.Contains("`r")) {
        throw 'Workflow paths must be single-line paths relative to the caller checkout.'
    }
    $Path = $Path.Replace('\', [IO.Path]::DirectorySeparatorChar)
    $resolved = [IO.Path]::GetFullPath($Path, $Base)
    $prefix = [IO.Path]::TrimEndingDirectorySeparator($Within) + [IO.Path]::DirectorySeparatorChar
    # Require exact lexical containment rather than assuming the directory's
    # case sensitivity from the host operating system.
    if ($resolved -cne $Within -and -not $resolved.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw "Workflow path escapes its checkout: $Path"
    }
    return $resolved
}

function Assert-WorkflowTemporaryDirectory {
    param([string] $Directory, [string] $Checkout)
    $checkoutItem = Get-Item -LiteralPath $Checkout
    if ($checkoutItem.LinkType) { $checkoutItem = $checkoutItem.ResolveLinkTarget($true) }
    $item = Get-Item -LiteralPath $Directory
    while ($null -ne $item) {
        if ($item.LinkType) { $item = $item.ResolveLinkTarget($true) }
        # Conservatively reject case-only overlaps without assuming filesystem case behavior.
        if ($item.FullName -ieq $checkoutItem.FullName) {
            throw 'Workflow temporary files must be outside the caller checkout.'
        }
        $item = $item.Parent
    }
}

function Invoke-WorkflowProcess {
    param([string] $FilePath, [string[]] $Arguments, [switch] $CaptureOutput)
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = 0
    $output = if ($CaptureOutput) { & $FilePath @Arguments } else { & $FilePath @Arguments | Out-Host }
    if ($global:LASTEXITCODE -ne 0) {
        throw "Workflow command $FilePath failed with exit code $global:LASTEXITCODE."
    }
    if ($CaptureOutput) { return $output }
}

Export-ModuleMember -Function Initialize-WorkflowContext, Install-WorkflowTool, Invoke-WorkflowOperation
