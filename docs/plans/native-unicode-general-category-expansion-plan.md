# Native Unicode General-Category Expansion Plan

This plan covers the next native-engine Unicode regex expansion after
[native-unicode-regex-plan.md](native-unicode-regex-plan.md).

It keeps the same architectural boundary:

- native engine: everything that stays inside the current Thompson NFA / DFA /
  Pike VM model
- no fallback engine
- generated Unicode tables checked into this repo

## Goal

Add more Unicode general-category-style properties using the same generated
table model already used for:

- `Alphabetic`
- `Letter`
- `Lowercase`
- `Number`
- `Uppercase`
- `Whitespace`

The next target properties are:

- `Mark`
- `Punctuation`
- `Symbol`
- `Separator`

## Phase 1: Lock Semantics

- [x] Confirm the user-visible property names:
  - `Mark`
  - `Punctuation`
  - `Symbol`
  - `Separator`

- [x] Confirm the alias policy for the first pass.
  Recommended:
  - `Mark` => `M`
  - `Punctuation` => `P`
  - `Symbol` => `S`
  - `Separator` => `Z`

- [x] Keep raw-byte semantics unchanged:
  - valid UTF-8 scalar => property lookup
  - invalid raw byte => does not match positive property predicates
  - invalid raw byte => does match negated property predicates

- [x] Keep shorthand classes unchanged:
  - do not widen `\w`, `\d`, or `\s`

## Phase 2: Extend Generated Data

- [x] Extend [tools/gen_unicode_props.zig](../../tools/gen_unicode_props.zig)
  to emit compact range tables for:
  - `mark_ranges`
  - `punctuation_ranges`
  - `symbol_ranges`
  - `separator_ranges`

- [x] Continue to derive these ranges from `UnicodeData.txt` category prefixes:
  - `M*` => `Mark`
  - `P*` => `Punctuation`
  - `S*` => `Symbol`
  - `Z*` => `Separator`

- [x] Keep the current aggregate logic explicit:
  - subgroup categories still contribute to any broader aggregate property that
    already exists

- [x] Regenerate
  [src/regex/unicode_props_generated.zig](../../src/regex/unicode_props_generated.zig)
  after the generator change

## Phase 3: Runtime Property Surface

- [x] Extend [src/regex/unicode.zig](../../src/regex/unicode.zig) with:
  - new `Property` enum members
  - lookup aliases
  - `hasProperty` support for the new generated tables

- [x] Keep `Strategy.category(...)` stable unless there is a deliberate reason
  to refine it further.
  Recommended:
  - leave the current high-level category surface alone for now
  - use the new properties only through explicit `\p{...}` and `\P{...}`

## Phase 4: Engine Validation

- [ ] Add Unicode helper tests for:
  - property lookup
  - positive membership
  - negative membership

- [ ] Add search-layer tests for:
  - top-level property escapes
  - bracket-class property items
  - raw-byte invalid-byte behavior

- [ ] Add CLI tests for:
  - one representative match for each new property
  - one representative negated-property case

- [ ] Reconfirm planner boundary behavior:
  - property-containing patterns still stay off the byte planner
  - they continue through the general raw-byte VM path

## Phase 5: Documentation

- [ ] Update [docs/supported-syntax.md](../supported-syntax.md) with:
  - the new property names
  - their aliases
  - unchanged raw-byte semantics

- [ ] Update
  [docs/unicode-data-generation.md](../unicode-data-generation.md)
  only if the generator inputs or workflow change

## Recommended Order

- [ ] 1. Add generated tables first
- [ ] 2. Wire lookup and matching second
- [ ] 3. Add tests before broadening aliases further
- [ ] 4. Update docs last

## Explicit Non-Goals

- [ ] Do not add Unicode properties unrelated to general-category-style sets in
  this plan
- [ ] Do not widen ASCII shorthand classes
- [ ] Do not add a fallback engine
- [ ] Do not teach the byte planner Unicode property execution
