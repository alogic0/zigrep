# Regex Surface Plan

This plan covers the next regex-surface expansion work after the multiline
project. It is scoped to features that are both high value and compatible with
`zigrep`'s native engine design.

The goal is not full PCRE2 parity. The goal is:

- close the most misleading gaps relative to ripgrep's default regex surface
- keep the native engine coherent and fast on the common path
- make any future "fancy regex" boundary explicit instead of accidental

## Engine Boundary

- [x] Native engine principle:
  - everything that can stay in Thompson NFA / DFA / Pike VM territory belongs
    in the native engine

- [x] Fallback engine principle:
  - only constructs that inherently need backtracking-like semantics belong in
    a fallback engine

- [x] Native-engine in-scope direction:
  - shorthand classes like `\d`, `\w`, `\s`
  - word boundaries like `\b`, `\B`
  - stricter and richer escape handling
  - Unicode literal escapes if added
  - Unicode-aware character-class extensions that still lower cleanly into the
    current automata-friendly model

- [x] Fallback-engine out-of-scope direction for the native engine:
  - backreferences
  - lookahead and lookbehind
  - conditional groups
  - recursion and subroutine calls
  - control verbs and other PCRE-style backtracking features

- [x] Non-capturing groups are not a fallback-engine feature by themselves.
  They should be treated as a separate syntax decision:
  - pure syntax sugar that can lower to existing native structure is still
    native-engine territory
  - they do not justify a second engine on their own

## Phase 1: Fix Misleading Escape Behavior

- [ ] Audit the current backslash behavior and pin the exact compatibility rule:
- [x] Audit the current backslash behavior and pin the exact compatibility rule:
  - which escapes stay literal
  - which escapes become explicit errors
  - which escapes will become real regex operators

- [x] Stop silently treating unsupported shorthand escapes as plain literals.
  Minimum target:
  - `\d`, `\D`
  - `\w`, `\W`
  - `\s`, `\S`
  - `\b`, `\B`

- [x] Add parser and CLI regressions proving unsupported shorthand escapes fail
  explicitly instead of quietly changing regex meaning.

## Phase 2: Add Shorthand Character Classes

- [ ] Add syntax support for:
  - `\d`, `\D`
  - `\w`, `\W`
  - `\s`, `\S`

- [ ] Decide and document the semantic boundary up front:
  - ASCII-only shorthand semantics
  - or Unicode-aware shorthand semantics

- [ ] Prefer lowering shorthand classes into existing character-class HIR where
  practical, instead of introducing a separate execution path.

- [ ] Add parser, HIR, VM, search-layer, and CLI tests for shorthand classes.

- [ ] Add explicit invalid-UTF-8/raw-byte tests for shorthand classes so the
  behavior is pinned across both UTF-8 and raw-byte matching paths.

## Phase 3: Add Word Boundaries

- [ ] Expose `\b` and `\B` in the regex surface.

- [ ] Reuse the existing boundary logic in `src/regex/unicode.zig` instead of
  inventing a second boundary implementation.

- [ ] Add the missing parser / HIR / NFA node support for word boundaries.

- [ ] Decide and document whether boundary behavior is:
  - Unicode-aware by default
  - ASCII-only
  - or mode-dependent

- [ ] Add tests for:
  - ASCII words
  - non-ASCII words
  - punctuation boundaries
  - boundaries on invalid UTF-8 input
  - interaction with multiline mode

## Phase 4: Unicode Escapes And Escape Surface Cleanup

- [ ] Decide whether to add Unicode literal escapes such as `\u{...}`.

- [ ] If yes, add them as lexer/parser/HIR support without changing the native
  engine model.

- [ ] Review all current accepted escapes and document them precisely in
  `docs/supported-syntax.md`.

- [ ] Add tests proving the escape surface is strict and predictable:
  - supported escapes compile and match correctly
  - unsupported escapes fail explicitly

## Recommended Order

- [ ] 1. Fix misleading escape behavior first.
- [ ] 2. Add shorthand classes.
- [ ] 3. Add word boundaries.
- [ ] 4. Decide on Unicode literal escapes.
- [ ] 5. Review the remaining native-engine candidates, such as Unicode-aware
  class extensions and Unicode literal escapes.
- [ ] 6. Only after the native-engine candidate set is clear, decide whether a
  second regex engine is worth introducing at all.

## Phase 5: Finish Native-Engine Candidate Scope

- [ ] Review which remaining regex features are still good native-engine
  candidates because they stay inside Thompson NFA / DFA / Pike VM territory.
  Candidates:
  - Unicode literal escapes if added
  - Unicode-aware character-class extensions
  - Unicode property classes if they can be lowered cleanly enough
  - non-capturing groups if they are treated purely as syntax sugar

- [ ] Separate those features from the constructs that remain intentionally out
  of scope for the native engine:
  - look-around
  - backreferences
  - conditional groups
  - recursion and subroutine calls
  - control verbs and other PCRE-style backtracking features

- [ ] Decide whether any of the remaining candidate features should be moved
  into the current implementation plan now, before making any fallback-engine
  decision.

## Phase 6: Fallback Engine Decision

- [ ] Decide whether `zigrep` should ever have a second regex engine for the
  remaining backtracking-like features.

- [ ] If the answer is yes, write a separate plan for a ripgrep-style boundary:
  - native engine remains default
  - richer engine is explicit or auto-selected only when needed
  - behavior and performance differences are documented clearly

- [ ] If the answer is no, document the non-goals explicitly and keep the
  native engine surface intentionally narrow.

## Explicit Non-Goals For This Plan

- [ ] Do not add full PCRE2-compatible syntax to the native engine.
- [ ] Do not mix multiline work back into this plan.
- [ ] Do not add a second regex engine before the native shorthand/boundary
  surface is cleaned up.
