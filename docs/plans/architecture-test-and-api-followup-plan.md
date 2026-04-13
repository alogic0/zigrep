# Architecture Test And API Follow-up Plan

This plan captures the next architecture targets after the root-surface and
search-stack cleanup work. The goal is to reduce the remaining boundary
pressure from tests and tooling, then make the app-facing API surface more
deliberate.

## Goal

Improve the architecture further by:

- reducing test dependence on broad root exports such as `search_runner` and
  `search_reporting`
- deciding whether the search execution surface should be treated as a stable
  public API or as an internal implementation detail
- separating bench-specific boundary needs from the app-facing root surface
- reviewing the remaining exported modules in `src/root.zig` as intentional API
  instead of convenience access

## Current Follow-up Issues

The main issues to address are:

- tests still rely on `zigrep.search_runner` and `zigrep.search_reporting`,
  which keeps pressure on the root surface
- the bench target still influences which execution entrypoints are convenient
  to export
- `src/root.zig` still exports a mixed surface of regex, search, command, CLI,
  and config modules without an explicit API policy
- the codebase is cleaner internally than the current public surface makes
  obvious

## Phase 1: Test Surface Audit

- [x] inspect which tests still depend on `zigrep.search_runner`
- [x] inspect which tests still depend on `zigrep.search_reporting`
- [x] separate cases that are true app-surface tests from cases that are only
  using those exports because of test wiring convenience
- [x] identify the narrowest low-risk cleanup opportunities

Phase 1 audit result:

- the remaining direct test users are:
  - `src/search_runner_tests.zig`
  - `src/cli_tail_tests.zig`
- `src/search_runner_tests.zig` is mostly a true owner-surface test for
  `search_runner` and `search_reporting`, not just convenience-only wiring
- `src/cli_tail_tests.zig` is mixed:
  - the CLI end-to-end cases are true app-surface tests
  - the direct reporting and runner helper cases are more convenience-oriented
- the narrowest low-risk cleanup opportunity is in `src/cli_tail_tests.zig`,
  not in `src/search_runner_tests.zig`

## Phase 2: Test Boundary Cleanup

- [x] review the narrow convenience-only cleanup in `src/cli_tail_tests.zig`
- [x] keep true app-surface tests on the app-facing imports
- [x] avoid reintroducing module-duplication problems just to force a narrower
  import style
- [x] decide not to narrow the remaining `search_reporting` test import in this
  plan, because direct file import reintroduces the executable-test
  module-duplication error

Phase 2 result:

- no low-risk test import cleanup remains in this area today
- `src/search_runner_tests.zig` remains a real owner-surface test
- `src/cli_tail_tests.zig` keeps the remaining `zigrep.search_reporting` use
  because the direct-file alternative regresses the build graph

## Phase 3: Search API Decision

- [x] decide whether `search_runner` is intended to be a stable public entrypoint
- [x] treat `search_runner.runSearch(...)` as the intentional app-facing search
  execution entrypoint for now
- [x] document that API boundary explicitly
- [x] decide not to add another wrapper because the current call surface is
  already narrow and additional indirection would not improve ownership

Phase 3 result:

- `search_runner.runSearch(...)` is the current deliberate app-facing search
  execution entrypoint
- the known direct callers are narrow:
  - `src/bench.zig`
  - `src/search_runner_tests.zig`
- no narrower wrapper is justified in this plan

## Phase 4: Bench And Tooling Boundary Review

- [x] inspect which root exports are still justified mainly by bench or tooling
- [x] decide whether bench should depend on a narrower internal execution
  entrypoint
- [x] decide not to add a narrower bench-only execution entrypoint in this
  plan, because bench intentionally measures the current app-facing
  `search_runner.runSearch(...)` path for output-oriented cases
- [x] document the remaining deliberate exceptions explicitly

Phase 4 result:

- `src/bench.zig` intentionally uses:
  - `zigrep.search_runner.runSearch(...)` for output-path measurement
  - `zigrep.search` and `zigrep.regex` for lower-level engine and corpus cases
- no small, low-risk export cleanup is justified here
- the remaining root-surface pressure from bench is deliberate, not accidental

## Phase 5: Root API Review

- [x] review the remaining exported modules in `src/root.zig`:
  - `regex`
  - `search`
  - `search_runner`
  - `search_reporting`
  - `command`
  - `cli`
  - `config`
- [x] decide which are intentional library surface and which are only current
  app/tooling conveniences
- [x] document the intended root API policy

Phase 5 result:

- intentional root API surface:
  - `regex`
  - `search`
  - `search_runner`
  - `search_reporting`
  - `command`
  - `cli`
  - `config`
  - `app_version`
- current intended meaning:
  - `regex` and `search` are low-level library-facing surfaces
  - `search_runner.runSearch(...)` is the app-facing search execution entrypoint
  - `search_reporting` remains exposed for the current runner/report test and
    tooling surface
  - `command`, `cli`, and `config` are app-facing support modules rather than
    generic stable library abstractions
- no further narrowing is justified in this plan without a broader product-level
  API decision

## Validation

- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Outcome

- the remaining test and bench pressure on the root surface is now explicit
- `search_runner.runSearch(...)` is treated as the deliberate app-facing search
  execution entrypoint
- `search_reporting` remains an unstable compatibility/tooling surface
- no further narrowing is justified in this plan without a broader product-level
  API change or a build-graph change

## Recommended Order

- [x] 1. Audit the current test dependence on root exports
- [x] 2. Remove the low-risk convenience-only test dependencies
- [x] 3. Decide whether `search_runner` is a public API or an internal surface
- [x] 4. Review bench/tooling-driven export pressure
- [x] 5. Document the intended root API policy

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- search behavior changes
- output format changes
- performance work unrelated to module boundaries
