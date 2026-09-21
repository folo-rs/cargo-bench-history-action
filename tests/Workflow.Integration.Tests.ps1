#Requires -Version 7.6
# Real bootstrap entry-point and local Git transport fixtures exercise the private
# workflow adapter. Installer mutation ports stay mocked; Git identities, signing
# and configuration are isolated from the developer machine.
BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Workflow.psm1') -Force -ErrorAction Stop
    $script:entry = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Run-Workflow.ps1'
    function Invoke-ContextGit {
        param([string] $Repository, [string[]] $Arguments)
        $PSNativeCommandUseErrorActionPreference = $false
        $text = & git -C $Repository -c user.name=Canary -c user.email=canary@example.invalid `
            -c commit.gpgsign=false -c tag.gpgsign=false -c gc.auto=0 @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Fixture Git failed: $text" }
        return ($text -join "`n")
    }

    function Initialize-DetachedBranchFixture {
        $null = Invoke-ContextGit $script:caller @('init', '--quiet', '-b', 'main')
        $null = Invoke-ContextGit $script:caller @('add', '.')
        $null = Invoke-ContextGit $script:caller @('commit', '--quiet', '-m', 'base')
        $script:base = Invoke-ContextGit $script:caller @('rev-parse', 'HEAD')
        $null = Invoke-ContextGit $script:caller @('commit', '--quiet', '--allow-empty', '-m', 'head')
        $script:head = Invoke-ContextGit $script:caller @('rev-parse', 'HEAD')
        $null = Invoke-ContextGit $script:caller @('update-ref', 'refs/remotes/origin/main', $script:head)
        $null = Invoke-ContextGit $script:caller @('symbolic-ref', 'refs/remotes/origin/HEAD', 'refs/remotes/origin/main')
        $null = Invoke-ContextGit $script:caller @('symbolic-ref', 'refs/remotes/origin/alias', 'refs/remotes/origin/main')
        $null = Invoke-ContextGit $script:caller @('checkout', '--quiet', '--detach', $script:head)
        $null = Invoke-ContextGit $script:caller @('update-ref', '-d', 'refs/heads/main', $script:head)
        $null = Invoke-ContextGit $script:caller @('update-ref', 'refs/heads/preserved', $script:base)
        $null = Invoke-ContextGit $script:caller @('update-ref', 'refs/remotes/origin/preserved', $script:head)
        $null = Invoke-ContextGit $script:caller @('update-ref', 'refs/tags/release', $script:base)
    }

    function Initialize-DetachedBranchAlias {
        & (Get-Module Workflow) {
            param($Directory)
            Initialize-WorkflowBackfillBranch $Directory
        } $script:caller
    }
}

