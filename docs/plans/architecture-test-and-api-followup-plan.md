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

- [ ] decide whether `search_runner` is intended to be a stable public entrypoint
- [ ] if yes, document that API boundary explicitly
- [ ] if no, define the narrower app-facing wrapper that should exist instead
- [ ] do not move code unless the new ownership model is clearly better than
  the current one

## Phase 4: Bench And Tooling Boundary Review

- [ ] inspect which root exports are still justified mainly by bench or tooling
- [ ] decide whether bench should depend on a narrower internal execution
  entrypoint
- [ ] remove convenience-only exports if there is a small, low-risk wiring fix
- [ ] otherwise document the remaining deliberate exceptions explicitly

## Phase 5: Root API Review

- [ ] review the remaining exported modules in `src/root.zig`:
  - `regex`
  - `search`
  - `search_runner`
  - `search_reporting`
  - `command`
  - `cli`
  - `config`
- [ ] decide which are intentional library surface and which are only current
  app/tooling conveniences
- [ ] document the intended root API policy

## Validation

- [ ] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [ ] 1. Audit the current test dependence on root exports
- [ ] 2. Remove the low-risk convenience-only test dependencies
- [ ] 3. Decide whether `search_runner` is a public API or an internal surface
- [ ] 4. Review bench/tooling-driven export pressure
- [ ] 5. Document the intended root API policy

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- search behavior changes
- output format changes
- performance work unrelated to module boundaries
