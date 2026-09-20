#Requires -Version 7.6
# Native filesystem fixtures and mocked process/installer ports protect the
# reusable workflow's path, argument and output handoffs without installing tools
# or making any GitHub/Azure requests.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Workflow.psm1') -Force -ErrorAction Stop

Describe 'Workflow adapter' {
    InModuleScope Workflow {
        BeforeAll {
            function Initialize-ContextFixture {
                param([hashtable] $Options = @{})
                $parameters = @{
                    Workspace = $script:workspace
                    TempDirectory = $script:temp
                    Repository = 'owner/project'
                }
                foreach ($key in $Options.Keys) { $parameters[$key] = $Options[$key] }
                Initialize-WorkflowContext @parameters
            }

            function Write-PreparationFixture {
                param([string] $Path, [string] $Flow = 'history', [string] $Packages = 'crate')
                $lines = @(
                    'instance=project'
                    'matrix={"platform":["linux","windows"]}'
                    'expected-platforms=linux,windows'
                    'collection-job-prefix=cbh-collect:project'
                    'head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
                    "base=$(if ($Flow -eq 'pr') { 'b' * 40 } else { 'a' * 40 })"
                    'skip-all=false'
                    "packages=$Packages"
                )
                Set-Content -LiteralPath $Path -Value $lines
            }
        }

        BeforeEach {
            $script:workspace = Join-Path $TestDrive "$([guid]::NewGuid()) caller with 'quotes'"
            $script:temp = Join-Path $TestDrive "$([guid]::NewGuid()) runner temp"
            $null = New-Item -ItemType Directory -Path $script:temp
            $configuration = Join-Path $script:workspace '.cargo'
            $null = New-Item -ItemType Directory -Path $configuration -Force
            Set-Content -LiteralPath (Join-Path $configuration 'bench_history.toml') -Value '[project]'
            $script:manifest = @{
                tools = @(
                    @{ name = 'companion-package'; binary = 'companion'; version = '2.3.4'; role = 'companion' }
                    @{ name = 'main-package'; binary = 'main'; version = '4.5.6'; role = 'tool' }
                    @{ name = 'fixture-package'; binary = 'fixture'; version = '5.6.7'; role = 'fixture' }
                )
            }
            Mock Install-ActionTools {
                param($Root, $Packages)
                $executables = @{}
                foreach ($package in $Packages) { $executables[$package] = Join-Path $Root $package }
                $executables
            }
            Mock Invoke-WorkflowProcess {}
        }

        Describe 'Workflow context isolation' {
            It 'separates invocation configuration, measured source and temporary evidence' {
                $context = Initialize-ContextFixture
                $context['config'] | Should -Be (Join-Path $workspace '.cargo\bench_history.toml')
                $context['working-directory'] | Should -Be (Join-Path $workspace '.bench-history\project')
                $context['state-path'].StartsWith($temp, [StringComparison]::Ordinal) | Should -BeTrue
                $context['receipt-file'] | Should -Not -Be $context['machine-key-file']
                $context['receipts-directory'] | Should -Not -Be $context['machine-key-directory']
                Test-Path -LiteralPath $context['receipts-directory'] | Should -BeTrue
                Test-Path -LiteralPath $context['machine-key-directory'] | Should -BeFalse
            }

            It 'allocates fresh tool roots without another installation metadata format' {
                $first = Initialize-ContextFixture
                $second = Initialize-ContextFixture
                $first['tools-root'] | Should -Not -Be $second['tools-root']
                Test-Path -LiteralPath $first['tools-root'] | Should -BeFalse
            }

            It 'uses a stable instance cache path independent of fresh runtime roots' {
                $first = Initialize-ContextFixture @{ Instance = 'project' }
                $second = Initialize-ContextFixture @{ Instance = 'project' }
                $first['run-root'] | Should -Not -Be $second['run-root']
                $first['cache-directory'] | Should -Be $second['cache-directory']
                $other = Initialize-ContextFixture @{ Instance = 'another-project' }
                $first['cache-directory'] | Should -Not -Be $other['cache-directory']
            }

            It 'keeps relative project/config paths anchored to the invocation checkout' {
                $project = Join-Path $workspace 'nested'
                $null = New-Item -ItemType Directory -Path $project
                Set-Content -LiteralPath (Join-Path $workspace 'shared.toml') -Value '[project]'
                $context = Initialize-ContextFixture @{ WorkingDirectory = 'nested'; Config = '..\shared.toml' }
                $context['config'] | Should -Be (Join-Path $workspace 'shared.toml')
                $context['working-directory'] | Should -Be (Join-Path $workspace '.bench-history\project\nested')
            }

            It 'rejects path traversal and malformed method/source combinations' -ForEach @(
                @{ options = @{ WorkingDirectory = '..' } }
                @{ options = @{ Config = '..\outside.toml' } }
                @{ options = @{ Method = 'path'; SourcePath = '..' } }
                @{ options = @{ Method = 'path' } }
                @{ options = @{ Method = 'install'; SourcePath = '.' } }
                @{ options = @{ Method = 'NONE' } }
                @{ options = @{ Method = 'BINSTALL' } }
                @{ options = @{ Instance = '..' } }
                @{ options = @{ Instance = 'one/two' } }
            ) {
                { Initialize-ContextFixture $options } | Should -Throw
            }

            It 'rejects runner temporary paths inside the caller checkout' {
                $inside = Join-Path $workspace 'temp'
                $null = New-Item -ItemType Directory -Path $inside
                { Initialize-ContextFixture @{ TempDirectory = $inside } } | Should -Throw
            }

            It 'reports a missing committed configuration instead of selecting another store' {
                { Initialize-ContextFixture @{ Config = 'missing.toml' } } | Should -Throw
            }
        }

        Describe 'Shared workflow tool installation' {
            It 'installs only the companion through the shared installer' {
                $context = Initialize-ContextFixture
                $null = New-Item -ItemType Directory -Path $context['working-directory'] -Force
                $result = Install-WorkflowTool $context $manifest
                $result['companion'] | Should -Be (Join-Path $context['tools-root'] 'companion-package')
                $result.Keys.Count | Should -Be 1
                Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'binstall' -and ($Packages -join ',') -eq 'companion-package'
                }
            }

            It 'does not obtain main or fixture tools for ordinary evidence/publication jobs' {
                $context = Initialize-ContextFixture
                $null = New-Item -ItemType Directory -Path $context['working-directory'] -Force
                $result = Install-WorkflowTool $context $manifest
                @($result.Keys) | Should -Be @('companion')
                Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
                    $Packages.Count -eq 1 -and $Packages[0] -eq 'companion-package'
                }
            }

            It 'preserves the source checkout and installation method for every selected tool' {
                $context = Initialize-ContextFixture @{ Method = 'path'; SourcePath = '.' }
                $null = New-Item -ItemType Directory -Path $context['working-directory'] -Force
                $null = Install-WorkflowTool $context $manifest
                Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
                    $Method -eq 'path' -and $SourcePath -ceq $script:workspace -and $Packages.Count -eq 1
                }
            }

            It 'obtains a frozen base object locally without another credentialed network fetch' {
                $context = Initialize-ContextFixture @{ Base = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' }
                $null = New-Item -ItemType Directory -Path $context['working-directory'] -Force
                $null = Install-WorkflowTool $context $manifest
                Should -Invoke Invoke-WorkflowProcess -Times 1 -Exactly -ParameterFilter {
                    $FilePath -eq 'git' -and $Arguments[2] -eq 'fetch' -and
                    $Arguments[-2] -ceq $script:workspace -and $Arguments[-1] -ceq $context['base']
                }
            }

            It 'propagates installer and local fetch failures' {
                $context = Initialize-ContextFixture @{ Base = 'base' }
                $null = New-Item -ItemType Directory -Path $context['working-directory'] -Force
                Mock Invoke-WorkflowProcess { throw 'fetch failed' }
                { Install-WorkflowTool $context $manifest } | Should -Throw
                Should -Invoke Install-ActionTools -Times 0
            }
        }

        Describe 'Companion handoff arguments' {
            BeforeEach {
                $script:operationContext = Initialize-ContextFixture
                $script:operationContext['companion'] = 'fixture-companion'
                $script:operationOutput = Join-Path $script:temp 'step-output'
            }

            It 'passes preparation input as data and excludes installation-owned values' {
                Mock Invoke-WorkflowProcess {
                    param($Arguments)
                    Write-PreparationFixture -Path $Arguments[-1]
                }
                Invoke-WorkflowOperation prepare $script:operationContext -Flow history -Platforms 'linux,windows' `
                    -Exclude 'excluded' -OutputPath $script:operationOutput
                $inputs = Get-Content (Join-Path $script:operationContext['run-root'] 'preparation.json') -Raw | ConvertFrom-Json -AsHashtable
                $inputs['working-directory'] | Should -Be $script:operationContext['working-directory']
                $inputs['config'] | Should -Be $script:operationContext['config']
                $inputs['exclude'] | Should -Be 'excluded'
                $inputs.Keys | Sort-Object | Should -Be @('config', 'exclude', 'platforms', 'working-directory')
                $inputs.ContainsKey('source-path') | Should -BeFalse
                $inputs.ContainsKey('install-method') | Should -BeFalse
                Should -Invoke Invoke-WorkflowProcess -Times 1 -Exactly -ParameterFilter {
                    $FilePath -eq 'fixture-companion' -and $Arguments[0] -eq 'prepare-workflow'
                }
            }

            It 'selects PR preparation through flow without another scope knob or executable' {
                Mock Invoke-WorkflowProcess {
                    param($Arguments)
                    Write-PreparationFixture -Path $Arguments[([array]::IndexOf($Arguments, '--github-output') + 1)] -Flow pr
                }
                Invoke-WorkflowOperation prepare $script:operationContext -Flow pr -Platforms linux -OutputPath $script:operationOutput
                $inputs = Get-Content (Join-Path $script:operationContext['run-root'] 'preparation.json') -Raw | ConvertFrom-Json -AsHashtable
                $inputs.ContainsKey('scope') | Should -BeFalse
                Should -Invoke Invoke-WorkflowProcess -Times 1 -Exactly -ParameterFilter {
                    $Arguments[0] -eq 'prepare-workflow' -and $Arguments[1] -eq '--flow' -and
                    $Arguments[2] -eq 'pr' -and $Arguments.Count -eq 7
                }
            }

            It 'binds a real key file to frozen collection identity without parsing reports' {
                Invoke-WorkflowOperation receipt $script:operationContext -Instance project -Head head -Platform linux `
                    -MachineKey 0123456789abcdef -RunId 42 -RunAttempt 3
                Get-Content -LiteralPath $script:operationContext['machine-key-file'] -Raw | Should -BeExactly '0123456789abcdef'
                Should -Invoke Invoke-WorkflowProcess -Times 1 -Exactly -ParameterFilter {
                    ($Arguments -join '|') -ceq (@('--instance', 'project', 'collection-receipt',
                            '--run-id', '42', '--run-attempt', '3', '--head', 'head', '--platform', 'linux',
                            '--machine-key-file', $script:operationContext['machine-key-file'], '--file', $script:operationContext['receipt-file']) -join '|')
                }
            }

            It 'hands original artifact roots and expected platforms to the Rust reconciler' {
                Invoke-WorkflowOperation reconcile $script:operationContext -Instance project -Head head -Platforms 'linux,windows' `
                    -RunId 42 -OutputPath $script:operationOutput
                Should -Invoke Invoke-WorkflowProcess -Times 1 -Exactly -ParameterFilter {
                    ($Arguments -join '|') -ceq (@('--instance', 'project', '--verbose', 'prepare-analysis',
                            '--run-id', '42', '--head', 'head', '--expected-platforms', 'linux,windows',
                            '--receipts-dir', $script:operationContext['receipts-directory'],
                            '--machine-key-dir', $script:operationContext['machine-key-directory'], '--github-output', $script:operationOutput) -join '|')
                }
            }

            It 'never turns a failed companion process into success' {
                Mock Invoke-WorkflowProcess { throw 'companion failed' }
                { Invoke-WorkflowOperation reconcile $script:operationContext -Instance project -Head head -Platforms linux -RunId 42 -OutputPath $script:operationOutput } |
                    Should -Throw
            }

            It 'rejects incomplete or contradictory preparation records' -ForEach @(
                @{ lines = @() }
                @{ lines = @('skip-all=true') }
                @{ lines = @('instance=one', 'instance=two') }
                @{ lines = @('instance<<EOF', 'one', 'EOF') }
            ) {
                Set-Content -LiteralPath $script:operationOutput -Value $lines
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow pr } | Should -Throw
            }

            It 'distinguishes empty PR selection from workspace collection' {
                Write-PreparationFixture -Path $script:operationOutput -Flow pr -Packages ''
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow pr } | Should -Throw
                (Get-Content -LiteralPath $script:operationOutput) -replace '^skip-all=false$', 'skip-all=true' |
                    Set-Content -LiteralPath $script:operationOutput
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow pr } | Should -Not -Throw
                Add-Content -LiteralPath $script:operationOutput -Value 'packages=unexpected'
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow pr } | Should -Throw
            }

            It 'never projects a fork policy skip into empty-scope publication' {
                Write-PreparationFixture -Path $script:operationOutput -Flow pr -Packages ''
                (Get-Content -LiteralPath $script:operationOutput) -replace '^skip-all=false$', 'skip-all=true' |
                    Set-Content -LiteralPath $script:operationOutput
                Add-Content -LiteralPath $script:operationOutput -Value @(
                    'skipped=true', 'skip-reason=fork-pull-request')
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow pr } | Should -Throw
            }

            It 'rejects a history handoff that selects a different analysis base' {
                Write-PreparationFixture -Path $script:operationOutput -Flow pr
                { Assert-WorkflowPreparationOutput -Path $script:operationOutput -Flow history } | Should -Throw
            }
        }
    }
}
