# Remaining Unicode Parity Plan

This plan covers the main remaining Unicode regex-surface gaps between
`zigrep` and the checked local `ripgrep` after the following work is already
landed:

- Unicode-aware `\w`, `\d`, `\s`, `\b`, `\B`
- broad Unicode property support
- script support via `Script=` and `sc=`
- Unicode ignore-case and smart-case parity for the implemented surface
- broad folded Unicode range support under `-i`

## Goal

Close the highest-value remaining Unicode regex parity gaps without:

- introducing a fallback engine
- weakening the current native-core correctness rules
- mixing unrelated Unicode-property expansion work into syntax-surface work

## Current Remaining Gaps

The strongest remaining Unicode regex-surface gaps are:

- `Script_Extensions` syntax such as `\p{scx=Greek}`
- inline Unicode mode toggles such as `(?-u:...)`
- ripgrep's half-boundary forms:
  - `\b{start-half}`
  - `\b{end-half}`
- character-class set operations such as subtraction/intersection

Secondary gap:

- broader Unicode property coverage beyond the currently implemented curated
  set

## Priority Order

Implementation order for this plan:

1. `Script_Extensions` / `scx=...`
2. inline Unicode mode toggles
3. half-boundaries
4. class set operations
5. broader property-surface expansion only if still needed afterward

## Phase 1: Script_Extensions

- [x] Confirm the exact local `ripgrep` syntax and matching behavior for:
  - `\p{scx=Greek}`
  - `\P{scx=Greek}`
  - bracketed forms such as `[\p{scx=Greek}]`
  - current result: local `ripgrep` supports `scx=...`,
    `Script_Extensions=...`, bracketed forms, and negated forms

- [x] Extend the Unicode generator inputs to include `ScriptExtensions.txt`

- [x] Generate a compact native data model for `Script_Extensions`
  - current result: the generator now emits a second script-spec registry for
    Script_Extensions, seeded from Script defaults and layered with
    `ScriptExtensions.txt`

- [x] Add native property lookup support for:
  - `scx=...`
  - `Script_Extensions=...`

- [x] Add search-layer and CLI regressions for the initial `scx=` surface

## Phase 2: Inline Unicode Mode Controls

- [x] Confirm the local `ripgrep` behavior for:
  - `(?-u:...)`
  - nested Unicode mode toggles
  - interactions with Unicode-aware shorthand and properties
  - current result: local `ripgrep` supports `(?-u:...)`, nested `(?u:...)`
    restoration, keeps ASCII shorthand and boundary behavior inside `(?-u:...)`,
    and rejects Unicode property escapes there

- [x] Decide whether `zigrep` should support only `(?-u:...)` first or a
  broader inline flag subset
  - current result: support only `(?-u:...)` and `(?u:...)` in this slice;
    broader inline-flag parsing stays out of scope

- [x] Add parser support for the chosen inline Unicode-mode syntax

- [x] Define the native-engine lowering rule:
  - Unicode-aware defaults outside the group
  - ASCII-mode behavior inside the group
  - current result:
    - `\d`, `\D`, `\w`, `\W`, `\s`, `\S`, `\b`, and `\B` switch to ASCII
      semantics inside `(?-u:...)`
    - `(?u:...)` restores Unicode-aware semantics in nested groups
    - `\p{...}` remains rejected inside ASCII-mode groups

- [x] Add search-layer and CLI regressions for mixed Unicode/ASCII subpatterns

## Phase 3: Half-Boundaries

- [x] Confirm the local `ripgrep` semantics for:
  - `\b{start-half}`
  - `\b{end-half}`
  - current result:
    - `\b{start-half}` checks only the left side for `\W|\A`
    - `\b{end-half}` checks only the right side for `\W|\z`
    - together they match the documented `-w/--word-regexp` wrapping behavior

- [x] Extend the parser AST and HIR with explicit half-boundary nodes

- [x] Add VM/NFA support for half-boundary assertions

- [x] Add search-layer and CLI regressions for:
  - ASCII words
  - Unicode words
  - punctuation boundaries

## Phase 4: Class Set Operations

- [x] Confirm the exact local `ripgrep` surface to target first:
  - subtraction
  - intersection
  - nested set expressions
  - current result:
    - local `ripgrep` supports subtraction like `[\w--\p{ascii}]`
    - local `ripgrep` supports intersection like `[\p{Greek}&&\p{Uppercase}]`
    - nested set expressions remain deferred in this slice

- [x] Decide the smallest native-core subset worth implementing first
  - current result:
    - support one top-level subtraction or intersection inside a bracket class
    - defer nested set expressions to a follow-up slice

- [x] Extend the parser with explicit class-set AST forms

- [x] Lower class-set operations into a native matcher representation that
  preserves Unicode property items and folded ranges

- [x] Keep planner support out of scope until VM semantics are proven

- [x] Add search-layer and CLI regressions for representative set expressions

## Phase 5: Remaining Property-Surface Review

- [ ] Re-check whether broader property expansion is still materially useful
  after the syntax-surface gaps are closed

- [ ] If yes, spin that into a separate follow-up plan instead of widening this
  plan

## Phase 6: Validation And Docs

- [x] Keep [docs/supported-syntax.md](../supported-syntax.md) aligned after each
  implemented slice

- [x] Compare each completed slice against local `ripgrep` before closing it

- [x] Run:
  - `zig build test`
  - `zig build bench`

## Recommended Order

- [x] 1. Land `Script_Extensions`
- [x] 2. Land inline Unicode mode toggles
- [x] 3. Land half-boundaries
- [x] 4. Decide and land the smallest useful class-set subset
- [ ] 5. Re-evaluate remaining property-surface gaps

## Explicit Non-Goals

This plan does not include:

- fallback-engine work
- unrelated performance tuning
- planner support for new Unicode regex constructs before VM equivalence is
  proven
