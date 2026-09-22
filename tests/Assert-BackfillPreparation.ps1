#Requires -Version 7.6
<#
The published installation gate calls this offline contract canary with its already
verified companion. It also accepts a locally built companion for source validation.
An isolated Git history loses its Cargo workspace at the invocation head: exact
and rolling preparation must still work without current-HEAD benchmark detection.
All cases pass the adapter's real input shape, including empty optional defaults.
Only child processes discard GitHub event context, which belongs to the action
repository rather than this fixture. No tools are installed and no APIs are called.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Companion,
    [Parameter(Mandatory)] [string] $Root
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Companion = (Get-Item -LiteralPath $Companion -ErrorAction Stop).FullName
if (Test-Path -LiteralPath $Root) { throw 'The preparation canary requires an absent fixture root.' }
$null = New-Item -ItemType Directory -Path $Root
$Root = (Get-Item -LiteralPath $Root).FullName
$workspace = Join-Path $Root 'workspace'
$null = New-Item -ItemType Directory -Path $workspace
Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixture') -Force |
    Copy-Item -Destination $workspace -Recurse
$gitConfig = Join-Path $Root 'gitconfig'
Set-Content -LiteralPath $gitConfig -Value '' -NoNewline

function Invoke-PreparationCanaryProcess {
    param([string] $FilePath, [string[]] $Arguments, [hashtable] $Environment = @{})
    $start = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $workspace
    foreach ($key in @($start.Environment.Keys)) {
        if ($key.StartsWith('GITHUB_', [StringComparison]::OrdinalIgnoreCase)) {
            $null = $start.Environment.Remove($key)
        }
    }
    $start.Environment['GIT_CONFIG_GLOBAL'] = $gitConfig
    $start.Environment['GIT_CONFIG_NOSYSTEM'] = '1'
    foreach ($key in $Environment.Keys) { $start.Environment[$key] = $Environment[$key] }
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEndAsync()
        $errorOutput = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $text = $output.GetAwaiter().GetResult()
        $diagnostics = $errorOutput.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Preparation canary command failed ($($process.ExitCode)): $text $diagnostics"
        }
        if ($diagnostics) { Write-Information $diagnostics -InformationAction Continue }
        return $text.Trim()
    }
    finally { $process.Dispose() }
}

function Invoke-PreparationCanaryGit {
    param([string[]] $Arguments)
    # Fixed historical dates keep this real-clock smoke far from cutoff boundaries.
    # Exact duration/calendar behavior belongs to the injected-clock Rust tests.
    Invoke-PreparationCanaryProcess -FilePath git -Arguments (@(
            '-c', 'user.name=Canary', '-c', 'user.email=canary@example.invalid',
            '-c', 'commit.gpgsign=false', '-c', 'gc.auto=0', '-c', 'core.autocrlf=false'
        ) + $Arguments) -Environment @{
        GIT_AUTHOR_DATE = '2000-01-01T00:00:00Z'
        GIT_COMMITTER_DATE = '2000-01-01T00:00:00Z'
    }
}

$null = Invoke-PreparationCanaryGit @('init', '--quiet', '-b', 'main')
$null = Invoke-PreparationCanaryGit @('add', '.')
$null = Invoke-PreparationCanaryGit @('commit', '--quiet', '-m', 'historical benchmark workspace')
$from = Invoke-PreparationCanaryGit @('rev-parse', 'HEAD')
Remove-Item -LiteralPath (Join-Path $workspace 'Cargo.toml')
$null = Invoke-PreparationCanaryGit @('add', '.')
$null = Invoke-PreparationCanaryGit @('commit', '--quiet', '-m', 'invocation without a Cargo workspace')
$to = Invoke-PreparationCanaryGit @('rev-parse', 'HEAD')
# Model actions/checkout at a SHA: fetched origin branches, but no local main.
$null = Invoke-PreparationCanaryGit @('update-ref', 'refs/remotes/origin/main', $to)
$null = Invoke-PreparationCanaryGit @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
$null = Invoke-PreparationCanaryGit @('checkout', '--quiet', '--detach', $to)
$null = Invoke-PreparationCanaryGit @('update-ref', '-d', 'refs/heads/main', $to)
$null = Invoke-PreparationCanaryGit @('update-ref', 'refs/heads/preserved', $from)
$null = Invoke-PreparationCanaryGit @('update-ref', 'refs/remotes/origin/preserved', $to)
$null = Invoke-PreparationCanaryGit @('update-ref', 'refs/tags/release', $from)

