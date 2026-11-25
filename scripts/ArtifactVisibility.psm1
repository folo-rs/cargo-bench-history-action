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

# Represents a known HTTP response without allowing an archive readiness check
# to hide a permanent status inside a generic script error.
class ArtifactVisibilityHttpException : System.Exception {
    [object] $Response

    ArtifactVisibilityHttpException([int] $StatusCode) : base("HTTP $StatusCode") {
        $this.Response = [pscustomobject]@{ StatusCode = $StatusCode }
    }
}

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
        return $status -in @(408, 429) -or $status -ge 500
    }
    return $ErrorRecord.Exception -is [System.TimeoutException] -or
        $ErrorRecord.Exception.Message -match '(?i)\b(?:timed? out|timeout|temporarily unavailable)\b'
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
        $response = Invoke-ArtifactRestMethod -Uri $uri -Headers $Headers
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
        $selected = @($Artifacts | Where-Object {
                (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $Name
            })
        if ($selected.Count -gt 1) {
            throw "Artifact name '$Name' matched more than one artifact in the workflow run."
        }
        return @($selected)
    }
    return @($Artifacts | Where-Object {
            (Get-ArtifactResponseProperty -Response $_ -Name 'name') -clike $Pattern
        })
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
            Pending = $false
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

# Checks only the archive redirect without consuming its payload. A missing
# redirect is eventual visibility; permanent HTTP responses remain failures.
function Test-ArtifactArchiveReady {
    param(
        [Parameter(Mandatory)] $Artifact,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    if ([bool] (Get-ArtifactResponseProperty -Response $Artifact -Name 'expired')) {
        throw "Artifact '$((Get-ArtifactResponseProperty -Response $Artifact -Name 'name'))' has expired."
    }
    $uri = [string] (Get-ArtifactResponseProperty -Response $Artifact -Name 'archive_download_url')
    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $Headers -Method Head `
            -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec $script:DefaultRequestTimeoutSeconds `
            -ErrorAction Stop
    }
    catch {
        $status = Get-ArtifactHttpStatusCode -ErrorRecord $_
        # With MaximumRedirection disabled, PowerShell reports a valid 3xx as a
        # statusless redirect-limit exception. Reaching that boundary proves the
        # GitHub archive endpoint issued its download redirect.
        if ($_.FullyQualifiedErrorId -like 'MaximumRedirectExceeded*' -or
            $_.Exception.Message -like '*maximum redirection count has been exceeded*' -or
            ($_.ErrorDetails -and
                $_.ErrorDetails.Message -like '*maximum redirection count has been exceeded*')) {
            return $true
        }
        if ($status -in @(200, 201, 202, 203, 204, 301, 302, 303, 307, 308)) { return $true }
        if ($status -eq 404) { return $false }
        if ((Test-ArtifactTransientFailure -ErrorRecord $_)) { throw }
        throw
    }

    $status = [int] $response.StatusCode
    if ($status -eq 404) { return $false }
    if ($status -ge 200 -and $status -lt 400) { return $true }
    throw [ArtifactVisibilityHttpException]::new($status)
}

# Proves every selected archive redirect before the official action transfers
# the same IDs, so a listed-but-not-downloadable artifact remains retryable.
function Test-ArtifactArchivesReady {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] [array] $Artifacts,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    foreach ($artifact in $Artifacts) {
        if (-not (Test-ArtifactArchiveReady -Artifact $artifact -Headers $Headers)) {
            return $false
        }
    }
    return $true
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
            if ($ready -and -not (Test-ArtifactArchivesReady -Artifacts $selected -Headers $headers)) {
                $ready = $false
            }
            if ($ready) {
                Write-Output "$description is visible to the official workflow-run downloader."
                return
            }
        }
        catch {
            if (-not (Test-ArtifactTransientFailure -ErrorRecord $_)) { throw }
        }

        if ($attempt -lt $MaximumAttempts) {
            Write-Output "$description is not completely visible yet; retrying."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "$description did not become completely visible in workflow run $RunId " +
        "after $MaximumAttempts attempts."
}

Export-ModuleMember -Function Wait-ArtifactVisibility
