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

Analysis ignore configuration belongs to the pinned Rust tools. The core reads
`[ignore].benchmarks`, matches literal case-sensitive qualified benchmark ID
prefixes and filters metric series before change detection. Rust reports the
ignored series as outside scope and retains the existing `nothing_in_scope` outcome
when every selected series is ignored. PowerShell and the workflows forward the
configuration path unchanged; they do not parse the ignore list, filter collection
or translate report outcomes.

The pinned Rust tools own the full Markdown report's Coverage listing, the Insights
help link and the conditional full-report pointer in the judged-series summary
bullet. The companion uses the core summary's heading and visible commit
attribution for completed GitHub issue and PR reports without adding duplicates.
Incomplete in-scope series do not produce a coverage warning; missing-platform and
staleness warnings remain Rust-owned. PowerShell passes report paths unchanged and
does not append or rewrite report content.

Peak outstanding-byte ingestion, default analysis and missing-peak handling belong
to the pinned Rust tools. Producer-side `ThreadSpan::no_peak()` belongs to
`alloc_tracker`; the action neither filters metrics nor adds an opt-in flag.

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

Root collection accepts the optional boolean string `collection-snapshot`, with a
runtime default of false. When enabled, Rust allocates an external snapshot path,
passes `--collection-output` to the core and emits the absolute `collection-file`
output after successful execution and persistence handling. The versioned snapshot
contains the exact per-engine runs, including when `on-existing: skip` preserves
an existing stored object. The companion derives its machine key from that snapshot.
PowerShell does not interpret the snapshot or compose measurement data.

Root analysis accepts `current-collections`, a directory containing selected
`<platform>/collection.json` files, instead of `machine-keys`. The companion validates
and forwards the snapshots through core `--current-collection` arguments. Scoped
current observations bypass stored and cached values for the analyzed context;
normal matching history remains available for baselines. Omitting scoped inputs
preserves the independent store-analysis interface.

`max-commits` is an optional backfill-only runtime string. The reusable workflow
and root action default it to `''`; the JSON handoff preserves that empty string
for unlimited replay and preserves supplied values without numeric conversion.
The companion validates a nonzero Rust `usize`, rejects nonempty values on other
commands and forwards `--max-commits` to the core backfill command. PowerShell owns
neither this validation nor attempt accounting.

`rustflags` remains an opaque runtime string in this handoff. Workflows forward it
only to root `collect` and `backfill` invocations, not to preparation, setup,
installation, analysis or publication. PowerShell leaves both ambient flag
variables and the input unchanged. The companion owns whitespace splitting,
effective ambient flag selection and child-only `CARGO_ENCODED_RUSTFLAGS`
composition, including the collection machine-key query. No workflow or script
calculates or replaces compiler options.

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
Faker behavioral checks belong to the CI canaries.

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

## Reusable workflow orchestration

`history.yml`, `pr.yml` and `backfill.yml` use `$/` self references to run this
repository's root action and internal `workflow-tools` composite at the called workflow's exact commit.
The caller's checkout cannot select that implementation. This requires GitHub.com
runner 2.336.0 or newer; actionlint's unsupported self/queue diagnostics have exact,
path-scoped compatibility exceptions.

The `workflow-tools` composite checks out the invocation at `GITHUB_WORKSPACE` for configuration,
the fixed setup hook and optional Folo tool sources. A separate full-history checkout
holds the frozen measurement head. Its basename matches the repository name to retain
directory-derived project identity. The PR's frozen base can be fetched from the
invocation checkout locally, without a persisted Git credential or another network
authentication path.

`Workflow.psm1` owns only paths, installer selection, input files and native argument
vectors. It calls the same `Install-ActionTools` used by the root and availability
gate. Private tools use fresh job-local roots; ordinary root-action cache behavior is
unchanged. The workflow state file contains invocation wiring, not another version
or executable-identity manifest.

The installed companion's `prepare-workflow` boundary resolves the canonical project
and matrix. History and PR also resolve real head/base and concrete benchmark
package scope. History selects workspace
benchmarks and PR selects affected packages, derived from the flow rather than a
separate scope input. Detection uses the companion's library
dependency, not another installed executable. The wrapper verifies the required
machine-readable `skipped`/`skip-all` handoff so missing scope outputs cannot silently
skip the graph. Policy skips carry a reason and gate every downstream operation,
independently of an empty selected package set.
`cargo-detect-package` follows the companion's Rust dependency/version plan; it has
no separate executable pin or installer role in the action manifest. The faker
remains independently pinned because the real collection canaries execute it.
History uses the prepared inventory to gate empty work, then retains root workspace
collection with the configured exclusions. PR receives the concrete nonempty prepared
package list and does not also forward exclusions, which preparation already applied.
Namespace normalization, dependency closure, report classification and receipt
selection remain Rust-owned.

