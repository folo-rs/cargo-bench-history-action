# Working in this repository

- Read `docs/design.md` and `docs/implementation.md` before changing behavior or ownership.
- Keep benchmark, report and lifecycle decisions in the pinned Rust companion in
  `folo-rs/folo`; PowerShell owns installation and GitHub release-process orchestration.
- Read versions and supported release targets from `release.json`; do not duplicate tool pins.
- Keep real installation checks separate from mocked installer tests. Never satisfy
  published-binary availability with a source checkout, cache hit or source fallback.
- Use PowerShell 7.6 or later, explicit native exit handling and argument arrays.
- Do not publish tags/releases or merge pull requests while developing or testing.
- Preserve immutable version tags and prevent older release runs from moving a major tag back.
- Keep `.github/monorepo-revision` pinned to the source commit used by path-mode canaries.
- Prefix agent-authored GitHub bodies with `[Copilot speaking]`.
