#Requires -Version 7.6
# Gates same-run downloads on one authenticated artifact inventory. Current-attempt
# producer evidence distinguishes fresh uploads from stale rerun artifacts, while
# the official download action retains archive transfer, extraction and layout.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The defaults bound the observed metadata propagation window and each REST call.
$script:DefaultMaximumAttempts = 12
$script:DefaultRetryDelaySeconds = 5
$script:DefaultRequestTimeoutSeconds = 30
$script:TransientStatuses = @(404, 408, 429, 500, 502, 503, 504)

# Extracts an HTTP status from real and mocked REST exceptions.
function Get-ArtifactHttpStatusCode {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty -or $null -eq $responseProperty.Value) { return $null }
    $statusProperty = $responseProperty.Value.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty) { return $null }
    return [int] $statusProperty.Value
}

# Retries only bounded transient API failures. Permanent responses and ordinary
# transport failures remain visible immediately.
function Test-ArtifactTransientFailure {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $status = Get-ArtifactHttpStatusCode -ErrorRecord $ErrorRecord
    if ($null -ne $status) {
        return $status -in $script:TransientStatuses
    }
    return $false
}

# Reads required response data and preserves valid empty inventories.
function Get-ArtifactResponseProperty {
    param([Parameter(Mandatory)] $Response, [Parameter(Mandatory)] [string] $Name)

    $found = $false
    $property = $null
    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains($Name)) {
            $found = $true
            $property = $Response[$Name]
        }
    }
    else {
        $member = $Response.PSObject.Properties[$Name]
        if ($null -ne $member) {
            $found = $true
            $property = $member.Value
        }
    }
    if (-not $found -or
        ($null -eq $property -and $Name -notin @('artifacts', 'jobs'))) {
        throw "GitHub artifact response omitted required property '$Name'."
    }
    return $property
}

# Reads nullable job and step fields without treating an incomplete unrelated
# producer snapshot as malformed.
function Get-ArtifactOptionalProperty {
    param([Parameter(Mandatory)] $Response, [Parameter(Mandatory)] [string] $Name)

    if ($Response -is [System.Collections.IDictionary]) {
        if ($Response.Contains($Name)) { return $Response[$Name] }
        return $null
    }
    $member = $Response.PSObject.Properties[$Name]
    if ($null -eq $member) { return $null }
    return $member.Value
}

