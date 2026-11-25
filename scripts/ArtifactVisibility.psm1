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

# Resolves producers that actually completed this upload step in the selected
# attempt. Failed or skipped upload steps cannot establish a newer artifact.
function Get-ArtifactProducer {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()] [array] $Jobs,
        [Parameter(Mandatory)] [string] $JobPrefix,
        [Parameter(Mandatory)] [string] $StepName,
        [string] $Identity
    )

    $producers = @($Jobs | Where-Object {
            $marker = Get-ArtifactJobMarker -Job $_
            $markerMatch = $marker.StartsWith($JobPrefix, [StringComparison]::Ordinal)
            $identityMatch = [string]::IsNullOrEmpty($Identity) -or
                $marker -ceq "$JobPrefix$Identity"
            $uploadSuccess = @(
                Get-ArtifactResponseProperty -Response $_ -Name 'steps' | Where-Object {
                    (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $StepName -and
                    (Get-ArtifactResponseProperty -Response $_ -Name 'conclusion') -ceq 'success'
                }
            ).Count -gt 0
            $markerMatch -and $identityMatch -and $uploadSuccess
        })
    if ($producers.Count -gt 1) {
        throw "Producer prefix '$JobPrefix' and identity '$Identity' matched more than one job."
    }
    return $producers
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
                    $producer = Get-ArtifactProducer -Jobs $jobs -JobPrefix $ProducerJobPrefix `
                        -StepName $ProducerStep
                    $ready = Test-ArtifactIsFresh -Artifacts $selected -Producer $producer
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
                    $producer = Get-ArtifactProducer -Jobs $jobs -JobPrefix $ProducerJobPrefix `
                        -StepName $ProducerStep -Identity $identity
                    if (-not (Test-ArtifactIsFresh -Artifacts $family -Producer $producer)) {
                        $ready = $false
                        break
                    }
                }
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
