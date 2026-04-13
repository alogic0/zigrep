# Module Boundary Rules

These rules are the current working contract for the `zigrep` codebase.

## Import rules

- Use `@import("zigrep")` only for app-facing modules exported from [src/root.zig](/home/oleg/prog/zigrep/src/root.zig).
- Use direct file imports for internal-only implementation modules that are not part of the intended root surface.
- Do not reintroduce convenience re-exports in [src/root.zig](/home/oleg/prog/zigrep/src/root.zig) just to avoid a local file import.

## Ownership rules

- Call the owning module directly when a responsibility has already been extracted.
- Do not route new code through historical compatibility layers or coordinator modules unless that module still truly owns the behavior.
- Keep coordinator modules thin:
  - [src/cli_entry.zig](/home/oleg/prog/zigrep/src/cli_entry.zig) for top-level CLI entry flow
  - [src/search_runner.zig](/home/oleg/prog/zigrep/src/search_runner.zig) for top-level search coordination

## CLI rules

- [src/cli.zig](/home/oleg/prog/zigrep/src/cli.zig) owns scanning, usage text, and usage-error classification.
- [src/cli_parse_state.zig](/home/oleg/prog/zigrep/src/cli_parse_state.zig), [src/cli_parse_helpers.zig](/home/oleg/prog/zigrep/src/cli_parse_helpers.zig), and [src/cli_validation.zig](/home/oleg/prog/zigrep/src/cli_validation.zig) own parser internals.
- [src/cli_dispatch.zig](/home/oleg/prog/zigrep/src/cli_dispatch.zig) owns parsed command execution.

## Search rules

- [src/search_path_runner.zig](/home/oleg/prog/zigrep/src/search_path_runner.zig) owns traversal, filtering, and schedule selection.
- [src/search_parallel.zig](/home/oleg/prog/zigrep/src/search_parallel.zig) owns parallel execution.
- [src/search_entry_runner.zig](/home/oleg/prog/zigrep/src/search_entry_runner.zig) owns per-file execution.
- [src/search_reporting.zig](/home/oleg/prog/zigrep/src/search_reporting.zig) owns report and output shaping.
- [src/search_result.zig](/home/oleg/prog/zigrep/src/search_result.zig) owns shared result types.

## Root surface rules

- Treat [src/root.zig](/home/oleg/prog/zigrep/src/root.zig) as the app-facing surface, not as a dump of internal modules.
- Any exception kept in [src/root.zig](/home/oleg/prog/zigrep/src/root.zig) for build or test convenience should be treated as temporary and documented when added.