# Applies one timeout and authenticated header set to every bounded REST call.
function Get-ArtifactHeaders {
    param([Parameter(Mandatory)] [string] $GitHubToken)

    return @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $GitHubToken"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

# Invokes GitHub REST without inheriting an effectively unbounded request wait.
function Invoke-ArtifactRestMethod {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    return Invoke-RestMethod -Uri $Uri -Headers $Headers `
        -TimeoutSec $script:DefaultRequestTimeoutSeconds -ErrorAction Stop
}

# Lists every artifact in the workflow run, matching the official downloader's
# authenticated run-wide inventory boundary.
function Get-GitHubRunArtifacts {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $artifacts = @()
    $expected = $null
    $page = 1
    while ($true) {
        $uri = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page"
        try {
            $response = Invoke-ArtifactRestMethod -Uri $uri -Headers $Headers
        }
        catch {
            if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return @() }
            throw
        }
        if ($null -eq $expected) {
            $expected = [int] (Get-ArtifactResponseProperty -Response $response -Name 'total_count')
        }
        $batch = @(Get-ArtifactResponseProperty -Response $response -Name 'artifacts')
        $artifacts += $batch
        if ($artifacts.Count -ge $expected) { return @($artifacts) }
        if ($batch.Count -eq 0) {
            throw "GitHub returned an incomplete artifact inventory for workflow run $RunId."
        }
        $page++
    }
}

# Reads the selected attempt's jobs. GitHub retains original execution timestamps
# for inherited jobs, which lets one freshness rule cover full and partial reruns.
function Get-GitHubRunAttemptJobs {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [long] $RunAttempt,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $jobs = @()
    $expected = $null
    $page = 1
    while ($true) {
        $uri = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/runs/$RunId/attempts/$RunAttempt/jobs?per_page=100&page=$page"
        $response = Invoke-ArtifactRestMethod -Uri $uri -Headers $Headers
        if ($null -eq $expected) {
            $expected = [int] (Get-ArtifactResponseProperty -Response $response -Name 'total_count')
        }
        $batch = @(Get-ArtifactResponseProperty -Response $response -Name 'jobs')
        $jobs += $batch
        if ($jobs.Count -ge $expected) { return @($jobs) }
        if ($batch.Count -eq 0) {
            throw "GitHub returned an incomplete job inventory for workflow run $RunId attempt $RunAttempt."
        }
        $page++
    }
}

# Normalizes reusable caller prefixes to the local producer job marker.
function Get-ArtifactJobMarker {
    param([Parameter(Mandatory)] $Job)

    $name = [string] (Get-ArtifactResponseProperty -Response $Job -Name 'name')
    $separator = $name.LastIndexOf(' / ', [StringComparison]::Ordinal)
    if ($separator -lt 0) { return $name }
    return $name.Substring($separator + 3)
}

# Selects matching artifacts while rejecting duplicate ID/name ambiguity that
# would make the official downloader select a different object than the gate.
function Select-VisibleArtifacts {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] [array] $Artifacts,
        [Parameter(Mandatory)] [string] $Selector,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern
    )

    if ($Selector -ceq 'artifact-ids') {
        $ids = @($ArtifactIds -split ',' | ForEach-Object {
                $value = $_.Trim()
                if ($value -notmatch '^[1-9][0-9]*$') { throw "Invalid artifact ID '$value'." }
                [long] $value
            })
        if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
            throw 'Artifact IDs must be unique.'
        }
        $selected = @($Artifacts | Where-Object {
                [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') -in $ids
            })
        foreach ($id in $ids) {
            if (@($selected | Where-Object {
                        [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') -eq $id
                    }).Count -gt 1) {
                throw "Artifact ID $id appears more than once in one run inventory."
            }
        }
        return @($selected)
    }
    if ($Selector -ceq 'name') {
        return @(
            $Artifacts |
                Where-Object { (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $Name } |
                Sort-Object { [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') } -Descending |
                Select-Object -First 1
        )
    }
    return @(
        $Artifacts |
            Where-Object { (Get-ArtifactResponseProperty -Response $_ -Name 'name') -clike $Pattern } |
            Sort-Object { [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id') } -Descending |
            Group-Object -CaseSensitive {
                Get-ArtifactResponseProperty -Response $_ -Name 'name'
            } |
            ForEach-Object { $_.Group | Select-Object -First 1 }
    )
}

# Resolves one matching producer job before inspecting any of its steps. The
# caller can distinguish an unavailable artifact from a confirmed terminal job
# that never reached upload.
function Get-ArtifactProducerState {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] [array] $Jobs,
        [Parameter(Mandatory)] [string] $JobPrefix,
        [Parameter(Mandatory)] [string] $StepName,
        [string] $Identity
    )

    $producers = @($Jobs | Where-Object {
            $marker = Get-ArtifactJobMarker -Job $_
            $marker.StartsWith($JobPrefix, [StringComparison]::Ordinal) -and
                ([string]::IsNullOrEmpty($Identity) -or $marker -ceq "$JobPrefix$Identity")
        })
    if ($producers.Count -gt 1) {
        throw "Producer prefix '$JobPrefix' and identity '$Identity' matched more than one job."
    }
    if ($producers.Count -eq 0) {
        return [pscustomobject]@{
            Found = $false
            Pending = $true
            Terminal = $false
            UploadSucceeded = $false
            Job = $null
        }
    }

    $job = $producers[0]
    $uploadSucceeded = @(
        Get-ArtifactResponseProperty -Response $job -Name 'steps' | Where-Object {
            (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $StepName -and
            (Get-ArtifactOptionalProperty -Response $_ -Name 'conclusion') -ceq 'success'
        }
    ).Count -gt 0
    $status = [string] (Get-ArtifactResponseProperty -Response $job -Name 'status')
    $conclusion = [string] (Get-ArtifactOptionalProperty -Response $job -Name 'conclusion')
    $terminal = $status -ceq 'completed' -and $conclusion -cin @(
        'success', 'failure', 'cancelled', 'skipped', 'timed_out',
        'action_required', 'neutral'
    )
    return [pscustomobject]@{
        Found = $true
        Pending = -not $terminal
        Terminal = $terminal
        UploadSucceeded = $uploadSucceeded
        Job = $job
    }
}

# Verifies that the newest artifact for one family was created by or after its
# current producer job start. Inherited jobs retain old starts, so their artifacts
# remain valid without requiring a replacement upload.
function Test-ArtifactIsFresh {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] [array] $Artifacts,
        [AllowNull()] $Producer
    )

    if ($Artifacts.Count -eq 0) { return $false }
    if ($null -eq $Producer) { return $true }
    $latest = @($Artifacts | Sort-Object -Property id -Descending) | Select-Object -First 1
    $createdAt = [DateTimeOffset]::Parse(
        [string] (Get-ArtifactResponseProperty -Response $latest -Name 'created_at'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    $startedAt = [DateTimeOffset]::Parse(
        [string] (Get-ArtifactResponseProperty -Response $Producer -Name 'started_at'),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    )
    return $createdAt -ge $startedAt
}

# Waits for complete selector visibility before the official action downloads.
function Wait-ArtifactVisibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [ValidateRange(1, [long]::MaxValue)] [long] $RunId,
        [Parameter(Mandatory)] [ValidateRange(1, [long]::MaxValue)] [long] $RunAttempt,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern,
        [string] $ProducerJobPrefix,
        [string] $ProducerStep,
        [string] $ArtifactNamePrefix,
        [string] $ExpectedIdentities,
        [switch] $ArtifactNameIncludesJobSuffix,
        [ValidateRange(1, 100)] [int] $MaximumAttempts = $script:DefaultMaximumAttempts,
        [ValidateRange(0, 60)] [int] $RetryDelaySeconds = $script:DefaultRetryDelaySeconds
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Expected GitHub repository in owner/name form.'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'Artifact visibility checks require a GitHub token.'
    }
    $selectors = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selectors.Count -ne 1) {
        throw 'Artifact visibility requires exactly one of artifact-ids, name or pattern.'
    }
    $selector = $selectors[0]
    $producerFields = @($ProducerJobPrefix, $ProducerStep | Where-Object {
            -not [string]::IsNullOrWhiteSpace($_)
        }).Count
    if ($selector -ceq 'artifact-ids' -and (
            $producerFields -ne 0 -or $ArtifactNamePrefix -or $ExpectedIdentities -or
            $ArtifactNameIncludesJobSuffix)) {
        throw 'Artifact-ID visibility does not accept producer completeness inputs.'
    }
    if ($selector -ceq 'name' -and (
            $producerFields -notin @(0, 2) -or $ArtifactNamePrefix -or $ExpectedIdentities -or
            $ArtifactNameIncludesJobSuffix)) {
        throw 'Exact-name producer freshness requires producer-job-prefix and producer-step only.'
    }
    if ($selector -ceq 'pattern' -and (
            $producerFields -ne 2 -or [string]::IsNullOrWhiteSpace($ArtifactNamePrefix) -or
            [string]::IsNullOrWhiteSpace($ExpectedIdentities))) {
        throw 'Pattern visibility requires producer job, step, artifact prefix and expected identities.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    $description = switch ($selector) {
        'artifact-ids' { "artifact IDs $ArtifactIds" }
        'name' { "artifact name '$Name'" }
        'pattern' { "artifact pattern '$Pattern'" }
    }
    $identities = @($ExpectedIdentities -split ',' | ForEach-Object { $_.Trim() } |
            Where-Object { $_ })

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            $artifacts = @(Get-GitHubRunArtifacts -ApiUrl $ApiUrl -Repository $Repository `
                    -RunId $RunId -Headers $headers)
            $selected = @(Select-VisibleArtifacts -Artifacts $artifacts -Selector $selector `
                    -ArtifactIds $ArtifactIds -Name $Name -Pattern $Pattern)
            $ready = $false
            if ($selector -ceq 'artifact-ids') {
                $expectedIds = @($ArtifactIds -split ',' | ForEach-Object { [long] $_.Trim() })
                $visibleIds = @($selected | ForEach-Object {
                        [long] (Get-ArtifactResponseProperty -Response $_ -Name 'id')
                    })
                $ready = @($expectedIds | Where-Object { $visibleIds -notcontains $_ }).Count -eq 0
            }
            elseif ($selector -ceq 'name') {
                $ready = $selected.Count -eq 1
                if ($ready -and $producerFields -eq 2) {
                    $jobs = @(Get-GitHubRunAttemptJobs -ApiUrl $ApiUrl -Repository $Repository `
                            -RunId $RunId -RunAttempt $RunAttempt -Headers $headers)
                    $state = Get-ArtifactProducerState -Jobs $jobs -JobPrefix $ProducerJobPrefix `
                        -StepName $ProducerStep
                    if ($state.Pending) {
                        $ready = $false
                    }
                    elseif ($state.UploadSucceeded) {
                        $ready = Test-ArtifactIsFresh -Artifacts $selected -Producer $state.Job
                    }
                }
            }
            else {
                $jobs = @(Get-GitHubRunAttemptJobs -ApiUrl $ApiUrl -Repository $Repository `
                        -RunId $RunId -RunAttempt $RunAttempt -Headers $headers)
                $identityCount = if ($ArtifactNameIncludesJobSuffix) { $identities.Count } else { 1 }
                $ready = $identityCount -gt 0
                for ($index = 0; $index -lt $identityCount; $index++) {
                    $identity = if ($ArtifactNameIncludesJobSuffix) { $identities[$index] } else { '' }
                    $familyPrefix = if ($ArtifactNameIncludesJobSuffix) {
                        "$ArtifactNamePrefix$identity-"
                    }
                    else {
                        $ArtifactNamePrefix
                    }
                    $family = @($selected | Where-Object {
                            [string] (Get-ArtifactResponseProperty -Response $_ -Name 'name') `
                                -clike "$familyPrefix*"
                        })
                    $state = Get-ArtifactProducerState -Jobs $jobs -JobPrefix $ProducerJobPrefix `
                        -StepName $ProducerStep -Identity $identity
                    if ($state.Terminal -and -not $state.UploadSucceeded) {
                        # A failed/skipped producer has no receipt to await. The
                        # companion will classify its missing platform evidence.
                        continue
                    }
                    $producer = if ($state.UploadSucceeded) { $state.Job } else { $null }
                    if ($state.Pending -or
                        -not (Test-ArtifactIsFresh -Artifacts $family -Producer $producer)) {
                        $ready = $false
                        break
                    }
                }
            }
            if ($ready) {
                Write-Information "$description is visible to the official workflow-run downloader." `
                    -InformationAction Continue
                foreach ($artifact in $selected) {
                    [pscustomobject]@{
                        Id = [long] (Get-ArtifactResponseProperty -Response $artifact -Name 'id')
                        Name = [string] (Get-ArtifactResponseProperty -Response $artifact -Name 'name')
                    }
                }
                return
            }
        }
        catch {
            if (-not (Test-ArtifactTransientFailure -ErrorRecord $_)) { throw }
        }

        if ($attempt -lt $MaximumAttempts) {
            Write-Information "$description is not completely visible yet; retrying." `
                -InformationAction Continue
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "$description did not become completely visible in workflow run $RunId " +
        "after $MaximumAttempts attempts."
}

# Reads only the REST archive redirect status. The workflow credential reaches
# GitHub, but automatic redirection is disabled so it never reaches the signed URL.
function Get-ArtifactArchiveStatus {
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:DefaultRequestTimeoutSeconds)
    try {
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('cargo-bench-history-action')
        foreach ($header in $Headers.GetEnumerator()) {
            $client.DefaultRequestHeaders.Add($header.Key, $header.Value)
        }
        $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).
            GetAwaiter().GetResult()
        try {
            if ([int] $response.StatusCode -eq 302 -and -not $response.Headers.Location) {
                throw 'GitHub returned an archive redirect without a Location.'
            }
            return [int] $response.StatusCode
        }
        finally { $response.Dispose() }
    }
    finally { $client.Dispose() }
}

