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
                'CBH_WORKFLOW_INPUTS', 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM')) {
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
}
