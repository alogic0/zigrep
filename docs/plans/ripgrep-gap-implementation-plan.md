# Ripgrep Gap Implementation Plan

This plan summarizes the major functionality present in the local `ripgrep`
repository that `zigrep` does not yet implement, with emphasis on what makes
sense for a Zig-native implementation.

It is not a goal to clone ripgrep flag-for-flag or crate-for-crate. The goal is
to close the most important user-visible gaps while keeping `zigrep` coherent,
portable, and maintainable in Zig.

## Current Position

`zigrep` already has:

- a custom automata-friendly regex engine
- raw-byte handling for invalid UTF-8
- UTF-16 support with `-E/--encoding`
- recursive search, ignore-file handling, binary detection, mmap/buffered reads
- ordered parallel search
- output formatting for normal line-oriented matches

Compared with the local `ripgrep` repo, the main missing functionality is now
less about core matching and more about search-tool breadth, UX depth, and
ecosystem features.

## Priority 1: Core Search UX Gaps

- [x] Add `-c/--count` style reporting.
  `zigrep` now supports count-only reporting for matching lines.

- [x] Add `-o/--only-matching`.
  The engine already tracks match spans, and `zigrep` now exposes that as a CLI
  output mode.

- [x] Add `-l/--files-with-matches` and `-L/--files-without-match` equivalents.
  `zigrep` now supports both `-l/--files-with-matches` and
  `-L/--files-without-match`.

- [x] Add before/after/context line support (`-A`, `-B`, `-C` style behavior).
  `zigrep` now supports context output for normal line mode, with merged groups
  and `--` separators between disjoint match groups.

- [x] Add `-m/--max-count`.
  `zigrep` now supports a per-file matching-line cap via `-m` or
  `--max-count`, including the existing `--count` and `--only-matching`
  output modes.

### Zig-specific guidance

- Reuse the current span-based reporting path instead of introducing a separate
  line-streaming engine just for context.
- Keep context extraction byte-oriented and file-buffer-based so it stays
  compatible with the current read/match model.

## Priority 2: Search Filtering And CLI Surface

- [x] Add glob filtering with `-g/--glob`.
  `zigrep` now supports repeated case-sensitive include/exclude globs with
  `-g/--glob`, including `!pattern` exclusions. `--iglob` is still open.

- [x] Add richer ignore controls:
  `zigrep` now supports `--ignore-file`, `--no-ignore`,
  `--no-ignore-vcs`, and `--no-ignore-parent`, layered on top of the
  current small internal `.gitignore`-subset matcher.

- [x] Add smart case and ignore-case modes.
  `zigrep` now supports `-i/--ignore-case` and `-S/--smart-case` through a
  case-folded HIR rewrite, with explicit rejection for overly broad folded
  ranges instead of silent under-matching.

- [x] Add file type filters:
  `zigrep` now supports `-t`, `-T`, `--type-add`, and `--type-list` with a
  small built-in type table plus runtime type additions.

- [x] Add `--hidden` / ignore interactions closer to ripgrep’s actual model.
  `zigrep` now supports ripgrep-style unrestricted mode via `-u`,
  `-uu`, and `-uuu`, which progressively disable ignore filtering,
  include hidden files, and search binary files.

### Zig-specific guidance

- Treat globs, ignore rules, and file-type definitions as first-class data
  structures in `src/search/`, not ad hoc conditionals in `main.zig`.
- Prefer explicit structs and compact internal representations over trying to
  emulate ripgrep’s Rust crate boundaries directly.

## Priority 3: Output Modes And Integration

- [x] Add heading / grouped file output.
  `zigrep` now supports heading-style grouped text output with `--heading`.

- [x] Add NUL-delimited path output where appropriate (`--null` style support).
  `zigrep` now supports `--null` for file-path reporting modes, emitting
  NUL-delimited paths for safe scripting.

- [x] Add JSON output.
  `zigrep` now supports newline-delimited JSON events via `--json` for
  match, count, and path-oriented reporting modes.

- [x] Add stats output.
  `zigrep` now supports `--stats`, emitting a compact search summary to
  stderr with searched file counts, matched file counts, searched bytes,
  and skipped binary-file counts.