# Waits for credentialed REST archive access after a transfer failure. A
# persistent single-ID 404 returns false so the official same-run client can
# retry without the narrower REST view; multi-ID retries never downgrade.
function Wait-ArtifactArchiveRedirect {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long[]] $ArtifactIds,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [switch] $AllowReadyRedirect
    )

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    $observedTransient = $false
    foreach ($id in $ArtifactIds) {
        $uri = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/artifacts/$id/zip"
        for ($attempt = 1; $attempt -le $script:DefaultMaximumAttempts; $attempt++) {
            $status = Get-ArtifactArchiveStatus -Uri $uri -Headers $headers
            if ($status -eq 302) { break }
            $detail = "Archive GET for artifact $id in $Repository returned HTTP $status " +
                "with the workflow token (attempt $attempt/$script:DefaultMaximumAttempts)."
            if ($status -eq 404 -and $attempt -eq $script:DefaultMaximumAttempts -and
                $ArtifactIds.Count -eq 1) {
                Write-Warning "$detail Retrying the transfer with the same-run artifact service instead."
                return $false
            }
            if ($status -notin $script:TransientStatuses -or
                $attempt -eq $script:DefaultMaximumAttempts) {
                throw "$detail Check this job's artifact access; a 404 does not distinguish delay from denial."
            }
            $observedTransient = $true
            Write-Warning "$detail Retrying in $script:DefaultRetryDelaySeconds seconds."
            Start-Sleep -Seconds $script:DefaultRetryDelaySeconds
        }
    }
    if (-not $observedTransient -and -not $AllowReadyRedirect) {
        throw 'The selected archive redirects were ready when the transfer failed; ' +
            'the failure is not a classified artifact-visibility error.'
    }
    return $true
}

