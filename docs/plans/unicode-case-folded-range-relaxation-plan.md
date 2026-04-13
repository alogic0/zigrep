# Unicode Case-Folded Range Relaxation Plan

This plan covers the remaining deliberate divergence after
[unicode-case-folding-parity-plan.md](unicode-case-folding-parity-plan.md):
`zigrep` still rejects some broad case-insensitive class ranges that local
`ripgrep` accepts, such as:

- `[\u{0000}-\u{FFFF}]` under `-i`

The current rejection is correct and explicit. This plan is only about whether
that boundary can be relaxed safely inside the native engine.

## Goal

Broaden the set of case-insensitive character-class ranges accepted under `-i`
without:

- silently under-matching
- blowing up rewrite size unpredictably
- introducing a fallback regex engine

## Current State

Current behavior:

- Unicode-aware ignore-case works for literals, classes, and selected property
  items through HIR rewrite
- broad folded ranges are rejected explicitly with
  `UnsupportedCaseInsensitivePattern`
- the rejection boundary is deterministic and covered by search-layer and CLI
  regressions

Current known divergence from local `ripgrep`:

- the universal scalar range `[\u{0000}-\u{10FFFF}]` is now accepted under
  `-i`
- local `ripgrep` still accepts broader folded ranges such as
  `[\u{0000}-\u{FFFF}]` under `-i`
- `zigrep` currently rejects those broader ranges

## Decision Boundary

Keep the native-core model.

Do not introduce:

- a fallback engine
- silent approximation of folded ranges
- a special "best effort" mode

The core rule remains:

- either rewrite folded ranges correctly
- or reject explicitly

## Phase 1: Reconfirm The Failure Surface

- [x] Enumerate the current rejected shapes under `-i`:
  - full Unicode ranges
  - large mixed ranges
  - ranges that expand badly only after folding
  - current result: the true universal scalar range is now accepted; the
    remaining rejected shapes are still broader folded ranges such as
    `[\u{0000}-\u{FFFF}]` and similarly large mixed ranges

- [x] Compare those exact shapes against local `ripgrep`
  - current result: local `ripgrep` accepts both the universal scalar range
    and broader folded ranges; `zigrep` now matches `ripgrep` on the universal
    scalar range but still rejects broader folded ranges

- [x] Record the smallest useful subset that would reduce user-visible
  divergence materially
  - current result: the smallest safe first relaxation was the universal
    scalar range `[\u{0000}-\u{10FFFF}]`, because it is already closed under
    folding and can be preserved directly as a range item without widening the
    general rewrite model

## Phase 2: Review Rewrite Strategy Options

- [ ] Review the current bounded fold-range rewrite in
  [src/regex/hir.zig](../../src/regex/hir.zig)

- [ ] Evaluate native-core options for larger folded ranges:
  - larger bounded expansion only
  - canonicalized folded interval sets
  - specialized case-insensitive range node lowered directly to the VM/NFA

- [ ] Reject any option that would:
  - silently miss folded equivalents
  - make compile-time blow-up effectively unbounded
  - force planner support before VM semantics are proven

## Phase 3: Choose The Narrowest Safe Improvement

- [x] Prefer the smallest change that expands accepted input materially, for
  example:
  - accepting large but still regular folded interval unions
  - accepting full-range-like classes only when they collapse to an obvious
    universal folded predicate
  - current result: accept the true universal scalar range
    `[\u{0000}-\u{10FFFF}]` under `-i` by rewriting it to the existing
    top-level `\p{Any}` representation instead of expanding it as a class

- [x] Keep the rejection boundary explicit for the remaining unsupported shapes
  - current result: broader folded ranges such as `[\u{0000}-\u{FFFF}]` remain
    explicitly rejected

- [x] Record the new boundary in the plan before implementation

## Phase 4: Implement The Chosen Rewrite Improvement

- [x] Implement the chosen native-core representation in:
  - [src/regex/hir.zig](../../src/regex/hir.zig)
  - [src/regex/nfa.zig](../../src/regex/nfa.zig)
  - [src/regex/vm.zig](../../src/regex/vm.zig)
  - any affected Unicode helpers
  - current result: only [src/regex/hir.zig](../../src/regex/hir.zig) needed
    code changes for this narrow slice; the universal scalar range now lowers
    to the existing `Any` property path under `-i`

- [x] Keep raw-byte planner exclusions unchanged unless equivalence is proven

- [x] Preserve the current explicit-failure behavior for shapes still outside
  the chosen model

## Phase 5: Validation

- [x] Add search-layer regressions for newly accepted broad folded ranges
  - current result: the universal scalar range is covered directly in the
    search layer

- [x] Add end-to-end CLI regressions for representative accepted cases
  - current result: the universal scalar range is covered end-to-end through
    the CLI

- [x] Re-run the focused local `ripgrep` comparison matrix for:
  - accepted broad ranges
  - still-rejected broad ranges
  - mixed property-plus-range classes under `-i`
  - current result: `zigrep` now matches local `ripgrep` for the universal
    scalar range, while broader folded ranges like `[\u{0000}-\u{FFFF}]`
    remain a deliberate divergence

- [x] Run:
  - `zig build test`
  - `zig build bench`
  - current result: both commands now pass for this slice; a small DFA
    exhaustiveness cleanup was needed in benchmark-only code before
    `zig build bench` would compile again

## Phase 6: Documentation

- [x] Update [supported-syntax.md](../supported-syntax.md) with the relaxed
  boundary if implementation lands

- [x] Document any remaining explicit rejection cases concretely

## Recommended Order

- [x] 1. Reconfirm the rejected-shape matrix
- [x] 2. Choose the narrowest native-core strategy
- [x] 3. Implement only that strategy
- [x] 4. Re-run ripgrep comparison and benchmarks
- [x] 5. Update docs with the new acceptance/rejection boundary

## Status

Initial narrow relaxation is complete.

Implemented outcome:

- `[\u{0000}-\u{10FFFF}]` under `-i` is now accepted
- that universal scalar range is rewritten to the existing `\p{Any}` path
- broader folded ranges such as `[\u{0000}-\u{FFFF}]` still keep the explicit
  native-core rejection boundary

Remaining work, if continued later:

- determine whether additional broad folded ranges can be represented without
  unbounded rewrite blow-up
- if broader rewrite work resumes, re-run `zig build bench` again after that
  structural change

## Explicit Non-Goals

This plan does not include:

- fallback-engine work
- planner support for folded Unicode ranges
- locale-sensitive case behavior
- unrelated Unicode property expansion
