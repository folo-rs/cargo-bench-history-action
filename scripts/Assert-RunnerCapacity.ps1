#Requires -Version 7.6
[CmdletBinding()]
param(
    [ValidateSet('installation', 'validation', 'collection')][string] $Scope,
    [string] $Runner,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $RunId = $env:GITHUB_RUN_ID,
    [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
    [string] $ExpectedHead = $env:CAPACITY_HEAD,
    [string] $ManifestPath = (Join-Path $PSScriptRoot '..\release.json')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-CapacityApi {
    param([string] $Endpoint, [switch] $Paginate)
    $arguments = @('api', $Endpoint)
    if ($Paginate) { $arguments += @('--paginate', '--slurp') }
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & gh @arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "GitHub capacity evidence lookup failed ($LASTEXITCODE): $output" }
    return (($output -join "`n") | ConvertFrom-Json -AsHashtable)
}

function Get-CapacityJob {
    param([object[]] $Jobs, [string] $Name, [string] $RunId, [int] $RunAttempt, [string] $ExpectedHead)
    $matches = @($Jobs | Where-Object { $_.name -ceq $Name })
    if ($matches.Count -eq 0) { throw "Missing job evidence: $Name." }
    foreach ($job in $matches) {
        if ([string] $job.run_id -cne $RunId -or $job.head_sha -cne $ExpectedHead -or
            $job.run_attempt -lt 1 -or $job.run_attempt -gt $RunAttempt -or $job.id -le 0) {
            throw "Job identity disagrees with the selected run: $Name."
        }
    }
    $attempt = ($matches | Measure-Object -Property run_attempt -Maximum).Maximum
    $latest = @($matches | Where-Object run_attempt -EQ $attempt)
    if ($latest.Count -ne 1) { throw "Ambiguous newest job evidence: $Name." }
    return $latest[0]
}

function Test-CapacityJob {
    param([System.Collections.IDictionary] $Job, $Target, [string] $Repository)
    if ($Job.status -cne 'completed') { throw "Job has not completed: $($Job.name)." }
    if ($Job.conclusion -ceq 'success') { return $false }
    if ($null -eq $Target -or $Target.runner -cne 'macos-latest' -or
        $Target.rust_target -cne 'aarch64-apple-darwin' -or $Target.os -cne 'macOS' -or
        $Target.arch -cne 'ARM64' -or $Job.conclusion -cne 'cancelled' -or
        -not $Job.Contains('steps') -or $null -eq $Job.steps -or @($Job.steps).Count -ne 0 -or
        $Job.runner_id -ne 0 -or @($Job.labels) -cnotcontains 'macos-latest') {
        throw "Required job did not pass: $($Job.name) ($($Job.conclusion))."
    }
    $pages = @(Invoke-CapacityApi "repos/$Repository/check-runs/$($Job.id)/annotations?per_page=100" -Paginate)
    $annotations = @($pages | ForEach-Object { $_ })
    $capacity = @($annotations | Where-Object {
        $_.annotation_level -ceq 'failure' -and
        $_.message -ceq 'The job was not acquired by Runner of type hosted even after multiple attempts'
    })
    $otherFailures = @($annotations | Where-Object {
        $_.annotation_level -ceq 'failure' -and
        $_.message -cne 'The job was not acquired by Runner of type hosted even after multiple attempts'
    })
    if ($capacity.Count -eq 0 -or $otherFailures.Count -ne 0) {
        throw "No unambiguous hosted macOS acquisition evidence: $($Job.name)."
    }
    Write-Warning "NOT RUN: $($Job.name) (job $($Job.id)); hosted macOS runner capacity unavailable. This is not passing installation or test evidence."
    return $true
}

function Assert-RunnerCapacity {
    param(
        [ValidateSet('installation', 'validation', 'collection')][string] $Scope,
        [string] $Runner, [string] $Repository, [string] $RunId, [string] $RunAttempt,
        [string] $ExpectedHead, [string] $ManifestPath
    )
    if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $RunId -cnotmatch '^[1-9][0-9]*$' -or $RunAttempt -cnotmatch '^[1-9][0-9]*$' -or
        $ExpectedHead -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Capacity verification requires an exact repository, run, attempt and head.'
    }
    $run = Invoke-CapacityApi "repos/$Repository/actions/runs/$RunId"
    $workflow = if ($Scope -ceq 'installation') {
        @('.github/workflows/test.yml', '.github/workflows/release.yml')
    } else { @('.github/workflows/test.yml') }
    if ([string] $run.id -cne $RunId -or $run.head_sha -cne $ExpectedHead -or
        [string] $run.run_attempt -cne $RunAttempt -or $run.path -cnotin $workflow) {
        throw 'Capacity verification run identity or workflow does not match.'
    }
    $localJson = Get-Content -LiteralPath $ManifestPath -Raw
    $remote = Invoke-CapacityApi "repos/$Repository/contents/release.json?ref=$ExpectedHead"
    if ($remote.encoding -cne 'base64') { throw 'Unexpected manifest content encoding.' }
    $remoteJson = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($remote.content))
    if ($localJson.Replace("`r`n", "`n").TrimEnd() -cne $remoteJson.Replace("`r`n", "`n").TrimEnd()) {
        throw 'Checked-out release manifest does not match the selected run head.'
    }
    Import-Module (Join-Path $PSScriptRoot 'Tools.psm1') -Force
    $manifest = Read-ActionManifest $ManifestPath
    if (@($manifest.targets.runner | Sort-Object -Unique).Count -ne $manifest.targets.Count -or
        @($manifest.targets.rust_target | Sort-Object -Unique).Count -ne $manifest.targets.Count) {
        throw 'Capacity verification requires unique manifest runners and targets.'
    }
    $pages = @(Invoke-CapacityApi "repos/$Repository/actions/runs/$RunId/jobs?filter=all&per_page=20" -Paginate)
    $jobs = @($pages | ForEach-Object { $_.jobs })
    $expected = @()
    if ($Scope -ceq 'installation') {
        $expected += @{ name = 'availability / matrix'; target = $null }
        foreach ($target in $manifest.targets) {
            foreach ($method in @('install', 'binstall')) {
                $expected += @{ name = "availability / $method ($($target.rust_target))"; target = $target }
            }
        }
    } else {
        $expected += @{ name = 'setup'; target = $null }
        $targets = @($manifest.targets)
        if ($Scope -ceq 'collection') {
            $targets = @($targets | Where-Object runner -CEQ $Runner)
            if ($targets.Count -ne 1) { throw "Runner is not uniquely declared in the manifest: $Runner." }
        }
        foreach ($target in $targets) {
            $expected += @{
                name = "cbh-collect:action-canary-$($target.runner):$($target.runner)"; target = $target
            }
            if ($Scope -ceq 'validation') {
                $expected += @{ name = "Pester ($($target.runner))"; target = $target }
                $expected += @{ name = "Source path ($($target.runner))"; target = $target }
            }
        }
    }
    $unavailable = @()
    foreach ($item in $expected) {
        $job = Get-CapacityJob $jobs $item.name $RunId ([int] $RunAttempt) $ExpectedHead
        if (Test-CapacityJob $job $item.target $Repository) { $unavailable += $item.name }
    }
    return [pscustomobject] @{ Unavailable = $unavailable }
}

if ($MyInvocation.InvocationName -ne '.') {
    $result = Assert-RunnerCapacity -Scope $Scope -Runner $Runner -Repository $Repository `
        -RunId $RunId -RunAttempt $RunAttempt -ExpectedHead $ExpectedHead -ManifestPath $ManifestPath
    if ($Scope -ceq 'collection' -and $env:GITHUB_OUTPUT) {
        "unavailable=$($result.Unavailable.Count -gt 0)".ToLowerInvariant() >> $env:GITHUB_OUTPUT
    }
    $message = if ($result.Unavailable.Count -eq 0) {
        "$Scope checks passed for $ExpectedHead."
    } else {
        "$Scope accepted with unavailable macOS evidence: $($result.Unavailable -join ', ')."
    }
    Write-Information $message -InformationAction Continue
    if ($env:GITHUB_STEP_SUMMARY) { $message >> $env:GITHUB_STEP_SUMMARY }
}
