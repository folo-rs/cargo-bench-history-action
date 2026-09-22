#Requires -Version 7.6
# Local storage/state fixtures exercise the backfill probe's evidence and tool reuse.
# Only Git and benchmark execution ports are mocked; no installation or network
# operation occurs. Real installed-tool canaries run these paths in each CI matrix leg.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Invoke-BackfillCanary.ps1')
    Import-Module (Join-Path $PSScriptRoot '..\scripts\Tools.psm1')
    $script:manifest = Read-ActionManifest (Join-Path $PSScriptRoot '..\release.json')
    $script:mainPackage = @($manifest.tools | Where-Object role -CEQ tool)[0].name

    function Write-CanaryRunFixture {
        param([string] $Commit, [hashtable] $Changes = @{})
        $run = @{
            context = @{ git = @{ commit = $Commit; dirty = $false }; machine = @{ fingerprint = 'fixture-key' } }
            results = @(@{ measurement = 100 })
        }
        foreach ($key in $Changes.Keys) { $run[$key] = $Changes[$key] }
        $directory = Join-Path -Path $script:store -ChildPath 'objects' -AdditionalChildPath 'fixture-key', $Commit
        $null = New-Item -ItemType Directory -Path $directory -Force
        $writer = [IO.StreamWriter]::new([IO.Compression.GZipStream]::new(
                [IO.File]::Create((Join-Path $directory 'clean.json')), [IO.Compression.CompressionLevel]::Optimal))
        try { $writer.Write(($run | ConvertTo-Json -Depth 6)) }
        finally { $writer.Dispose() }
    }

    function Write-CollectorStateFixture {
        param([string] $Name = 'collector', [string] $Command = 'collect', [string] $Workspace = $script:workspace)
        $root = Join-Path $script:temporary "cbh-action-$Name"
        $null = New-Item -ItemType Directory -Path $root -Force
        $inputs = Join-Path $root 'inputs.json'
        @{ command = $Command; 'working-directory' = $Workspace } |
            ConvertTo-Json | Set-Content -LiteralPath $inputs
        @{ inputPath = $inputs; executables = @{ $script:mainPackage = $script:tool } } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'state.json')
    }
}

