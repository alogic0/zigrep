# `rg` Code Search Parity Plan

This plan covers the next small set of features needed for `zigrep` to replace
`rg` more comfortably in day-to-day codebase work.

The focus here is not full ripgrep parity. The focus is the concrete workflow
gap exposed by using `zigrep` in this repo for architecture review and source
navigation.

## Goal

Improve `zigrep` as a developer-facing code search tool by adding:

- file enumeration comparable to `rg --files`
- fixed-string search comparable to `rg -F`
- safer pattern passing comparable to `rg -e`
- better literal-search ergonomics for code snippets

## Current Gap

When used as a substitute for `rg` in this repository:

- recursive regex search works
- file-only match search works
- glob filtering works
- JSON output works
- plain file listing now exists via `--files`
- exact literal code search now works via `-F` / `--fixed-strings`
- patterns that begin with `-` can now be passed explicitly via `-e`

The practical result is that `zigrep` can replace `grep`-style content search
today and now covers the main local `rg`-style code-navigation workflow for
file listing, literal snippet search, and explicit awkward-pattern passing.

## Scope

This plan includes:

- `--files`
- `-F` / `--fixed-strings`
- `-e PATTERN` / `--regexp PATTERN`
- the parser and search-layer changes needed to make those flags compose
  cleanly with existing globs, ignore handling, hidden-file policy, type
  filters, and output modes

This plan does not include:

- full ripgrep flag parity
- replacement syntax for multiple patterns in one invocation beyond the
  minimum needed to support `-e`
- sorting, path coloring, or shell-completion work
- performance work beyond what is necessary to keep the added modes coherent

## Feature 1: `--files`

- [x] Add `--files` as a path-enumeration mode that lists candidate files after
  traversal, ignore filtering, glob filtering, hidden-file policy, symlink
  policy, and type filtering.
- [x] Make `--files` skip regex compilation and matching entirely.
- [x] Reuse existing path-output formatting where appropriate, including
  `--null`.
- [ ] Decide and document whether `--files` should reject reporting flags that
  only make sense for match output, such as `-n`, `-o`, `-c`, `-A`, `-B`, and
  `-C`.
- [ ] Add tests proving `--files` respects:
  - ignore files
  - `--hidden`
  - `-u` / `-uu` / `-uuu`
  - `-g`
  - `-t` / `-T`
  - `--null`

### Design Guidance

- `--files` should be a first-class CLI/report mode, not a fake empty-pattern
  search.
- Ownership should stay aligned with the current architecture:
  - CLI parsing in `src/cli*.zig`
  - traversal and filtering in `src/search_path_runner.zig` and
    `src/search_filtering.zig`
  - path output shaping in `src/search_output.zig` / `src/search_reporting.zig`

## Feature 2: Fixed-String Search

- [x] Add `-F` / `--fixed-strings`.
- [x] Define fixed-string semantics in plain terms:
  - the pattern is interpreted literally
  - regex metacharacters lose special meaning
  - case-mode flags still apply
- [x] Decide whether fixed-string matching should lower through the existing
  regex/HIR path as an escaped literal pattern or through a dedicated literal
  search path.
- [ ] Keep invalid-UTF-8 and raw-byte behavior aligned with existing literal
  search semantics.
- [ ] Add tests for literal searches containing characters such as:
  - `()[]{}`
  - `.`
  - `*`
  - `+`
  - `?`
  - `\`
  - `"search/root.zig"`

### Design Guidance

- Prefer the smallest implementation that preserves current search semantics.
- If escaping into the existing regex compiler is enough, start there.
- Only add a dedicated literal-only fast path if the implementation becomes
  cleaner or materially faster, not just because `rg` has one.

## Feature 3: `-e` / `--regexp`

- [x] Add `-e PATTERN` and `--regexp PATTERN`.
- [x] Support patterns that begin with `-` without requiring `--`.
- [x] Allow at least one explicit pattern source through `-e`, even if the
  first non-flag positional pattern remains supported for compatibility.
- [ ] Decide and document whether multiple `-e` flags are:
  - rejected for now
  - accepted as alternation
  - accepted as repeated independent searches
- [ ] Add tests for:
  - `-e -literal`
  - `-e "@import(\"search/root.zig\")"`
  - interactions with `-F`
  - interactions with existing positional pattern parsing

### Recommended Initial Policy

- repeated `-e` is allowed
- positional pattern plus any `-e` remains invalid for now
- repeated `-e` becomes one effective OR-style search

That keeps the parser simple while matching the current implemented behavior.

## Cross-Cutting Parser Cleanup

- [x] Update `src/cli_parse_state.zig`, `src/cli_parse_helpers.zig`, and
  `src/cli_validation.zig` so pattern-source handling is explicit instead of
  being coupled only to “first non-flag argument wins”.
- [x] Represent pattern mode explicitly in parsed options:
  - regex pattern
  - fixed-string pattern
  - file-list mode with no pattern
- [ ] Keep usage errors precise for missing, duplicated, or incompatible
  pattern inputs.

## Cross-Cutting Search-Layer Cleanup

- [x] Avoid forcing `search_runner.runSearch(...)` and
  `search_path_runner.searchPath(...)` through a fake searcher setup for
  `--files`.
- [x] Make the dispatch layer choose between:
  - search execution
  - type listing
  - file listing
- [x] Keep reporting ownership narrow:
  - path-only emission should reuse existing path output helpers
  - match reporting should stay separate

## Validation

- [x] Add end-to-end CLI coverage for the new flags and their interactions.
- [ ] Add regression coverage for code-search examples used in this repo:
  - listing all tracked candidate source files with `--files`
  - searching for `@import("search/root.zig")` with `-F`
  - searching for a pattern beginning with `-` via `-e`
- [ ] Run `zig build test`

## Suggested Implementation Order

- [x] 1. Add explicit pattern-source parsing for `-e` and file-list mode.
- [x] 2. Add `--files` as a dispatch/report mode that bypasses regex compile.
- [x] 3. Add `-F` / `--fixed-strings` with the smallest coherent semantics.
- [ ] 4. Tighten validation for invalid flag combinations in file-list mode.
- [x] 5. Add end-to-end tests for the new developer-search workflows.

## Outcome

If this plan is complete, `zigrep` should be able to replace `rg` for the
common local code-search workflow:

- enumerate files with `--files`
- search code snippets literally with `-F`
- pass awkward patterns safely with `-e`

That is enough to remove the main fallback to `find` and reduce the need for
manual regex escaping during normal source navigation.
