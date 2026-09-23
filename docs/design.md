# Benchmark-history action

Public `history.yml`, `pr.yml` and `backfill.yml` workflows own benchmark execution.
History and PR own the collection matrix, evidence handoff, analysis, artifacts and
publication; backfill owns a frozen historical range and its collection matrix.
Consumers choose triggers and supply their
Azure identifiers; the default interface does not require a manual package list.
History measures the workspace, while PR preparation selects affected benchmark
packages and dependents before applying exclusions. There is no separate consumer
scope selector.

The root composite action exposes the same stages for custom job graphs. Those
advanced callers own checkout, benchmark prerequisites, dependencies, concurrency
and artifact upload/download.

## Commands and evidence

`command` selects collection, backfill, history or PR analysis, a
`publish-<comment|issue>-<state>` operation, or a one-off failure alert.
The command values are `collect`, `backfill`, `analyze-history`, `analyze-pr`,
`alert`, and `publish-comment-` or `publish-issue-` followed by `findings`, `clean`,
`preflight`, `inconclusive` or `failed`.
Analysis writes reports but never posts them. Publication consumes the summary and
JSON from the same successful analysis and validates the expected/completed platforms.
Findings remain advisory; execution failures fail the step.

Inputs inapplicable to the selected command are errors. `working-directory` selects
the measured/configuration checkout and defaults to the caller's working directory.
It is distinct from `source-path`, which supplies the Folo checkout used to build tools.
This permits separate automation, measurement and local test-fixture directories.
Known optional inputs with empty values receive command-specific defaults from the
runtime, not defaults shared between unrelated commands. Unknown input names are
rejected even when their values are empty.

Analysis receives explicit expected/completed platform evidence so it can emit
`partial-platform-coverage` without inventing coverage from machine keys. The keys
select comparable data; they are not provenance identifiers.
The `machine-keys` input selects a directory of collection key files, found
recursively as `<platform>/machine-key.txt`. Callers aggregate only the selected
successful collections into that directory; platform coverage remains explicit
and separate.

The internal report namespace follows the core's canonical storage project identity.
It has no consumer override. Source/configuration inputs and process arguments remain
data, not interpolated shell programs.

## Shared workflow behavior

The workflow owns its collect matrix; a caller matrix is not required. Each
successful collection supplies a receipt bound to its run, attempt, frozen commit,
platform and actual hardware key. Analysis selects the latest completed attempt
for each expected platform. A failed retry cannot reuse older success; an untouched
successful leg remains eligible. No successful collection is an execution failure,
not an empty-scope verdict.

Supported collection runners are x64 Linux, x64 Windows and Apple Silicon macOS,
with Linux and Windows selected by default. Callers can include `macos-latest`
through `platforms` when their benchmarks support it. The release manifest defines
the supported native targets; each participates in real source and published-tool
installation checks. Folo's own performance-collection policy is separate from the
platforms supported by the reusable workflows.

Partial collection can produce a qualified report while failed jobs remain visible.
Analysis, report upload and publication share a job so the publication consumes
the matching summary/JSON and upload URL. Publication forwards the companion's
checked disposition without deriving it from convenience flags.

An empty selected scope is distinct from the root collector's empty package
selection, which means the workspace. The empty-scope branch performs no analysis.
Closed PR events supersede older work but start no collection. Terminal updates
retain exact run/attempt/head ownership across partial reruns.

The optional benchmark setup action has one fixed caller-owned location:
`.github/actions/bench-history-setup/action.yml`. There are no setup-reference,
tool-version or publication-wording overrides. `publish: false` suppresses report,
lifecycle and alert writes without suppressing analysis or report artifacts.

The shared workflows use the selected workflow commit's own root action and
internal adapter, independently of the caller checkout. Runtime files and
measurement checkouts are separate from invocation configuration and tool sources.

### Historical backfill

Backfill callers provide either explicit `from` and `to` refs together, or a
rolling window through `lookback` and `minimum-age` together. There is no mode
selector. Rolling windows permit an optional `to` override and no `from`;
explicit ranges do not accept rolling-window inputs. The companion validates
these combinations and freezes the selected endpoints to full commit SHAs.

Window inputs are duration magnitudes in Jiff's friendly or ISO span notation,
including friendly `ago` notation, not absolute dates. `lookback` must be nonzero;
`minimum-age` may be zero. The companion uses one clock snapshot and UTC calendar
arithmetic. Without an override, `to` is the first eligible commit on the frozen
invocation head's first-parent history at or before the minimum-age cutoff.
The oldest first-parent commit in the now-relative lookback window reachable
from `to` becomes `from`; when none lies in that window, `from` equals `to`.
An explicit `to` override is resolved first and bypasses automatic endpoint age
selection. Callers need no date arithmetic, Git queries or preparation jobs.

