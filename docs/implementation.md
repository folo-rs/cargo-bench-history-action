# Implementation

The action metadata exposes string inputs and passes them through environment/file
boundaries. A PowerShell bootstrap reads the release manifest, selects required
executables, manages installation roots and invokes the installed companion. It
does not interpret benchmark reports or reimplement lifecycle policy.

The companion's `action` command is maintained in `folo-rs/folo`. It validates
command-specific inputs, resolves project identity through the core configuration
and storage-key helpers, drives the main executable with argument vectors, and
reuses the existing evidence and publication implementations. Long-running tool
execution streams its diagnostics rather than accumulating benchmark logs.

## Bootstrap interface

`scripts/Tools.psm1` owns `Read-ActionManifest`, `Get-RequiredTool`,
`Install-ActionTools` and `Get-ActionToolPath`. Installation receives a manifest,
method, explicit installation root and package selection. Path mode also receives
one source checkout. `RequirePrebuilt` is an internal availability-gate switch, not
a consumer input.

`scripts/Run-Action.ps1` separates preparation, installation and invocation so
first-party cache actions can surround installation. Bootstrap inputs are removed
before the remaining string-input JSON is passed to the companion.

The invocation contract is:

```text
cargo-bench-history-github action --inputs-file PATH --github-output PATH --temp-dir PATH [--tool PATH]
```

The input file contains `command`, `working-directory` and command-specific action
inputs. It contains neither `install-method` nor `source-path`; bootstrap owns those.
The output file is the current step's `GITHUB_OUTPUT`. The temporary root is outside
the measured checkout. Publication uses the normal ambient GitHub repository/run
context where an explicit execution-data input is absent.

### Installation identity and cache ownership

The installer returns a map from package names to absolute executable paths below
the explicit root's `bin` directory. It reads Cargo's generated `.crates.toml`
installation table, which both Cargo and binstall write. If `.crates2.json`
contains a record for the same package, the records must agree. Restored files
require a matching crates.io receipt at the manifest version and the executable
named by that receipt. Cargo's records are the installation identity authority;
the action does not maintain a second checksum or version manifest.
Corrupt or conflicting receipts are explicit errors.

The companion's `--version` must match the receipt and its `action --help` must
succeed. The main binary has no version flag, so its evidence is the fresh Cargo
record, executable presence and successful help invocations for the commands used
by the runtime. This is not an independently reported executable version.
Fixture/scope behavioral checks belong to their CI canaries.

Path mode reads the selected package's `cargo metadata --no-deps --locked`
output for its version and required binary target. It always force-installs that
checkout and verifies the resulting path receipt against the source version.
Source package versions may differ from the release manifest; that manifest only
selects versions for published installation methods.

`RequirePrebuilt` always bypasses reuse and selects binstall's
`--strategies crate-meta-data`: neither compilation nor the quick-install service
may satisfy the gate. Ordinary binstall permits all upstream installation
strategies. The official cargo-binstall action is pinned to its verified v1.23.0
commit and receives `version: 1.23.0`; the shared installer only checks that its
prerequisite exists, without downloading tools itself.

Preparation consumes `CBH_INPUTS_JSON`, removes only installation-owned inputs,
resolves the caller working directory and creates an isolated root under
`RUNNER_TEMP`. It emits `state-path`, `install-root`, `cache-enabled` and `cache-key`.
Runtime keys retain empty string values so Rust validates every supplied name
before applying command-specific defaults. Empty `install-method` and
`working-directory` values receive their bootstrap defaults explicitly.
The key includes the verification format, runner OS/architecture and exact selected
package versions. Installation and invocation consume `CBH_STATE_PATH`. The entire
installation root, including hidden Cargo records, is cached between
preparation and invocation; path mode neither restores nor saves it.
Published installation paths are stable for a given cache key because
`actions/cache` includes the requested paths in its internal cache version.
Runtime input/report directories and path-mode installation roots are unique per
invocation.
Internal root-action canaries set `CBH_ACTION_DISABLE_CACHE=true` to select a fresh
installation root and emit `cache-enabled=false` for every installation method.
Both cache actions use that output, so neither restore nor save occurs. The switch
is an environment-level CI control, not a public action input or tool-version
override; unset or `false` preserves ordinary published-installation caching.

