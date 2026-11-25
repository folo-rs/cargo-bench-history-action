#Requires -Version 7.6
# Same-run visibility tests use mocked REST responses and never wait in real time.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'ArtifactVisibility.psm1') -Force

# Models the REST exception shape without requiring a live HTTP request.
class ArtifactVisibilityHttpException : System.Exception {
    [object] $Response

    ArtifactVisibilityHttpException([int] $StatusCode) : base("HTTP $StatusCode") {
        $this.Response = [pscustomobject]@{ StatusCode = $StatusCode }
    }
}

InModuleScope ArtifactVisibility {
    Describe 'Same-run artifact visibility' {
        BeforeEach {
            $script:windows = [pscustomobject]@{
                id = 41
                name = 'collection-windows-latest-1'
                created_at = '2026-01-01T00:01:30Z'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/41/zip'
            }
            $script:ubuntu = [pscustomobject]@{
                id = 42
                name = 'collection-ubuntu-latest-1'
                created_at = '2026-01-01T00:01:30Z'
                expired = $false
                archive_download_url = 'https://api.github.test/artifacts/42/zip'
            }
            $script:reads = 0
            Mock Start-Sleep {}
        }

        It 'waits for an artifact ID in the same paginated run inventory used by downloads' {
            Mock Invoke-RestMethod {
                $script:reads++
                [pscustomobject]@{
                    total_count = 1
                    artifacts = @(
                        [pscustomobject]@{
                            id = if ($script:reads -eq 1) { 99 } else { 41 }
                            name = 'collection-windows-latest-1'
                            expired = $false
                            archive_download_url = 'https://api.github.test/artifacts/redirect'
                        }
                    )
                }
            }

            $selection = @(Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -RunId 7 -RunAttempt 2 `
                    -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0)

            $selection.Id | Should -Be @(41)
            $selection.Name | Should -Be @('collection-windows-latest-1')
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
                $Uri -ceq 'https://api.github.test/repos/owner/repository/actions/runs/7/artifacts?per_page=100&page=1' -and
                    $Headers.Authorization -ceq 'Bearer token' -and $TimeoutSec -eq 30
            }
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'searches every artifact page before retrying a missing exact ID' {
            Mock Invoke-RestMethod {
                if ($Uri -like '*page=1') {
                    [pscustomobject]@{
                        total_count = 2
                        artifacts = @([pscustomobject]@{
                                id = 99
                                name = 'other'
                                expired = $false
                                archive_download_url = 'https://api.github.test/artifacts/99/zip'
                            })
                    }
                }
                else {
                    [pscustomobject]@{
                        total_count = 2
                        artifacts = @($script:windows)
                    }
                }
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                -MaximumAttempts 1

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*/artifacts?per_page=100&page=2'
            }
        }

        It 'preserves an empty run inventory as a visibility miss' {
            Mock Invoke-RestMethod {
                $script:reads++
                $artifacts = if ($script:reads -eq 1) {
                    [object[]]::new(0)
                }
                else {
                    @($script:windows)
                }
                [pscustomobject]@{
                    total_count = if ($script:reads -eq 1) { 0 } else { 1 }
                    artifacts = $artifacts
                }
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Name $script:windows.name `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'does not let an old exact-name artifact satisfy a rerun producer' {
            Mock Get-GitHubRunArtifacts {
                $script:reads++
                @([pscustomobject]@{
                        id = 50
                        name = 'canary-fixture'
                        expired = $false
                        archive_download_url = 'https://api.github.test/artifacts/50/zip'
                        created_at = if ($script:reads -eq 1) {
                            '2026-01-01T00:00:30Z'
                        }
                        else {
                            '2026-01-01T00:02:30Z'
                        }
                    })
            }
            Mock Get-GitHubRunAttemptJobs {
                @([pscustomobject]@{
                        name = 'benchmark / cbh-collect:action-canary-ubuntu-latest:ubuntu-latest'
                        started_at = '2026-01-01T00:02:00Z'
                status = 'completed'
                conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload fixture'
                                conclusion = 'success'
                            })
                    })
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Name 'canary-fixture' `
                -ProducerJobPrefix 'cbh-collect:action-canary-ubuntu-latest:ubuntu-latest' `
                -ProducerStep 'Upload fixture' -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
            Should -Invoke Get-GitHubRunAttemptJobs -Times 2 -Exactly
        }

        It 'counts distinct pattern names and resets through a nonempty-empty-nonempty sequence' {
            Mock Get-GitHubRunArtifacts {
                $script:reads++
                if ($script:reads -eq 1) { return @($script:windows, $script:windows) }
                if ($script:reads -eq 2) { return @() }
                return @($script:windows, $script:ubuntu)
            }
            Mock Get-GitHubRunAttemptJobs {
                @(
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:ubuntu-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                )
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Pattern 'collection-*' `
                -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix `
                -ExpectedIdentities 'windows-latest,ubuntu-latest' `
                -MaximumAttempts 3 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 2 -Exactly
            Should -Invoke Get-GitHubRunAttemptJobs -Times 3 -Exactly
        }

        It 'waits for a rerun artifact while accepting untouched inherited producers' {
            Mock Get-GitHubRunArtifacts {
                $script:reads++
                if ($script:reads -eq 1) {
                    return @($script:windows, $script:ubuntu)
                }
                return @(
                    [pscustomobject]@{
                        id = 43
                        name = 'collection-windows-latest-2'
                        created_at = '2026-01-01T00:02:30Z'
                        expired = $false
                        archive_download_url = 'https://api.github.test/artifacts/43/zip'
                    }
                    $script:ubuntu
                )
            }
            Mock Get-GitHubRunAttemptJobs {
                @(
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:02:00Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:ubuntu-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                )
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Pattern 'collection-*' `
                -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix `
                -ExpectedIdentities 'windows-latest,ubuntu-latest' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'requires a successful upload step before applying producer freshness' {
            Mock Get-GitHubRunArtifacts { @($script:windows) }
            Mock Get-GitHubRunAttemptJobs {
                @([pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:02:00Z'
                        status = 'completed'
                        conclusion = 'failure'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'failure'
                            })
                    })
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Pattern 'collection-*' `
                -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix `
                -ExpectedIdentities 'windows-latest' -MaximumAttempts 1
        }

        It 'allows a confirmed failed platform while retaining successful partial evidence' {
            Mock Get-GitHubRunArtifacts { @($script:ubuntu) }
            Mock Get-GitHubRunAttemptJobs {
                @(
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'failure'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'skipped'
                            })
                    }
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:ubuntu-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                )
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 1 -GitHubToken 'token' -Pattern 'collection-*' `
                -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix `
                -ExpectedIdentities 'windows-latest,ubuntu-latest' -MaximumAttempts 1
        }

        It 'does not inspect steps belonging to unrelated jobs' {
            Mock Get-GitHubRunArtifacts { @($script:windows) }
            Mock Get-GitHubRunAttemptJobs {
                @(
                    [pscustomobject]@{
                        name = 'caller / unrelated-workflow'
                        status = 'in_progress'
                        steps = @([pscustomobject]@{ name = 'Upload receipt' })
                    }
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:00:10Z'
                        status = 'completed'
                        conclusion = 'success'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                )
            }

            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 1 -GitHubToken 'token' -Pattern 'collection-*' `
                    -ProducerJobPrefix 'cbh-collect:project:' -ProducerStep 'Upload receipt' `
                    -ArtifactNamePrefix 'collection-' -ArtifactNameIncludesJobSuffix `
                    -ExpectedIdentities 'windows-latest' -MaximumAttempts 1
            } | Should -Not -Throw
        }

        It 'retries a failed transfer with the workflow credential until archive access is ready' {
            $script:archiveReads = 0
            Mock Get-ArtifactArchiveStatus {
                $script:archiveReads++
                if ($Uri -like '*/42/zip' -and $script:archiveReads -eq 2) { return 404 }
                return 302
            }

            Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                -Repository 'owner/repository' -GitHubToken 'job-token' `
                -ArtifactIds 41,42 | Should -BeTrue

            Should -Invoke Get-ArtifactArchiveStatus -Times 1 -Exactly -ParameterFilter {
                $Uri -ceq 'https://api.github.test/repos/owner/repository/actions/artifacts/41/zip' -and
                    $Headers.Authorization -ceq 'Bearer job-token'
            }
            Should -Invoke Get-ArtifactArchiveStatus -Times 2 -Exactly -ParameterFilter {
                $Uri -ceq 'https://api.github.test/repos/owner/repository/actions/artifacts/42/zip'
            }
            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'does not retry a transfer when the archive was already ready' {
            Mock Get-ArtifactArchiveStatus { 302 }

            {
                Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -GitHubToken 'job-token' -ArtifactIds 41
            } | Should -Throw '*not a classified artifact-visibility error*'

            Should -Invoke Get-ArtifactArchiveStatus -Times 1 -Exactly
            Should -Invoke Start-Sleep -Times 0
        }

        It 'retries a known incomplete transfer when every archive is ready' {
            Mock Get-ArtifactArchiveStatus { 302 }

            Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                -Repository 'owner/repository' -GitHubToken 'job-token' `
                -ArtifactIds 41,42 -AllowReadyRedirect | Should -BeTrue

            Should -Invoke Get-ArtifactArchiveStatus -Times 2 -Exactly
            Should -Invoke Start-Sleep -Times 0
        }

        It 'propagates a permanent archive status without retry' -ForEach @(
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 410 }
        ) {
            Mock Get-ArtifactArchiveStatus { $StatusCode }

            {
                Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -GitHubToken 'job-token' -ArtifactIds 41
            } | Should -Throw "*HTTP $StatusCode*attempt 1/*"

            Should -Invoke Start-Sleep -Times 0
        }

        It 'falls back after persistent REST 404 for one immutable artifact ID' {
            Mock Get-ArtifactArchiveStatus { 404 }

            Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                -Repository 'owner/repository' -GitHubToken 'job-token' -ArtifactIds 41 |
                Should -BeFalse

            Should -Invoke Get-ArtifactArchiveStatus -Times 12 -Exactly
            Should -Invoke Start-Sleep -Times 11 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'never accepts persistent REST 404 for an incomplete multi-ID transfer' {
            Mock Get-ArtifactArchiveStatus { 404 }

            {
                Wait-ArtifactArchiveRedirect -ApiUrl 'https://api.github.test' `
                    -Repository 'owner/repository' -GitHubToken 'job-token' -ArtifactIds 41,42
            } | Should -Throw '*artifact 41*HTTP 404*attempt 12/12*'
        }

        It 'rejects incomplete multi-artifact staging and publishes only a complete set' {
            $selection = @(
                [pscustomobject]@{ Id = 41; Name = $script:windows.name }
                [pscustomobject]@{ Id = 42; Name = $script:ubuntu.name }
            )
            $stage = Join-Path $TestDrive 'stage'
            $destination = Join-Path $TestDrive 'destination'
            $null = New-Item -ItemType Directory -Path (Join-Path $stage $script:windows.name) -Force
            $null = New-Item -ItemType Directory -Path $destination -Force
            'preparation' | Set-Content -LiteralPath (Join-Path $destination 'preparation.json')

            {
                Assert-ArtifactTransferComplete -Path $stage -Selection $selection
            } | Should -Throw "*missing*$($script:ubuntu.name)*"

            {
                Publish-ArtifactTransfer -Path $stage -Selection $selection -Destination $destination
            } | Should -Throw "*missing*$($script:ubuntu.name)*"
            Test-Path -LiteralPath (Join-Path $destination 'preparation.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $destination $script:windows.name) | Should -BeFalse

            $null = New-Item -ItemType Directory -Path (Join-Path $stage $script:ubuntu.name) -Force
            Publish-ArtifactTransfer -Path $stage -Selection $selection -Destination $destination

            Test-Path -LiteralPath (Join-Path $destination 'preparation.json') | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $destination $script:windows.name) | Should -BeTrue
            Test-Path -LiteralPath (Join-Path $destination $script:ubuntu.name) | Should -BeTrue
        }

        It 'fails clearly after the bounded visibility budget' {
            Mock Get-GitHubRunArtifacts { return @() }

            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Name 'missing' `
                    -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*after 3 attempts*'

            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It 'uses the agreed twelve-attempt and five-second default budget' {
            Mock Get-GitHubRunArtifacts { @() }

            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41'
            } | Should -Throw '*12 attempts*'

            Should -Invoke Get-GitHubRunArtifacts -Times 12 -Exactly
            Should -Invoke Start-Sleep -Times 11 -Exactly -ParameterFilter { $Seconds -eq 5 }
        }

        It 'retries recognized transient HTTP status <StatusCode>' -ForEach @(
            @{ StatusCode = 404 }
            @{ StatusCode = 408 }
            @{ StatusCode = 429 }
            @{ StatusCode = 500 }
            @{ StatusCode = 502 }
            @{ StatusCode = 503 }
            @{ StatusCode = 504 }
        ) {
            Mock Get-GitHubRunArtifacts {
                if (++$script:reads -eq 1) {
                    throw [ArtifactVisibilityHttpException]::new($StatusCode)
                }
                @($script:windows)
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

            Should -Invoke Start-Sleep -Times 1 -Exactly
        }

        It 'propagates permanent HTTP status <StatusCode> without retry' -ForEach @(
            @{ StatusCode = 401 }
            @{ StatusCode = 403 }
            @{ StatusCode = 410 }
        ) {
            Mock Get-GitHubRunArtifacts {
                throw [ArtifactVisibilityHttpException]::new($StatusCode)
            }

            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw "*HTTP $StatusCode*"

            Should -Invoke Start-Sleep -Times 0
        }

        It 'propagates statusless timeout and transport errors without retry' {
            Mock Get-GitHubRunArtifacts {
                throw [System.TimeoutException]::new('request timed out')
            }
            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw '*request timed out*'
            Should -Invoke Start-Sleep -Times 0

            Mock Get-GitHubRunArtifacts {
                throw [System.IO.IOException]::new('connection reset')
            }
            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw '*connection reset*'
        }
    }
}
