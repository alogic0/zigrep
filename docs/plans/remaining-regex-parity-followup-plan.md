# Remaining Regex Parity Follow-Up Plan

This plan covers the remaining regex-surface gaps that still differ from the
checked local `ripgrep` after the completed Unicode parity work.

The completed work already covers:

- Unicode-aware `\w`, `\d`, `\s`, `\b`, `\B`
- `Script_Extensions` / `scx=...`
- half-boundaries `\b{start-half}` and `\b{end-half}`
- one top-level class-set subtraction or intersection
- broad Unicode property support for the currently chosen native-core surface

## Goal

Close the remaining high-value regex-surface parity gaps without:

- introducing a fallback engine
- weakening the current native-core correctness rules
- mixing performance work into syntax-surface work

## Remaining Gaps

The strongest remaining gaps against local `ripgrep` are:

- broader inline flag groups, especially forms like `(?i:...)`
- nested class-set expressions beyond the current one-operator subset

Secondary gap:

- any still-missing property names only if a concrete parity or user-facing
  need appears after the syntax work is done

## Priority Order

Implementation order for this plan:

1. broader inline flag groups
2. nested class-set expressions
3. only then re-check whether any property-surface follow-up is still needed

## Phase 1: Inline Flag Group Surface

- [x] Confirm the exact local `ripgrep` inline-flag subset worth targeting first:
  - `(?i:...)`
  - `(?-i:...)`
  - whether grouped `m`, `s`, `U`, or `x` style flags matter for the current
    engine surface
  - current result:
    - local `ripgrep` supports `(?i:...)` and `(?-i:...)`
    - those are the highest-value local case-flag forms for the current engine
    - broader grouped inline flags stay deferred in this slice

- [x] Decide the smallest native-core subset worth implementing first
  - expected first slice:
    - `(?i:...)`
    - `(?-i:...)`
    - keep unsupported combinations explicit
  - current result:
    - implement only `(?i:...)` and `(?-i:...)` in this slice
    - keep broader inline flag groups explicit non-goals for now

- [x] Extend the parser with explicit inline-flag group forms

- [x] Define lowering rules against existing CLI and pattern-level behavior:
  - local flag scope only
  - nested restoration
  - interaction with existing `(?-u:...)` / `(?u:...)`
  - current result:
    - local case groups lower as scoped case-fold overrides in HIR
    - `(?i:...)` and `(?-i:...)` override only their local subtree
    - they compose with global `--ignore-case` and `--smart-case`
    - they coexist with existing `(?-u:...)` / `(?u:...)`

- [x] Add search-layer and CLI regressions for mixed local case modes

## Phase 2: Nested Class-Set Expressions

- [ ] Confirm the exact local `ripgrep` nested class-set surface to target:
  - nested subtraction
  - nested intersection
  - whether union forms like `||` must be supported in the first slice

- [ ] Decide the smallest native representation that can express nested class
  algebra without duplicating evaluation logic

- [ ] Extend the parser from the current one-operator class-set node to a
  recursive class-set expression tree

- [ ] Lower nested class-set expressions into native matcher nodes that preserve:
  - Unicode property items
  - folded ranges
  - existing negated-class semantics

- [ ] Keep planner support out of scope until VM semantics are proven

- [ ] Add VM, search-layer, and CLI regressions for representative nested set
  expressions

## Phase 3: Remaining Property-Surface Re-Check

- [ ] Re-check whether any still-missing property names remain materially useful
  after the syntax-surface gaps are closed

- [ ] If yes, spin that into a separate narrow follow-up plan instead of
  widening this one

## Phase 4: Validation And Docs

- [x] Keep [docs/supported-syntax.md](../supported-syntax.md) aligned after each
  implemented slice

- [x] Compare each completed slice against local `ripgrep` before closing it

- [x] Run:
  - `zig build test`
  - `zig build bench`

## Recommended Order

- [x] 1. Land the smallest useful inline-flag group subset
- [ ] 2. Land nested class-set expressions
- [ ] 3. Re-evaluate any remaining property-surface follow-up

## Explicit Non-Goals

This plan does not include:

- fallback-engine work
- unrelated performance tuning
- planner support for the new constructs before VM equivalence is proven
- broad property expansion without a concrete parity or user-facing need