When no automatic endpoint is old enough, preparation explicitly reports no
work and starts no backfill matrix. This is distinct from a fork-policy skip and
from the absence of benchmarks at the invocation head.
Preparation uses the real calling event head; execution
uses the frozen range tip with full history. Configuration, the fixed setup hook
and source-built tools belong to the invocation checkout, not a historical commit.
The main tool owns first-parent range validation and traversal.

Each historical commit supplies its own workspace benchmark inventory. There is
no current-head scope detection, empty-scope skip, public package list or scope
selector. The common exclusions and benchmark/feature options apply to historical
collection. Existing measurements are always skipped for resumable reruns.

Optional `max-commits` is a positive integer string accepted only for backfill.
Omission or an empty value means unlimited replay. Each platform independently
counts actual replay attempts, newest missing commit first, after skipping
already-recorded commits in its current target/machine partition. Existing
measurements anywhere in the range are skipped, not deferred.
Empty results, ignored failures and duplicates
detected at write time still consume an attempt; only precheck skips are free.
After the final allowed attempt completes normal storage and cleanup, execution
stops successfully without starting another attempt. The CLI reports stored,
skipped, failed and deferred work and the stop reason. The limit does not change
error policy.

Every invocation queues without cancellation or replacement. Canonical project and
platform queues also serialize callers using different configuration paths for the
same project. Each platform retains the hosted six-hour ceiling as an exceptional
watchdog and does not cancel other matrix legs on failure. A commit budget is not
a deadline; even a single attempt can exceed that ceiling.
`ignore-errors` defaults to false and controls the core's per-commit
build/benchmark failure policy, not infrastructure failures. The workflow does
not suppress job failures or hosted timeout cancellations.

Backfill uses history's same-repository/open-event work selection and excludes
`pull_request_target`. It produces no receipts, analysis, reports, publication or
public workflow outputs.

### Measurement compiler flags

The root action's `collect` and `backfill` commands and the public reusable workflows
accept optional `rustflags`, defaulting to empty. This is additional rustc
configuration for measurements, not a setup or installation option. Workflows
forward it only to measurement commands.

The companion appends these arguments to the effective ambient compiler flags,
using Cargo's `RUSTFLAGS` whitespace splitting rather than shell parsing.
Ambient `CARGO_ENCODED_RUSTFLAGS`, when present, takes precedence over `RUSTFLAGS`;
existing encoded argument boundaries and unrelated options are preserved.
Composition is child-only for collection, backfill and the collection machine-key
query. Empty input leaves the environment unchanged. PowerShell forwards the
input as data and performs no flag splitting, replacement or calculation.

## Installation

`release.json` defines the action version, exact monorepo tool pins and supported
release targets. `binstall` is the default and permits source fallback in ordinary
consumer runs; `install` builds the exact published versions. `path` builds the
selected Folo checkout and does not restore a released-binary cache. Source
versions come from that checkout's Cargo metadata and need not match the published
pins; the selected source must implement the action's runtime contract.

Every command uses the companion's action execution boundary. Collection, backfill
and analysis additionally use the main tool. Test-only tools are installed only by
the action's canaries, never by a consumer invocation.

The installation method applies to every required binary. Cached installations are
accepted only when their Cargo installation records and executable files match the
requested pins. Availability checks use fresh roots and bypass the cache.

## Publication and credentials

The companion owns GitHub reporting, freshness and run-attempt ownership.
It uses the caller's short-lived GitHub token; Azure authentication remains in the
main tool. Fork-origin PR work is skipped explicitly as work selection.
No stored credential, token input, alternate publisher or automatic alert resolution
is introduced.

For ordinary fork PRs under GitHub defaults, the platform removes effective
`id-token` capability after YAML evaluation. Workflow approval does not elevate
that permission. This server-enforced restriction, not an editable `if`, is the
default storage authorization barrier. The production and separate test identities
retain their selected-branch and ordinary-PR federation contexts.

Notification depends on obtaining the companion. An installation failure leaves the
workflow failed and can prevent an issue alert; there is no independent fallback.

## Releases

The required `install-tools` check installs the exact registry packages and their
promised prebuilt archives for every supported target. Neither `path`, a cache hit
nor source fallback establishes availability. It runs on PRs and merge candidates.

Merge to `main` triggers the same availability gate before release publication.
Version tags are immutable. Retries reconcile partial publication; a later commit
with unchanged release-bearing content does not relocate an existing version tag.
Older release runs cannot move the floating major tag backwards.

Changes to distributed runtime, consumer reusable workflows or manifest pins require
a newer action version. Documentation, tests and CI-only maintenance can retain the
current version. Incompatible public action or workflow input changes require a
new major version; compatible feature additions use a minor version.
Publication may reconcile a missing release or major ref on retry, but unchanged
release-bearing content never relocates the immutable version tag.

Monorepo tool changes have a cross-linked action PR. The monorepo publishes first;
the action PR then passes its installation gate before merging. Publication in the
other repository does not automatically rerun a failed action check.
