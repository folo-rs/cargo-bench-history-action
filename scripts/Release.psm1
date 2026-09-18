#Requires -Version 7.6
# Used by Publish-Release.ps1 and Pester to reconcile GitHub release refs without a
# benchmark toolchain. See docs/implementation.md, "Validation and release boundaries".
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-ReleaseGit {
    param([string] $RepositoryPath, [string[]] $Arguments, [switch] $AllowMissing)
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & git -C $RepositoryPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowMissing -and $LASTEXITCODE -eq 1) {
            # A missing ref is successful absence here, not the script's exit status.
            $global:LASTEXITCODE = 0
            return $null
        }
        throw "git $($Arguments -join ' ') failed ($LASTEXITCODE): $output"
    }
    return ($output -join "`n")
}

function Invoke-ReleaseGh {
    param([string[]] $Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $output = & gh @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed ($LASTEXITCODE): $output"
    }
    return ($output -join "`n")
}

function ConvertTo-ReleaseVersion {
    param([string] $Version)
    if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Expected a stable major.minor.patch action version, received '$Version'."
    }
    return [version] $Version
}

function Test-ReleaseBearingPath {
    param([string] $Path)
    # Default new scripts/workflows to release-bearing so new consumer entry points
    # cannot accidentally bypass readiness. Only these CI-owned files are exempt.
    if ($Path -cin @('action.yml', 'action.yaml', 'release.json')) { return $true }
    if ($Path -clike 'scripts/*') {
        return $Path -cnotin @(
            'scripts/Release.psm1', 'scripts/Publish-Release.ps1', 'scripts/Install-Canary.ps1'
        )
    }
    if ($Path -clike '.github/workflows/*') {
        return $Path -cnotin @(
            '.github/workflows/test.yml', '.github/workflows/install-tools.yml',
            '.github/workflows/release.yml'
        )
    }
    return $false
}

function Get-ReleaseManifestAtRef {
    param([string] $RepositoryPath, [string] $Ref, [switch] $Optional)
    if ($Optional) {
        $paths = Invoke-ReleaseGit $RepositoryPath @('ls-tree', '--name-only', $Ref, '--', 'release.json')
        if ([string]::IsNullOrEmpty($paths)) { return $null }
    }
    $json = Invoke-ReleaseGit $RepositoryPath @('show', "${Ref}:release.json")
    $manifest = $json | ConvertFrom-Json
    if ($manifest.schema_version -ne 1) { throw "Unsupported release manifest schema at $Ref." }
    $null = ConvertTo-ReleaseVersion $manifest.version
    return $manifest
}

function Get-ReleaseContent {
    param([string] $RepositoryPath, [string] $Ref)
    $tree = Invoke-ReleaseGit $RepositoryPath @('ls-tree', '-r', '--full-tree', $Ref)
    $bearing = foreach ($line in ($tree -split "`n")) {
        if ($line -cmatch "^([0-9]+) blob ([0-9a-f]+)`t(.+)$") {
            if (Test-ReleaseBearingPath $Matches[3]) { $line }
        }
        elseif ($line) {
            # A submodule at a runtime path changes the distribution just as a blob does.
            if ($line -cmatch "^([0-9]+) commit ([0-9a-f]+)`t(.+)$") {
                if (Test-ReleaseBearingPath $Matches[3]) { $line }
            }
            else { throw "Unrecognized Git tree entry at ${Ref}: $line" }
        }
    }
    return ($bearing -join "`n")
}

function Assert-ReleaseReadiness {
    param([string] $RepositoryPath, [string] $Ref = 'HEAD', [string] $BaseRef)
    $manifest = Get-ReleaseManifestAtRef $RepositoryPath $Ref
    $version = ConvertTo-ReleaseVersion $manifest.version
    $content = Get-ReleaseContent $RepositoryPath $Ref
    if ($BaseRef) {
        $base = Get-ReleaseManifestAtRef $RepositoryPath $BaseRef -Optional
        if ($null -ne $base) {
            $baseVersion = ConvertTo-ReleaseVersion $base.version
            $baseContent = Get-ReleaseContent $RepositoryPath $BaseRef
            if ($version -lt $baseVersion -or ($content -cne $baseContent -and $version -le $baseVersion)) {
                throw "Release-bearing changes require a version newer than $($base.version)."
            }
        }
    }
    $tag = "v$version"
    $existing = Invoke-ReleaseGit $RepositoryPath @('rev-parse', '--verify', '--quiet', "refs/tags/$tag^{commit}") -AllowMissing
    if ($existing) {
        $tagManifest = Get-ReleaseManifestAtRef $RepositoryPath $existing
        if ($tagManifest.version -cne $manifest.version -or
            (Get-ReleaseContent $RepositoryPath $existing) -cne $content) {
            throw "Immutable tag $tag conflicts with the candidate's release-bearing content."
        }
    }
    return $manifest
}