Describe 'Workflow native handoff' {
    BeforeEach {
        $script:caller = Join-Path $TestDrive "$([guid]::NewGuid()) caller"
        $script:temporary = Join-Path $TestDrive "$([guid]::NewGuid()) temporary"
        $null = New-Item -ItemType Directory -Path $script:temporary
        $null = New-Item -ItemType Directory -Path (Join-Path $script:caller '.cargo') -Force
        Set-Content (Join-Path $script:caller '.cargo\bench_history.toml') '[project]'
        $script:environment = @{}
        foreach ($name in @('GITHUB_WORKSPACE', 'GITHUB_REPOSITORY', 'RUNNER_TEMP', 'GITHUB_OUTPUT',
                'CBH_WORKFLOW_INPUTS', 'CBH_WORKFLOW_STATE', 'CBH_FLOW', 'CBH_PLATFORMS',
                'CBH_EXCLUDE', 'CBH_FROM', 'CBH_TO', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM')) {
            $script:environment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_WORKSPACE = $script:caller
        $env:GITHUB_REPOSITORY = 'owner/project'
        $env:RUNNER_TEMP = $script:temporary
        $env:GITHUB_OUTPUT = Join-Path $script:temporary 'outputs'
        $env:GIT_CONFIG_GLOBAL = Join-Path $script:temporary 'gitconfig'
        Set-Content $env:GIT_CONFIG_GLOBAL '' -NoNewline
        $env:GIT_CONFIG_NOSYSTEM = '1'
        $env:CBH_WORKFLOW_INPUTS = @{
            'install-method' = 'binstall'; 'source-path' = ''; 'working-directory' = '.'
            config = ''; instance = ''; base = ''
        } | ConvertTo-Json -Compress
    }

    AfterEach {
        foreach ($name in $script:environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:environment[$name])
        }
    }

    It 'runs layout from the implementation scripts rather than the caller checkout' {
        & $entry -Stage layout
        $outputs = @{}
        foreach ($line in Get-Content $env:GITHUB_OUTPUT) {
            $key, $value = $line -split '=', 2
            $outputs[$key] = $value
        }
        Test-Path -LiteralPath $outputs['state-path'] | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $outputs['scripts-path'] 'Run-Workflow.ps1') | Should -BeTrue
        $outputs['config'] | Should -Be (Join-Path $caller '.cargo\bench_history.toml')
        Test-Path -LiteralPath $outputs['working-directory'] | Should -BeFalse
        $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $state['install-method'] | Should -Be 'binstall'
        $state['scripts-path'] | Should -Not -Be $caller
    }

    It 'rejects invalid internal selections before installing anything' {
        $env:CBH_WORKFLOW_INPUTS = '{"install-method":"none"}'
        { & $entry -Stage layout } | Should -Throw
        Test-Path -LiteralPath $env:GITHUB_OUTPUT | Should -BeFalse
    }

    It 'passes range environment values only to the backfill preparation entry point' -ForEach @(
        @{ flow = 'backfill' }, @{ flow = 'history' }, @{ flow = 'pr' }
    ) {
        $env:CBH_FLOW = $flow
        $env:CBH_PLATFORMS = 'ubuntu-latest'
        $env:CBH_EXCLUDE = 'excluded'
        $env:CBH_FROM = 'topic/from'
        $env:CBH_TO = 'topic/to'
        $env:CBH_WORKFLOW_STATE = Join-Path $temporary 'state.json'
        '{"companion":"fixture"}' | Set-Content $env:CBH_WORKFLOW_STATE
        Mock Invoke-WorkflowOperation {}
        & $entry -Stage prepare
        Should -Invoke Invoke-WorkflowOperation -Times 1 -Exactly -ParameterFilter {
            $Operation -ceq 'prepare' -and $Flow -ceq $env:CBH_FLOW -and
            $Platforms -ceq $env:CBH_PLATFORMS -and $Exclude -ceq $env:CBH_EXCLUDE -and
            $(if ($Flow -eq 'backfill') { $From -ceq $env:CBH_FROM -and $To -ceq $env:CBH_TO }
                else { -not $From -and -not $To })
        }
    }

    It 'fetches a missing frozen base locally without changing measured source' {
        $null = Invoke-ContextGit $caller @('init', '--quiet', '-b', 'main')
        $null = Invoke-ContextGit $caller @('add', '.')
        $null = Invoke-ContextGit $caller @('commit', '--quiet', '-m', 'base')
        $base = Invoke-ContextGit $caller @('rev-parse', 'HEAD')
        Set-Content (Join-Path $caller 'head.txt') 'head'
        $null = Invoke-ContextGit $caller @('add', '.')
        $null = Invoke-ContextGit $caller @('commit', '--quiet', '-m', 'head')
        $head = Invoke-ContextGit $caller @('rev-parse', 'HEAD')
        $context = Initialize-WorkflowContext -Workspace $caller -TempDirectory $temporary `
            -Repository owner/project -Base $base
        $null = Invoke-ContextGit $caller @('clone', '--quiet', '--no-local', '--depth=1',
            $caller, $context['measured-root'])
        { Invoke-ContextGit $context['measured-root'] @('cat-file', '-e', "$base^{commit}") } | Should -Throw
        Mock Install-ActionTools -ModuleName Workflow { @{ companion = 'fixture-companion' } }
        $null = Install-WorkflowTool $context @{ tools = @(@{ name = 'companion'; role = 'companion' }) }
        $null = Invoke-ContextGit $context['measured-root'] @('cat-file', '-e', "$base^{commit}")
        Invoke-ContextGit $context['measured-root'] @('rev-parse', 'HEAD') | Should -Be $head
        Invoke-ContextGit $context['measured-root'] @('status', '--porcelain') | Should -BeNullOrEmpty
    }

    It 'makes <reference> resolvable in a detached fetched checkout without moving HEAD' -ForEach @(
        @{ reference = 'main'; ancestor = $false }
        @{ reference = 'refs/heads/main'; ancestor = $false }
        @{ reference = 'main~1'; ancestor = $true }
    ) {
        Initialize-DetachedBranchFixture
        { Invoke-ContextGit $caller @('rev-parse', '--verify', '--end-of-options', "$reference^{commit}") } |
            Should -Throw
        Initialize-DetachedBranchAlias
        Invoke-ContextGit $caller @('rev-parse', '--verify', '--end-of-options', "$reference^{commit}") |
            Should -BeExactly $(if ($ancestor) { $base } else { $head })
        Invoke-ContextGit $caller @('rev-parse', 'HEAD') | Should -BeExactly $head
        Invoke-ContextGit $caller @('rev-parse', '--abbrev-ref', 'HEAD') | Should -BeExactly HEAD
        Invoke-ContextGit $caller @('rev-parse', 'preserved') | Should -BeExactly $base
        Invoke-ContextGit $caller @('rev-parse', 'release') | Should -BeExactly $base
        Invoke-ContextGit $caller @('for-each-ref', '--format=%(refname)', 'refs/heads/') |
            Should -BeExactly "refs/heads/main`nrefs/heads/preserved"
        Invoke-ContextGit $caller @('symbolic-ref', 'refs/remotes/origin/HEAD') |
            Should -BeExactly 'refs/remotes/origin/main'
        Invoke-ContextGit $caller @('status', '--porcelain') | Should -BeNullOrEmpty
        Initialize-DetachedBranchAlias
        Invoke-ContextGit $caller @('rev-parse', 'refs/heads/main') | Should -BeExactly $head
    }

    It 'preserves existing local branch and tag resolution rather than replacing them with origin' {
        Initialize-DetachedBranchFixture
        $null = Invoke-ContextGit $caller @('update-ref', 'refs/heads/main', $base)
        $null = Invoke-ContextGit $caller @('update-ref', 'refs/remotes/origin/release', $head)
        Initialize-DetachedBranchAlias
        Invoke-ContextGit $caller @('rev-parse', 'main') | Should -BeExactly $base
        Invoke-ContextGit $caller @('rev-parse', 'refs/heads/release') | Should -BeExactly $head
        # Two names intentionally coincide; inspect Git's ordinary tag precedence
        # without its expected ambiguity diagnostic obscuring the resolved object ID.
        Invoke-ContextGit $caller @('-c', 'core.warnAmbiguousRefs=false', 'rev-parse', 'release') |
            Should -BeExactly $base
        Invoke-ContextGit $caller @('rev-parse', 'refs/tags/release') | Should -BeExactly $base
        Invoke-ContextGit $caller @('rev-parse', 'HEAD') | Should -BeExactly $head
    }

    It 'surfaces ref creation failures instead of hiding checkout wiring errors' {
        Initialize-DetachedBranchFixture
        $lock = Join-Path $caller '.git\refs\heads\main.lock'
        Set-Content -LiteralPath $lock -Value ''
        { Initialize-DetachedBranchAlias } | Should -Throw
        Invoke-ContextGit $caller @('for-each-ref', '--format=%(refname)', 'refs/heads/main') |
            Should -BeNullOrEmpty
        Invoke-ContextGit $caller @('rev-parse', 'HEAD') | Should -BeExactly $head
    }

    It 'fails a raced creation without overwriting the newly created local ref' {
        Initialize-DetachedBranchFixture
        $script:nativeWorkflowProcess = & (Get-Module Workflow) { (Get-Command Invoke-WorkflowProcess).ScriptBlock }
        Mock Invoke-WorkflowProcess -ModuleName Workflow {
            param($FilePath, $Arguments, $CaptureOutput)
            $references = & $script:nativeWorkflowProcess -FilePath $FilePath -Arguments $Arguments -CaptureOutput:$CaptureOutput
            $null = Invoke-ContextGit $script:caller @('update-ref', 'refs/heads/main', $script:base)
            return $references
        } -ParameterFilter { $CaptureOutput }
        { Initialize-DetachedBranchAlias } | Should -Throw
        Invoke-ContextGit $caller @('rev-parse', 'refs/heads/main') | Should -BeExactly $base
        Invoke-ContextGit $caller @('rev-parse', 'HEAD') | Should -BeExactly $head
    }
}
