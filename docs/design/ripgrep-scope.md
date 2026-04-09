# Ripgrep-Style Scope and Module Plan

## Goal

Build a Zig-native regex and search stack that mimics the practical behavior of `ripgrep`:

- Fast search over code and text corpora
- Regex features that preserve automata-friendly execution
- Search-tool behavior that aggressively avoids unnecessary work

This project is not targeting full PCRE2 compatibility. The implementation boundary is intentionally narrower so we can preserve predictable performance and a simpler engine design.

## Scope

### Supported regex surface

The first implementation targets the regular-language subset:

- Literals and UTF-8 input
- Concatenation
- Alternation
- Grouping
- Wildcard `.`
- Anchors `^` and `$`
- Quantifiers `*`, `+`, `?`, `{m,n}`
- Character classes
- Escapes needed for search use cases
- Unicode-aware character handling

### Explicit non-goals

These should be rejected during parsing or semantic validation:

- Backreferences
- Recursion and subroutine calls
- Arbitrary lookbehind
- Conditional subpatterns
- PCRE2 control verbs
- Features that require unbounded backtracking semantics

If we later support richer syntax, it should be via clearly isolated fallback paths and not contaminate the main linear-time engine.

## Performance Model

The project should copy `ripgrep`'s broad strategy, not its exact implementation:

1. Extract literals and cheap prefilters before running the full matcher.
2. Compile the supported regex subset into automata-friendly forms that operate on UTF-8 bytes.
3. Use a Pike VM / Thompson NFA baseline for correctness and captures.
4. Add a DFA or lazy DFA fast path for non-capturing search.
5. Spend as much effort on file filtering, I/O, and parallelism as on regex execution.

## UTF-8 and Unicode Strategy

Unicode support should follow the same broad design direction as `ripgrep`:

- Matching runs on raw UTF-8 bytes in the hot path.
- Unicode-aware semantics are integrated into compilation and execution.
- The engine must preserve valid code point boundaries in Unicode mode.
- We do not decode entire files into arrays of code points before matching.

This means the syntax layer may decode code points while parsing patterns, but
the matcher should remain byte-oriented. Unicode classes, case folding, and
boundary logic should be compiled into engine decisions instead of forcing a
full-text decode step ahead of search.

### Invalid UTF-8 policy

We should treat invalid UTF-8 as an engine-level semantic decision, not as an
accidental consequence of whichever reader implementation happens to be in use.

The default policy for the ripgrep-style engine should be:

- In Unicode mode, invalid UTF-8 is not treated as normal Unicode text.
- Match boundaries must never split a valid UTF-8 sequence.
- Any fallback behavior for raw byte matching must be explicit and mode-driven.

This avoids coupling syntax parsing, search behavior, and Unicode semantics to
one decoder implementation.

## Architectural Split

### `regex`

Owns pattern syntax, compilation, and execution.

- Syntax layer: reader, lexer, parser, AST
- Lowering layer: AST to HIR normalization
- Unicode layer: property lookup, case folding, and boundary helpers
- Analysis layer: literal extraction and fast-path decisions
- Automata layer: Thompson NFA and Pike VM
- Acceleration layer: DFA / lazy DFA and SIMD prefilters

### `search`

Owns the tool behavior around the regex engine.

- Directory walking
- Ignore-file compilation and filtering
- Binary-file detection
- Buffered I/O and mmap policy
- Parallel work scheduling
- Match reporting

This separation matters because `ripgrep` wins partly on regex speed, but heavily on searching less data.

## Dependency Boundary

External Unicode libraries such as `zg` may be used as data and algorithm
providers, but they should not own the regex architecture.

Allowed uses:

- Unicode property tables
- Case folding data
- Word-boundary or segmentation helpers when explicitly needed
- Other Unicode classification utilities behind repo-owned adapters

Disallowed uses:

- Defining lexer or parser architecture
- Owning AST or HIR structure
- Owning regex compilation or matching semantics
- Driving the hot-path byte scanner

If we adopt a Unicode dependency, it should live behind a narrow internal module
such as `regex/unicode.zig`, so engine semantics remain repo-owned.

## Module Layout

The repository should evolve toward this shape:

```text
src/
  root.zig
  main.zig
  reader.zig          # transitional compatibility shim / shared low-level reader
  lexer.zig           # transitional compatibility shim
  parser.zig          # transitional compatibility shim
  decoder.zig         # compatibility alias
  regex/
    root.zig
    unicode.zig
    syntax/
      root.zig
      reader.zig
      lexer.zig
      parser.zig
      ast.zig
    hir.zig
    literal.zig
    nfa.zig
    vm.zig
    dfa.zig
  search/
    root.zig
    walk.zig
    ignore.zig
    io.zig
    grep.zig
```

The current top-level parser/lexer/reader files can remain temporarily and re-export into the new structure while the implementation is still small.

## Milestones

### Milestone 1: Syntax foundation

- Finish the parser for the supported subset
- Add span-aware parse errors
- Add AST tests for valid and rejected syntax

### Milestone 2: Normalization and analysis

- Introduce HIR
- Lower AST into HIR
- Add literal extraction and prefix analysis

### Milestone 3: Matching engine

- Compile HIR to Thompson NFA
- Implement Pike VM execution
- Add captures only where needed

### Milestone 4: Fast path

- Add DFA or lazy DFA for non-capturing search
- Add literal prefilters
- Add optional SIMD scanning behind target-feature gates

### Milestone 5: Search tool

- File walking
- Ignore handling
- Binary-file skipping
- Buffered and mmap-backed search
- Parallel directory traversal

## Design Rules

- Prefer explicit compile-time boundaries over feature creep.
- Reject unsupported constructs early and clearly.
- Keep engine internals independent from CLI and filesystem policy.
- Use allocators deliberately; avoid hidden heap churn in hot paths.
- Keep Unicode policy explicit in syntax and matching code.
- Avoid "decode the whole haystack into code points first" designs.
- Keep ASCII fast paths first-class even when Unicode mode is enabled.

## Immediate Next Steps

1. Move syntax types under `src/regex/syntax/`.
2. Introduce `hir.zig` as the boundary between parsing and execution.
3. Add `regex/unicode.zig` as the adapter boundary for Unicode tables and helpers.
4. Define the first NFA instruction set before implementing a matcher.
5. Start `search/ignore.zig` and `search/walk.zig` only after the regex compiler boundary is stable.
