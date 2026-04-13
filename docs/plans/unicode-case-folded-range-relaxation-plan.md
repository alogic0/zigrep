# Unicode Case-Folded Range Relaxation Plan

This plan covers the remaining deliberate divergence after
[unicode-case-folding-parity-plan.md](unicode-case-folding-parity-plan.md):
`zigrep` used to reject some broad case-insensitive class ranges that local
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
- broader folded ranges now lower to a dedicated folded-range representation
- the rejection boundary is deterministic and covered by search-layer and CLI
  regressions

Current focused parity result:

- the universal scalar range `[\u{0000}-\u{10FFFF}]` is accepted under `-i`
- broader folded ranges such as `[\u{0000}-\u{FFFF}]` are also accepted under
  `-i`
- the checked local `ripgrep` samples for broad folded ranges now match

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
  - current result: the original broad folded-range rejection surface was
    confirmed and then removed by the dedicated folded-range representation

- [x] Compare those exact shapes against local `ripgrep`
  - current result: the checked local `ripgrep` samples for universal, BMP,
    medium, and mixed broad folded ranges now match `zigrep`

- [x] Record the smallest useful subset that would reduce user-visible
  divergence materially
  - current result: the smallest safe first relaxation was the universal
    scalar range `[\u{0000}-\u{10FFFF}]`, because it is already closed under
    folding and can be preserved directly as a range item without widening the
    general rewrite model

## Phase 2: Review Rewrite Strategy Options

- [x] Review the current bounded fold-range rewrite in
  [src/regex/hir.zig](../../src/regex/hir.zig)
  - current result: the current rewrite expands each class range code point by
    code point and then appends each scalar's simple-fold closure as literal
    items
  - current result: this is simple and correct for small ranges, but compile
    cost grows with source range width before any normalization happens
  - current result: the existing `max_case_folded_range_size` guard is a blunt
    compile-time blow-up cap, not a semantic boundary

- [x] Evaluate native-core options for larger folded ranges:
  - larger bounded expansion only
  - canonicalized folded interval sets
  - specialized case-insensitive range node lowered directly to the VM/NFA
  - current result: simply increasing the bounded expansion limit is not a
    credible long-term fix because it scales compile cost linearly with source
    range width and still leaves the newline-suppression problem unsolved
  - current result: canonicalized folded interval sets are viable in principle
    but would still require careful newline handling in non-multiline mode and
    a new coalescing representation instead of today's literal-only expansion
  - current result: a specialized case-insensitive range/class node lowered
    directly to the VM/NFA is the most coherent native-core direction if work
    continues beyond the universal-range exception

- [x] Reject any option that would:
  - silently miss folded equivalents
  - make compile-time blow-up effectively unbounded
  - force planner support before VM semantics are proven
  - current result: the plan rejects a larger expansion cap as the primary
    strategy
  - current result: the planner remains out of scope for these shapes
  - current result: any future broader relaxation should start from a new
    matcher representation, not from raising the current limit

## Phase 3: Choose The Narrowest Safe Improvement

- [x] Prefer the smallest change that expands accepted input materially, for
  example:
  - accepting large but still regular folded interval unions
  - accepting full-range-like classes only when they collapse to an obvious
    universal folded predicate
  - current result: the first step accepted the true universal scalar range
    `[\u{0000}-\u{10FFFF}]` under `-i` by rewriting it to the existing
    top-level `\p{Any}` representation, and the follow-up step broadened this
    into a general folded-range representation

- [x] Keep the rejection boundary explicit for the remaining unsupported shapes
  - current result: the old broad folded-range rejection boundary is gone for
    the checked cases in this plan

- [x] Record the new boundary in the plan before implementation

## Phase 4: Implement The Chosen Rewrite Improvement

- [x] Implement the chosen native-core representation in:
  - [src/regex/hir.zig](../../src/regex/hir.zig)
  - [src/regex/nfa.zig](../../src/regex/nfa.zig)
  - [src/regex/vm.zig](../../src/regex/vm.zig)
  - any affected Unicode helpers
  - current result: the final implementation uses both the earlier universal
    `Any` rewrite and the new folded-range item through HIR, NFA, VM, DFA,
    and Unicode helpers

- [x] Keep raw-byte planner exclusions unchanged unless equivalence is proven

- [x] Preserve the current explicit-failure behavior for shapes still outside
  the chosen model

## Phase 5: Validation

- [x] Add search-layer regressions for newly accepted broad folded ranges
  - current result: universal and broader BMP-style folded ranges are covered
    directly in the search layer

- [x] Add end-to-end CLI regressions for representative accepted cases
  - current result: universal and broader BMP-style folded ranges are covered
    end-to-end through the CLI

- [x] Re-run the focused local `ripgrep` comparison matrix for:
  - accepted broad ranges
  - still-rejected broad ranges
  - mixed property-plus-range classes under `-i`
  - current result: `zigrep` now matches the checked local `ripgrep` samples
    for universal, BMP, medium, and mixed broad folded-range cases

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
  - current result: no broad folded-range rejection example remains in the
    checked docs because this plan removed that earlier divergence

## Recommended Order

- [x] 1. Reconfirm the rejected-shape matrix
- [x] 2. Choose the narrowest native-core strategy
- [x] 3. Implement only that strategy
- [x] 4. Re-run ripgrep comparison and benchmarks
- [x] 5. Update docs with the new acceptance/rejection boundary

## Status

This plan is complete.

Implemented outcome:

- `[\u{0000}-\u{10FFFF}]` under `-i` is now accepted
- that universal scalar range is rewritten to the existing `\p{Any}` path
- broader folded ranges such as `[\u{0000}-\u{FFFF}]` now use a dedicated
  folded-range representation instead of literal expansion or explicit
  rejection
- folded-range classes stay off the raw-byte planner and use the general VM
  path
- the focused local `ripgrep` comparison matrix now matches for the checked
  broad folded-range cases

Remaining work, if continued later:

- there is no unfinished work in this plan
- any future work here would be a new follow-up for performance tuning or
  planner support, not more correctness work

## Explicit Non-Goals

This plan does not include:

- fallback-engine work
- planner support for folded Unicode ranges
- locale-sensitive case behavior
- unrelated Unicode property expansion
