#Requires -Version 7.6
# Resolve and build the real fixture with Cargo without installing published tools.
# Package detection excludes root packages, so its benchmark must belong to a
# non-root workspace member. This remains independent of the availability gate.
BeforeAll {
    $script:workspace = Join-Path $TestDrive 'workspace'
    $null = New-Item -ItemType Directory -Path $script:workspace
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'fixture') -Force |
        Copy-Item -Destination $script:workspace -Recurse
    $script:manifestPath = Join-Path $script:workspace 'Cargo.toml'
    $script:targetRoot = Join-Path $TestDrive 'target'
}

Describe 'Resolvable non-root benchmark fixture' {
    It 'resolves the synthetic benchmark to a non-root workspace member' {
        $json = & cargo metadata --offline --no-deps --format-version 1 `
            --manifest-path $manifestPath
        if ($LASTEXITCODE -ne 0) { throw 'Fixture Cargo metadata failed.' }
        $metadata = $json | ConvertFrom-Json
        $members = @($metadata.packages | Where-Object { $_.id -cin $metadata.workspace_members })
        $members.Count | Should -Be 1
        $member = $members[0]
        $member.name | Should -BeExactly 'action_canary'
        $member.manifest_path | Should -Not -BeExactly (Join-Path $metadata.workspace_root 'Cargo.toml')
        $benches = @($member.targets | Where-Object { 'bench' -cin $_.kind })
        $benches.Count | Should -Be 1
        $benches[0].src_path | Should -BeExactly (Join-Path $workspace 'packages\action_canary\benches\synthetic.rs')
        Test-Path -LiteralPath $benches[0].src_path -PathType Leaf | Should -BeTrue
    }

    It 'builds the member benchmark without registry dependencies or running measurements' {
        & cargo check --offline --benches --manifest-path $manifestPath --target-dir $targetRoot
        if ($LASTEXITCODE -ne 0) { throw 'Fixture benchmark build failed.' }
    }
}
