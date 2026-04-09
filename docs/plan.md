# Zigrep Build Plan

## Goal

Build a Zig-native analog of `ripgrep` with:

- A regex engine for the automata-friendly subset
- Byte-oriented UTF-8 aware matching
- Search-tool behavior optimized for real codebases

## Plan

### 1. Syntax Foundation

- [x] Extend the parser to support the intended regex subset
- [x] Add character classes
- [x] Add escape handling needed for search use cases
- [x] Add counted repetition like `{m,n}`
- [x] Add span-aware parse errors
- [x] Reject unsupported PCRE-style constructs explicitly
- [x] Add parser tests for valid and invalid syntax

### 2. HIR and Analysis

- [x] Introduce a normalized HIR layer
- [x] Lower AST into HIR
- [x] Add literal extraction
- [x] Add prefix analysis
- [x] Add detection for fast-path opportunities
- [x] Add tests for HIR lowering and analysis

### 3. Core Matcher

- [x] Define the first Thompson NFA instruction set
- [x] Compile HIR into NFA
- [ ] Implement Pike VM execution
- [ ] Add support for captures only where needed
- [ ] Add matcher correctness tests
- [ ] Add focused regression tests for edge cases

### 4. Unicode Boundary Layer

- [ ] Define the internal interface in `src/regex/unicode.zig`
- [ ] Add Unicode property lookup support
- [ ] Add case folding support
- [ ] Add Unicode-aware boundary semantics as needed
- [ ] Keep matching byte-oriented in the hot path
- [ ] Avoid whole-input decode-first designs

### 5. Fast Path

- [ ] Add literal prefilters ahead of the full matcher
- [ ] Add a DFA or lazy DFA for non-capturing search
- [ ] Add ASCII-first fast paths
- [ ] Add optional SIMD scanning behind target-feature gates
- [ ] Add benchmarks for engine-level performance

### 6. Search Tool Plumbing

- [ ] Add recursive directory walking
- [ ] Add ignore-file handling
- [ ] Add binary-file detection
- [ ] Add buffered I/O strategy
- [ ] Add mmap strategy where appropriate
- [ ] Add match reporting
- [ ] Add a first usable CLI

### 7. Parallelism and Polish

- [ ] Add parallel file search
- [ ] Add work scheduling strategy
- [ ] Add configuration flags and CLI polish
- [ ] Add benchmarks on realistic corpora
- [ ] Add end-to-end integration tests
- [ ] Add documentation for supported syntax and non-goals

## Current Priority

- [x] Finish the syntax layer
- [x] Introduce HIR as the compiler boundary

Completed in this pass: the parser now handles counted repetition, character
classes, common escapes, and span-carrying diagnostics for unsupported syntax;
`compile` now lowers AST into HIR and exposes literal/prefix fast-path analysis
as the public compiler boundary.

Completed in the next pass: the first Thompson NFA instruction set now exists
in `src/regex/nfa.zig`, and HIR lowers into that program form for literals,
classes, concatenation, alternation, repetition, dot, and anchors.

These two items should happen before serious matcher work, otherwise the engine
will churn as syntax and internal representation keep changing.
