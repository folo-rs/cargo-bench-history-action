#Requires -Version 7.6
# Real root-action canaries use this to verify stored measurements and report
# evidence. The short synthetic history must not claim an all-clear or findings.
[CmdletBinding()]
param(
    [string] $Workspace,
    [string] $Store,
    [string] $MachineKey,
    [string] $CollectionJson,
    [string] $AnalysisJson
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-CanaryForkSkip {
    param($EventData, $Collection, $Analysis)
    $pr = $EventData['pull_request']
    if (-not $pr) { throw 'A non-PR invocation must execute the behavioral canary.' }
    $headRepo = $pr['head']['repo']
    $baseRepo = $pr['base']['repo']
    if ($headRepo -and $baseRepo -and $headRepo['full_name'] -ieq $baseRepo['full_name']) {
        throw 'A same-repository PR must execute the behavioral canary.'
    }
    if ($Collection['skipped'] -cne 'true' -or $Analysis['skipped'] -cne 'true' -or
        $Collection['machine-key'] -or $Analysis['outcome']) {
        throw 'Fork canaries must explicitly skip both commands without claiming benchmark evidence.'
    }
}

function Assert-CanaryAnalysis {
    param($Report, $Outputs, [string] $Commit)
    if ($Report.tip_commit -cne $Commit -or $Report.tip_dirty -or $Report.mode -cne 'history') {
        throw 'Analysis did not describe the committed fixture history.'
    }
    # Both the ordinarily collected tip and the backfilled parent must reach analysis.
    if ($Report.runs -ne 2) { throw 'Analysis did not include both synthetic fixture commits.' }
    if ($Report.census.in_scope -le 0 -or $Report.census.judged -ne 0 -or
        $Report.census.coverage -cne 'nothing_judged' -or
        $Report.outcome -cne 'insufficient_baseline' -or $Report.notable) {
        throw 'The short synthetic history must yield an honest insufficient-baseline report.'
    }
    if ($Outputs['outcome'] -cne $Report.outcome -or $Outputs['publication-state'] -cne 'inconclusive' -or
        $Outputs['can-clear'] -cne 'false' -or $Outputs['partial-platform-coverage'] -cne 'false') {
        throw 'Action outputs disagree with the report or the complete fixture platform evidence.'
    }
}

function Get-CanaryStoreEvidence {
    param([string] $Store, [string] $MachineKey, [string[]] $Commits)
    if ([string]::IsNullOrWhiteSpace($MachineKey) -or $MachineKey -match '[\r\n]') {
        throw 'Collection must emit one real machine key.'
    }
    $files = @(Get-ChildItem -LiteralPath $Store -Recurse -File -Force)
    $objects = @($files | Where-Object Name -CEQ clean.json)
    if ($objects.Count -ne $Commits.Count -or $files.Count -ne $objects.Count) {
        throw 'Storage does not contain exactly the expected clean commit set.'
    }
    $remaining = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($commit in $Commits) {
        if (-not $remaining.Add($commit)) { throw 'Expected fixture commits must be distinct.' }
    }
    foreach ($object in $objects) {
        # Local clean.json objects contain gzip bodies. Hash the original stored
        # bytes below, but inspect the decompressed measurement document here.
        $reader = [IO.StreamReader]::new([IO.Compression.GZipStream]::new(
                [IO.File]::OpenRead($object.FullName), [IO.Compression.CompressionMode]::Decompress))
        try { $run = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable }
        finally { $reader.Dispose() }
        $commit = $run.context.git.commit
        if ($commit -cnotmatch '^[0-9a-f]{40}$' -or $object.Directory.Name -cne $commit -or
            $run.context.git.dirty -ne $false -or $run.context.machine.fingerprint -cne $MachineKey -or
            $MachineKey -cnotin ($object.FullName -split '[\\/]') -or
            @($run.results).Count -eq 0 -or -not $remaining.Remove($commit)) {
            throw 'Stored measurements disagree with the clean fixture commit or runner identity.'
        }
    }
    $hashes = @{}
    foreach ($file in $files) {
        $hashes[[IO.Path]::GetRelativePath($Store, $file.FullName)] =
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Assert-CanaryStorePreserved {
    param([hashtable] $Before, [hashtable] $After, [switch] $AllowAdditional)
    if (-not $AllowAdditional -and $Before.Count -ne $After.Count) {
        throw 'Resuming backfill changed the stored file set.'
    }
    foreach ($path in $Before.Keys) {
        if (-not $After.ContainsKey($path) -or $After[$path] -cne $Before[$path]) {
            throw 'Backfill changed an already recorded measurement.'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $collection = $CollectionJson | ConvertFrom-Json -AsHashtable
    $outputs = $AnalysisJson | ConvertFrom-Json -AsHashtable
    if ($collection['skipped'] -eq 'true' -or $outputs['skipped'] -eq 'true') {
        $workflowEvent = Get-Content $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable
        Assert-CanaryForkSkip $workflowEvent $collection $outputs
        Write-Information 'Verified explicit fork policy: no collection/report evidence is claimed. Published availability is checked independently before these invocations.' -InformationAction Continue
        return
    }
    foreach ($name in @('report-json', 'report-markdown', 'report-summary')) {
        if (-not $outputs.Contains($name) -or -not (Test-Path -LiteralPath $outputs[$name] -PathType Leaf) -or
            (Get-Item -LiteralPath $outputs[$name]).Length -eq 0) {
            throw "Analysis did not emit a nonempty $name file."
        }
    }
    $report = Get-Content -LiteralPath $outputs['report-json'] -Raw | ConvertFrom-Json -AsHashtable
    $commit = & git -C $Workspace rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify fixture commit.' }
    $parent = & git -C $Workspace rev-parse 'HEAD~1'
    if ($LASTEXITCODE -ne 0) { throw 'Cannot identify historical fixture commit.' }
    $null = Get-CanaryStoreEvidence -Store $Store -MachineKey $MachineKey -Commits @($parent, $commit)
    Assert-CanaryAnalysis -Report $report -Outputs $outputs -Commit $commit
    Write-Information 'Verified collected storage, real machine key and parseable insufficient-baseline reports.' -InformationAction Continue
}
