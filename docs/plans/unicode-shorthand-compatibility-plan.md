# Unicode Shorthand Compatibility Plan

This plan covers parity-oriented migration of shorthand classes and word
boundaries toward ripgrep-style Unicode behavior.

It is intentionally separate from:

- [native-unicode-regex-plan.md](native-unicode-regex-plan.md)
- [native-unicode-full-property-surface-plan.md](native-unicode-full-property-surface-plan.md)

Those plans expanded explicit Unicode property support. This plan changes the
default semantics of shorthand regex operators, which is a compatibility change
and needs to be treated separately.

## Decision

`zigrep` will migrate shorthand defaults to Unicode-aware semantics.

There will be no separate Unicode mode switch for this migration.

That means:

- `\w` becomes Unicode-aware
- `\d` becomes Unicode-aware
- `\s` becomes Unicode-aware
- `\b` and `\B` become Unicode word boundaries

ASCII-only intent will remain available through explicit regexes, not through
the shorthand defaults.

Examples:

- `[0-9]` for ASCII-only digits
- `[A-Za-z0-9_]` for ASCII-only word characters
- explicit ASCII whitespace classes for ASCII-only space matching

## ripgrep Parity Target

The target behavior is:

- Unicode mode semantics by default for shorthand operators
- `\w` matches Unicode word characters
- `\d` matches Unicode decimal digits
- `\s` matches Unicode whitespace
- `\b` and `\B` use Unicode word-character semantics

Important default-mode exception:

- in normal non-multiline search, `\s` must not permit matches through `\n`
- in multiline mode, newline-aware matching may be allowed according to the
  existing multiline engine semantics

This reflects ripgrep's documented and observed behavior.

## Native-Core Boundary

This work remains inside the native engine.

It must continue to fit the existing Thompson NFA / DFA / Pike VM model:

- scalar predicate checks over decoded Unicode scalars
- zero-width boundary assertions
- no fallback engine
- no backtracking-only semantics

Planner rule:

- shorthand and boundary patterns using Unicode-aware semantics stay off the
  raw-byte planner unless planner equivalence is proven explicitly

## Raw-Byte Semantics

The raw-byte behavior remains explicit:

- valid UTF-8 scalar => Unicode-aware shorthand or boundary check
- invalid raw byte => no positive `\w`, `\d`, or `\s` match
- invalid raw byte => `\W`, `\D`, and `\S` may match under the existing negated
  raw-byte rule
- invalid raw byte => treated as non-word for `\b` / `\B`

## Phase 1: Lock Semantic Mapping

- [x] Map `\d` to Unicode decimal digits only
  - parity target: `Decimal_Number`
  - do not widen `\d` to all numeric properties

- [x] Map `\s` to Unicode whitespace
  - parity target: `White_Space`
  - in non-multiline mode, suppress newline matching through `\s`

- [x] Define the Unicode word-character predicate for `\w`
  - pin the exact property combination used by the native engine
  - apply the same predicate to `\b` / `\B`
  - chosen predicate:
    - `Alphabetic`
    - `Mark`
    - `Decimal_Number`
    - `Connector_Punctuation`
    - `Join_Control` (`U+200C`, `U+200D`)

- [x] Record the migration impact in docs before code lands
  - shorthand defaults are changing
  - explicit ASCII regexes are the migration path

## Phase 2: Engine Data And Helper Layer

- [x] Add dedicated helper predicates in the Unicode matcher layer for:
  - `isUnicodeDigit`
  - `isUnicodeWhitespace`
  - `isUnicodeWord`

- [x] Reuse generated property tables where possible instead of duplicating
  logic

- [ ] Keep newline handling for `\s` explicit rather than burying it inside the
  generic whitespace predicate

## Phase 3: Unicode-Aware `\d` And `\s`

- [ ] Change shorthand class lowering so `\d` / `\D` use Unicode decimal-digit
  semantics

- [ ] Change shorthand class lowering so `\s` / `\S` use Unicode whitespace
  semantics

- [ ] Preserve the normal non-multiline boundary:
  - `\s` must not make a default search match through `\n`

- [ ] Add search-layer and CLI regressions for:
  - non-ASCII digits
  - non-ASCII whitespace
  - non-breaking space
  - newline handling in non-multiline mode
  - newline handling in multiline mode

## Phase 4: Unicode-Aware `\w`

- [ ] Change shorthand class lowering so `\w` / `\W` use the chosen Unicode
  word-character predicate

- [ ] Add representative regressions for:
  - Cyrillic letters
  - Greek letters
  - combining-mark cases
  - connector characters
  - invalid raw-byte behavior

## Phase 5: Unicode-Aware `\b` And `\B`

- [ ] Change boundary evaluation so `\b` / `\B` use the Unicode word-character
  predicate instead of ASCII wordness

- [ ] Add UTF-8 and raw-byte regressions for:
  - single-word non-ASCII lines
  - boundaries around mixed-script text
  - boundaries near combining marks
  - invalid-byte behavior

## Phase 6: Planner Boundary

- [ ] Keep Unicode-aware shorthand and boundary patterns off the raw-byte
  planner initially

- [ ] Add explicit regressions proving those patterns use the general raw-byte
  VM path

- [ ] Only revisit planner support after planner-vs-VM equivalence is proven

## Phase 7: Documentation And Migration Notes

- [ ] Update [supported-syntax.md](../supported-syntax.md) to document the new
  default shorthand and boundary semantics

- [ ] Add a migration note describing the visible change from ASCII-only
  shorthand behavior

- [ ] Document the explicit ASCII alternatives:
  - `[0-9]`
  - `[A-Za-z0-9_]`
  - explicit ASCII whitespace classes

## Phase 8: Validation

- [ ] Add Unicode helper tests that pin the new shorthand predicates directly

- [ ] Add search-layer equivalence coverage for UTF-8 and invalid UTF-8 inputs

- [ ] Add end-to-end CLI regressions for representative multilingual cases

- [ ] Re-run planner-boundary and output-equivalence coverage after the
  shorthand migration lands

## Recommended Order

- [ ] 1. Lock the exact semantic mapping for `\d`, `\s`, and `\w`
- [ ] 2. Implement Unicode-aware `\d` and `\s`
- [ ] 3. Implement Unicode-aware `\w`
- [ ] 4. Implement Unicode-aware `\b` / `\B`
- [ ] 5. Update docs and migration notes
- [ ] 6. Reconfirm raw-byte and planner boundaries

## Explicit Non-Goals

The following remain outside this plan:

- adding a separate fallback regex engine
- adding a separate Unicode mode switch for shorthand migration
- silently changing explicit ASCII regexes
- `Script_Extensions`
- unrelated Unicode property expansion work