$statePath = Join-Path $Root 'state.json'
@{
    companion = $Companion
    'run-root' = $Root
    'working-directory' = $workspace
    config = Join-Path $workspace '.cargo\bench_history.toml'
} | ConvertTo-Json | Set-Content -LiteralPath $statePath
$entry = Join-Path $PSScriptRoot '..\scripts\Run-Workflow.ps1'
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
# A narrow window exercises the single-commit fallback. An age cutoff predating
# the fixture exercises no-work, while an explicit endpoint bypasses that cutoff.
$cases = @(
    @{
        name = 'exact-short'; from = 'main~1'; to = 'main'; lookback = ''; age = ''
        hasWork = 'true'; expectedFrom = $from; expectedTo = $to
    }
    @{
        name = 'exact-qualified'; from = 'main~1'; to = 'refs/heads/main'; lookback = ''; age = ''
        hasWork = 'true'; expectedFrom = $from; expectedTo = $to
    }
    @{
        name = 'rolling'; from = ''; to = ''; lookback = '1 nanosecond'; age = '0 seconds'
        hasWork = 'true'; expectedFrom = $to; expectedTo = $to
    }
    @{
        name = 'rolling-override'; from = ''; to = 'release'; lookback = '1 nanosecond'; age = '100 years'
        hasWork = 'true'; expectedFrom = $from; expectedTo = $from
    }
    @{
        name = 'no-work'; from = ''; to = ''; lookback = '14 days'; age = '100 years'
        hasWork = 'false'
    }
)
$results = @(foreach ($case in $cases) {
    $outputPath = Join-Path $Root "preparation-output-$($case.name)"
    $null = Invoke-PreparationCanaryProcess -FilePath $pwsh `
        -Arguments @('-NoProfile', '-File', $entry, '-Stage', 'prepare', '-StatePath', $statePath) `
        -Environment @{
            GITHUB_OUTPUT = $outputPath
            CBH_FLOW = 'backfill'
            CBH_PLATFORMS = 'ubuntu-latest,windows-latest'
            CBH_EXCLUDE = ''
            CBH_FROM = $case.from
            CBH_TO = $case.to
            CBH_LOOKBACK = $case.lookback
            CBH_MINIMUM_AGE = $case.age
        }

    # Run-Workflow validates the strict output shape; compare its frozen endpoints
    # with actual fixture commits rather than merely SHA-shaped strings.
    $outputs = @{}
    foreach ($line in Get-Content -LiteralPath $outputPath) {
        $key, $value = $line -split '=', 2
        $outputs[$key] = $value
    }
    if ($outputs['skipped'] -cne 'false' -or $outputs['has-work'] -cne $case.hasWork) {
        throw "Backfill preparation selected unexpected work for $($case.name)."
    }
    if ($case.hasWork -ceq 'true') {
        if ($outputs['from'] -cne $case.expectedFrom -or $outputs['to'] -cne $case.expectedTo) {
            throw "Backfill preparation selected unexpected endpoints for $($case.name)."
        }
    }
    elseif ($outputs['no-work-reason'] -cne 'no-eligible-commit' -or
        $outputs.ContainsKey('from') -or $outputs.ContainsKey('to')) {
        throw 'No eligible endpoint must produce an explicit no-work handoff without a range.'
    }
    Copy-Item -LiteralPath (Join-Path $Root 'preparation.json') `
        -Destination (Join-Path $Root "preparation-input-$($case.name).json")
    @{ case = $case.name; outputs = $outputs }
})
if ((Invoke-PreparationCanaryGit @('rev-parse', 'HEAD')) -cne $to -or
    (Invoke-PreparationCanaryGit @('rev-parse', '--abbrev-ref', 'HEAD')) -cne 'HEAD' -or
    (Invoke-PreparationCanaryGit @('rev-parse', 'preserved')) -cne $from -or
    (Invoke-PreparationCanaryGit @('rev-parse', 'release')) -cne $from -or
    (Invoke-PreparationCanaryGit @('for-each-ref', '--format=%(refname)', 'refs/heads/HEAD'))) {
    throw 'Branch alias preparation changed frozen HEAD or existing ref resolution.'
}
$results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $Root 'preparation-results.json')
Write-Information 'Verified exact, rolling, override and no-work preparation through the real workflow adapter with empty defaults.' -InformationAction Continue
