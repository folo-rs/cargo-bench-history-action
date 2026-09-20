#Requires -Version 7.6
# Installer integration tests use TestDrive receipts and mocked processes. They
# never install tools, access registries or rely on real-time delays.
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Tools.psm1') -Force

InModuleScope Tools {
    Describe 'Manifest and installer contract' {
        BeforeAll {
            function Write-ReceiptFixture {
                param([string] $Root, $Tool, [string] $Version, [string] $Source)
                New-Item -ItemType Directory -Path (Join-Path $Root 'bin') -Force | Out-Null
                $exe = Get-ActionToolPath -Manifest $script:manifest -Root $Root -Package $Tool.name
                Set-Content -LiteralPath $exe -Value "$($Tool.name) executable $Version"
                $script:receipts[$Tool.name] = @{
                    id = "$($Tool.name) $Version ($Source)"
                    version = $Version
                    bins = @([IO.Path]::GetFileName($exe))
                }
                $lines = @('[v1]') + @($script:receipts.Values | ForEach-Object {
                    '"{0}" = {1}' -f $_.id, (ConvertTo-Json -InputObject $_.bins -Compress)
                })
                $lines | Set-Content -LiteralPath (Join-Path $Root '.crates.toml')
            }
            function Write-SourceFixture {
                param([string[]] $Packages)
                $source = Join-Path $TestDrive "$([guid]::NewGuid()) Folo source with 'quotes'"
                foreach ($package in $Packages) {
                    $directory = Join-Path -Path $source -ChildPath 'packages' -AdditionalChildPath $package
                    New-Item -ItemType Directory -Path $directory -Force | Out-Null
                    @('[package]', "name = `"$package`"", "version = `"$script:sourceVersion`"") |
                        Set-Content -LiteralPath (Join-Path $directory 'Cargo.toml')
                }
                return $source
            }
        }
        BeforeEach {
            $script:manifest = @{
                schema_version = 1
                version = '1.0.0'
                tools = @(
                    @{ name = 'cargo-bench-history'; binary = 'cargo-bench-history'; version = '3.2.1'; role = 'tool' }
                    @{ name = 'cargo-bench-history-github'; binary = 'cargo-bench-history-github'; version = '4.3.2'; role = 'companion' }
                    @{ name = 'cargo-bench-history-faker'; binary = 'cargo-bench-history-faker'; version = '5.4.3'; role = 'fixture' }
                )
                targets = @(@{ runner = 'fixture'; rust_target = 'fixture-target'; os = 'Fixture'; arch = 'Fixture' })
            }
            $script:root = Join-Path $TestDrive "$([guid]::NewGuid()) tools with spaces & 'quotes'"
            $script:receipts = @{}
            $script:processCalls = [Collections.Generic.List[object]]::new()
            $script:installedVersion = $null
            # Deliberately differs from every release pin to exercise source identity.
            $script:sourceVersion = '9.0.0'
            $script:reportedVersion = $null
            $script:failInstall = $false
            $script:failSmoke = $false
            Mock Get-Command { @{ Source = 'fixture-cargo' } } -ParameterFilter { $Name -eq 'cargo' }
            Mock Get-Command { @{ Source = 'fixture-binstall' } } -ParameterFilter { $Name -eq 'cargo-binstall' }
            Mock Invoke-ToolProcess {
                param($FilePath, $Arguments, [switch] $CaptureOutput)
                $script:processCalls.Add(@{ file = $FilePath; arguments = $Arguments })
                if ($FilePath -eq 'fixture-cargo') {
                    if ($script:failInstall) { throw 'fixture installation failure' }
                    if ($Arguments[0] -eq 'metadata') {
                        $path = $Arguments[([array]::IndexOf($Arguments, '--manifest-path') + 1)]
                        $package = Split-Path -Leaf (Split-Path -Parent $path)
                        $tool = Get-ManifestTool $script:manifest $package
                        return (@{ packages = @(@{
                            name = $package
                            version = $script:sourceVersion
                            targets = @(@{ name = $tool.binary; kind = @('bin') })
                        }) } | ConvertTo-Json -Depth 8)
                    }
                    $isPath = $Arguments -contains '--path'
                    $package = if ($isPath) {
                        Split-Path -Leaf $Arguments[([array]::IndexOf($Arguments, '--path') + 1)]
                    } else { $Arguments[1] }
                    $tool = Get-ManifestTool $script:manifest $package
                    $version = if ($script:installedVersion) { $script:installedVersion } elseif ($isPath) {
                        $script:sourceVersion
                    } else { $tool.version }
                    $source = if ($isPath) { 'path+file:///fixture/source' } else {
                        'registry+https://github.com/rust-lang/crates.io-index'
                    }
                    Write-ReceiptFixture -Root $script:root -Tool $tool -Version $version -Source $source
                } elseif ($CaptureOutput) {
                    $tool = $script:manifest.tools | Where-Object role -EQ 'companion'
                    $version = if ($script:reportedVersion) { $script:reportedVersion } else {
                        $script:receipts[$tool.name].version
                    }
                    "$($tool.binary) $version"
                } elseif ($script:failSmoke) {
                    throw 'fixture command contract failure'
                }
            }
        }

        It 'reads exact versions independently rather than inferring companion or fixture pins' {
            $path = Join-Path $TestDrive 'release.json'
            $script:manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
            $read = Read-ActionManifest -Path $path
            $read.tools.version | Should -Be @('3.2.1', '4.3.2', '5.4.3')
        }

        It 'rejects invalid manifests: <case>' -ForEach @(
            @{ case = 'unsupported schema'; change = { $script:manifest.schema_version = 2 } }
            @{ case = 'duplicate package'; change = { $script:manifest.tools[1].name = $script:manifest.tools[0].name } }
            @{ case = 'duplicate role'; change = { $script:manifest.tools[2].role = 'companion' } }
            @{ case = 'version range'; change = { $script:manifest.tools[0].version = '^3.2' } }
            @{ case = 'package path'; change = { $script:manifest.tools[0].name = '../another-package' } }
            @{ case = 'unknown role'; change = { $script:manifest.tools[2].role = 'unused' } }
        ) {
            & $change
            $path = Join-Path $TestDrive 'invalid.json'
            $script:manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path
            { Read-ActionManifest -Path $path } | Should -Throw
        }

        It 'selects main and companion for <command>' -ForEach @(
            @{ command = 'collect' }; @{ command = 'backfill' }
            @{ command = 'analyze-history' }; @{ command = 'analyze-pr' }
        ) {
            @(Get-RequiredTool -Manifest $script:manifest -Command $command) |
                Should -Be @('cargo-bench-history', 'cargo-bench-history-github')
        }

        It 'selects only the companion for every publication and alert command' {
            $commands = @('alert') + @(foreach ($sink in @('comment', 'issue')) {
                foreach ($state in @('findings', 'clean', 'preflight', 'inconclusive', 'failed')) {
                    "publish-$sink-$state"
                }
            })
            foreach ($command in $commands) {
                @(Get-RequiredTool -Manifest $script:manifest -Command $command) |
                    Should -Be @('cargo-bench-history-github')
            }
        }

        It 'rejects unsupported commands instead of installing anything' {
            { Get-RequiredTool -Manifest $script:manifest -Command 'publish-issue-unknown' } | Should -Throw
            { Get-RequiredTool -Manifest $script:manifest -Command 'publish-issue-no-data' } | Should -Throw
            { Get-RequiredTool -Manifest $script:manifest -Command 'publish-comment-no-data' } | Should -Throw
            { Get-RequiredTool -Manifest $script:manifest -Command 'COLLECT' } | Should -Throw
            $script:processCalls.Count | Should -Be 0
        }

        It 'installs both required packages with exact locked Cargo argument vectors' {
            $packages = @(Get-RequiredTool -Manifest $script:manifest -Command collect)
            $result = Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages $packages
            $result.Keys.Count | Should -Be 2
            $calls = @($script:processCalls | Where-Object file -EQ 'fixture-cargo')
            foreach ($index in 0..1) {
                $tool = $script:manifest.tools[$index]
                $calls[$index].arguments | Should -Be @(
                    'install', $tool.name, '--version', "=$($tool.version)",
                    '--locked', '--force', '--root', $script:root)
                $result[$tool.name] | Should -Be (Get-ActionToolPath -Manifest $script:manifest -Root $script:root -Package $tool.name)
                Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root -Package $tool.name |
                    Should -BeTrue
            }
        }

        It 'permits binstall fallback normally but disables quick-install and compilation for the gate' {
            foreach ($strict in @($false, $true)) {
                Install-ActionTools -Manifest $script:manifest -Method binstall -Root $script:root `
                    -Packages cargo-bench-history-github -RequirePrebuilt:$strict | Out-Null
                $call = @($script:processCalls | Where-Object file -EQ 'fixture-cargo')[-1]
                $strategies = if ($strict) { 'crate-meta-data' } else { 'crate-meta-data,quick-install,compile' }
                $call.arguments | Should -Be @('binstall', 'cargo-bench-history-github',
                    '--version', '=4.3.2', '--locked', '--no-confirm', '--force',
                    '--root', $script:root, '--strategies', $strategies)
            }
            @($script:processCalls | Where-Object file -EQ 'fixture-cargo').Count | Should -Be 2
        }

        It 'fails clearly when cargo-binstall is absent without attempting an installation' {
            Mock Get-Command { $null } -ParameterFilter { $Name -eq 'cargo-binstall' }
            { Install-ActionTools -Manifest $script:manifest -Method binstall -Root $script:root `
                -Packages cargo-bench-history-github } | Should -Throw
            $script:processCalls.Count | Should -Be 0
        }

        It 'reuses only a verified installation and still checks the companion runtime contract' {
            1..2 | ForEach-Object {
                Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                    -Packages cargo-bench-history-github | Out-Null
            }
            @($script:processCalls | Where-Object file -EQ 'fixture-cargo').Count | Should -Be 1
            @($script:processCalls | Where-Object { $_.arguments[0] -eq '--version' }).Count | Should -Be 2
            @($script:processCalls | Where-Object { $_.arguments[0] -eq 'action' }).Count | Should -Be 2
        }

        It 'reinstalls rather than accepting <damage> as a cache hit' -ForEach @(
            @{ damage = 'missing executable'; change = {
                Remove-Item -LiteralPath (Get-ActionToolPath -Manifest $script:manifest -Root $script:root -Package cargo-bench-history-github)
            } }
            @{ damage = 'missing Cargo receipt'; change = {
                Remove-Item -LiteralPath (Join-Path $script:root '.crates.toml') -Force
            } }
            @{ damage = 'missing package receipt'; change = {
                Set-Content -LiteralPath (Join-Path $script:root '.crates.toml') -Value '[v1]'
            } }
            @{ damage = 'different registry receipt'; change = {
                $tool = Get-ManifestTool $script:manifest 'cargo-bench-history-github'
                Write-ReceiptFixture -Root $script:root -Tool $tool -Version $tool.version -Source 'registry+https://example.invalid/index'
            } }
            @{ damage = 'wrong Cargo version'; change = {
                $tool = Get-ManifestTool $script:manifest 'cargo-bench-history-github'
                Write-ReceiptFixture -Root $script:root -Tool $tool -Version '0.0.1' -Source 'registry+fixture'
            } }
            @{ damage = 'source checkout receipt'; change = {
                $tool = Get-ManifestTool $script:manifest 'cargo-bench-history-github'
                Write-ReceiptFixture -Root $script:root -Tool $tool -Version $tool.version -Source 'path+file:///fixture'
            } }
        ) {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            & $change
            Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github | Should -BeFalse
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            @($script:processCalls | Where-Object file -EQ 'fixture-cargo').Count | Should -Be 2
        }

        It 'rejects a corrupt receipt without claiming an install or cache success' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            Set-Content -LiteralPath (Join-Path $script:root '.crates.toml') -Value 'corrupt receipt'
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github } | Should -Throw
        }

        It 'checks Cargo JSON receipts when present and rejects disagreement' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            $receipt = $script:receipts['cargo-bench-history-github']
            $records = @{ installs = @{ $receipt.id = @{ bins = $receipt.bins } } }
            $jsonPath = Join-Path $script:root '.crates2.json'
            $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath
            Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github | Should -BeTrue
            $records.installs[$receipt.id].bins = @('wrong-binary')
            $records | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath
            { Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github } | Should -Throw
        }

        It 'accepts a multiline generated Cargo binary array' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            $receipt = $script:receipts['cargo-bench-history-github']
            "[v1]`n`"$($receipt.id)`" = [`n`"$($receipt.bins[0])`",`n]`n" |
                Set-Content -LiteralPath (Join-Path $script:root '.crates.toml')
            Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github | Should -BeTrue
        }

        It 'force-builds differing source versions using Cargo metadata instead of released pins' {
            $packages = @(Get-RequiredTool -Manifest $script:manifest -Command collect)
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages $packages | Out-Null
            $source = Write-SourceFixture -Packages $packages
            Install-ActionTools -Manifest $script:manifest -Method path -Root $script:root `
                -Packages $packages -SourcePath $source | Out-Null
            $calls = @($script:processCalls | Where-Object {
                $_.file -eq 'fixture-cargo' -and $_.arguments[0] -eq 'install'
            })
            $calls.Count | Should -Be 4
            $metadataCalls = @($script:processCalls | Where-Object { $_.arguments[0] -eq 'metadata' })
            $metadataCalls.Count | Should -Be 2
            foreach ($index in 0..1) {
                $packagePath = Join-Path -Path $source -ChildPath 'packages' -AdditionalChildPath $packages[$index]
                $metadataCalls[$index].arguments | Should -Be @('metadata', '--manifest-path',
                    (Join-Path $packagePath 'Cargo.toml'), '--no-deps', '--format-version', '1', '--locked')
                $calls[$index + 2].arguments | Should -Be @('install', '--path',
                    $packagePath, '--locked', '--force', '--root', $script:root)
                $script:receipts[$packages[$index]].version | Should -Be $script:sourceVersion
            }
            $script:manifest.tools.version | Should -Be @('3.2.1', '4.3.2', '5.4.3')
            Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github | Should -BeFalse
        }

        It 'rejects a source receipt that differs from Cargo metadata even when it matches the release pin' {
            $source = Write-SourceFixture -Packages cargo-bench-history
            $script:installedVersion = $script:manifest.tools[0].version
            { Install-ActionTools -Manifest $script:manifest -Method path -Root $script:root `
                -Packages cargo-bench-history -SourcePath $source } | Should -Throw
            @($script:processCalls | Where-Object { $_.arguments[0] -eq 'metadata' }).Count | Should -Be 1
        }

        It 'rejects source metadata without the selected package or executable before installation' -ForEach @(
            @{ metadata = '{"packages":[]}' }
            @{ metadata = '{"packages":[{"name":"cargo-bench-history","version":"9.0.0","targets":[]}]}' }
        ) {
            $source = Write-SourceFixture -Packages cargo-bench-history
            Mock Invoke-ToolProcess { $metadata } -ParameterFilter { $Arguments[0] -eq 'metadata' }
            { Install-ActionTools -Manifest $script:manifest -Method path -Root $script:root `
                -Packages cargo-bench-history -SourcePath $source } | Should -Throw
            @($script:processCalls | Where-Object { $_.arguments[0] -eq 'install' }).Count | Should -Be 0
        }

        It 'uses Cargo receipts without creating a second installation metadata file' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            @(Get-ChildItem -LiteralPath $script:root -File -Force).Name | Should -Be @('.crates.toml')
            Test-ActionToolInstallation -Manifest $script:manifest -Root $script:root `
                -Package cargo-bench-history-github | Should -BeTrue
        }

        It 'rejects missing source, non-path source, unknown package and invalid strict mode' {
            { Install-ActionTools -Manifest $script:manifest -Method path -Root $script:root -Packages cargo-bench-history } | Should -Throw
            { Install-ActionTools -Manifest $script:manifest -Method path -Root $script:root -Packages cargo-bench-history -SourcePath $TestDrive } | Should -Throw
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history -SourcePath $TestDrive } | Should -Throw
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages missing } | Should -Throw
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history -RequirePrebuilt } | Should -Throw
            $script:processCalls.Count | Should -Be 0
        }

        It 'propagates installation, version and command-contract failures' {
            $script:failInstall = $true
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history-github } | Should -Throw
            $script:failInstall = $false
            $script:reportedVersion = '0.0.1'
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history-github } | Should -Throw
            $script:reportedVersion = $null
            $script:failSmoke = $true
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history-github } | Should -Throw
        }

        It 'does not accept an installer success with the wrong published version' {
            $script:installedVersion = '0.0.1'
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history-github } | Should -Throw
        }

        It 'does not accept process success without installation evidence' {
            Mock Invoke-ToolProcess {}
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github } | Should -Throw
        }

        It 'rejects a cached companion whose actual version disagrees with its records' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github | Out-Null
            $script:reportedVersion = '0.0.1'
            { Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root `
                -Packages cargo-bench-history-github } | Should -Throw
            @($script:processCalls | Where-Object file -EQ 'fixture-cargo').Count | Should -Be 1
        }

        It 'smokes the main commands without pretending a --version interface exists' {
            Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages cargo-bench-history | Out-Null
            $calls = @($script:processCalls | Where-Object file -NE 'fixture-cargo')
            $calls.Count | Should -Be 4
            foreach ($index in 0..3) {
                $calls[$index].arguments | Should -Be @(@('collect', 'backfill', 'analyze', 'machine-key')[$index], '--help')
            }
        }

        It 'allows test tooling only when the gate explicitly selects it' {
            $packages = @($script:manifest.tools | Where-Object role -EQ fixture | ForEach-Object name)
            $result = Install-ActionTools -Manifest $script:manifest -Method install -Root $script:root -Packages $packages
            $result.Keys | Sort-Object | Should -Be ($packages | Sort-Object)
        }
    }

    Describe 'Native exit propagation' {
        It 'propagates nonzero exit codes and preserves argument boundaries' {
            $fixture = Join-Path $TestDrive 'native-fixture.ps1'
            # An in-process script stands in for the native executable boundary.
            @'
param([string] $Value)
$Value | Set-Content -LiteralPath $env:CBH_FIXTURE_ARGUMENT
exit 23
'@ | Set-Content -LiteralPath $fixture
            $oldArgument = $env:CBH_FIXTURE_ARGUMENT
            try {
                $env:CBH_FIXTURE_ARGUMENT = Join-Path $TestDrive 'argument.txt'
                $value = 'spaces; $(not-a-command) "quotes"'
                { Invoke-ToolProcess -FilePath $fixture -Arguments @($value) } | Should -Throw
                (Get-Content -LiteralPath $env:CBH_FIXTURE_ARGUMENT -Raw).Trim() | Should -Be $value
            } finally {
                $env:CBH_FIXTURE_ARGUMENT = $oldArgument
            }
        }
    }
}
