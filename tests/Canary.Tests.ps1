#Requires -Version 7.6
# Protect the behavioral canary against accepting empty evidence or an unjustified
# all-clear. These in-memory report/output values never invoke benchmark tools.
BeforeAll {
    . (Join-Path $PSScriptRoot 'Assert-Canary.ps1')
}

Describe 'Honest fork policy evidence' {
    BeforeEach {
        $script:forkEvent = @{
            pull_request = @{
                head = @{ repo = @{ full_name = 'contributor/action' } }
                base = @{ repo = @{ full_name = 'folo-rs/action' } }
            }
        }
        $script:skipped = @{ skipped = 'true' }
    }

    It 'accepts explicit fork skips without claiming collected data' {
        { Assert-CanaryForkSkip $forkEvent $skipped $skipped } | Should -Not -Throw
    }

    It 'rejects skipping a same-repository canary' {
        $forkEvent.pull_request.head.repo.full_name = 'folo-rs/action'
        { Assert-CanaryForkSkip $forkEvent $skipped $skipped } | Should -Throw
    }

    It 'rejects skipping a non-PR canary' {
        { Assert-CanaryForkSkip @{} $skipped $skipped } | Should -Throw
    }

    It 'rejects success-shaped benchmark outputs accompanying a skip' {
        { Assert-CanaryForkSkip $forkEvent $skipped @{ skipped = 'true'; outcome = 'clean' } } | Should -Throw
    }
}

Describe 'Honest short-history analysis evidence' {
    BeforeEach {
        $script:report = @{
            tip_commit = 'fixture'; tip_dirty = $false; mode = 'history'
            outcome = 'insufficient_baseline'; notable = $false; runs = 2
            census = @{ in_scope = 1; judged = 0; coverage = 'nothing_judged' }
        }

        $script:outputs = @{
            outcome = 'insufficient_baseline'; 'publication-state' = 'inconclusive'
            'can-clear' = 'false'; 'partial-platform-coverage' = 'false'
        }
    }

    It 'accepts stored data that cannot establish a baseline yet' {
        { Assert-CanaryAnalysis $report $outputs fixture } | Should -Not -Throw
    }

    It 'rejects an empty series census' {
        $report.census.in_scope = 0
        { Assert-CanaryAnalysis $report $outputs fixture } | Should -Throw
    }

    It 'rejects a report missing the backfilled observation' {
        $report.runs = 1
        { Assert-CanaryAnalysis $report $outputs fixture } | Should -Throw
    }

    It 'rejects a clean claim without a baseline' {
        $report.outcome = 'clean'
        { Assert-CanaryAnalysis $report $outputs fixture } | Should -Throw
    }

    It 'rejects outputs granting publication all-clear' {
        $outputs['can-clear'] = 'true'
        { Assert-CanaryAnalysis $report $outputs fixture } | Should -Throw
    }

    It 'rejects a report about a different commit' {
        { Assert-CanaryAnalysis $report $outputs another } | Should -Throw
    }
}

Describe 'Backfill storage preservation' {
    It 'allows only the new historical object while filling the range' {
        { Assert-CanaryStorePreserved @{ head = 'original' } @{ head = 'original'; parent = 'new' } -AllowAdditional } |
            Should -Not -Throw
    }

    It 'rejects replacing an existing measurement while filling the range' {
        { Assert-CanaryStorePreserved @{ head = 'original' } @{ head = 'changed'; parent = 'new' } -AllowAdditional } |
            Should -Throw
    }

    It 'requires identical hashes and file membership when resuming' {
        $original = @{ head = 'head-hash'; parent = 'parent-hash' }
        { Assert-CanaryStorePreserved $original $original.Clone() } | Should -Not -Throw
        { Assert-CanaryStorePreserved $original @{ head = 'head-hash' } } | Should -Throw
        { Assert-CanaryStorePreserved $original @{ head = 'head-hash'; parent = 'changed' } } | Should -Throw
        { Assert-CanaryStorePreserved $original @{ head = 'head-hash'; parent = 'parent-hash'; extra = 'extra' } } | Should -Throw
    }
}
