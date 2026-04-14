# Architecture Reporting And Options Cleanup Plan

This plan captures the next architecture cleanup after the recent ripgrep
parity work. The goal is not feature expansion. The goal is to restore cleaner
boundaries around reporting, stats aggregation, and command shaping before
more output and parity work accumulates on the current structure.

## Goal

Improve the architecture by:

- removing reporting-output re-parsing from search orchestration
- splitting the oversized command/options model into narrower internal groups
- centralizing output-policy decisions in one layer
- shrinking the responsibility of the current reporting stack without changing
  regex semantics

## Current Architectural Issues

The main issues to address are:

- `src/search_runner.zig` currently re-parses emitted JSON bytes to recover
  `matched_lines` and `matches` for top-level summary aggregation
- `src/command.zig` carries one broad `CliOptions` struct that mixes traversal,
  matcher configuration, output policy, parse leftovers, and runtime knobs
- output-policy decisions are split across multiple layers:
  - `src/search_runner.zig`
  - `src/search_reporting.zig`
  - `src/search_output.zig`
- `src/search_reporting.zig` now owns too many report families in one file:
  - normal line output
  - context output
  - replacement output
  - multiline output
  - invert-match output
  - count and path-only output
  - JSON branching

## Design Guardrails

- Keep this cleanup strictly out of the regex parser, compiler, and VM.
- Reporting must consume match results from the current search engine; it must
  not redefine match semantics.
- Avoid broad rewrites. Prefer small boundary-improving extractions that keep
  behavior stable.
- Preserve the current CLI surface and output behavior while changing internal
  ownership.

## Phase 1: Stop Deriving Stats From Emitted Output

- [x] Introduce a small reporting result type for line-oriented and file-level
  reporting, for example:
  - `matched`
  - `printed_bytes`
  - `matched_lines`
  - `matches`
- [x] Make reporting return those counters directly instead of forcing
  `src/search_runner.zig` to inspect serialized JSON bytes.
- [x] Keep JSON serialization a pure sink for already-known report data.
- [x] Remove the JSON-specific output scraping logic from
  `src/search_runner.zig`.

### Phase 1 Guidance

- Keep the reporting result type internal to the search/report stack.
- Do not make the regex engine aware of report counters just to support this.
- Prefer one shared result shape used by both sequential and parallel paths.

## Phase 2: Split Internal Command Options By Responsibility

- [x] Keep the CLI-facing parse result stable, but introduce narrower internal
  groupings for execution:
  - traversal options
  - matcher options
  - report/output options
  - parse-hint flags such as explicit filename/line/column visibility
- [x] Reduce the number of modules that need to depend on the full
  `CliOptions` surface.
- [x] Keep the public command model stable unless a stronger API reason
  appears.

### Phase 2 Guidance

- This is an internal shaping cleanup first, not a public API redesign.
- Prefer additive internal views or grouped sub-structs over immediately
  deleting the existing top-level type.
- Avoid spreading parse-hint state deeper into execution modules than
  necessary.

## Phase 3: Centralize Output Policy

- [x] Create one internal output-policy layer that owns decisions such as:
  - explicit single-file defaults
  - JSON fallback behavior for non-line modes
  - raw binary text display policy
  - filename/line/column default interactions
- [x] Make `src/search_runner.zig` stop carrying output-policy branches that
  are really reporting decisions.
- [x] Keep `src/search_output.zig` focused on serialization and formatting, not
  policy selection.

### Phase 3 Guidance

- Distinguish policy from rendering:
  - policy decides what shape to emit
  - rendering serializes that shape
- Avoid duplicating the same policy rules in both stdin and file-path flows.
- Keep this layer below CLI parsing and above byte-writing helpers.

## Phase 4: Split Reporting By Report Family

- [x] Decompose `src/search_reporting.zig` into smaller modules by behavior
  family, for example:
  - line reporting
  - context reporting
  - replacement reporting
  - multiline reporting
  - JSON/event-specific helpers
- [x] Extract the count, path-only, and binary-match report family into a
  dedicated helper module without changing the public reporting facade.
- [x] Extract multiline reporting and multiline JSON helpers into a dedicated
  helper module without changing the public reporting facade.
- [x] Keep one small coordinating facade if needed, but move large mode-specific
  branches out of the current monolithic file.
- [x] Preserve the current end-to-end output behavior and tests.

### Phase 4 Guidance

- Split by ownership, not by arbitrary line count.
- Do not create a deep abstraction tree if a flat module split is enough.
- Keep shared helper types close to the smallest common owner.

## Phase 5: Re-check Root And Test Pressure After Cleanup

- [ ] Re-review whether the current root exports still match intentional API
  boundaries after the reporting cleanup.
- [ ] Re-check whether tests still need direct access to unstable reporting
  internals or can depend on narrower owners.
- [ ] Document any remaining deliberate exceptions instead of leaving them as
  accidental convenience imports.

## Validation

- [ ] Keep current CLI behavior unchanged
- [ ] Keep current regex behavior unchanged
- [ ] Run:
  - [x] `zig build test`
  - [x] `zig build bench-smoke`
- [ ] Re-run the practical parity checks that recently exercised:
  - `--json`
  - `--text`
  - `--binary`
  - `--only-matching`
  - `--replace`

## Recommended Order

- [x] 1. Remove output-derived stats aggregation
- [x] 2. Introduce narrower internal option groupings
- [x] 3. Centralize output-policy decisions
- [x] 4. Split reporting by report family
- [ ] 5. Re-check root and test boundary pressure

## Explicit Non-Goals

This plan does not include:

- new regex features
- new CLI flags
- changing match semantics to satisfy JSON parity
- broad public API redesign
- performance tuning unrelated to boundary cleanup
