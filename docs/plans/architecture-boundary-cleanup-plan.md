# Architecture Boundary Cleanup Plan

This plan captures the next architecture-focused cleanup after the recent CLI
and regex-surface work. The goal is not feature expansion. The goal is to make
the module boundaries honest, reduce accidental coupling, and make future
changes safer.

## Goal

Improve the application architecture by:

- separating CLI-facing command types from execution internals
- reducing the accidental utility surface of `src/main.zig`
- narrowing the responsibility of `src/search_runner.zig`
- fixing misleading public API boundaries

## Current Architectural Issues

The main issues to address are:

- the public `compile(...)` entrypoint in `src/root.zig` accepts
  `CompileOptions` but currently ignores them
- `src/cli.zig` depends on CLI-facing types that are still defined inside
  `src/search_runner.zig`
- `src/main.zig` still carries test-facing wrappers and pass-through helpers
  instead of being pure process bootstrap
- `src/search_runner.zig` still combines too many concerns in one module:
  command execution, traversal, ignore loading, scheduling, reporting,
  multiline output, JSON output, and stats

## Phase 1: Shared Command Model

- [x] Create a shared command-model module, for example `src/command.zig`
- [x] Move the CLI-facing types there:
  - `CliOptions`
  - `OutputOptions`
  - `OutputFormat`
  - `BinaryMode`
  - `ReportMode`
- [x] Update `src/cli.zig` to parse into the shared command model
- [x] Update `src/search_runner.zig` to execute the shared command model
- [x] Keep the public behavior unchanged

## Phase 2: Main Entrypoint Cleanup

- [ ] Remove the remaining pass-through helper surface from `src/main.zig`
- [ ] Move test wrappers out of `src/main.zig`
- [ ] Update tests to import the real owning modules directly where practical:
  - `src/cli.zig`
  - `src/search_runner.zig`
  - `src/cli_test_support.zig`
- [ ] Keep `src/main.zig` focused on:
  - process setup
  - stdio wiring
  - process exit behavior

## Phase 3: Search Runner Split

- [ ] Split `src/search_runner.zig` by responsibility
- [ ] First extract output/report formatting into a dedicated module
- [ ] Then extract ignore-loading and filtering helpers into a dedicated module
- [ ] Keep execution orchestration in the runner layer
- [ ] Preserve current end-to-end behavior and benchmark smoke coverage

## Phase 4: Public API Boundary Fixes

- [ ] Decide whether `src/root.zig` should expose a real option-carrying
  `compile(...)` API
- [ ] If yes, thread `CompileOptions` through for real
- [ ] If not, remove the misleading unused option parameter from the public
  entrypoint
- [ ] Re-check any other public aliases in `src/root.zig` for accidental
  coupling

## Validation

- [x] Keep current CLI behavior and test expectations stable
- [x] Run:
  - `zig build test`
  - `zig build bench-smoke`

## Recommended Order

- [x] 1. Extract the shared command model
- [ ] 2. Move test wrappers out of `src/main.zig`
- [ ] 3. Split `src/search_runner.zig` by responsibility
- [ ] 4. Fix the public compile boundary in `src/root.zig`

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- CRLF-aware regex semantics
- replacement/output feature expansion
