#Requires -Version 7.6
# Pester exercises release policy and retry ordering without GitHub or Git writes.
# Native Git read adapters have separate hermetic fixtures in Release.Integration.Tests.ps1.
BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Release.psm1') -Force
}

Describe 'Release-bearing paths' {
    It 'requires increments for distributed runtime and reusable workflow changes' -ForEach @(
        'action.yml', 'release.json', 'scripts/Tools.psm1', 'scripts/Run-Action.ps1',
        'scripts/New-Runtime.ps1', '.github/workflows/history.yml', '.github/workflows/pr.yml'
    ) {
        Test-ReleaseBearingPath $_ | Should -BeTrue
    }

    It 'permits unchanged versions for documentation, tests and owned CI' -ForEach @(
        'README.md', 'docs/design.md', 'tests/Release.Tests.ps1',
        '.github/monorepo-revision', '.github/workflows/test.yml',
        '.github/workflows/install-tools.yml', '.github/workflows/release.yml',
        'scripts/Release.psm1', 'scripts/Publish-Release.ps1', 'scripts/Install-Canary.ps1'
    ) {
        Test-ReleaseBearingPath $_ | Should -BeFalse
    }
}

Describe 'Stable release versions' {
    It 'orders numeric components rather than lexical tag names' {
        (ConvertTo-ReleaseVersion '1.10.0') | Should -BeGreaterThan (ConvertTo-ReleaseVersion '1.9.0')
    }

    It 'rejects ambiguous or prerelease versions' -ForEach @('v1.0.0', '01.0.0', '1.0', '1.0.0-rc.1') {
        { ConvertTo-ReleaseVersion $_ } | Should -Throw
    }
}

Describe 'Release reconciliation' {
    InModuleScope Release {
        BeforeEach {
            $script:version = '1.2.0'
            $script:baseVersion = '1.1.0'
            $script:tagTarget = $null
            $script:majorTarget = $null
            $script:majorVersion = '1.1.0'
            $script:tagContent = 'runtime'
            $script:releaseExists = $false
            $script:operations = [System.Collections.Generic.List[string]]::new()
            Mock Get-ReleaseManifestAtRef {
                param($Ref)
                $v = switch ($Ref) {
                    'base' { $script:baseVersion }
                    'major-commit' { $script:majorVersion }
                    default { $script:version }
                }
                [pscustomobject] @{ schema_version = 1; version = $v }
            }
            Mock Get-ReleaseContent {
                param($Ref)
                if ($Ref -eq 'base') { return 'baseline' }
                if ($Ref -eq 'original') { return $script:tagContent }
                return 'runtime'
            }
            Mock Invoke-ReleaseGit {
                param($Arguments)
                if ($Arguments[0] -eq 'rev-parse') {
                    switch ($Arguments[-1]) {
                        'HEAD^{commit}' { return 'candidate' }
                        'refs/tags/v1^{commit}' { return $script:majorTarget }
                        'refs/tags/v1' { return $script:majorTarget }
                        default { return $script:tagTarget }
                    }
                }
                if ($Arguments[0] -eq 'push') {
                    $script:operations.Add("git $($Arguments -join ' ')")
                }
            }
            Mock Invoke-ReleaseGh {
                param($Arguments)
                if ($Arguments[0] -eq 'api') {
                    if ($script:releaseExists) {
                        return '[[{"tag_name":"v1.2.0","draft":false,"prerelease":false}]]'
                    }
                    return '[[]]'
                }
                $script:operations.Add("gh $($Arguments -join ' ')")
            }
        }

        It 'publishes immutable tag before release before floating tag' {
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 3
            $script:operations[0] | Should -Be 'git push origin candidate:refs/tags/v1.2.0'
            $script:operations[1] | Should -Match '^gh release create v1\.2\.0 '
            $script:operations[1] | Should -Match '--verify-tag'
            $script:operations[1] | Should -Match '--notes \[Copilot speaking\]'
            $script:operations[2] | Should -Be 'git push --force-with-lease=refs/tags/v1: origin candidate:refs/tags/v1'
        }

        It 'preserves the original immutable commit after a documentation-only commit' {
            $script:tagTarget = 'original'
            $script:majorTarget = 'original'
            Mock Get-ReleaseManifestAtRef { [pscustomobject] @{ schema_version = 1; version = '1.2.0' } }
            $script:releaseExists = $true
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 0
        }

        It 'retries after tag creation without moving the immutable tag' {
            $script:tagTarget = 'original'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 2
            $script:operations[0] | Should -Match '^gh release create '
            $script:operations[1] | Should -Match 'original:refs/tags/v1$'
        }

        It 'retries after release creation by reconciling only the major' {
            $script:tagTarget = 'original'
            $script:releaseExists = $true
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 1
            $script:operations[0] | Should -Match 'original:refs/tags/v1$'
        }

        It 'finds an existing release on a later page without creating it again' {
            $script:tagTarget = 'original'
            Mock Invoke-ReleaseGh {
                '[[{"tag_name":"v1.0.0","draft":false,"prerelease":false}],[{"tag_name":"v1.1.0","draft":false,"prerelease":false},{"tag_name":"v1.2.0","draft":false,"prerelease":false}]]'
            } -ParameterFilter { $Arguments[0] -eq 'api' }
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 1
            $script:operations[0] | Should -Match 'original:refs/tags/v1$'
            Should -Invoke Invoke-ReleaseGh -Times 0 -ParameterFilter { $Arguments[0] -eq 'release' }
        }

        It 'does not roll a newer major release backwards' {
            $script:majorTarget = 'major-commit'
            $script:majorVersion = '1.10.0'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations.Count | Should -Be 2
            $script:operations | Should -Not -Match '--force'
        }

        It 'uses a lease when advancing an existing major' {
            $script:majorTarget = 'major-commit'
            Publish-ActionRelease -RepositoryPath repo -Repository owner/repo
            $script:operations[-1] | Should -Match '--force-with-lease=refs/tags/v1:major-commit'
        }

        It 'rejects changed runtime at the same immutable version before any write' {
            $script:tagTarget = 'original'
            $script:tagContent = 'different'
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }

        It 'requires increment relative to the base even before the first tag is published' {
            $script:baseVersion = '1.2.0'
            { Assert-ReleaseReadiness -RepositoryPath repo -BaseRef base } | Should -Throw
        }

        It 'does not mutate any refs when release lookup fails' {
            Mock Invoke-ReleaseGh { throw 'API unavailable' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }

        It 'does not move major after release creation fails' {
            Mock Invoke-ReleaseGh { throw 'creation failed' } -ParameterFilter { $Arguments[0] -eq 'release' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 1
            $script:operations[0] | Should -Be 'git push origin candidate:refs/tags/v1.2.0'
        }

        It 'does not publish a release after immutable tag push fails' {
            Mock Invoke-ReleaseGit { throw 'push rejected' } -ParameterFilter { $Arguments[0] -eq 'push' }
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            Should -Invoke Invoke-ReleaseGh -Times 0 -ParameterFilter { $Arguments[0] -eq 'release' }
        }

        It 'rejects a major ref that disagrees with the same immutable version' {
            $script:majorTarget = 'major-commit'
            $script:majorVersion = '1.2.0'
            { Publish-ActionRelease -RepositoryPath repo -Repository owner/repo } | Should -Throw
            $script:operations.Count | Should -Be 0
        }
    }
}
