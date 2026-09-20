# Benchmark-history action

Public history and PR workflows own the collection matrix, evidence handoff,
analysis, artifacts and publication. Consumers choose triggers and supply their
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
current version. Publication may reconcile a missing release or major ref on retry,
but unchanged release-bearing content never relocates the immutable version tag.

Monorepo tool changes have a cross-linked action PR. The monorepo publishes first;
the action PR then passes its installation gate before merging. Publication in the
other repository does not automatically rerun a failed action check.
