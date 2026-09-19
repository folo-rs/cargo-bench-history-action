# Benchmark history action

A root composite GitHub action for independently scheduled benchmark collection,
analysis and publication. It installs the tool set pinned in `release.json` and
delegates execution to `cargo-bench-history-github`.

This repository exposes the root action, not public reusable workflows. Callers
assemble their own jobs, checkout, benchmark prerequisites, platform evidence,
storage, concurrency and artifact upload/download. Analysis never posts a comment
or issue, and the action never uploads reports.

## Prerequisites

- A Rust workspace with benchmarks supported by
  [cargo-bench-history](https://folo-rs.github.io/folo/cargo-bench-history/), its chosen
  Rust toolchain and any benchmark engine/system dependencies.
- PowerShell 7.6 or later and Cargo. The release manifest lists supported runners.
  `binstall` bootstraps the pinned official cargo-binstall action; `install` and
  fallback compilation additionally require a working Rust build environment.
- Full Git history for analysis and backfill (`fetch-depth: 0`), and any required
  base refs fetched by the caller.
- A committed `.cargo/bench_history.toml` with a stable project identity, or an
  explicit `config` path. Use `local-path` for a local store or configure Azure.

For a local store, the configuration can be:

```toml
[project]
id = "my-project"
```

For Azure storage, add the account and existing container:

```toml
[storage.azure]
account = "myhistoryaccount"
container = "bench-history"
```

Provision the account/container and a Microsoft Entra federated identity before the
workflow runs. Configure storage data-plane access for that identity, set job
environment variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`, and grant
`id-token: write` for GitHub OIDC. The main tool handles Azure authentication;
the action passes its environment through unchanged. Do not set `local-path` in
that flow. Cloud analysis may use `cache` for its local read cache.

## Hand-assembled local history workflow

Replace `ACTION_COMMIT` with a reviewed immutable commit of this repository.
Registry installation succeeds only once every exact release-manifest pin is
published; source-mode results do not establish registry/prebuilt availability.
The initial companion runtime pin requires the coordinated monorepo release.

This example keeps local measurement history in a caller-owned cache, collects on
one platform, analyzes it and uploads the reports. Its first run may report no
comparable history. Configure concurrency for the project's chosen history branch.

```yaml
name: Benchmark history
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: benchmark-history-${{ github.ref }}
  cancel-in-progress: false
jobs:
  history:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      # Prepare the workspace's Rust toolchain and benchmark engine prerequisites here.
      - uses: actions/cache@v4
        with:
          path: ${{ runner.temp }}/measurement-history
          key: measurements-${{ runner.os }}-${{ runner.arch }}-${{ github.ref_name }}-${{ github.run_id }}-${{ github.run_attempt }}
          restore-keys: measurements-${{ runner.os }}-${{ runner.arch }}-${{ github.ref_name }}-
      - uses: folo-rs/cargo-bench-history-action@ACTION_COMMIT
        id: collect
        with:
          command: collect
          local-path: ${{ runner.temp }}/measurement-history
          on-existing: skip
      - name: Prepare analysis machine keys
        id: keys
        shell: pwsh
        env:
          CBH_MACHINE_KEY: ${{ steps.collect.outputs.machine-key }}
        run: |
          # Pass this successful collection's key through the directory-based analysis contract.
          $directory = Join-Path $env:RUNNER_TEMP "collected-keys-$([guid]::NewGuid().ToString('N'))"
          $platformDirectory = Join-Path $directory 'ubuntu-latest'
          New-Item -ItemType Directory -Path $platformDirectory | Out-Null
          $env:CBH_MACHINE_KEY | Set-Content -LiteralPath (Join-Path $platformDirectory 'machine-key.txt')
          "directory=$directory" | Add-Content -LiteralPath $env:GITHUB_OUTPUT
      - uses: folo-rs/cargo-bench-history-action@ACTION_COMMIT
        id: analyze
        with:
          command: analyze-history
          local-path: ${{ runner.temp }}/measurement-history
          context: ${{ github.sha }}
          machine-keys: ${{ steps.keys.outputs.directory }}
          expected-platforms: ubuntu-latest
          completed-platforms: ubuntu-latest
      - uses: actions/upload-artifact@v4
        id: reports
        with:
          name: benchmark-reports
          path: |
            ${{ steps.analyze.outputs.report-markdown }}
            ${{ steps.analyze.outputs.report-json }}
            ${{ steps.analyze.outputs.report-summary }}
          if-no-files-found: error
```

Local storage is not shared between jobs unless the caller restores/downloads it.
A platform matrix must aggregate successful collection evidence before a separate
analysis job. Pass the intended platform names as `expected-platforms`, only
confirmed successful platform names as `completed-platforms`, and a directory
containing the selected `<platform>/machine-key.txt` files as `machine-keys`.
The runtime reads those files recursively; this input is a directory, not an
inline fingerprint or CSV. Each file contains the `machine-key` output from that
platform's successful collection. Machine keys are not proof of collection.

Publication is a separate step after upload. For example, history findings can be
published with the following step in a job granted `issues: write`:

```yaml
- uses: folo-rs/cargo-bench-history-action@ACTION_COMMIT
  if: steps.analyze.outputs.publication-state == 'findings'
  with:
    command: publish-issue-findings
    body-file: ${{ steps.analyze.outputs.report-summary }}
    report-file: ${{ steps.analyze.outputs.report-json }}
    analyzed-sha: ${{ github.sha }}
    artifact-url: ${{ steps.reports.outputs.artifact-url }}
    expected-platforms: ubuntu-latest
    completed-platforms: ubuntu-latest
```

Publish only matching summary/JSON evidence from the same successful analysis.
PR comment publication requires `pull-requests: write`, a `pr-number`, and the
command's PR scope/head evidence. The companion uses the ambient short-lived
`${{ github.token }}`; there is no token input. It explicitly skips fork-origin
PR work before credentialed benchmark/publication operations. Do not run untrusted
PR code in a privileged `pull_request_target` workflow.

## Commands and inputs

| Command | Purpose |
| --- | --- |
| `collect` | Measure and store the selected benchmarks. |
| `backfill` | Collect missing measurements across a historical range. |
| `analyze-history` | Analyze history and write reports without publication. |
| `analyze-pr` | Compare a PR against its base and write reports without publication. |
| `publish-comment-findings`, `publish-comment-clean`, `publish-comment-preflight`, `publish-comment-no-data`, `publish-comment-failed` | Publish PR result or lifecycle evidence. |
| `publish-issue-findings`, `publish-issue-clean`, `publish-issue-preflight`, `publish-issue-no-data`, `publish-issue-failed` | Maintain the project's rolling history issue. |
| `alert` | Publish one workflow-failure alert, separate from the rolling issue. |

`command` is required. `install-method` defaults to `binstall`. All other metadata
defaults are empty: the Rust runtime applies per-command defaults and rejects
inapplicable inputs. Inputs are strings, including `"true"`/`"false"` boolean inputs.
The root metadata in [action.yml](action.yml) describes every input.

`working-directory` defaults to the caller's current directory. It selects the
measured/configuration checkout, not the tool's source checkout. In source mode:

```yaml
- uses: folo-rs/cargo-bench-history-action@ACTION_COMMIT
  with:
    command: collect
    install-method: path
    source-path: ${{ github.workspace }}/folo-source
    working-directory: ${{ github.workspace }}/measured-project
    local-path: ${{ runner.temp }}/measurement-history
```

The caller must check out both directories. `source-path` is required only for
`path`; it points to the Folo monorepo containing `packages/`. It does not override
the release manifest for registry installations.

## Installation and outputs

`binstall` installs exact manifest versions and permits source fallback.
`install` uses exact-version `cargo install --locked`. `path` always builds and
force-installs from the selected source checkout; it never restores the released
tool cache. Its installed versions must match that checkout's Cargo metadata,
not the registry versions in `release.json`. Every command installs the companion.
Collection, backfill and analysis also install the main tool; consumers never
install fixture/scope tools.

Published installations cache Cargo receipts and verified executable files by OS,
architecture and the exact required tool versions. Invalid or missing evidence
causes reinstallation or an explicit error, not an assumed hit. Installation and
runtime files live under a dedicated runner-temporary directory outside the
caller checkout.

The companion reports its executable version. The main tool does not implement
`--version`: its identity evidence is the Cargo installation record and the
available executable, with runtime command smoke checks. These checks are not an
independent executable-reported version. If installation fails, the action fails;
it cannot guarantee a GitHub alert when the companion itself is unavailable.

Outputs are available only where meaningful for the selected command:
`instance`, `skipped`, `machine-key`, `outcome`, `notable`,
`partial-platform-coverage`, `regressions`, `report-markdown`, `report-json`,
`report-summary`, `publication-state` and `can-clear`. Report outputs are paths;
callers upload those files. Findings are advisory; execution errors fail the step.

## Local bootstrap checks

With Pester and PSScriptAnalyzer already installed:

```powershell
Invoke-Pester -Path .\tests\Tools.Tests.ps1, .\tests\Run-Action.Tests.ps1
Invoke-ScriptAnalyzer -Path .\scripts\Tools.psm1
Invoke-ScriptAnalyzer -Path .\scripts\Run-Action.ps1
```

These checks mock installation and use filesystem fixtures. They do not prove
published package or prebuilt-archive availability; that is the separate real
installation gate.
