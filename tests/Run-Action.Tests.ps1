#Requires -Version 7.6
# Runtime wiring tests exercise all stages with filesystem fixtures and mocked
# installation. The companion fixture records arguments instead of spawning tools.
BeforeAll {
    $script:entryPoint = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Run-Action.ps1'
    Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Tools.psm1') -Force
    $script:manifest = Read-ActionManifest -Path (
        Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'release.json')
    $script:main = ($script:manifest.tools | Where-Object role -EQ 'tool').name
    $script:companion = ($script:manifest.tools | Where-Object role -EQ 'companion').name

    function Invoke-Preparation {
        param([hashtable] $Inputs)
        $env:CBH_INPUTS_JSON = $Inputs | ConvertTo-Json -Compress
        & $script:entryPoint -Stage prepare
        $outputs = @{}
        foreach ($line in Get-Content -LiteralPath $env:GITHUB_OUTPUT) {
            $parts = $line.Split('=', 2)
            $outputs[$parts[0]] = $parts[1]
        }
        $env:CBH_STATE_PATH = $outputs['state-path']
        return $outputs
    }
}

Describe 'Root action stage wiring' {
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in @('CBH_INPUTS_JSON', 'CBH_STATE_PATH', 'CBH_ACTION_DISABLE_CACHE',
                'GITHUB_OUTPUT', 'GITHUB_WORKSPACE',
                'RUNNER_TEMP', 'RUNNER_OS', 'RUNNER_ARCH', 'GITHUB_TOKEN',
                'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'CBH_FIXTURE_CAPTURE', 'CBH_FIXTURE_EXIT',
                'CBH_FIXTURE_EXECUTABLE', 'RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS')) {
            $script:savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $script:work = Join-Path $TestDrive 'measured checkout'
        $env:RUNNER_TEMP = Join-Path $TestDrive 'runner temp'
        New-Item -ItemType Directory -Path $script:work, $env:RUNNER_TEMP -Force | Out-Null
        $env:GITHUB_WORKSPACE = $script:work
        $env:RUNNER_OS = 'FixtureOS'
        $env:RUNNER_ARCH = 'FixtureArch'
        $env:GITHUB_OUTPUT = Join-Path $TestDrive 'prepare-output'
        Set-Content -LiteralPath $env:GITHUB_OUTPUT -Value '' -NoNewline
        $env:CBH_FIXTURE_CAPTURE = Join-Path $TestDrive 'invocation.json'
        $env:CBH_FIXTURE_EXIT = '0'
        $env:CBH_ACTION_DISABLE_CACHE = $null
        $env:GITHUB_TOKEN = 'ambient-fixture-token'
        $env:AZURE_CLIENT_ID = 'ambient-fixture-client'
        $env:AZURE_TENANT_ID = 'ambient-fixture-tenant'
        $script:fixture = Join-Path $TestDrive 'companion fixture.ps1'
        $env:CBH_FIXTURE_EXECUTABLE = $script:fixture
        # Capture the process contract and emit an output just as the Rust boundary
        # does. This fixture never parses reports or makes network requests.
        @'
$values = @($args)
$inputPath = $values[([array]::IndexOf($values, '--inputs-file') + 1)]
$outputPath = $values[([array]::IndexOf($values, '--github-output') + 1)]
@{
    arguments = $values
    inputs = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json -AsHashtable
    githubToken = $env:GITHUB_TOKEN
    azureClient = $env:AZURE_CLIENT_ID
    azureTenant = $env:AZURE_TENANT_ID
    rustflags = $env:RUSTFLAGS
    encodedRustflags = $env:CARGO_ENCODED_RUSTFLAGS
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE
'skipped=false' | Add-Content -LiteralPath $outputPath
exit ([int] $env:CBH_FIXTURE_EXIT)
'@ | Set-Content -LiteralPath $script:fixture
        Mock Install-ActionTools {
            @{ plain = $env:RUSTFLAGS; encoded = $env:CARGO_ENCODED_RUSTFLAGS } |
                ConvertTo-Json | Set-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE
            $companion = ($Manifest.tools | Where-Object role -EQ 'companion').name
            $main = ($Manifest.tools | Where-Object role -EQ 'tool').name
            $map = @{ $companion = $env:CBH_FIXTURE_EXECUTABLE }
            if ($Packages -contains $main) {
                $map[$main] = Join-Path $Root "bin main; 'literal'"
            }
            return $map
        }
        Push-Location -LiteralPath $script:work
    }
    AfterEach {
        Pop-Location
        foreach ($name in $script:savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $script:savedEnvironment[$name])
        }
    }

    It 'preserves runtime input values and leaves command-specific defaults to Rust' {
        $outputs = Invoke-Preparation @{
            command = 'collect'
            'install-method' = 'binstall'
            'source-path' = ''
            config = ".cargo/config with 'quotes'; `$literal.toml"
            since = ''
            'all-features' = 'false'
            features = "feature-a,`nfeature-b"
        }
        $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $inputs = Get-Content -LiteralPath $state.inputPath -Raw | ConvertFrom-Json -AsHashtable
        $inputs.ContainsKey('install-method') | Should -BeFalse
        $inputs.ContainsKey('source-path') | Should -BeFalse
        $inputs.ContainsKey('since') | Should -BeTrue
        $inputs.since | Should -Be ''
        $inputs['all-features'] | Should -Be 'false'
        $inputs.features | Should -Be "feature-a,`nfeature-b"
        $inputs.config | Should -Be ".cargo/config with 'quotes'; `$literal.toml"
        $inputs['working-directory'] | Should -Be $script:work
        $outputs['cache-enabled'] | Should -Be 'true'
        $outputs['cache-key'] | Should -Match 'FixtureOS-FixtureArch'
        foreach ($tool in $script:manifest.tools | Where-Object role -In @('tool', 'companion')) {
            $outputs['cache-key'] | Should -Match ([regex]::Escape("$($tool.name)-$($tool.version)"))
        }
        $state.tempDir.StartsWith($env:RUNNER_TEMP, [StringComparison]::Ordinal) | Should -BeTrue
        $state.root.StartsWith($script:work, [StringComparison]::Ordinal) | Should -BeFalse
    }

    It 'uses binstall and the caller directory for empty metadata defaults' {
        $outputs = Invoke-Preparation @{
            command = 'alert'
            'install-method' = ''
            'source-path' = ''
            'working-directory' = ''
        }
        $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $inputs = Get-Content -LiteralPath $state.inputPath -Raw | ConvertFrom-Json -AsHashtable
        $state.method | Should -Be 'binstall'
        $inputs['working-directory'] | Should -Be $script:work
        $inputs.ContainsKey('install-method') | Should -BeFalse
        $inputs.ContainsKey('source-path') | Should -BeFalse
        & $script:entryPoint -Stage install
        Should -Invoke Install-ActionTools -Exactly 1 -ParameterFilter { $Method -eq 'binstall' }
    }

    It 'forwards <command> rustflags as data without composing flags for installation or the companion' -ForEach @(
        @{ command = 'collect'; flags = '' }
        @{ command = 'backfill'; flags = '' }
        @{ command = 'collect'; flags = "-Cllvm-args=-align-all-functions=6`t--cfg='literal; `$value'" }
        @{ command = 'backfill'; flags = "-Cllvm-args=-align-all-functions=6`t--cfg='literal; `$value'" }
    ) {
        $plain = '-C opt-level=1 --cfg=ambient'
        $encodedWithBoundary = "--cfg$([char] 0x1f)name=`"value with spaces`""
        foreach ($encoded in @($null, '', $encodedWithBoundary)) {
            $env:RUSTFLAGS = $plain
            $env:CARGO_ENCODED_RUSTFLAGS = $encoded
            $env:GITHUB_OUTPUT = Join-Path $TestDrive "flag-prepare-$([guid]::NewGuid())"
            $outputs = Invoke-Preparation @{ command = $command; 'install-method' = 'install'; rustflags = $flags }
            & $script:entryPoint -Stage install
            $installerFlags = Get-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE -Raw | ConvertFrom-Json -AsHashtable
            $installerFlags.plain | Should -BeExactly $plain
            $installerFlags.encoded | Should -BeExactly $encoded
            $env:GITHUB_OUTPUT = Join-Path $TestDrive "flag-invoke-$([guid]::NewGuid())"
            & $script:entryPoint -Stage invoke
            $captured = Get-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE -Raw | ConvertFrom-Json -AsHashtable
            $captured.inputs.rustflags | Should -BeExactly $flags
            $captured.rustflags | Should -BeExactly $plain
            $captured.encodedRustflags | Should -BeExactly $encoded
            $env:RUSTFLAGS | Should -BeExactly $plain
            $env:CARGO_ENCODED_RUSTFLAGS | Should -BeExactly $encoded
            $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
            $state.ContainsKey('rustflags') | Should -BeFalse
            $state.packages | Should -Contain $script:main
        }
    }

    It 'forwards unknown empty keys into the runtime JSON for strict name validation' {
        Invoke-Preparation @{
            command = 'alert'
            'install-method' = 'install'
            'misspelled-input' = ''
            config = ''
        } | Out-Null
        & $script:entryPoint -Stage install
        $env:GITHUB_OUTPUT = Join-Path $TestDrive "runtime output $([guid]::NewGuid())"
        & $script:entryPoint -Stage invoke
        $captured = Get-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE -Raw | ConvertFrom-Json -AsHashtable
        $captured.inputs.ContainsKey('misspelled-input') | Should -BeTrue
        $captured.inputs['misspelled-input'] | Should -Be ''
        $captured.inputs.ContainsKey('config') | Should -BeTrue
        $captured.inputs.config | Should -Be ''
    }

    It 'keeps tool installation and cache identity independent of measurement rustflags' {
        $first = Invoke-Preparation @{ command = 'collect'; rustflags = '' }
        $second = Invoke-Preparation @{ command = 'collect'; rustflags = '-C opt-level=1' }
        $first['cache-key'] | Should -BeExactly $second['cache-key']
        $first['install-root'] | Should -BeExactly $second['install-root']
        $first['cache-enabled'] | Should -BeExactly $second['cache-enabled']
    }

    It 'keeps source installation separate from the measurement checkout and disables released caching' {
        $source = Join-Path $TestDrive 'Folo source'
        New-Item -ItemType Directory -Path $source | Out-Null
        $outputs = Invoke-Preparation @{ command = 'alert'; 'install-method' = 'path'; 'source-path' = $source }
        $outputs['cache-enabled'] | Should -Be 'false'
        & $script:entryPoint -Stage install
        Should -Invoke Install-ActionTools -Exactly 1 -ParameterFilter {
            $Method -eq 'path' -and $SourcePath -eq $source -and
                $Packages.Count -eq 1 -and $Packages[0] -eq $script:companion
        }
        $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $inputs = Get-Content -LiteralPath $state.inputPath -Raw | ConvertFrom-Json -AsHashtable
        $inputs['working-directory'] | Should -Be $script:work
        $inputs.ContainsKey('source-path') | Should -BeFalse
    }

    It 'invokes the exact companion boundary and forwards its outputs and ambient credentials for <command>' -ForEach @(
        @{ command = 'collect'; needsMain = $true }
        @{ command = 'alert'; needsMain = $false }
    ) {
        $outputs = Invoke-Preparation @{ command = $command; 'install-method' = 'install' }
        & $script:entryPoint -Stage install
        $env:GITHUB_OUTPUT = Join-Path $TestDrive "runtime output $([guid]::NewGuid())"
        & $script:entryPoint -Stage invoke
        $captured = Get-Content -LiteralPath $env:CBH_FIXTURE_CAPTURE -Raw | ConvertFrom-Json -AsHashtable
        $state = Get-Content -LiteralPath $outputs['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $expected = @('action', '--inputs-file', $state.inputPath, '--github-output',
            $env:GITHUB_OUTPUT, '--temp-dir', $state.tempDir)
        if ($needsMain) { $expected += @('--tool', $state.executables[$script:main]) }
        $captured.arguments | Should -Be $expected
        $captured.githubToken | Should -Be 'ambient-fixture-token'
        $captured.azureClient | Should -Be 'ambient-fixture-client'
        $captured.azureTenant | Should -Be 'ambient-fixture-tenant'
        Get-Content -LiteralPath $env:GITHUB_OUTPUT | Should -Be 'skipped=false'
    }

    It 'isolates runtime files but keeps published cache paths and exact-version keys reproducible' {
        $first = Invoke-Preparation @{ command = 'alert' }
        $second = Invoke-Preparation @{ command = 'alert' }
        $first['state-path'] | Should -Not -Be $second['state-path']
        $first['install-root'] | Should -Be $second['install-root']
        $first['cache-key'] | Should -Be $second['cache-key']
        $env:RUNNER_ARCH = 'DifferentArch'
        $third = Invoke-Preparation @{ command = 'alert' }
        $third['cache-key'] | Should -Not -Be $first['cache-key']
    }

    It 'uses fresh installation roots for repeated source-mode invocations' {
        $inputs = @{ command = 'alert'; 'install-method' = 'path'; 'source-path' = $TestDrive }
        $first = Invoke-Preparation $inputs
        $second = Invoke-Preparation $inputs
        $first['install-root'] | Should -Not -Be $second['install-root']
        $first['cache-enabled'] | Should -Be 'false'
        $second['cache-enabled'] | Should -Be 'false'
    }

    It 'forces fresh uncached roots for the real <method> action canary' -ForEach @(
        @{ method = 'binstall' }; @{ method = 'install' }; @{ method = 'path' }
    ) {
        $env:CBH_ACTION_DISABLE_CACHE = 'true'
        $inputs = @{ command = 'collect'; 'install-method' = $method }
        if ($method -eq 'path') { $inputs['source-path'] = $TestDrive }
        $first = Invoke-Preparation $inputs
        $second = Invoke-Preparation $inputs
        $first['cache-enabled'] | Should -Be 'false'
        $second['cache-enabled'] | Should -Be 'false'
        $first['install-root'] | Should -Not -Be $second['install-root']
        Test-Path -LiteralPath $first['install-root'] | Should -BeFalse
        Test-Path -LiteralPath $second['install-root'] | Should -BeFalse
        & $script:entryPoint -Stage install
        $expectedMethod = $method
        Should -Invoke Install-ActionTools -Exactly 1 -ParameterFilter {
            $Method -eq $expectedMethod -and $Root -eq $second['install-root']
        }
        $state = Get-Content -LiteralPath $second['state-path'] -Raw | ConvertFrom-Json -AsHashtable
        $runtimeInputs = Get-Content -LiteralPath $state.inputPath -Raw | ConvertFrom-Json -AsHashtable
        $runtimeInputs.ContainsKey('CBH_ACTION_DISABLE_CACHE') | Should -BeFalse
    }

    It 'preserves normal caching when the canary switch is explicitly false' {
        $env:CBH_ACTION_DISABLE_CACHE = 'false'
        $first = Invoke-Preparation @{ command = 'alert' }
        $second = Invoke-Preparation @{ command = 'alert' }
        $first['cache-enabled'] | Should -Be 'true'
        $first['install-root'] | Should -Be $second['install-root']
    }

    It 'rejects a malformed canary cache switch rather than silently reusing tools' {
        $env:CBH_ACTION_DISABLE_CACHE = 'yes'
        { Invoke-Preparation @{ command = 'alert' } } | Should -Throw
        Should -Invoke Install-ActionTools -Exactly 0
    }

    It 'rejects <case> before installation' -ForEach @(
        @{ case = 'unknown command'; inputs = @{ command = 'bad' } }
        @{ case = 'unknown method'; inputs = @{ command = 'alert'; 'install-method' = 'bad' } }
        @{ case = 'non-string inputs'; inputs = @{ command = 'alert'; 'empty-scope' = $true } }
        @{ case = 'missing path source'; inputs = @{ command = 'alert'; 'install-method' = 'path' } }
        @{ case = 'source on registry install'; inputs = @{ command = 'alert'; 'source-path' = 'source' } }
    ) {
        { Invoke-Preparation $inputs } | Should -Throw
        Should -Invoke Install-ActionTools -Exactly 0
    }

    It 'rejects a scratch root inside the caller checkout even when measuring a subdirectory' {
        $nested = Join-Path $script:work 'measured-package'
        $env:RUNNER_TEMP = Join-Path $script:work 'scratch'
        New-Item -ItemType Directory -Path $nested, $env:RUNNER_TEMP | Out-Null
        { Invoke-Preparation @{ command = 'alert'; 'working-directory' = $nested } } | Should -Throw
    }

    It 'propagates installer and companion failures' {
        Invoke-Preparation @{ command = 'alert'; 'install-method' = 'install' } | Out-Null
        & $script:entryPoint -Stage install
        $env:CBH_FIXTURE_EXIT = '19'
        { & $script:entryPoint -Stage invoke } | Should -Throw
        Mock Install-ActionTools { throw 'fixture installation failure' }
        { & $script:entryPoint -Stage install } | Should -Throw
    }
}