History/PR workflow-wide cancellation uses repository, flow and configuration location plus the
PR or commit identity available before any job runs. Job queues and sink serialization
use the canonical project identity from preparation. This avoids a nested workflow
layer solely to obtain a preparation-dependent workflow-level concurrency group.

Backfill preparation sends only `working-directory`, `config`, `platforms`,
`exclude`, `from`, `to`, `lookback` and `minimum-age` to
`prepare-workflow --flow backfill`. Empty values remain data for Rust to validate
and interpret; PowerShell does not choose a mode, parse durations, read the clock
or select historical commits. Rust validates explicit versus rolling inputs,
resolves refs option-safely and calculates a rolling window from one injected
clock snapshot. It does not inspect current-HEAD Cargo metadata or select packages.

Backfill always emits `instance`, `matrix`, `expected-platforms`, `skipped` and
`has-work`. A normal range has `skipped=false`, `has-work=true` and full-SHA `from`
and `to`. No eligible automatic endpoint has `skipped=false`, `has-work=false`
and `no-work-reason=no-eligible-commit`, without endpoints. A policy skip has
`skipped=true`, `has-work=false` and `skip-reason`, without endpoints.
The adapter rejects missing, malformed, unexpected or contradictory handoffs,
including mixed reasons and ranges. Only non-skipped preparation with explicit
work enables the execution matrix. History/PR preparation input and output shapes
are unchanged.

Backfill preparation checks out the real event head through `workflow-tools`.
Only the backfill preparation operation exposes fetched `origin` branches as
missing local branch refs: SHA-detached Actions checkouts otherwise retain those
names only under `refs/remotes/origin/`. The adapter enumerates refs locally,
compares names ordinally, ignores `origin/HEAD` and symbolic remote refs, and creates
each missing `refs/heads/*` with `git update-ref` requiring an absent old ref.
Existing local branches and tags remain untouched, as does the frozen detached
HEAD. Enumeration, namespace conflicts and raced ref creation fail explicitly;
there is no network fetch, force update or failed-resolution remapping. Rust still
resolves caller expressions such as `main`, `refs/heads/main` and `main~1` through
ordinary Git semantics and owns all range policy. History, PR and non-preparation
operations do not perform this checkout wiring.

Each matrix job then passes the prepared `to` SHA as that adapter's measurement
head, fetching full history even if the original remote branch has moved.
Invocation configuration, setup and source installation use the adapter unchanged.
The root `backfill` command receives the frozen range, optional `max-commits` and
common collection options, with `on-existing: skip`; rolling inputs never reach
the explicit-range executor. `max-commits` goes only to execution, not preparation
or setup. First-parent validity, traversal and the per-platform attempt budget
stay in the main executable. Its normal summary describes processed and deferred
work; the graph has no receipt, analysis, artifact or sink jobs.

Backfill's `cbh-backfill-run` workflow queue groups repository/configuration
locations independently of event, SHA or run identity. Its `cbh-backfill-work`
job queues use canonical project/platform identities so aliased configurations
cannot race. Distinct prefixes prevent a workflow from waiting on its own queue;
both levels use `cancel-in-progress: false` and `queue: max`. Matrix fail-fast is
disabled so one platform's failure does not cancel other platforms. No backfill
job or step suppresses execution failures. `ignore-errors` is passed to the core
through the root action and controls only its per-commit failure policy.
The hosted timeout remains an exceptional watchdog whose cancellation is visible,
not a normal completion mechanism.

Collection records a receipt only after the root command supplies its snapshot.
The adapter passes that file to `collection-receipt --collection-file`; the
companion validates it and embeds its version-1 payload in a version-2 receipt.
One self-contained `receipt.json` is uploaded, without a second payload path or a
shared-store reference. Artifacts include project, flow, platform and attempt; downloads use the
authenticated run-wide view. Rust accepts the downloader's flat single-receipt and
per-artifact-directory layouts, enforcing the same identity/latest-job checks for both.
Legacy receipts do not establish scoped collection evidence. `prepare-analysis`
receives `--current-collection-dir`, writes only the selected
`<platform>/collection.json` files and emits `current-collections`. The adapter
requires an absolute existing output directory before root analysis receives it.
It consumes Rust's checked native path without requiring the input's spelling;
physical path normalization can resolve aliases and simplify native prefixes.
Receipt selection, empty-collection handling, payload validation and
duplicate current-identity rejection remain Rust-owned.
The analysis cache has a stable instance-scoped path outside both checkouts. History
can save read-cache updates; PR analysis only restores them.

