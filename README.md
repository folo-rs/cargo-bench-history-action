# Benchmark history action

Reusable workflows collect benchmark history and report changes without requiring
each repository to maintain the collection matrix, receipt handoff and publication
job graph. The root composite action remains available for custom job graphs.

## Start with the reusable workflows

Commit your benchmark-history configuration and provision its Azure store and
federated identity using
[`setup-azure`](https://folo-rs.github.io/folo/cargo-bench-history/commands/setup-azure.html).
Set repository variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` to the deployment's
managed-identity client ID and tenant ID.

Create a history caller:

```yaml
name: Benchmark history
on:
  push:
    branches: [main]
  workflow_dispatch: {}
jobs:
  benchmark-history:
    if: github.ref == 'refs/heads/main'
    permissions:
      contents: read
      actions: read
      id-token: write
      issues: write
    uses: folo-rs/cargo-bench-history-action/.github/workflows/history.yml@v1
    with:
      azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
```

Create a PR caller:

```yaml
name: PR benchmark history
on:
  pull_request:
    types: [opened, synchronize, reopened, closed]
jobs:
  benchmark-history:
    if: github.event.pull_request.head.repo.full_name == github.repository
    permissions:
      contents: read
      actions: read
      id-token: write
      pull-requests: write
    uses: folo-rs/cargo-bench-history-action/.github/workflows/pr.yml@v1
    with:
      azure-client-id: ${{ vars.AZURE_CLIENT_ID }}
      azure-tenant-id: ${{ vars.AZURE_TENANT_ID }}
```

No package list is needed. History collects the workspace; PR preparation selects
affected benchmark packages and their dependents automatically. The workflows own
checkout, the platform matrix, rerun-safe collection, receipt reconciliation,
analysis, report upload, publication and concurrency. The `closed` event cancels
superseded PR work without starting another collection.

Collection defaults to x64 Linux and Windows. Apple Silicon macOS is also supported;
set `platforms: ubuntu-latest,windows-latest,macos-latest` in each caller's `with:`
block to include it. The workspace's benchmarks and their dependencies must support
the selected runners. Intel macOS is not a supported release target.

Under default GitHub settings, the platform restricts effective fork-PR
`id-token` permission after YAML evaluation. Approval to run does not grant that
permission. This server-enforced restriction prevents a default fork PR from
minting the Azure assertion; the same-repository conditions select intended work
and are not the authorization boundary. Nondefault write-token exceptions are
outside this starter's assumptions.

Reports are uploaded as `bench-history-report-<project>-<run-id>-<attempt>` or
`pr-bench-history-report-<project>-<run-id>-<attempt>`, containing `report.md`,
`report.json` and `summary.md`. A first history may be inconclusive, and no rolling
issue need exist until findings appear. Clean updates leave an existing issue open;
inconclusive evidence cannot clear findings. Execution failures remain failures,
including when surviving platforms produce a useful qualified report.

### Workflow configuration

Both callers require the Azure identifiers as strings. Optional inputs are:

| Input | Default | Purpose |
| --- | --- | --- |
| `platforms` | `ubuntu-latest,windows-latest` | CSV collection runner labels. |
| `working-directory` | `.` | Project directory relative to the caller repository. |
| `config` | `.cargo/bench_history.toml` under the invocation project | Committed configuration file, relative to that project directory. |
| `exclude` | Empty | Packages excluded from collection; PR exclusions apply after dependency expansion. |
| `bench` | Empty | CSV Cargo benchmark targets. |
| `best-of` | `1` | Repetitions, retaining each metric's minimum. |
| `all-features` | `true` | Enable all Cargo features. |
| `no-default-features` | `false` | Disable default Cargo features. |
| `features` | Empty | Additional CSV Cargo features. |
| `install-method` | `binstall` | `binstall`, `install` or `path` for every required tool. |
| `source-path` | Empty | Folo source directory relative to the invocation checkout, required only for `path`. |
| `publish` | `true` | Enable all GitHub lifecycle/report writes. Analysis and artifacts remain available when false. |
| `since` | Main tool default | History-only look-back window. |

The workflows return `outcome`, `publication-state`, `notable`, `regressions`,
`partial-platform-coverage`, `report-artifact-id` and `report-artifact-url` when
analysis runs. They do not expose paths belonging to another job. `publication-state`
is `findings`, `clean` or `inconclusive`; the underlying analysis outcome remains
distinct. An empty selected benchmark scope is an explicit no-analysis path.

For extra benchmark prerequisites, provide the fixed repository-local action
`.github/actions/bench-history-setup/action.yml`. Collection calls it from the
invocation checkout. There is no setup action path/ref override. Repositories
needing a different job graph can use the root action below.

Source-mode Folo callers set `install-method: path` and `source-path: .`. Every tool
comes from that invocation checkout, while PR measurements use a separate checkout
of the frozen real head. The workflow and its internal actions stay on the same
selected action revision through GitHub's `$/` self-repository references.

## Prerequisites

- A Rust workspace with benchmarks supported by
  [cargo-bench-history](https://folo-rs.github.io/folo/cargo-bench-history/), its chosen
  Rust toolchain and any benchmark engine/system dependencies.
- PowerShell 7.6 or later and Cargo. The release manifest lists supported runners.
  `binstall` bootstraps the pinned official cargo-binstall action; `install` and
  fallback compilation additionally require a working Rust build environment.
- GitHub.com Actions runner 2.336.0 or later for reusable workflow self references.
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

## Advanced: root action reference

The root composite exposes individual commands for custom workflows. Callers of
this lower layer own checkout, prerequisites, dependencies, concurrency, collection
evidence and artifact transport. Analysis never publishes, and the root action
never uploads reports. A full commit reference can replace `@v1` when a consumer
wants immutable version selection.

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
      - uses: folo-rs/cargo-bench-history-action@v1
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
      - uses: folo-rs/cargo-bench-history-action@v1
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
- uses: folo-rs/cargo-bench-history-action@v1
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

### Root commands and inputs

| Command | Purpose |
| --- | --- |
| `collect` | Measure and store the selected benchmarks. |
| `backfill` | Collect missing measurements across a historical range. |
| `analyze-history` | Analyze history and write reports without publication. |
| `analyze-pr` | Compare a PR against its base and write reports without publication. |
| `publish-comment-findings`, `publish-comment-clean`, `publish-comment-preflight`, `publish-comment-inconclusive`, `publish-comment-failed` | Publish PR result or lifecycle evidence. |
| `publish-issue-findings`, `publish-issue-clean`, `publish-issue-preflight`, `publish-issue-inconclusive`, `publish-issue-failed` | Maintain the project's rolling history issue. |
| `alert` | Publish one workflow-failure alert, separate from the rolling issue. |

`command` is required. `install-method` defaults to `binstall`. All other metadata
defaults are empty: the Rust runtime applies per-command defaults and rejects
inapplicable inputs. Inputs are strings, including `"true"`/`"false"` boolean inputs.
The root metadata in [action.yml](action.yml) describes every input.

`working-directory` defaults to the caller's current directory. It selects the
measured/configuration checkout, not the tool's source checkout. In source mode:

```yaml
- uses: folo-rs/cargo-bench-history-action@v1
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

### Root installation and outputs

`binstall` installs exact manifest versions and permits source fallback.
`install` uses exact-version `cargo install --locked`. `path` always builds and
force-installs from the selected source checkout; it never restores the released
tool cache. Its installed versions must match that checkout's Cargo metadata,
not the registry versions in `release.json`. Every command installs the companion.
Collection, backfill and analysis also install the main tool; consumers never
install the faker. Package ownership queries are linked into the companion, not
provided by a separately installed detector executable.

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
