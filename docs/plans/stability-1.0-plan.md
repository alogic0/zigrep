# Stability 1.0 Plan

This plan defines what `zigrep` must stabilize before a `1.0.0` release.

The goal is not to add more surface area. The goal is to make the existing
surface explicit, testable, and sustainable under semver.

## Phase 1: Freeze The Public Surface

- classify the current exported root surface into:
  - stable public API
  - app-facing stable support API
  - unstable/internal compatibility surface
- make that classification explicit in the docs
- confirm which modules and entrypoints are part of the `1.0.0` promise
- identify any exports that should be removed or marked unstable before `1.0.0`

Required outcome:

- a short, explicit list of stable surfaces for `1.0.0`

Current expected stable candidates:

- library-facing:
  - `zigrep.regex`
  - `zigrep.search`
- app-facing:
  - `zigrep.search_runner.runSearch(...)`
  - `zigrep.cli`
  - `zigrep.config`
  - `zigrep.command`
  - `zigrep.app_version`

Current expected unstable surface:

- `zigrep.search_reporting`

## Phase 2: Freeze The Regex Behavior Contract

- define the regex behavior that is considered part of the public contract
- align docs and tests around that contract
- explicitly record supported semantics for:
  - Unicode shorthand and boundaries
  - Unicode properties
  - ignore-case and smart-case behavior
  - multiline behavior
  - inline flag support
  - class-set support
- explicitly record non-goals and unsupported syntax

Required outcome:

- documented regex semantics that can be treated as stable from `1.0.0`

## Phase 3: Freeze Library Usage Expectations

- review whether `zigrep.regex.compileRe(...)` is sufficient as the main
  ergonomic embedding API
- ensure the recommended library usage path is documented and covered by tests
- make sure examples compile and reflect the intended public surface
- avoid exposing internal engine details as the first recommended API

Required outcome:

- one clear recommended library usage path for `1.0.0`

## Phase 4: Define Breaking-Change Policy

- define what counts as a breaking change after `1.0.0`
- include at least:
  - public API signature changes
  - removal or reclassification of stable exports
  - changes to documented regex semantics
  - changes to capture result shape
  - changes to documented CLI behavior for stable flags and modes
- define what can still change without a major version:
  - internal module structure
  - unstable/tooling-only surfaces
  - undocumented behavior

Required outcome:

- a short semver policy doc or release policy section

## Phase 5: Stabilization Pass

- prioritize regression coverage over feature expansion
- audit docs for consistency with actual behavior
- verify public examples
- run the standard verification targets:
  - `zig build test`
  - `zig build bench-smoke`
- collect any last pre-1.0 cleanups that are truly required for stability

Required outcome:

- a release candidate state with no known documentation/behavior mismatch on the
  promised public surface

## Release Criteria For 1.0.0

`1.0.0` is ready only when:

- the stable public surface is explicitly listed
- unstable surfaces are explicitly marked
- the regex behavior contract is documented
- the recommended library usage path is documented and verified
- semver expectations are written down
- tests and smoke benchmarks are green
- there is no known required pre-1.0 architecture refactor left

## Explicit Non-Goals

- adding new regex surface only to chase parity
- widening the public API without a clear stability reason
- promising internal modules as stable just because they are currently exported
- treating undocumented behavior as part of the `1.0.0` contract

## Recommended Order

- [ ] 1. freeze the stable and unstable public surfaces
- [ ] 2. freeze the regex behavior contract
- [ ] 3. freeze the recommended library usage path
- [ ] 4. define the breaking-change and semver policy
- [ ] 5. run a stabilization pass and decide whether `1.0.0` is justified
