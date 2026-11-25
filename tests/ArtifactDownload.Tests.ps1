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
            }
            $script:ubuntu = [pscustomobject]@{
                id = 42
                name = 'collection-ubuntu-latest-1'
                created_at = '2026-01-01T00:01:30Z'
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
                            name = 'unrelated'
                        }
                    )
                }
            }

            Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                -MaximumAttempts 2 -RetryDelaySeconds 0

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
                        artifacts = @([pscustomobject]@{ id = 99; name = 'other' })
                    }
                }
                else {
                    [pscustomobject]@{
                        total_count = 2
                        artifacts = @([pscustomobject]@{ id = 41; name = 'wanted' })
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
            Mock Get-GitHubRunAttemptJobs { @() }

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
                    }
                    $script:ubuntu
                )
            }
            Mock Get-GitHubRunAttemptJobs {
                @(
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:windows-latest'
                        started_at = '2026-01-01T00:02:00Z'
                        steps = @([pscustomobject]@{
                                name = 'Upload receipt'
                                conclusion = 'success'
                            })
                    }
                    [pscustomobject]@{
                        name = 'caller / cbh-collect:project:ubuntu-latest'
                        started_at = '2026-01-01T00:00:10Z'
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

        It 'fails clearly after the bounded visibility budget' {
            Mock Get-GitHubRunArtifacts { return @() }

            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -Name 'missing' `
                    -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*after 3 attempts*'

            Should -Invoke Start-Sleep -Times 2 -Exactly
        }

        It 'retries recognized transient HTTP status <StatusCode>' -ForEach @(
            @{ StatusCode = 408 }
            @{ StatusCode = 429 }
            @{ StatusCode = 503 }
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
            @{ StatusCode = 404 }
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

        It 'retries a timeout but propagates an ordinary statusless transport error' {
            Mock Get-GitHubRunArtifacts {
                throw [System.TimeoutException]::new('request timed out')
            }
            {
                Wait-ArtifactVisibility -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                    -RunId 7 -RunAttempt 2 -GitHubToken 'token' -ArtifactIds '41' `
                    -MaximumAttempts 2 -RetryDelaySeconds 0
            } | Should -Throw '*after 2 attempts*'
            Should -Invoke Start-Sleep -Times 1 -Exactly

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
