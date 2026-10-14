#Requires -Version 7.6
# Exercise the executable starter against real action/workflow declarations.
# Command substitutes test the copyable setup hook without installing prerequisites.
# Ref: docs/implementation.md, "Validation and release boundaries".
Set-StrictMode -Version Latest

BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop
    $script:root = Split-Path $PSScriptRoot -Parent
    $script:action = Get-Content (Join-Path $root 'action.yml') -Raw | ConvertFrom-Yaml
    $script:setup = Get-Content (Join-Path $root '.github\actions\bench-history-setup\action.yml') -Raw | ConvertFrom-Yaml
    $script:setupScript = [scriptblock]::Create($setup.runs.steps[0].run)
    $script:examples = foreach ($path in @('README.md', 'docs\reference.md')) {
        $document = Get-Content (Join-Path $root $path) -Raw
        foreach ($block in [regex]::Matches($document, '(?ms)^```yaml\r?\n(.*?)^```')) {
            ,($block.Groups[1].Value | ConvertFrom-Yaml)
        }
    }

    # All external commands terminate deterministically and record their real argument vectors.
    function rustup {
        $script:calls.Add(@{ name = 'rustup'; arguments = @($args) })
        $global:LASTEXITCODE = if ($script:failCommand -eq 'rustup') { 1 } else { 0 }
    }
    function sudo {
        $script:calls.Add(@{ name = 'sudo'; arguments = @($args) })
        $global:LASTEXITCODE = if ($script:failCommand -eq "sudo-$($args[1])") { 1 } else { 0 }
    }
    function cargo {
        $script:calls.Add(@{ name = 'cargo'; arguments = @($args); toolchain = $env:RUSTUP_TOOLCHAIN })
        $global:LASTEXITCODE = if ($script:failCommand -eq 'cargo') { 1 } else { 0 }
    }
}

Describe 'Runnable documentation contracts' {
    It 'binds reusable caller inputs and permissions to the called workflows' {
        $callers = @($examples | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('jobs') })
        $callers.Count | Should -BeGreaterThan 0
        foreach ($caller in $callers) {
            foreach ($job in $caller.jobs.Values) {
                if ($job['uses'] -notmatch '/\.github/workflows/(history|pr|backfill)\.yml@') { continue }
                $flow = $Matches[1]
                $workflow = Get-Content (Join-Path $root ".github\workflows\$flow.yml") -Raw | ConvertFrom-Yaml
                $inputs = $workflow.on.workflow_call.inputs
                foreach ($key in $job.with.Keys) {
                    $inputs.ContainsKey($key) | Should -BeTrue -Because "$flow must accept $key"
                    $value = $job.with[$key]
                    if ($value -is [string] -and $value.StartsWith('${{')) { continue }
                    switch ($inputs[$key].type) {
                        'string' { $value | Should -BeOfType [string] }
                        'boolean' { $value | Should -BeOfType [bool] }
                        'number' { $value | Should -BeOfType [ValueType] }
                    }
                }
                foreach ($key in $inputs.Keys) {
                    if ($inputs[$key]['required']) { $job.with.ContainsKey($key) | Should -BeTrue }
                }
                foreach ($calleeJob in $workflow.jobs.Values) {
                    foreach ($permission in $calleeJob.permissions.Keys) {
                        $job.permissions.ContainsKey($permission) | Should -BeTrue -Because "$flow requests $permission"
                        if ($calleeJob.permissions[$permission] -eq 'write') {
                            $job.permissions[$permission] | Should -BeExactly 'write'
                        }
                    }
                }
            }
        }
    }

    It 'binds root-action example inputs to the actual metadata' {
        $steps = foreach ($example in $examples) {
            if ($example -is [hashtable] -and $example.ContainsKey('jobs')) {
                foreach ($job in $example.jobs.Values) {
                    if ($job.ContainsKey('steps')) { $job.steps }
                }
            } elseif ($example -is [System.Collections.IList]) {
                $example
            }
        }
        $rootSteps = @($steps | Where-Object { $_['uses'] -match '^folo-rs/cargo-bench-history-action@' })
        $rootSteps.Count | Should -BeGreaterThan 0
        foreach ($step in $rootSteps) {
            foreach ($key in $step.with.Keys) {
                $action.inputs.ContainsKey($key) | Should -BeTrue -Because "root metadata must accept $key"
                $step.with[$key] | Should -BeOfType [string]
            }
            $step.with.ContainsKey('command') | Should -BeTrue
        }
    }

    It 'copies the exact current snapshot through the documented analysis handoff' {
        $workflow = $examples | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('jobs') -and $_.jobs.ContainsKey('history') }
        $step = $workflow.jobs.history.steps | Where-Object { $_['id'] -eq 'collection' }
        $old = @{}
        foreach ($name in @('RUNNER_TEMP', 'GITHUB_OUTPUT', 'CBH_COLLECTION_FILE')) {
            $old[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_OUTPUT = Join-Path $TestDrive 'outputs'
            $env:CBH_COLLECTION_FILE = Join-Path $TestDrive 'source.json'
            $bytes = [Text.Encoding]::UTF8.GetBytes('{"exact":"selected collection"}')
            [IO.File]::WriteAllBytes($env:CBH_COLLECTION_FILE, $bytes)
            & ([scriptblock]::Create($step.run))
            $directory = (Get-Content $env:GITHUB_OUTPUT -Raw).Trim().Substring('directory='.Length)
            [IO.File]::ReadAllBytes((Join-Path $directory 'ubuntu-latest\collection.json')) | Should -Be $bytes
            $env:CBH_COLLECTION_FILE = ''
            { & ([scriptblock]::Create($step.run)) } | Should -Throw
        } finally {
            foreach ($name in $old.Keys) { [Environment]::SetEnvironmentVariable($name, $old[$name]) }
        }
    }
}