Describe 'Stored backfill and resumption evidence' {
    BeforeEach {
        $script:workspace = Join-Path $TestDrive 'workspace'
        $script:store = Join-Path $TestDrive "store-$([guid]::NewGuid())"
        $script:temporary = Join-Path $TestDrive "runner-$([guid]::NewGuid())"
        $null = New-Item -ItemType Directory -Path $script:workspace, $script:store, $script:temporary -Force
        $script:head = 'b' * 40
        $script:parent = 'a' * 40
        $script:tool = Join-Path $TestDrive 'main.ps1'
        Set-Content -LiteralPath $script:tool 'exit 0'
        $script:offline = $env:CARGO_NET_OFFLINE
        Write-CanaryRunFixture $script:head
        Mock git {
            $global:LASTEXITCODE = 0
            if ($args[-1] -ceq 'HEAD~1') { $script:parent } else { $script:head }
        }
        Mock Invoke-CanaryBackfill {
            param($Bench)
            $env:CARGO_NET_OFFLINE | Should -BeExactly 'true'
            if ($Bench -ceq 'synthetic') { Write-CanaryRunFixture $script:parent }
        }
    }

    AfterEach { $env:CARGO_NET_OFFLINE = $script:offline }

    It 'fills only the historical gap and resumes without changing any stored bytes' {
        Write-CollectorStateFixture
        $before = Get-CanaryStoreEvidence $script:store fixture-key @($script:head)
        Invoke-BackfillCanary -Workspace $script:workspace -Store $script:store -MachineKey fixture-key -TemporaryDirectory $script:temporary
        $after = Get-CanaryStoreEvidence $script:store fixture-key @($script:parent, $script:head)
        Assert-CanaryStorePreserved $before $after -AllowAdditional
        Should -Invoke Invoke-CanaryBackfill -Times 1 -Exactly -ParameterFilter {
            $Tool -ceq $script:tool -and $Bench -ceq 'synthetic'
        }
        Should -Invoke Invoke-CanaryBackfill -Times 1 -Exactly -ParameterFilter {
            $Tool -ceq $script:tool -and $Bench -ceq 'canary_target_must_not_execute'
        }
        $env:CARGO_NET_OFFLINE | Should -Be $script:offline
    }

    It 'rejects a successful process that fails to store the older commit' {
        Mock Invoke-CanaryBackfill {}
        { Invoke-BackfillCanary $script:workspace $script:store fixture-key $script:tool } | Should -Throw
        Should -Invoke Invoke-CanaryBackfill -Times 1 -Exactly
    }

    It 'rejects replacement of the originally collected tip' {
        Mock Invoke-CanaryBackfill {
            Write-CanaryRunFixture $script:parent
            Write-CanaryRunFixture $script:head @{ results = @(@{ measurement = 200 }) }
        }
        { Invoke-BackfillCanary $script:workspace $script:store fixture-key $script:tool } | Should -Throw
        Should -Invoke Invoke-CanaryBackfill -Times 1 -Exactly
    }

    It 'rejects resumed backfill that executes the nonexistent target or changes storage' -ForEach @(
        @{ failure = 'execution' }, @{ failure = 'replacement' }, @{ failure = 'additional-file' }
    ) {
        $script:failure = $failure
        Mock Invoke-CanaryBackfill {
            param($Bench)
            if ($Bench -ceq 'synthetic') { Write-CanaryRunFixture $script:parent; return }
            switch ($script:failure) {
                'execution' { throw 'nonexistent target executed' }
                'replacement' { Write-CanaryRunFixture $script:parent @{ results = @(@{ measurement = 200 }) } }
                'additional-file' { Set-Content (Join-Path $script:store 'extra.json') '{}' }
            }
        }
        { Invoke-BackfillCanary $script:workspace $script:store fixture-key $script:tool } | Should -Throw
        Should -Invoke Invoke-CanaryBackfill -Times 2 -Exactly
        $env:CARGO_NET_OFFLINE | Should -Be $script:offline
    }

    It 'rejects false commit, dirty, empty or other-runner measurement evidence' -ForEach @(
        @{ defect = 'commit' }, @{ defect = 'dirty' }, @{ defect = 'empty' }, @{ defect = 'machine' }
    ) {
        $context = @{ git = @{ commit = $script:head; dirty = $false }; machine = @{ fingerprint = 'fixture-key' } }
        $changes = @{ context = $context }
        switch ($defect) {
            'commit' { $context.git.commit = $script:parent }
            'dirty' { $context.git.dirty = $true }
            'empty' { $changes.results = @() }
            'machine' { $context.machine.fingerprint = 'another-runner' }
        }
        Write-CanaryRunFixture $script:head $changes
        { Get-CanaryStoreEvidence $script:store fixture-key @($script:head) } | Should -Throw
    }

    It 'selects the installed collector only for the measured fixture' {
        Write-CollectorStateFixture
        Write-CollectorStateFixture -Name analysis -Command analyze-history
        Write-CollectorStateFixture -Name another -Workspace (Join-Path $TestDrive 'another-workspace')
        Get-CanaryCollectionTool $script:workspace $script:temporary | Should -BeExactly $script:tool
    }

    It 'rejects malformed or uncompressed stored bodies' {
        $object = @(Get-ChildItem -LiteralPath $script:store -Recurse -Filter clean.json)[0]
        Set-Content -LiteralPath $object.FullName '{}'
        { Get-CanaryStoreEvidence $script:store fixture-key @($script:head) } | Should -Throw
    }

    It 'rejects a missing or ambiguous collector rather than installing another tool' {
        { Get-CanaryCollectionTool $script:workspace $script:temporary } | Should -Throw
        Write-CollectorStateFixture
        Write-CollectorStateFixture -Name duplicate
        { Get-CanaryCollectionTool $script:workspace $script:temporary } | Should -Throw
    }
}

Describe 'Core backfill process contract' {
    It 'forwards the real range and target without enabling overwrite or ignored errors' {
        $capture = Join-Path $TestDrive 'arguments.json'
        $fixture = Join-Path $TestDrive 'core.ps1'
        @'
$args | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'arguments.json')
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $fixture
        Invoke-CanaryBackfill -Tool $fixture -Workspace $TestDrive -Store (Join-Path $TestDrive 'store') -Bench canary_target_must_not_execute
        $arguments = Get-Content $capture -Raw | ConvertFrom-Json
        $arguments | Should -Be @(
            'backfill', '--repo', $TestDrive, "--local=$(Join-Path $TestDrive 'store')",
            '--config', (Join-Path $TestDrive '.cargo\bench_history.toml'),
            '--bench', 'canary_target_must_not_execute', 'HEAD~1', 'HEAD'
        )
    }
}