## Validation and release boundaries

Pester covers installer argument construction, exact manifest selection, cache
validation and release reconciliation using mocked process results. Real canaries
exercise the same installer and root action with isolated roots.
`.github/monorepo-revision` selects the source checkout for path-mode canaries and is
test configuration, not a consumer version override.

The release job operates after the matrix availability gate and uses the runner's
PowerShell, Git and GitHub CLI to reconcile repository refs/releases. This is
GitHub job/publication orchestration, not a second benchmark-domain implementation;
it does not install a benchmark binary merely to manipulate tags. No release script
is executed against real GitHub publication endpoints by local tests.

### CI evidence

`test.yml` runs fast Pester tests, version readiness and source-path smoke independently
of the published-tool gate. Source smoke checks out the exact monorepo revision into
`Folo`; neither its source path nor its isolated measurement workspace selects a
released tool version.

The shared `install-tools.yml` workflow derives an install/binstall matrix from the
current checkout's manifest, not a released action. Each leg checks that the Rust
host matches its declared target and uses absent installation roots. It downloads
every promised monorepo `.zip` and sibling `.sha256`, checks the downloaded archive
against the sidecar, and calls the same installer used by consumers. Sidecar checking
is explicit CI behavior, not an assumed cargo-binstall verification feature.
The shared installer verifies exact crates.io identities using fresh Cargo receipts.
The companion also reports its version directly; main/faker/scope lack a dedicated version interface,
so their identity is receipt-based, with their used contracts exercised separately.

Root-action method canaries disable installation-cache restore/save with
`CBH_ACTION_DISABLE_CACHE=true`. Their fresh installs exercise collection and
analysis after the strict availability probe; ordinary consumer fallback remains
permitted, but can never establish the required prebuilt evidence. The standalone
`install-tools` aggregate fails if any availability leg fails, is cancelled or is
skipped. A future/unpublished pin or missing archive is a real failure.

Canaries create a committed, dependency-free Cargo workspace outside the action and
Folo checkouts. The workspace is virtual: its benchmark belongs to a non-root member,
because package detection deliberately excludes workspace-root packages. The root
still owns the benchmark-history configuration. Its small benchmark entry point
delegates to the manifest-pinned faker, producing deterministic engine output without
wall-clock measurements.
No canary posts issues or comments. Same-repository assertions require a nonempty stored object under the emitted
machine-key partition, parseable reports about the fixture commit, a nonempty series
census and an honest insufficient-baseline outcome for its single history point.
Fork-triggered canaries instead assert the root action's explicit fork skip for both
commands and reject any claimed collection or report evidence. This never bypasses
published availability: every exact registry/prebuilt installation, asset check and
fixture-tool smoke runs before these invocations on all triggers. GitHub's event
context is preserved, not replaced with synthetic same-repository provenance.

After successful, non-skipped analysis, each source and published-method canary
passes the emitted report paths unchanged to `actions/upload-artifact`. The upload
must find files, establishing compatibility with the real report consumer rather
than only the native filesystem assertions. Artifacts are distinct by installation
method, target and run attempt; they remain available for diagnostics even when
the report assertions fail.

### Version readiness and reconciliation

Release-bearing paths are `action.yml`/`action.yaml`, `release.json`, scripts and
workflow definitions. The CI-only exemptions are `scripts/Release.psm1`,
`scripts/Publish-Release.ps1`, `scripts/Install-Canary.ps1` and the `test.yml`,
`install-tools.yml`, `release.yml` workflows. New scripts and consumer reusable
workflows are release-bearing by default. Documentation, tests and the canary
source revision do not require a version increment. Git tree identity includes
file modes, content and path names; readiness compares both the event's base
commit and any existing immutable version tag.

The content-write job is serialized after the shared availability workflow, with
read-only permissions everywhere else. It refreshes tags inside the publication
queue, preserves an existing equivalent version tag's original commit, creates
missing releases using verified tags and prefixed generated notes, and advances
the major tag only to a newer semantic version. A force-with-lease protects the
major ref against out-of-band changes. Failed intermediate operations remain
visible; retries reconcile the missing operations instead of moving immutable tags.
The GitHub token is the only publication credential. No repository settings are
changed by this automation.
