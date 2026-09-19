#Requires -Version 7.6
# Pester guards exact installation evidence and the monorepo archive/checksum
# contract. These tests perform no downloads or installations.
BeforeAll {
    . (Join-Path $PSScriptRoot '..\scripts\Install-Canary.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Tools.psm1')
}

Describe 'Shared real installation gate orchestration' {
    BeforeEach {
        $script:manifest = @{
            tools = @(
                @{ name = 'main'; binary = 'main'; version = '1.2.3'; role = 'tool' },
                @{ name = 'companion'; binary = 'companion'; version = '2.0.0'; role = 'companion' },
                @{ name = 'faker'; binary = 'faker'; version = '3.0.0'; role = 'fixture' },
                @{ name = 'scope'; binary = 'scope'; version = '4.0.0'; role = 'scope' }
            )
            targets = @(@{ rust_target = 'test-target' })
        }
        $script:oldOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = $null
        Mock Import-Module {}
        Mock Read-ActionManifest { $script:manifest }
        Mock Test-Path { $false }
        Mock New-Item {}
        Mock Invoke-WebRequest { [pscustomobject] @{ Content = 'sidecar' } }
        Mock Get-FileHash { [pscustomobject] @{ Hash = 'hash' } }
        Mock Assert-CanaryChecksum {}
        Mock Install-ActionTools {}
        Mock Test-ActionToolInstallation { $true }
        Mock Get-ActionToolPath { param($Package) $Package }
        Mock Invoke-CanaryExecutable {
            param($Executable)
            switch ($Executable) {
                'rustc' { 'host: test-target' }
                'companion' { 'companion 2.0.0' }
                default { 'actual-machine-key' }
            }
        }
    }

    AfterEach { $env:GITHUB_OUTPUT = $script:oldOutput }

    It 'uses only the shared installer with strict prebuilt mode and every manifest tool' {
        Invoke-InstallationCanary -Method binstall -RustTarget test-target -Root $TestDrive -ManifestPath manifest
        Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'binstall' -and $RequirePrebuilt -and $Packages.Count -eq 4 -and
            ($Packages -join ',') -eq 'main,companion,faker,scope' -and $Root.EndsWith('installed')
        }
        Should -Invoke Invoke-WebRequest -Times 8 -Exactly
        Should -Invoke Test-ActionToolInstallation -Times 4 -Exactly
    }

    It 'uses registry installation without a prebuilt-only switch for the install leg' {
        Invoke-InstallationCanary -Method install -RustTarget test-target -Root $TestDrive -ManifestPath manifest
        Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'install' -and -not $RequirePrebuilt
        }
    }

    It 'rejects any preexisting root before installing' {
        Mock Test-Path { $true }
        { Invoke-InstallationCanary -Method binstall -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
        Should -Invoke Install-ActionTools -Times 0
    }

    It 'does not substitute installation or success when a promised asset is absent' {
        Mock Invoke-WebRequest { throw 'asset absent' }
        { Invoke-InstallationCanary -Method binstall -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
        Should -Invoke Install-ActionTools -Times 0
    }

    It 'propagates missing registry packages without switching methods' {
        Mock Install-ActionTools { throw 'version unpublished' }
        { Invoke-InstallationCanary -Method install -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
        Should -Invoke Install-ActionTools -Times 1 -Exactly -ParameterFilter { $Method -eq 'install' }
    }

    It 'rejects a runner that does not execute the promised target' {
        Mock Invoke-CanaryExecutable { 'host: another-target' }
        { Invoke-InstallationCanary -Method install -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
        Should -Invoke Install-ActionTools -Times 0
    }

    It 'rejects a mismatched runtime version even if Cargo receipts match' {
        Mock Invoke-CanaryExecutable { 'companion 1.0.0' } -ParameterFilter { $Executable -eq 'companion' }
        { Invoke-InstallationCanary -Method install -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
    }

    It 'rejects any tool whose shared Cargo receipt verification fails' {
        Mock Test-ActionToolInstallation { $false } -ParameterFilter { $Package -eq 'scope' }
        { Invoke-InstallationCanary -Method install -RustTarget test-target -Root $TestDrive -ManifestPath manifest } | Should -Throw
        Should -Invoke Test-ActionToolInstallation -Times 1 -Exactly -ParameterFilter { $Package -eq 'scope' }
    }
}

Describe 'Official archive evidence' {
    It 'derives archive and sibling checksum URLs from each requested target and version' {
        $tool = @{ name = 'example'; version = '1.2.3' }
        $asset = Get-CanaryAsset $tool x86_64-pc-windows-msvc
        $asset.Url | Should -Be 'https://github.com/folo-rs/folo/releases/download/example-v1.2.3/example-v1.2.3-x86_64-pc-windows-msvc.zip'
        $asset.ChecksumUrl | Should -Be ($asset.Url -replace '\.zip$', '.sha256')
    }

    It 'accepts matching hash and archive identity' {
        $hash = 'ab' * 32
        { Assert-CanaryChecksum "$hash  example.zip" example.zip $hash.ToUpperInvariant() } | Should -Not -Throw
    }

    It 'rejects wrong bytes, wrong identity and missing checksums' -ForEach @(
        @{ sidecar = "$('ab' * 32)  example.zip"; file = 'example.zip'; hash = 'cd' * 32 },
        @{ sidecar = "$('ab' * 32)  other.zip"; file = 'example.zip'; hash = 'ab' * 32 },
        @{ sidecar = ''; file = 'example.zip'; hash = 'ab' * 32 }
    ) {
        { Assert-CanaryChecksum $sidecar $file $hash } | Should -Throw
    }
}