Successful analysis, report upload and disposition publication share a job.
The workflow forwards `publication-state` into the named command and never interprets
`notable` or `can-clear` as a substitute. Empty PR scope uses the explicit flag on the
inconclusive command. Terminal jobs retain a reused preflight's original attempt;
otherwise they use the current attempt, with the companion enforcing exact ownership.
A failed history collection can both preserve a useful partial report and file its
separate workflow-failure alert.

## Validation and release boundaries

Pester covers installer argument construction, exact manifest selection, cache
validation and release reconciliation using mocked process results. Real canaries
exercise the same installer and root action with isolated roots.
`.github/monorepo-revision` selects the source checkout for path-mode canaries and is
test configuration, not a consumer version override.
Tool-pin releases select the full monorepo commit carrying the paired implementation
and version plan. That commit must be available on GitHub before source-path checks
can pass; source success does not establish published-tool availability.

Source-path compatibility evidence covers the real collection snapshot,
`--collection-file` receipt, `--current-collection-dir` reconciliation and
root-action `current-collections` analysis handoff. Installing binaries alone
does not establish this workflow contract.

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

The source and published-tool canaries pin `dtolnay/rust-toolchain` to the same
reviewed full commit SHA from upstream `master` and explicitly select
`toolchain: stable`. Upstream requires pins from
[`master` history](https://github.com/dtolnay/rust-toolchain#choice-of-full-length-commit-sha);
its generated compiler-selection branches are not durable sources for SHA pins.

Dependabot checks GitHub Actions references weekly and proposes updates for review,
not automatic merging. Bootstrap updates retain the full SHA and compiler input;
reviewers verify membership in upstream `master` and inspect the implementation
changes before accepting a proposal. Dependabot infers its update source from the
SHA's matching tag or containing branch, not from the compiler input or comments.
The upstream [`v1` tag is unsupported](https://github.com/dtolnay/rust-toolchain/issues/114)
and is not a release-approval signal. Check the first Dependabot update log after
enabling the configuration on the default branch, and inspect its selected source
if upstream `master` advances without a proposal.

Manifest tool pins and explicit action inputs such as cargo-binstall's `version`
remain separately maintained. Dependency updates still obey version-readiness and
published-availability gates.

The shared `install-tools.yml` workflow derives an install/binstall matrix from the
current checkout's manifest, not a released action. Each leg checks that the Rust
host matches its declared target and uses absent installation roots. It downloads
every promised monorepo `.zip` and sibling `.sha256`, checks the downloaded archive
against the sidecar, and calls the same installer used by consumers. Sidecar checking
is explicit CI behavior, not an assumed cargo-binstall verification feature.
The shared installer verifies exact crates.io identities using fresh Cargo receipts.
The companion also reports its version directly; main/faker lack a dedicated version interface,
so their identity is receipt-based, with their used contracts exercised separately.

The availability probe also runs `tests/Assert-BackfillPreparation.ps1` with the
verified installed companion. This offline fixture retains historical benchmarks
but removes the Cargo workspace at its invocation head, then runs the real adapter
with `prepare-workflow --flow backfill`. Its frozen outputs must match the actual
fixture commits without a scope skip. The checkout is detached with fetched
`origin/main` but no local `main`; the real preparation boundary must resolve
`main~1`, `main` and `refs/heads/main` while preserving HEAD and existing refs.
The same adapter then exercises rolling selection, a rolling endpoint override
and no eligible endpoint. Every request retains the real workflow's empty optional
defaults so validation cannot mistake them for conflicting selections. Fixed
historical Git dates keep this native smoke far from live-clock cutoff boundaries;
injected-clock Rust tests own exact duration and calendar behavior.
GitHub event environment is cleared only in
the fixture's child processes: the action repository's event SHA is not a fixture
commit. This contract probe neither installs tools nor substitutes for registry
and archive availability.

Root-action method canaries disable installation-cache restore/save with
`CBH_ACTION_DISABLE_CACHE=true`. Their fresh installs exercise collection and
analysis after the strict availability probe; ordinary consumer fallback remains
permitted, but can never establish the required prebuilt evidence. The standalone
`install-tools` aggregate fails if any availability leg fails, is cancelled or is
skipped. A future/unpublished pin or missing archive is a real failure.

Canaries create a committed, dependency-free Cargo workspace outside the action and
Folo checkouts. The workspace is virtual: its benchmark belongs to a non-root member,
because the companion's package-ownership library excludes workspace-root packages. The root
still owns the benchmark-history configuration. Its small benchmark entry point
delegates to the manifest-pinned faker, producing deterministic engine output without
wall-clock measurements. Fixed Git dates keep fixture commit identities stable
across workflow attempts; analysis explicitly includes that synthetic history.
No canary posts issues or comments. The fixture has a working synthetic benchmark
at both commits, with generated build output Git-ignored so historical worktrees
store clean observations. Ordinary collection stores the tip, then the canary
reuses that root invocation's installed main executable from its bootstrap state file to
backfill the older commit on the same runner. No additional root action or tool
installation is needed for backfill. The existing faker supplies deterministic
measurements; Cargo remains offline.

The probe decompresses local gzip objects and inspects JSON commit identities,
clean status, nonempty results and machine-key provenance. It requires exactly
the expected commits and preserves
the tip's original object hash. Repeating backfill with a valid but nonexistent
benchmark target must succeed while every stored file and hash stays unchanged,
proving resumption skips execution as well as writes. Analysis then requires
parseable reports about the tip, a nonempty series census and an honest
insufficient-baseline outcome for this short history. Published-method canaries
copy the root action's exact `collection-file` bytes into the selected platform
directory and analyze with `current-collections`, not machine-key selection.

The source canary separates collection and analysis jobs so `prepare-analysis`
can inspect real completed GitHub jobs. Each independent platform smoke pair uses
a distinct project identity in both its fixture configuration and the companion's
canonical job marker. Its analysis therefore selects only its own platform without
classifying another smoke pair's jobs as unexpected platforms. Each collection job
runs the normal backfill probe and records a self-contained
receipt using its already-installed companion. Immutable receipt artifacts retain
all platform attempts. Analysis downloads the authenticated run-wide receipts and
uses the production workflow adapter to reconcile them before root-action analysis.
Both jobs use the same pinned Folo source revision.

A separate per-platform archive transports only the synthetic Git checkout, local
baseline store and collection output metadata. That supporting fixture is replaced
when its platform is rerun; untouched platforms retain theirs. It carries no
installed binaries or build outputs and cannot replace the current values embedded
in the selected receipt. This transport is canary-only: reusable workflows continue
to read their configured shared history and upload only collection receipts.

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

Each canary permits one upload-only retry through the same official action, avoiding
another installation for a transient artifact-service failure while bounding repeated
failures. The retry uses a distinct artifact name because a failed finalization may
leave the original name occupied. Only the initial upload permits `continue-on-error`;
a final assertion requires a successful step outcome and emits a warning for recovery.
Upload attempts and the assertion retain the same successful-analysis, policy-skip
and cancellation guards, independently of earlier report-assertion failures.
The retry applies to any upload failure, preserves missing-file errors and does not
change the required installation gate or consumer workflows. Artifact-service
failures are tracked in [issue #2](https://github.com/folo-rs/cargo-bench-history-action/issues/2);
selective upstream retry handling is tracked in
[actions/toolkit#2452](https://github.com/actions/toolkit/pull/2452).

### Version readiness and reconciliation

Release-bearing paths are `action.yml`/`action.yaml`, `release.json`, scripts,
private actions and workflow definitions. The CI-only exemptions are `scripts/Release.psm1`,
`scripts/Publish-Release.ps1`, `scripts/Install-Canary.ps1` and the `test.yml`,
`install-tools.yml`, `release.yml` workflows. New scripts and consumer reusable
workflows are release-bearing by default. Documentation, tests and the canary
source revision do not require a version increment. Git tree identity includes
file modes, content and path names; readiness compares the release baseline and any
existing immutable version tag. Feature pushes, PRs (including stacked PRs) and manual
validation compare with the fetched `main` tip, so repeated feature commits retain a
sufficient pending increment. A push to `main` uses its previous tip; merge-group validation
uses the group's recorded base.

The content-write job is serialized after the shared availability workflow, with
read-only permissions everywhere else. It refreshes tags inside the publication
queue, preserves an existing equivalent version tag's original commit, creates
missing releases using verified tags and prefixed generated notes, and advances
the major tag only to a newer semantic version. A force-with-lease protects the
major ref against out-of-band changes. Failed intermediate operations remain
visible; retries reconcile the missing operations instead of moving immutable tags.
The GitHub token is the only publication credential. No repository settings are
changed by this automation.