# Validates that a frozen multi-artifact selection transferred completely.
# Single-artifact transfers rely on the official action's required success exit.
function Assert-ArtifactTransferComplete {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Selection,
        [switch] $MergeMultiple
    )

    $entries = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)
    if ($entries.Count -eq 0) {
        throw 'Incomplete artifact transfer: staging directory is empty.'
    }
    if ($Selection.Count -eq 1) { return }
    if ($MergeMultiple) {
        throw 'Cannot prove completeness for multiple merged artifact IDs.'
    }

    $missing = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Selection) {
        if (-not $missing.Add([string] $item.Name)) {
            throw "Cannot distinguish multiple selected artifact IDs named '$($item.Name)'."
        }
    }
    foreach ($entry in $entries) {
        if (-not $entry.PSIsContainer -or -not $missing.Remove($entry.Name)) {
            throw "Incomplete artifact transfer: unexpected staged entry '$($entry.Name)'."
        }
    }
    if ($missing.Count) {
        throw "Incomplete artifact transfer: missing $($missing -join ', ')."
    }
}

# Atomically exposes a fully verified transfer while retaining unrelated existing
# destination entries, such as backfill preparation evidence.
function Publish-ArtifactTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Selection,
        [Parameter(Mandatory)] [string] $Destination,
        [switch] $MergeMultiple
    )

    Assert-ArtifactTransferComplete -Path $Path -Selection $Selection -MergeMultiple:$MergeMultiple
    $resolvedDestination = [IO.Path]::GetFullPath($Destination)
    $parent = [IO.Path]::GetDirectoryName($resolvedDestination)
    $null = New-Item -ItemType Directory -Path $parent -Force
    if ((Test-Path -LiteralPath $resolvedDestination) -and
        -not (Test-Path -LiteralPath $resolvedDestination -PathType Container)) {
        throw "Artifact destination is not a directory: $resolvedDestination"
    }
    $stagedDestination = Join-Path $parent ".cbh-artifact-publish-$([guid]::NewGuid().ToString('N'))"
    $backup = Join-Path $parent ".cbh-artifact-backup-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $stagedDestination
    $published = $false
    $destinationMoved = $false
    try {
        if (Test-Path -LiteralPath $resolvedDestination -PathType Container) {
            foreach ($entry in Get-ChildItem -LiteralPath $resolvedDestination -Force) {
                Copy-Item -LiteralPath $entry.FullName `
                    -Destination (Join-Path $stagedDestination $entry.Name) -Recurse -Force
            }
        }
        foreach ($entry in Get-ChildItem -LiteralPath $Path -Force) {
            $target = Join-Path $stagedDestination $entry.Name
            if (Test-Path -LiteralPath $target) {
                throw "Downloaded artifact entry collides with existing destination '$($entry.Name)'."
            }
            Move-Item -LiteralPath $entry.FullName -Destination $target
        }

        if (Test-Path -LiteralPath $resolvedDestination) {
            Move-Item -LiteralPath $resolvedDestination -Destination $backup
            $destinationMoved = $true
        }
        Move-Item -LiteralPath $stagedDestination -Destination $resolvedDestination
        $published = $true
    }
    catch {
        if ($destinationMoved -and -not (Test-Path -LiteralPath $resolvedDestination) -and
            (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $resolvedDestination
            $destinationMoved = $false
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stagedDestination) {
            Remove-Item -LiteralPath $stagedDestination -Recurse -Force
        }
        if ($published -and (Test-Path -LiteralPath $backup)) {
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
    }
}

Export-ModuleMember -Function Wait-ArtifactVisibility, Wait-ArtifactArchiveRedirect,
    Assert-ArtifactTransferComplete, Publish-ArtifactTransfer
