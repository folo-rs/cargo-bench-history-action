#Requires -Version 7.6
# Canary fixture preparation must install and invoke only the faker. The installer
# and Git/Cargo ports are mocked; a local PowerShell fixture supplies faker output
# without installing binaries, querying a registry or running benchmarks.
BeforeAll {
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Tools.psm1') -ErrorAction Stop
    $script:initializer = Join-Path $PSScriptRoot 'Initialize-Canary.ps1'
}

Describe 'Canary fixture tool selection' {
    BeforeEach {
        $script:root = Join-Path $TestDrive "$([guid]::NewGuid()) canary"
        $script:faker = Join-Path $TestDrive 'faker.ps1'
        # This executable fixture reproduces only the output consumed by the initializer.
        @'
param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
if ($Arguments.Count -ne 4 -or $Arguments[0] -cne '--criterion' -or $Arguments[2] -cne '--chdir') {
    throw 'Unexpected faker invocation.'
}
$null = New-Item -ItemType Directory -Path $env:CARGO_TARGET_DIR -Force
'{"mean":{"point_estimate":100}}' | Set-Content (Join-Path $env:CARGO_TARGET_DIR 'estimates.json')
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $script:faker
        $script:oldOutput = $env:GITHUB_OUTPUT
        $script:oldEnvironment = $env:GITHUB_ENV
        $script:oldFaker = $env:CBH_FIXTURE_FAKER
        $script:oldMethod = $env:CBH_FIXTURE_METHOD
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'outputs'
        $env:GITHUB_ENV = Join-Path $TestDrive 'environment'
        $env:CBH_FIXTURE_FAKER = $script:faker
        Mock Import-Module {}
        Mock Read-ActionManifest {
            @{ tools = @(
                @{ name = 'main'; role = 'tool' },
                @{ name = 'companion'; role = 'companion' },
                @{ name = 'faker'; role = 'fixture' }
            ) }
        }
        Mock Install-ActionTools {}
        Mock Get-ActionToolPath { $env:CBH_FIXTURE_FAKER }
        Mock cargo { $global:LASTEXITCODE = 0 }
        Mock git { $global:LASTEXITCODE = 0 }
    }

    AfterEach {
        $env:GITHUB_OUTPUT = $script:oldOutput
        $env:GITHUB_ENV = $script:oldEnvironment
        $env:CBH_FIXTURE_FAKER = $script:oldFaker
        $env:CBH_FIXTURE_METHOD = $script:oldMethod
    }

    It 'selects only the actual fixture producer with <method>' -ForEach @(
        @{ method = 'binstall' }, @{ method = 'install' }, @{ method = 'path' }
    ) {
        $env:CBH_FIXTURE_METHOD = $method
        $parameters = @{ Root = $script:root; Method = $method }
        if ($method -eq 'path') { $parameters.SourcePath = $TestDrive }
        & $initializer @parameters
        Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
            $Method -ceq $env:CBH_FIXTURE_METHOD -and $Packages.Count -eq 1 -and $Packages[0] -ceq 'faker'
        }
        Should -Invoke Get-ActionToolPath -Times 1 -Exactly -ParameterFilter { $Package -ceq 'faker' }
        $environment = Get-Content $env:GITHUB_ENV
        $environment | Should -Contain "ACTION_CANARY_FAKER=$script:faker"
        Should -Invoke git -Times 2 -Exactly -ParameterFilter { 'commit' -cin $args }
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { 'commit' -cin $args -and '--allow-empty' -cin $args }
    }

    It 'uses an existing gate installation without installing another tool' {
        & $initializer -Root $script:root -Method binstall -ExistingToolRoot $TestDrive
        Should -Invoke Install-ActionTools -Times 0
        Should -Invoke Get-ActionToolPath -Times 1 -Exactly -ParameterFilter {
            $Package -ceq 'faker' -and $Root -eq $TestDrive
        }
    }

    It 'rejects missing fixture producers before calling the installer' {
        Mock Read-ActionManifest { @{ tools = @(@{ name = 'companion'; role = 'companion' }) } }
        { & $initializer -Root $script:root -Method binstall } | Should -Throw
        Should -Invoke Install-ActionTools -Times 0
    }
}
