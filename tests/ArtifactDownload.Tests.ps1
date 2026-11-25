#Requires -Version 7.6
# Same-run artifact retry tests use mocked GitHub responses and never wait in real time.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'ArtifactDownload.psm1') -Force

# Models PowerShell's HTTP response exception shape without making network requests.
class ArtifactDownloadHttpException : System.Exception {
    [object] $Response

    ArtifactDownloadHttpException([int] $StatusCode) : base("HTTP $StatusCode") {
        $this.Response = [pscustomobject]@{ StatusCode = $StatusCode }
    }
}

InModuleScope ArtifactDownload {
    Describe 'Same-run artifact downloads' {
        BeforeAll {
            $script:saveArchiveImplementation = ${function:Save-GitHubArtifactArchive}
        }

        BeforeEach {
            $script:artifact = [pscustomobject]@{
                id = 41
                name = 'collection-windows-latest-1'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/41/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:secondArtifact = [pscustomobject]@{
                id = 42
                name = 'collection-ubuntu-latest-1'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/42/zip'
                workflow_run = [pscustomobject]@{ id = 7 }
            }
            $script:selectionCalls = 0
            $script:archiveCalls = 0
            $script:originalRunnerTemp = $env:RUNNER_TEMP
            $env:RUNNER_TEMP = $TestDrive
            Mock Start-Sleep {}
            Mock Expand-Archive {}
            Mock Save-GitHubArtifactArchive {
                $script:archiveCalls++
                return $true
            }
        }

        AfterEach {
            $env:RUNNER_TEMP = $script:originalRunnerTemp
        }

        It 'resolves exact name and pattern selectors from the authenticated run inventory' {
            Mock Get-GitHubRunArtifacts { @($script:artifact, $script:secondArtifact) }
            $parameters = @{
                ApiUrl = 'https://api.github.test'
                Repository = 'owner/repository'
                RunId = 7
                GitHubToken = 'token'
            }

            @(Select-GitHubArtifacts @parameters -Name $script:artifact.name).name |
                Should -Be @($script:artifact.name)
            @(Select-GitHubArtifacts @parameters -Pattern 'collection-*-1').name |
                Should -Be @($script:artifact.name, $script:secondArtifact.name)
        }

        It 'resolves comma-separated IDs without listing unrelated run artifacts' {
            Mock Get-GitHubArtifact {
                if ($ArtifactId -eq 41) { return $script:artifact }
                if ($ArtifactId -eq 42) { return $script:secondArtifact }
                return $null
            }
            Mock Get-GitHubRunArtifacts { throw 'ID selection must not list the run.' }

            $selected = @(Select-GitHubArtifacts -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -GitHubToken 'token' `
                    -ArtifactIds '41, 42')

            $selected.id | Should -Be @(41, 42)
            Should -Invoke Get-GitHubRunArtifacts -Times 0
        }

        It 'rejects ambiguous selectors and artifacts owned by another run' {
            { Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Name 'one' -Pattern 'one*' } |
                Should -Throw '*exactly one*'
            Mock Get-GitHubArtifact {
                [pscustomobject]@{
                    id = 41
                    name = 'wrong-run'
                    expired = $false
                    archive_download_url = 'https://api.github.test/artifacts/41/zip'
                    workflow_run = [pscustomobject]@{ id = 8 }
                }
            }
            { Select-GitHubArtifacts -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -ArtifactIds '41' } |
                Should -Throw '*belongs to workflow run 8, not 7*'
        }

        It 'retries a real empty run inventory and a real exact-name miss' {
            $script:inventoryCalls = 0
            Mock Invoke-RestMethod {
                $script:inventoryCalls++
                if ($script:inventoryCalls -eq 1) {
                    return [pscustomobject]@{ total_count = 0; artifacts = @() }
                }
                return [pscustomobject]@{ total_count = 1; artifacts = @($script:artifact) }
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'empty-inventory') `
                -Name $script:artifact.name -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 1 -Exactly

            $script:inventoryCalls = 0
            Mock Invoke-RestMethod {
                $script:inventoryCalls++
                $artifacts = if ($script:inventoryCalls -eq 1) {
                    @($script:secondArtifact)
                }
                else {
                    @($script:artifact, $script:secondArtifact)
                }
                return [pscustomobject]@{ total_count = $artifacts.Count; artifacts = $artifacts }
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'name-miss') `
                -Name $script:artifact.name -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 2 -Exactly
        }

        It 'waits for every exact pattern artifact named by completed producer jobs' {
            $script:inventoryCalls = 0
            Mock Invoke-RestMethod {
                if ($Uri -like '*/jobs?*') {
                    $jobs = @(
                        [pscustomobject]@{
                            name = 'cbh-collect:project:windows-latest'
                            run_attempt = 1
                            started_at = '2026-01-01T00:00:00Z'
                            completed_at = '2026-01-01T00:01:00Z'
                            steps = @([pscustomobject]@{
                                    name = 'Upload receipt'
                                    conclusion = 'success'
                                })
                        }
                        [pscustomobject]@{
                            name = 'cbh-collect:project:ubuntu-latest'
                            run_attempt = 1
                            started_at = '2026-01-01T00:00:00Z'
                            completed_at = '2026-01-01T00:01:00Z'
                            steps = @([pscustomobject]@{
                                    name = 'Upload receipt'
                                    conclusion = 'success'
                                })
                        }
                    )
                    return [pscustomobject]@{ total_count = $jobs.Count; jobs = $jobs }
                }
                $script:inventoryCalls++
                $artifacts = if ($script:inventoryCalls -eq 1) {
                    @($script:artifact)
                }
                else {
                    @($script:artifact, $script:secondArtifact)
                }
                return [pscustomobject]@{ total_count = $artifacts.Count; artifacts = $artifacts }
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'complete-pattern') `
                -Pattern 'collection-*' -ProducerJobPrefix 'cbh-collect:project:' `
                -ProducerStep 'Upload receipt' -ArtifactNamePrefix 'collection-' `
                -ArtifactNameIncludesJobSuffix -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 2 -Exactly
            Should -Invoke Expand-Archive -Times 2 -Exactly
        }

        It 'normalizes reusable-workflow job prefixes when deriving expected names' {
            Mock Get-GitHubRunJobs {
                @([pscustomobject]@{
                        name = 'benchmark / cbh-collect:project:ubuntu-latest'
                        run_attempt = 1
                        started_at = '2026-01-01T00:00:00Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{ name = 'Upload receipt'; conclusion = 'success' })
                    })
            }

            @(Get-ExpectedArtifactNames -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -JobPrefix 'cbh-collect:project:' -StepName 'Upload receipt' `
                    -ArtifactNamePrefix 'collection-' -Headers @{} -IncludeJobSuffix $true) |
                Should -Be @('collection-ubuntu-latest-1')
        }

        It 'omits a successful job copy reused by a partial rerun' {
            Mock Get-GitHubRunJobs {
                @(
                    [pscustomobject]@{
                        name = 'benchmark / cbh-collect:project:ubuntu-latest'
                        run_attempt = 1
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{ name = 'Upload receipt'; conclusion = 'success' })
                    }
                    [pscustomobject]@{
                        name = 'benchmark / cbh-collect:project:ubuntu-latest'
                        run_attempt = 2
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{ name = 'Upload receipt'; conclusion = 'success' })
                    }
                    [pscustomobject]@{
                        name = 'benchmark / cbh-collect:project:windows-latest'
                        run_attempt = 2
                        started_at = '2026-01-01T00:02:10Z'
                        completed_at = '2026-01-01T00:03:00Z'
                        steps = @([pscustomobject]@{ name = 'Upload receipt'; conclusion = 'success' })
                    }
                    [pscustomobject]@{
                        name = 'benchmark / cbh-collect:project:ubuntu-latest'
                        run_attempt = 3
                        started_at = '2026-01-01T00:00:10Z'
                        completed_at = '2026-01-01T00:01:00Z'
                        steps = @([pscustomobject]@{ name = 'Upload receipt'; conclusion = 'success' })
                    }
                )
            }
            Mock Get-GitHubRunAttemptStart {
                [DateTimeOffset]::Parse('2026-01-01T00:02:00Z').AddMinutes($Attempt - 2)
            }

            @(Get-ExpectedArtifactNames -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -JobPrefix 'cbh-collect:project:' -StepName 'Upload receipt' `
                    -ArtifactNamePrefix 'collection-' -Headers @{} -IncludeJobSuffix $true) |
                Should -Be @('collection-ubuntu-latest-1', 'collection-windows-latest-2')
        }

        It 'retries metadata absence and stops once the selector becomes visible' {
            Mock Select-GitHubArtifacts {
                $script:selectionCalls++
                if ($script:selectionCalls -lt 3) { return @() }
                return @($script:artifact)
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'metadata') `
                -Name $script:artifact.name -MaximumAttempts 3 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 1 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
        }

        It 'retries an archive endpoint that is not yet downloadable' {
            Mock Select-GitHubArtifacts { @($script:artifact) }
            Mock Save-GitHubArtifactArchive {
                $script:archiveCalls++
                return $script:archiveCalls -gt 1
            }

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'archive') `
                -ArtifactIds '41' -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 2 -Exactly
            Should -Invoke Expand-Archive -Times 1 -Exactly
        }

        It 'fails clearly after the bounded visibility budget' {
            Mock Select-GitHubArtifacts { @() }

            {
                Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'missing') `
                    -Name 'collection-missing' -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*still unavailable*3 attempts*'

            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Save-GitHubArtifactArchive -Times 0
            Should -Invoke Expand-Archive -Times 0
        }

        It 'does not retry unrelated selection failures' {
            Mock Select-GitHubArtifacts { throw 'GitHub denied access.' }

            {
                Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -GitHubToken 'token' -Path (Join-Path $TestDrive 'denied') `
                    -Name 'collection-denied' -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*denied access*'

            Should -Invoke Start-Sleep -Times 0
            Should -Invoke Save-GitHubArtifactArchive -Times 0
        }

        It 'preserves per-artifact pattern directories and flattens exact-name downloads' {
            Mock Select-GitHubArtifacts { @($script:artifact, $script:secondArtifact) }
            Mock Get-ExpectedArtifactNames { @($script:artifact.name, $script:secondArtifact.name) }
            Mock Save-GitHubArtifactArchive { $true }
            $patternRoot = Join-Path $TestDrive 'pattern'

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path $patternRoot -Pattern 'collection-*' `
                -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix

            foreach ($artifact in @($script:artifact, $script:secondArtifact)) {
                $target = Join-Path $patternRoot $artifact.name
                Should -Invoke Expand-Archive -Times 1 -Exactly -ParameterFilter {
                    $DestinationPath -ceq $target
                }
            }

            Mock Select-GitHubArtifacts { @($script:artifact) }
            $nameRoot = Join-Path $TestDrive 'name'
            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path $nameRoot -Name $script:artifact.name

            Should -Invoke Expand-Archive -Times 1 -Exactly -ParameterFilter {
                $DestinationPath -ceq $nameRoot
            }
        }

        It 'retries an artifact metadata 404' {
            Mock Invoke-RestMethod { throw [ArtifactDownloadHttpException]::new(404) }

            Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -ArtifactId 41 -Headers (Get-ArtifactHeaders -GitHubToken 'token') |
                Should -BeNullOrEmpty
        }

        It 'propagates artifact metadata HTTP <StatusCode> without retry' -TestCases @(
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 410 }
        ) {
            param($StatusCode)
            $script:statusCode = $StatusCode
            Mock Invoke-RestMethod { throw [ArtifactDownloadHttpException]::new($script:statusCode) }

            { Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -ArtifactId 41 -Headers (Get-ArtifactHeaders -GitHubToken 'token') } |
                Should -Throw "*HTTP $StatusCode*"
        }

        It 'propagates a statusless metadata transport error' {
            Mock Invoke-RestMethod { throw [System.IO.IOException]::new('transport failed') }

            { Get-GitHubArtifact -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -ArtifactId 41 -Headers (Get-ArtifactHeaders -GitHubToken 'token') } |
                Should -Throw '*transport failed*'
        }

        It 'returns false for an artifact archive 404' {
            Mock Invoke-WebRequest { throw [ArtifactDownloadHttpException]::new(404) }

            & $script:saveArchiveImplementation -Artifact $script:artifact `
                -Path (Join-Path $TestDrive 'artifact.zip') -GitHubToken 'token' |
                Should -BeFalse
        }

        It 'propagates artifact archive HTTP <StatusCode> without retry' -TestCases @(
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 410 }
        ) {
            param($StatusCode)
            $script:statusCode = $StatusCode
            Mock Invoke-WebRequest { throw [ArtifactDownloadHttpException]::new($script:statusCode) }

            { & $script:saveArchiveImplementation -Artifact $script:artifact `
                    -Path (Join-Path $TestDrive 'artifact.zip') -GitHubToken 'token' } |
                Should -Throw "*HTTP $StatusCode*"
        }

        It 'propagates a statusless archive transport error' {
            Mock Invoke-WebRequest { throw [System.IO.IOException]::new('transport failed') }

            { & $script:saveArchiveImplementation -Artifact $script:artifact `
                    -Path (Join-Path $TestDrive 'artifact.zip') -GitHubToken 'token' } |
                Should -Throw '*transport failed*'
        }
    }
}
