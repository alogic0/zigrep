# Module Boundary Rules

These rules are the current working contract for the `zigrep` codebase.

## Import rules

- Use `@import("zigrep")` only for app-facing modules exported from [src/root.zig](../src/root.zig).
- Use direct file imports for internal-only implementation modules that are not part of the intended root surface.
- Do not reintroduce convenience re-exports in [src/root.zig](../src/root.zig) just to avoid a local file import.

## Ownership rules

- Call the owning module directly when a responsibility has already been extracted.
- Do not route new code through historical compatibility layers or coordinator modules unless that module still truly owns the behavior.
- Keep coordinator modules thin:
  - [src/cli_entry.zig](../src/cli_entry.zig) for top-level CLI entry flow
  - [src/search_runner.zig](../src/search_runner.zig) for top-level search coordination

## CLI rules

- [src/cli.zig](../src/cli.zig) owns scanning, usage text, and usage-error classification.
- [src/cli_parse_state.zig](../src/cli_parse_state.zig), [src/cli_parse_helpers.zig](../src/cli_parse_helpers.zig), and [src/cli_validation.zig](../src/cli_validation.zig) own parser internals.
- [src/cli_dispatch.zig](../src/cli_dispatch.zig) owns parsed command execution.
- [src/cli_entry.zig](../src/cli_entry.zig) should reach `cli_dispatch` through dedicated build wiring, not through [src/root.zig](../src/root.zig).

## Search rules

- [src/search_runner.zig](../src/search_runner.zig) remains the top-level
  coordinator and intentionally keeps the sequential execution path.
- [src/search_path_runner.zig](../src/search_path_runner.zig) owns traversal, filtering, and schedule selection.
- [src/search_parallel.zig](../src/search_parallel.zig) owns parallel execution.
- [src/search_entry_runner.zig](../src/search_entry_runner.zig) owns per-file execution.
- [src/search_reporting.zig](../src/search_reporting.zig) owns report and output shaping.
- [src/search_result.zig](../src/search_result.zig) owns shared result types.
- Do not add a search facade layer unless it removes real coupling; a thin
  wrapper over the current search modules is not enough justification on its
  own.

## Root surface rules

- Treat [src/root.zig](../src/root.zig) as the app-facing surface, not as a dump of internal modules.
- Do not reintroduce convenience exports in [src/root.zig](../src/root.zig) just to satisfy local test or build wiring.
