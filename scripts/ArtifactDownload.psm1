#Requires -Version 7.6
# The private artifact-download action uses this module to bridge same-run
# artifact uploads to consumers without embedding retry policy in each workflow.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The bounded budget tolerates short artifact-service propagation without turning
# missing evidence, authorization failures or corrupt archives into long waits.
$script:DefaultMaximumAttempts = 10
$script:DefaultRetryDelaySeconds = 2

# Extracts an HTTP status only from a failed web request so retry policy can
# distinguish expected temporary absence from unrelated permanent failures.
function Get-ArtifactHttpStatusCode {
    param([Parameter(Mandatory)] [System.Management.Automation.ErrorRecord] $ErrorRecord)

    $responseProperty = $ErrorRecord.Exception.PSObject.Properties['Response']
    if ($null -eq $responseProperty) { return $null }
    $response = $responseProperty.Value
    if ($null -eq $response) { return $null }
    $statusProperty = $response.PSObject.Properties['StatusCode']
    if ($null -eq $statusProperty) { return $null }
    return [int] $statusProperty.Value
}

# Reads one validated JSON property without assuming that mocked and real REST
# responses use the same PowerShell dictionary representation.
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
    if (-not $found -or $null -eq $property) {
        throw "GitHub artifact response omitted required property '$Name'."
    }
    return $property
}

# Constructs authenticated GitHub REST headers at the action boundary while
# keeping the token out of command arguments, logs and downloaded file paths.
function Get-ArtifactHeaders {
    param([Parameter(Mandatory)] [string] $GitHubToken)

    return @{
        Accept = 'application/vnd.github+json'
        Authorization = "Bearer $GitHubToken"
        'X-GitHub-Api-Version' = '2022-11-28'
    }
}

# Lists every artifact belonging to one workflow run because pattern-based
# consumers must see the complete authenticated run-wide inventory.
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
    $base = $ApiUrl.TrimEnd('/')
    while ($true) {
        $uri = "$base/repos/$Repository/actions/runs/$RunId/artifacts?per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
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

# Lists every job for all attempts in one run. Pattern consumers use completed
# producer steps to establish the exact immutable artifact names they must await.
function Get-GitHubRunJobs {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    $jobs = @()
    $expected = $null
    $page = 1
    $base = $ApiUrl.TrimEnd('/')
    while ($true) {
        $uri = "$base/repos/$Repository/actions/runs/$RunId/jobs?filter=all&per_page=100&page=$page"
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -ErrorAction Stop
        if ($null -eq $expected) {
            $expected = [int] (Get-ArtifactResponseProperty -Response $response -Name 'total_count')
        }
        $batch = @(Get-ArtifactResponseProperty -Response $response -Name 'jobs')
        $jobs += $batch
        if ($jobs.Count -ge $expected) { return @($jobs) }
        if ($batch.Count -eq 0) {
            throw "GitHub returned an incomplete job inventory for workflow run $RunId."
        }
        $page++
    }
}

# Resolves exact artifact names from successful producer jobs across run
# attempts. This keeps retry completeness tied to authenticated job evidence,
# while artifact naming remains explicit workflow data rather than a benchmark decision.
function Get-ExpectedArtifactNames {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [string] $JobPrefix,
        [Parameter(Mandatory)] [string] $StepName,
        [Parameter(Mandatory)] [string] $ArtifactNamePrefix,
        [Parameter(Mandatory)] [hashtable] $Headers,
        [bool] $IncludeJobSuffix
    )

    $names = @(
        foreach ($job in @(Get-GitHubRunJobs -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId -Headers $Headers)) {
            $jobName = [string] (Get-ArtifactResponseProperty -Response $job -Name 'name')
            if (-not $jobName.StartsWith($JobPrefix, [StringComparison]::Ordinal)) { continue }
            $successfulStep = @(
                Get-ArtifactResponseProperty -Response $job -Name 'steps' | Where-Object {
                    (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $StepName -and
                    (Get-ArtifactResponseProperty -Response $_ -Name 'conclusion') -ceq 'success'
                }
            )
            if ($successfulStep.Count -eq 0) { continue }
            $attempt = [long] (Get-ArtifactResponseProperty -Response $job -Name 'run_attempt')
            if ($IncludeJobSuffix) {
                $suffix = $jobName.Substring($JobPrefix.Length)
                if ([string]::IsNullOrEmpty($suffix)) {
                    throw "Producer job '$jobName' has no identity suffix after '$JobPrefix'."
                }
                "$ArtifactNamePrefix$suffix-$attempt"
            }
            else {
                "$ArtifactNamePrefix$attempt"
            }
        }
    )
    $unique = @($names | Select-Object -Unique)
    if ($unique.Count -ne $names.Count) {
        throw 'Completed producer jobs map to duplicate artifact names.'
    }
    return @($unique)
}

# Resolves an artifact ID directly, treating only an HTTP not-found response as
# temporary eventual-visibility evidence.
function Get-GitHubArtifact {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $ArtifactId,
        [Parameter(Mandatory)] [hashtable] $Headers
    )

    try {
        return Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/actions/artifacts/$ArtifactId" `
            -Headers $Headers -ErrorAction Stop
    }
    catch {
        if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return $null }
        throw
    }
}

