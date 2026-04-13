# Architecture Overview

`zigrep` is now split into a small set of focused layers instead of one large CLI and one large search runner.

## CLI stack

- `src/cli.zig`
  - argument parsing
  - parse-time validation
  - usage text
- `src/cli_dispatch.zig`
  - execution of parsed command variants
  - currently `run` and `type_list`
- `src/cli_entry.zig`
  - top-level CLI entry orchestration
  - config resolution
  - help/version handling
  - fatal usage-error formatting

## Search stack

- `src/search_runner.zig`
  - top-level search coordination across input paths
  - sequential entry loop
  - stats emission
- `src/search_path_runner.zig`
  - path-level traversal, ignore loading, filtering, and schedule selection
- `src/search_parallel.zig`
  - worker-pool execution and parallel result aggregation
- `src/search_entry_runner.zig`
  - per-file execution
  - binary detection, reads, preprocessing, and report generation entry
- `src/search_reporting.zig`
  - line, multiline, context, count, path-only, and match-report output logic
- `src/search_result.zig`
  - shared `SearchStats` and `SearchResult` types

## Public root

`src/root.zig` exposes the app-facing surface and intentionally does not re-export most internal decomposition modules. The remaining exceptions are present to keep the current build and test wiring practical.

Today that mainly means `cli_entry`: it remains exported through the root
surface because the current Zig build/test wiring still makes direct imports of
that internal entry module awkward.

See also:
- [docs/module-boundary-rules.md](/home/oleg/prog/zigrep/docs/module-boundary-rules.md)

## Current boundary rule

When a module has a clear owner, new code should call the owning module directly instead of routing through historical compatibility wrappers.
