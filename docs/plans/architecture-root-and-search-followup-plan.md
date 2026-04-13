# Architecture Root And Search Follow-up Plan

This plan captures the next architecture targets after the recent CLI and
search-stack decomposition work. The goal is to finish the remaining root
surface compromises and then decide whether the search execution surface needs a
smaller internal facade.

## Goal

Improve the architecture further by:

- removing the remaining `cli_dispatch` root export
- deciding whether the current search execution modules need a smaller internal
  facade
- deciding whether sequential and parallel execution ownership should live under
  one execution layer
- reducing the remaining test/build coupling that still pushes internal modules
  toward the root surface

## Current Follow-up Issues

The main issues to address are:

- the search stack is decomposed, but internal callers still need to know
  several modules directly
- `src/search_runner.zig` still owns the sequential execution path while
  `src/search_parallel.zig` owns the parallel path
- build and test wiring still influences which internal modules are convenient
  to expose from the app root

## Phase 1: Remove The Remaining CLI Root Exception

- [x] inspect why `cli_entry` still needs `cli_dispatch` through `zigrep`
- [x] choose the smallest build-graph fix that lets `cli_entry` depend on
  `cli_dispatch` without re-exporting it from `src/root.zig`
- [x] remove `cli_dispatch` from `src/root.zig`
- [x] update CLI entrypoints and tests to use the new wiring directly
- [x] keep CLI behavior unchanged

## Phase 2: Search Surface Review

- [x] review the current search module call graph:
  - `src/search_runner.zig`
  - `src/search_path_runner.zig`
  - `src/search_parallel.zig`
  - `src/search_entry_runner.zig`
  - `src/search_reporting.zig`
  - `src/search_result.zig`
- [x] decide whether the current module set is already the right boundary
- [x] decide not to add another facade layer, because the current modules are
  already narrow and a new wrapper would mostly add indirection without
  reducing coupling materially

## Phase 3: Execution Ownership Decision

- [x] decide whether sequential execution should stay in
  `src/search_runner.zig`
- [x] decide whether sequential and parallel execution belong together under one
  execution layer
- [x] keep the current split, because `src/search_runner.zig` is the top-level
  coordinator and the sequential path is now small enough to fit there without
  competing with the parallel worker implementation in `src/search_parallel.zig`

## Phase 4: Build And Test Coupling Review

- [ ] review which remaining imports are shaped by build/test wiring instead of
  ownership
- [ ] remove convenience-only wiring where the fix is narrow and low-risk
- [ ] document any remaining deliberate exceptions instead of leaving them
  implicit

## Validation

- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [x] 1. Remove the remaining `cli_dispatch` root export
- [x] 2. Review whether the search stack needs a smaller internal facade
- [x] 3. Decide sequential versus parallel execution ownership
- [ ] 4. Clean up the remaining build/test-driven boundary compromises

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- search behavior changes
- output format changes
- performance tuning unrelated to architectural boundaries