Describe 'Copyable runner prerequisite hook' {
    BeforeEach {
        $script:savedEnvironment = @{}
        foreach ($name in @('RUNNER_OS', 'GITHUB_ENV', 'RUSTUP_TOOLCHAIN', 'BENCHMARK_RUST_TOOLCHAIN', 'BENCHMARK_GUNGRAUN_VERSION')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $script:calls = [System.Collections.Generic.List[hashtable]]::new()
        $script:failCommand = ''
        $env:GITHUB_ENV = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        # Representative pinned versions exercise argument forwarding, not availability.
        $env:BENCHMARK_RUST_TOOLCHAIN = '1.90.0'
        $env:BENCHMARK_GUNGRAUN_VERSION = ''
        $env:RUNNER_OS = 'Linux'
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
    }

    It 'selects the current-collection compiler on <platform>' -ForEach @(
        @{ platform = 'Linux' }, @{ platform = 'Windows' }, @{ platform = 'macOS' }
    ) {
        $env:RUNNER_OS = $platform
        & $setupScript
        $calls.Count | Should -Be 1
        $calls[0].name | Should -BeExactly 'rustup'
        $calls[0].arguments | Should -Be @('toolchain', 'install', $env:BENCHMARK_RUST_TOOLCHAIN, '--profile', 'minimal', '--no-self-update')
        $env:RUSTUP_TOOLCHAIN | Should -BeExactly $env:BENCHMARK_RUST_TOOLCHAIN
        (Get-Content $env:GITHUB_ENV -Raw).Trim() | Should -BeExactly "RUSTUP_TOOLCHAIN=$env:BENCHMARK_RUST_TOOLCHAIN"
    }

    It 'accepts a dated nightly without requiring it for other projects' {
        $env:BENCHMARK_RUST_TOOLCHAIN = 'nightly-2026-01-01'
        & $setupScript
        $env:RUSTUP_TOOLCHAIN | Should -BeExactly $env:BENCHMARK_RUST_TOOLCHAIN
    }

    It 'installs matching Gungraun runner and Linux system prerequisites' {
        $env:BENCHMARK_GUNGRAUN_VERSION = '0.17.2'
        & $setupScript
        $calls.Count | Should -Be 4
        $calls[1].arguments | Should -Be @('apt-get', 'update')
        $calls[2].arguments | Should -Be @('apt-get', 'install', '--yes', 'valgrind')
        $calls[3].name | Should -BeExactly 'cargo'
        $calls[3].arguments | Should -Be @('install', 'gungraun-runner', '--version', "=$env:BENCHMARK_GUNGRAUN_VERSION", '--locked')
        $calls[3].toolchain | Should -BeExactly $env:BENCHMARK_RUST_TOOLCHAIN
    }

    It 'rejects incompatible configuration before installing anything' -ForEach @(
        @{ platform = 'Windows'; compiler = '1.90.0'; engine = '0.17.2' }
        @{ platform = 'macOS'; compiler = '1.90.0'; engine = '0.17.2' }
        @{ platform = 'Linux'; compiler = 'stable'; engine = '' }
        @{ platform = 'Linux'; compiler = ''; engine = '' }
        @{ platform = 'Linux'; compiler = '1.90.0'; engine = '*' }
        @{ platform = 'unsupported'; compiler = '1.90.0'; engine = '' }
    ) {
        $env:RUNNER_OS = $platform
        $env:BENCHMARK_RUST_TOOLCHAIN = $compiler
        $env:BENCHMARK_GUNGRAUN_VERSION = $engine
        { & $setupScript } | Should -Throw
        $calls.Count | Should -Be 0
    }

    It 'stops immediately after failed <command>' -ForEach @(
        @{ command = 'rustup'; count = 1 }
        @{ command = 'sudo-update'; count = 2 }
        @{ command = 'sudo-install'; count = 3 }
        @{ command = 'cargo'; count = 4 }
    ) {
        $env:BENCHMARK_GUNGRAUN_VERSION = '0.17.2'
        $script:failCommand = $command
        { & $setupScript } | Should -Throw
        $calls.Count | Should -Be $count
    }
}
