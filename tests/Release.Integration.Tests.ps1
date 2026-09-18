#Requires -Version 7.6
# Native, local-only Git fixtures verify release-bearing tree comparisons and
# original-tag retention. No production publication port is called.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Release.psm1') -Force
    function Invoke-FixtureGit {
        param([string[]] $Arguments)
        $output = & git -C $script:repo -c user.name=Canary -c user.email=canary@example.invalid `
            -c commit.gpgsign=false -c tag.gpgsign=false -c gc.auto=0 @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $output" }
        return ($output -join "`n")
    }
    function Save-FixtureCommit {
        $null = Invoke-FixtureGit @('add', '.')
        $null = Invoke-FixtureGit @('commit', '--quiet', '-m', 'fixture')
        return Invoke-FixtureGit @('rev-parse', 'HEAD')
    }
}

Describe 'Readiness against native Git trees' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory $script:repo
        $script:oldGlobal = $env:GIT_CONFIG_GLOBAL
        $script:oldSystem = $env:GIT_CONFIG_NOSYSTEM
        $env:GIT_CONFIG_GLOBAL = Join-Path $TestDrive 'empty-gitconfig'
        Set-Content $env:GIT_CONFIG_GLOBAL '' -NoNewline
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $null = Invoke-FixtureGit @('init', '--quiet', '-b', 'main')
        Set-Content (Join-Path $script:repo 'release.json') '{"schema_version":1,"version":"1.0.0","tools":[]}'
        Set-Content (Join-Path $script:repo 'action.yml') 'runtime'
        $script:original = Save-FixtureCommit
        $null = Invoke-FixtureGit @('tag', 'v1.0.0')
    }

    AfterEach {
        $env:GIT_CONFIG_GLOBAL = $script:oldGlobal
        $env:GIT_CONFIG_NOSYSTEM = $script:oldSystem
    }

    It 'retains the immutable target when only documentation changes' {
        Set-Content (Join-Path $script:repo 'README.md') 'documentation'
        $null = Save-FixtureCommit
        $plan = Get-ReleasePlan -RepositoryPath $script:repo -BaseRef $script:original
        $plan.Target | Should -Be $script:original
        $plan.CreateTag | Should -BeFalse
    }

    It 'rejects runtime content changes without an increment' {
        Set-Content (Join-Path $script:repo 'action.yml') 'changed runtime'
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw
        { Get-ReleasePlan -RepositoryPath $script:repo } | Should -Throw
    }

    It 'accepts a runtime change with a newer version' {
        Set-Content (Join-Path $script:repo 'action.yml') 'changed runtime'
        Set-Content (Join-Path $script:repo 'release.json') '{"schema_version":1,"version":"1.0.1","tools":[]}'
        $head = Save-FixtureCommit
        $plan = Get-ReleasePlan -RepositoryPath $script:repo -BaseRef $script:original
        $plan.Target | Should -Be $head
        $plan.CreateTag | Should -BeTrue
    }

    It 'treats adding a consumer workflow as a release-bearing change' {
        $workflows = Join-Path $script:repo '.github\workflows'
        $null = New-Item -ItemType Directory $workflows -Force
        Set-Content (Join-Path $workflows 'history.yml') 'consumer workflow'
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw
    }

    It 'requires an increment for tool pins even without a runtime edit' {
        Set-Content (Join-Path $script:repo 'release.json') '{"schema_version":1,"version":"1.0.0","tools":[{"version":"2.0.0"}]}'
        $null = Save-FixtureCommit
        { Assert-ReleaseReadiness -RepositoryPath $script:repo -BaseRef $script:original } | Should -Throw
    }

    It 'uses an annotated major tag object rather than its peeled commit for the lease' {
        $null = Invoke-FixtureGit @('tag', '-a', 'v1', '-m', 'major')
        $tagObject = Invoke-FixtureGit @('rev-parse', 'refs/tags/v1')
        Set-Content (Join-Path $script:repo 'release.json') '{"schema_version":1,"version":"1.0.1","tools":[]}'
        $null = Save-FixtureCommit
        $plan = Get-ReleasePlan -RepositoryPath $script:repo -BaseRef $script:original
        $plan.PreviousMajorTarget | Should -Be $tagObject
        $plan.PreviousMajorTarget | Should -Not -Be $script:original
        $plan.MoveMajor | Should -BeTrue
    }
}