# Validates the selector and resolves artifacts for one retry attempt. Missing
# IDs, names and pattern matches remain retryable; other response defects fail.
function Select-GitHubArtifacts {
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [long] $RunId,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern
    )

    $selectors = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selectors.Count -ne 1) {
        throw 'Artifact download requires exactly one of artifact-ids, name or pattern.'
    }

    $headers = Get-ArtifactHeaders -GitHubToken $GitHubToken
    $selected = @(
        if ($selectors[0] -ceq 'artifact-ids') {
            $ids = @($ArtifactIds -split ',' | ForEach-Object {
                    $value = $_.Trim()
                    if ($value -notmatch '^[1-9][0-9]*$') { throw "Invalid artifact ID '$value'." }
                    [long] $value
                })
            if (@($ids | Select-Object -Unique).Count -ne $ids.Count) {
                throw 'Artifact IDs must be unique.'
            }
            foreach ($id in $ids) {
                $artifact = Get-GitHubArtifact -ApiUrl $ApiUrl -Repository $Repository -ArtifactId $id -Headers $headers
                if ($null -eq $artifact) { return @() }
                $artifact
            }
        }
        else {
            $available = @(Get-GitHubRunArtifacts -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId -Headers $headers)
            if ($selectors[0] -ceq 'name') {
                @($available | Where-Object {
                        (Get-ArtifactResponseProperty -Response $_ -Name 'name') -ceq $Name
                    })
            }
            else {
                @($available | Where-Object {
                        (Get-ArtifactResponseProperty -Response $_ -Name 'name') -clike $Pattern
                    })
            }
        }
    )

    if ($selectors[0] -ceq 'name' -and $selected.Count -gt 1) {
        throw "Artifact name '$Name' unexpectedly matched more than one artifact in workflow run $RunId."
    }
    foreach ($artifact in @($selected)) {
        $workflowRun = Get-ArtifactResponseProperty -Response $artifact -Name 'workflow_run'
        $artifactRun = [long] (Get-ArtifactResponseProperty -Response $workflowRun -Name 'id')
        if ($artifactRun -ne $RunId) {
            throw "Artifact '$((Get-ArtifactResponseProperty -Response $artifact -Name 'name'))' belongs to workflow run $artifactRun, not $RunId."
        }
        if ([bool] (Get-ArtifactResponseProperty -Response $artifact -Name 'expired')) {
            throw "Artifact '$((Get-ArtifactResponseProperty -Response $artifact -Name 'name'))' has expired."
        }
        $null = Get-ArtifactResponseProperty -Response $artifact -Name 'archive_download_url'
    }
    return @($selected)
}

