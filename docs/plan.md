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
- [x] Implement Pike VM execution
- [x] Add support for captures only where needed
- [x] Add matcher correctness tests
- [x] Add focused regression tests for edge cases

### 4. Unicode Boundary Layer

- [x] Define the internal interface in `src/regex/unicode.zig`
- [x] Add Unicode property lookup support
- [x] Add case folding support
- [x] Add Unicode-aware boundary semantics as needed
- [x] Keep matching byte-oriented in the hot path
- [x] Avoid whole-input decode-first designs

### 5. Fast Path

- [x] Add literal prefilters ahead of the full matcher
- [x] Add a DFA or lazy DFA for non-capturing search
- [x] Add ASCII-first fast paths
- [x] Add optional SIMD scanning behind target-feature gates
- [x] Add benchmarks for engine-level performance

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

Completed in the latest pass: the Pike VM gained broader correctness and
regression coverage, including ported ripgrep-inspired tests; this also fixed
dot semantics so `.` no longer matches newlines by default.

Completed in the current pass: capture groups are preserved through AST/HIR,
compiled into NFA save instructions, and exposed by the VM as whole-match and
group spans without changing the default non-capturing search API.

Completed in the newest pass: `src/regex/unicode.zig` now defines the internal
Unicode boundary interface with incremental scalar decoding, category/boundary
hooks, and case-fold entry points designed to stay byte-oriented in the hot
path instead of requiring whole-input preprocessing.

Completed in the current Unicode pass: the Unicode layer now supports stable
named property lookup with aliases and direct code point membership checks,
providing an internal API for future regex property syntax without changing the
incremental matcher model.

Completed in the newest Unicode pass: the Unicode layer now exposes explicit
case-fold support with canonical folded scalars, fold-set generation, and
folded scalar comparison hooks that later matcher work can consume directly.

Completed in the current Unicode boundary pass: the Unicode layer now supports
word and line boundary checks at byte offsets in UTF-8 input, including
incremental boundary queries and rejection of offsets that land inside a scalar.

Completed in the first fast-path pass: compiled regex programs now carry a
required-literal prefilter derived from HIR analysis, and the VM rejects
haystacks that cannot contain that literal before running full NFA execution.

Completed in the current fast-path pass: boolean non-capturing search now uses
a lazy DFA cache over NFA state sets, while capture-bearing queries continue to
use the Pike VM path that preserves match spans.

Completed in the newest fast-path pass: ASCII-safe regex programs now take
byte-oriented fast paths in both the lazy DFA and Pike VM, skipping UTF-8
decoding when the haystack and compiled program are both ASCII-only.

Completed in the current SIMD fast-path pass: the literal prefilter now has an
optional SIMD-gated single-byte scan path controlled by a build option, while
all non-SIMD and non-eligible cases continue to use the normal fallback logic.

Completed in the benchmark pass: `zig build bench` now runs a small engine
benchmark harness that measures representative prefilter, lazy-DFA, and
capture-preserving Pike-VM cases and prints CSV-friendly timing output.

These two items should happen before serious matcher work, otherwise the engine
will churn as syntax and internal representation keep changing.