function Get-ReleasePlan {
    param([string] $RepositoryPath, [string] $Ref = 'HEAD', [string] $BaseRef)
    $manifest = Assert-ReleaseReadiness $RepositoryPath $Ref $BaseRef
    $version = ConvertTo-ReleaseVersion $manifest.version
    $tag = "v$version"
    $major = "v$($version.Major)"
    $candidate = Invoke-ReleaseGit $RepositoryPath @('rev-parse', '--verify', "$Ref^{commit}")
    $existing = Invoke-ReleaseGit $RepositoryPath @('rev-parse', '--verify', '--quiet', "refs/tags/$tag^{commit}") -AllowMissing
    $target = if ($existing) { $existing } else { $candidate }
    $majorTarget = Invoke-ReleaseGit $RepositoryPath @('rev-parse', '--verify', '--quiet', "refs/tags/$major^{commit}") -AllowMissing
    $majorObject = $null
    $moveMajor = $true
    if ($majorTarget) {
        # A lease compares the tag object itself, not its peeled commit; this
        # also handles an existing annotated major tag.
        $majorObject = Invoke-ReleaseGit $RepositoryPath @('rev-parse', '--verify', "refs/tags/$major")
        $majorManifest = Get-ReleaseManifestAtRef $RepositoryPath $majorTarget
        $majorVersion = ConvertTo-ReleaseVersion $majorManifest.version
        if ($majorVersion.Major -ne $version.Major) { throw "$major points to a different major version." }
        if ($majorVersion -eq $version -and $majorTarget -cne $target) {
            throw "$major disagrees with immutable tag $tag."
        }
        $moveMajor = $version -gt $majorVersion
    }
    return [pscustomobject] @{
        Version = "$version"
        Tag = $tag
        Target = $target
        CreateTag = -not [bool] $existing
        Major = $major
        PreviousMajorTarget = $majorObject
        MoveMajor = $moveMajor
    }
}

function Get-ExistingRelease {
    param([string] $Repository, [string] $Tag)
    # Listing returns success with an empty result for a missing release. Unlike
    # swallowing `release view` errors, authentication/server failures remain fatal.
    $json = Invoke-ReleaseGh @('api', '--paginate', '--slurp', "repos/$Repository/releases?per_page=100")
    $releases = @($json | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object tag_name -CEQ $Tag)
    if ($releases.Count -gt 1) { throw "Multiple releases refer to $Tag." }
    if ($releases.Count -eq 1) { return $releases[0] }
    return $null
}

function Publish-ActionRelease {
    param([string] $RepositoryPath, [string] $Repository, [string] $Ref = 'HEAD', [string] $BaseRef)
    # Publication jobs share a queue. Refresh refs after acquiring it; a queued old
    # run must see a newer major version published while it was waiting.
    $null = Invoke-ReleaseGit $RepositoryPath @('fetch', '--force', 'origin', '+refs/tags/*:refs/tags/*')
    $plan = Get-ReleasePlan $RepositoryPath $Ref $BaseRef
    $release = Get-ExistingRelease $Repository $plan.Tag
    if ($null -ne $release -and ($release.draft -or $release.prerelease)) {
        throw "$($plan.Tag) has an unexpected draft/prerelease; reconcile it explicitly."
    }
    if ($plan.CreateTag) {
        # No force: a raced or conflicting immutable ref fails instead of moving.
        $null = Invoke-ReleaseGit $RepositoryPath @('push', 'origin', "$($plan.Target):refs/tags/$($plan.Tag)")
    }
    if ($null -eq $release) {
        $null = Invoke-ReleaseGh @(
            'release', 'create', $plan.Tag, '--repo', $Repository, '--verify-tag',
            '--title', $plan.Tag, '--generate-notes', '--notes', '[Copilot speaking]',
            '--latest=false'
        )
    }
    if ($plan.MoveMajor) {
        # A lease also refuses out-of-band changes between planning and publication.
        $lease = "--force-with-lease=refs/tags/$($plan.Major):$($plan.PreviousMajorTarget)"
        $null = Invoke-ReleaseGit $RepositoryPath @(
            'push', $lease, 'origin', "$($plan.Target):refs/tags/$($plan.Major)"
        )
    }
    Write-Information "$($plan.Tag) reconciled at $($plan.Target); move $($plan.Major): $($plan.MoveMajor)." -InformationAction Continue
}

Export-ModuleMember -Function ConvertTo-ReleaseVersion, Test-ReleaseBearingPath,
    Assert-ReleaseReadiness, Get-ReleasePlan, Publish-ActionRelease
