# Architecture Next Cleanup Plan

This plan captures the next architecture-focused cleanup after the boundary
cleanup plan. The goal is not new features. The goal is to keep shrinking the
remaining oversized modules and make the public surface more deliberate.

## Goal

Improve the architecture further by:

- moving file-execution policy out of `src/search_runner.zig`
- decomposing the monolithic CLI argument parser in `src/cli.zig`
- narrowing the top-level export surface in `src/root.zig`

## Current Follow-up Issues

The main issues to address are:

- `src/search_runner.zig` still owns file-processing policy such as binary
  handling, warning classification, and preprocess/decompression decisions
- `src/cli.zig` still uses one long `parseArgs(...)` function for tokenization,
  validation, and final command assembly
- `src/root.zig` still re-exports a broad mixed surface of app modules and
  regex internals

## Phase 1: Search Execution Policy Split

- [x] Extract file-execution policy into a dedicated module, for example
  `src/search_execution.zig`
- [x] Move warning classification and warning message helpers there
- [x] Move preprocess/decompression and binary-decision helpers there
- [x] Update `src/search_runner.zig` to depend on the new module
- [x] Keep current search behavior unchanged

## Phase 2: CLI Parse Decomposition

- [ ] Split `parseArgs(...)` into smaller helpers
- [ ] Separate scalar flag parsing from value-taking flag parsing
- [ ] Separate post-parse validation from final `CliOptions` assembly
- [ ] Keep current CLI syntax and error behavior unchanged

## Phase 3: Root Surface Narrowing

- [ ] Decide which regex internals should remain re-exported from `src/root.zig`
- [ ] Remove re-exports that are convenience-only and not part of the intended
  app-facing surface
- [ ] Keep the public entrypoints used by bench, tests, and the app stable

## Validation

- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [x] 1. Split search execution policy out of `src/search_runner.zig`
- [ ] 2. Decompose `src/cli.zig` argument parsing
- [ ] 3. Narrow `src/root.zig` exports

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- output format changes
- execution-model changes such as CRLF-aware regex semantics