- [ ] Add passthrough / non-match-printing modes only if justified.
  This is lower priority than count/context/json, but it is part of the broader
  ripgrep output surface.

### Zig-specific guidance

- Implement JSON output with a dedicated event model instead of formatting text
  and reparsing it.
- Keep text and JSON reporting paths separate but driven by shared internal
  match events.

## Priority 4: Regex Surface Gaps

- [ ] Add case-insensitive regex support in the native engine.
  This is currently the single biggest regex usability gap.

- [ ] Decide whether to support multiline search (`-U/--multiline` style).
  This is a major ripgrep feature but has real architectural cost.

- [ ] Decide whether to support a richer regex fallback such as PCRE2-like
  functionality or to keep the current deliberate non-goal.

- [ ] Add more grep/ripgrep-compatible character class and escape syntax only if
  it fits the engine model cleanly.

### Zig-specific guidance

- Do not compromise the current linear-time engine design just to chase full
  PCRE2 compatibility.
- If richer regex support is added later, isolate it behind an explicit fallback
  boundary rather than contaminating the main engine path.

## Priority 5: Binary, Encoding, And Input Parity

- [ ] Add a distinct `--binary` mode similar to ripgrep’s
  “search and suppress binary output” behavior.

- [ ] Decide whether to add `-E none` style raw-byte mode explicitly.
  ripgrep exposes a sharper encoding boundary here than `zigrep` does today.

- [ ] Expand encoding coverage beyond UTF-8 / UTF-16 if this project wants real
  ripgrep-like text-encoding breadth.

- [ ] Revisit binary detection behavior under mmap vs buffered reads.
  ripgrep documents subtle differences here; `zigrep` should decide whether to
  normalize behavior or document intentional differences.

### Zig-specific guidance

- Keep binary/encoding policy explicit in `src/search/io.zig` instead of
  scattering it across CLI and matcher code.
- Prefer a small number of clearly documented input modes over a complicated
  matrix of partially implicit behavior.

## Priority 6: External Input Pipelines

- [ ] Add compressed-file search (`-z/--search-zip` style).
  This is a meaningful gap versus ripgrep for real-world log and artifact search.

- [ ] Add preprocessor support (`--pre`, `--pre-glob` style) if the project
  wants ripgrep-like arbitrary input transforms.

### Zig-specific guidance

- Keep decompression and preprocessing isolated behind a narrow input-provider
  interface.
- Avoid baking shell-process assumptions into the core matcher or reporting
  layers.

## Priority 7: Config And Tooling Surface

- [ ] Add configuration file support.
  ripgrep’s config file support is a real UX multiplier for regular users.

- [ ] Add better exit/status and warning behavior around new modes as they land.

- [ ] Expand end-to-end CLI tests to cover flag interactions, not just isolated
  features.

### Zig-specific guidance

- Keep config parsing simple and explicit.
- Avoid introducing a complex “global state” model just to support a config
  file.

## Suggested Implementation Order

- [x] 1. Add count-only and files-with-matches modes.
- [x] 2. Add only-matching output.
- [x] 3. Add `-m/--max-count`.
- [x] 4. Add `-A/-B/-C` context output for normal line mode.
- [ ] 3. Add context line support.
- [ ] 4. Add glob filtering and richer ignore controls.
- [ ] 5. Add case-insensitive / smart-case search.
- [x] 6. Add file type filters.
- [x] 7. Add JSON output and NUL-delimited path output.
- [ ] 8. Revisit binary-mode parity and explicit raw-byte input modes.
- [ ] 9. Decide whether multiline search is worth the complexity.
- [ ] 10. Only then consider compressed search, preprocessors, or richer regex
  fallback work.

## Explicit Non-Goals For Now

- [ ] Do not chase full flag parity with ripgrep before closing the common grep
  workflows.
- [ ] Do not mirror ripgrep’s Rust crate structure mechanically in Zig.
- [ ] Do not add PCRE2-style complexity to the native engine unless an explicit
  fallback architecture exists first.
