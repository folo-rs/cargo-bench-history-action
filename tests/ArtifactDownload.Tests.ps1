#Requires -Version 7.6
# Same-run artifact retry tests use mocked GitHub responses and never wait in real time.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'ArtifactDownload.psm1') -Force

InModuleScope ArtifactDownload {
    Describe 'Same-run artifact downloads' {
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
                    -Pattern 'collection-*' -MaximumAttempts 3 -RetryDelaySeconds 0
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
                    -Pattern 'collection-*' -MaximumAttempts 3 -RetryDelaySeconds 0
            } | Should -Throw '*denied access*'

            Should -Invoke Start-Sleep -Times 0
            Should -Invoke Save-GitHubArtifactArchive -Times 0
        }

        It 'preserves per-artifact pattern directories and flattens exact-name downloads' {
            Mock Select-GitHubArtifacts { @($script:artifact, $script:secondArtifact) }
            Mock Save-GitHubArtifactArchive { $true }
            $patternRoot = Join-Path $TestDrive 'pattern'

            Invoke-ArtifactDownload -ApiUrl 'https://api.github.test' -Repository 'owner/repository' `
                -RunId 7 -GitHubToken 'token' -Path $patternRoot -Pattern 'collection-*'

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
    }
}