# Downloads one archive. A not-found response is the only retryable result;
# authentication, authorization and service failures remain visible failures.
function Save-GitHubArtifactArchive {
    param(
        [Parameter(Mandatory)] $Artifact,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GitHubToken
    )

    $uri = Get-ArtifactResponseProperty -Response $Artifact -Name 'archive_download_url'
    try {
        Invoke-WebRequest -Uri $uri -Headers (Get-ArtifactHeaders -GitHubToken $GitHubToken) `
            -OutFile $Path -ErrorAction Stop
        return $true
    }
    catch {
        if ((Get-ArtifactHttpStatusCode -ErrorRecord $_) -eq 404) { return $false }
        throw
    }
}

# Resolves the download layout without accepting artifact names that can escape
# the destination. Name and single-ID downloads flatten; multi-artifact downloads
# retain the artifact-name directory behavior of actions/download-artifact.
function Get-ArtifactDestination {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] $Artifact,
        [Parameter(Mandatory)] [string] $Selector,
        [Parameter(Mandatory)] [int] $SelectedCount,
        [switch] $MergeMultiple
    )

    if ($MergeMultiple -or
        ($Selector -ceq 'name') -or
        ($Selector -ceq 'artifact-ids' -and $SelectedCount -eq 1)) {
        return $Root
    }
    $name = [string] (Get-ArtifactResponseProperty -Response $Artifact -Name 'name')
    if ([string]::IsNullOrWhiteSpace($name) -or $name -cin @('.', '..') -or $name -match '[\\/]') {
        throw "Artifact name '$name' cannot be used as a download directory."
    }
    return Join-Path $Root $name
}

# Bridges all same-run artifact selector forms through one bounded retry budget.
# The function downloads and validates every selected archive before extracting,
# so an eventual archive-ID race cannot leave a misleading partial artifact set.
function Invoke-ArtifactDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ApiUrl,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [ValidateRange(1, [long]::MaxValue)] [long] $RunId,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GitHubToken,
        [string] $ArtifactIds,
        [string] $Name,
        [string] $Pattern,
        [string] $ProducerJobPrefix,
        [string] $ProducerStep,
        [string] $ArtifactNamePrefix,
        [switch] $ArtifactNameIncludesJobSuffix,
        [switch] $MergeMultiple,
        [ValidateRange(1, 100)] [int] $MaximumAttempts = $script:DefaultMaximumAttempts,
        [ValidateRange(0, 60)] [int] $RetryDelaySeconds = $script:DefaultRetryDelaySeconds
    )

    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Expected GitHub repository in owner/name form.'
    }
    $selector = @(
        if (-not [string]::IsNullOrWhiteSpace($ArtifactIds)) { 'artifact-ids' }
        if (-not [string]::IsNullOrWhiteSpace($Name)) { 'name' }
        if (-not [string]::IsNullOrWhiteSpace($Pattern)) { 'pattern' }
    )
    if ($selector.Count -ne 1) {
        throw 'Artifact download requires exactly one of artifact-ids, name or pattern.'
    }
    if ([string]::IsNullOrWhiteSpace($GitHubToken)) {
        throw 'Artifact download requires a GitHub token.'
    }
    $producerInputs = @(
        if (-not [string]::IsNullOrWhiteSpace($ProducerJobPrefix)) { 'producer-job-prefix' }
        if (-not [string]::IsNullOrWhiteSpace($ProducerStep)) { 'producer-step' }
        if (-not [string]::IsNullOrWhiteSpace($ArtifactNamePrefix)) { 'artifact-name-prefix' }
    )
    if (($selector[0] -ceq 'pattern' -and $producerInputs.Count -ne 3) -or
        ($selector[0] -cne 'pattern' -and ($producerInputs.Count -ne 0 -or $ArtifactNameIncludesJobSuffix))) {
        throw 'Pattern downloads require producer job, step and artifact-name inputs; other selectors reject them.'
    }

    $destination = [IO.Path]::GetFullPath($Path)
    $temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
    $downloadRoot = Join-Path $temporaryRoot "cbh-artifacts-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $downloadRoot | Out-Null
    try {
        for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
            $selected = @(Select-GitHubArtifacts -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId `
                    -GitHubToken $GitHubToken -ArtifactIds $ArtifactIds -Name $Name -Pattern $Pattern)
            $ready = $selected.Count -gt 0
            if ($selector[0] -ceq 'pattern') {
                $expectedNames = @(Get-ExpectedArtifactNames -ApiUrl $ApiUrl -Repository $Repository -RunId $RunId `
                        -JobPrefix $ProducerJobPrefix -StepName $ProducerStep -ArtifactNamePrefix $ArtifactNamePrefix `
                        -Headers (Get-ArtifactHeaders -GitHubToken $GitHubToken) `
                        -IncludeJobSuffix:$ArtifactNameIncludesJobSuffix)
                $selectedNames = @($selected | ForEach-Object {
                        [string] (Get-ArtifactResponseProperty -Response $_ -Name 'name')
                    })
                $missingNames = @($expectedNames | Where-Object { $selectedNames -notcontains $_ })
                $ready = $selected.Count -gt 0 -and $expectedNames.Count -gt 0 -and $missingNames.Count -eq 0
            }
            $archives = @()
            if ($ready) {
                Remove-Item -LiteralPath (Join-Path $downloadRoot 'archives') -Recurse -Force -ErrorAction SilentlyContinue
                $archiveDirectory = Join-Path $downloadRoot 'archives'
                New-Item -ItemType Directory -Path $archiveDirectory | Out-Null
                foreach ($artifact in $selected) {
                    $id = [long] (Get-ArtifactResponseProperty -Response $artifact -Name 'id')
                    $archive = Join-Path $archiveDirectory "$id.zip"
                    if (-not (Save-GitHubArtifactArchive -Artifact $artifact -Path $archive -GitHubToken $GitHubToken)) {
                        $ready = $false
                        break
                    }
                    $archives += @{ artifact = $artifact; path = $archive }
                }
            }

            if ($ready) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                foreach ($archive in $archives) {
                    $target = Get-ArtifactDestination -Root $destination -Artifact $archive.artifact `
                        -Selector $selector[0] -SelectedCount $selected.Count -MergeMultiple:$MergeMultiple
                    New-Item -ItemType Directory -Path $target -Force | Out-Null
                    Expand-Archive -LiteralPath $archive.path -DestinationPath $target -Force
                }
                return
            }

            if ($attempt -eq $MaximumAttempts) {
                throw "Selected artifacts were still unavailable for workflow run $RunId after $MaximumAttempts attempts."
            }
            Write-Output "Selected artifacts are not visible yet for workflow run $RunId; retrying."
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
    finally {
        Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-ArtifactDownload
