# Native Unicode Full Property Surface Plan

This plan covers the full Unicode property surface that can still live inside
`zigrep`'s native Thompson NFA / DFA / Pike VM model.

It is intentionally broader than:

- [native-unicode-regex-plan.md](native-unicode-regex-plan.md)
- [native-unicode-general-category-expansion-plan.md](native-unicode-general-category-expansion-plan.md)

The goal is to define a complete native-core Unicode property roadmap without
crossing into fallback-engine territory.

## Core Boundary

This plan stays inside the native engine when a property feature is:

- a predicate over a single Unicode scalar
- representable as a zero-width assertion or class/property membership check
- matchable without backtracking-only semantics
- compatible with the existing NFA / DFA / Pike VM execution model

This plan does not include:

- look-around
- backreferences
- conditional groups
- property features that inherently require a different execution model

## Scope Categories

The full native-core Unicode property surface is divided into four buckets:

1. General categories and category aliases
2. Derived boolean properties
3. Script and Script_Extensions style properties
4. Unicode-aware shorthand and boundary semantics

## Phase 1: Finish Property Naming Policy

- [x] Define the accepted naming forms for every supported property family:
  - long names
  - short aliases
  - case normalization
  - separator normalization

- [x] Keep the current permissive name normalization model:
  - ignore case
  - ignore `_`, `-`, and ASCII whitespace in property names

- [x] Decide whether unsupported-but-recognizable aliases should fail with a
  dedicated error or the existing unsupported-property error.

## Phase 2: General Categories

This bucket should stay fully native.

- [x] Support the complete general-category families:
  - `Letter`
  - `Number`
  - `Mark`
  - `Punctuation`
  - `Symbol`
  - `Separator`
  - `Other`

- [x] Support subgroup categories where they map cleanly to generated range
  tables:
  - `Lu`, `Ll`, `Lt`, `Lm`, `Lo`
  - `Mn`, `Mc`, `Me`
  - `Nd`, `Nl`, `No`
  - `Pc`, `Pd`, `Ps`, `Pe`, `Pi`, `Pf`, `Po`
  - `Sm`, `Sc`, `Sk`, `So`
  - `Zs`, `Zl`, `Zp`
  - `Cc`, `Cf`, `Cs`, `Co`, `Cn`

- [x] Decide whether to expose category-family aliases explicitly:
  - `L`, `N`, `M`, `P`, `S`, `Z`, `C`

- [x] Generate and check in compact range tables for all supported category
  groups and subgroups.

## Phase 3: Derived Boolean Properties

This bucket also stays native if each property is just a scalar predicate over
 generated tables.

- [x] Support the highest-value derived properties first:
  - `Alphabetic`
  - `White_Space`
  - `Uppercase`
  - `Lowercase`
  - [x] `Cased`
  - [x] `Case_Ignorable`

- [ ] Evaluate other derived properties that are still good native-core fits:
  - [x] `ID_Start`
  - [x] `ID_Continue`
  - [x] `XID_Start`
  - [x] `XID_Continue`
  - [x] `Default_Ignorable_Code_Point`

- [x] Keep each derived property table generated from checked-in Unicode data,
  not handwritten logic.

- [x] Treat `Any` and `ASCII` as matcher-level special cases rather than
  generated-table properties.

## Phase 4: Script Properties

Script matching is still native-core work if implemented as table lookup over a
 decoded scalar.

- [x] Lock the script-surface decision:
  - [x] support `Script` in the native engine
  - [x] defer `Script_Extensions`
  - [x] keep `scx=` syntax out of scope for the current plan

- [x] Support syntax only if it stays parser-friendly:
  - [x] `\p{Greek}`
  - [x] `\p{Script=Greek}`
  - [x] `\p{sc=Greek}`
  - [x] leave `\p{scx=Greek}` unsupported in this plan

- [x] Generate script tables from checked-in Unicode data instead of embedding
  them manually.
  - current `Script` lookup is generated from `Scripts.txt`
  - current `sc=` aliases are generated from `PropertyValueAliases.txt`

- [x] Keep raw-byte semantics unchanged:
  - valid scalar => script lookup
  - invalid raw byte => no positive match
  - invalid raw byte => negated match allowed

## Phase 5: Special Unicode Property Cases

- [x] Add `\p{Any}` if we want parity with ripgrep’s default regex surface.
  Native-core rule:
  - valid Unicode scalar always matches
  - invalid raw byte does not match positive `Any`
  - invalid raw byte does match negated `Any`

- [x] Consider `\p{ASCII}` as a special native-core property.

- [ ] Decide whether binary-property-style names like `Emoji` are in scope.
  Default recommendation:
  - do not attempt all of them at once
  - stage only the ones backed by clear user demand

## Phase 6: Bracket-Class Integration

- [x] Ensure every supported property family also works inside bracket classes:
  - `[\p{Greek}]`
  - `[\P{White_Space}]`
  - mixed with literals and ranges

- [x] Keep class range syntax literal-only:
  - property items do not participate in `x-y` ranges

- [x] Keep Unicode property class items off the byte planner unless a future
  planner extension proves equivalence safely.

## Phase 7: Unicode-Aware Shorthand And Boundaries

This is still native-core work, but it is a compatibility decision, not just
table generation.

- [ ] Decide whether to keep ASCII shorthand semantics forever or add an
  explicit Unicode mode switch.

- [ ] If parity with ripgrep is the goal, plan the migration for:
  - Unicode-aware `\w`
  - Unicode-aware `\d`
  - Unicode-aware `\s`
  - Unicode-aware `\b` / `\B`

- [ ] If shorthand semantics remain ASCII-only, consider explicit Unicode
  alternatives instead of widening current behavior silently.

## Phase 8: Generator Strategy

- [x] Expand [tools/gen_unicode_props.zig](../../tools/gen_unicode_props.zig)
  carefully instead of fragmenting into many ad hoc generators.

- [x] Keep the generator-time-only dependency on local Unicode data sources.

- [x] Continue checking in generated Zig tables so runtime remains self-contained.

- [x] Watch binary size and compile-time cost as property coverage grows.
  Current note:
  - `zig build test` remains green after the expanded Unicode surface
  - `zig build bench` is currently blocked by unrelated stale DFA/bench compile
    coverage and is not a Unicode-plan correctness blocker

## Phase 9: Validation

- [x] Add Unicode helper tests for:
  - property lookup
  - alias lookup
  - positive and negated membership
  - representative values from each property family

- [x] Add search-layer tests for:
  - top-level property escapes
  - bracket-class property items
  - invalid raw-byte behavior
  - multiline interactions where relevant

- [x] Add end-to-end CLI tests for:
  - one representative match per property family
  - representative negated-property cases
  - unsupported property names and unsupported syntax forms

- [x] Reconfirm planner boundary behavior after each property-family expansion.

## Recommended Implementation Order

- [x] 1. Finish general categories and subgroup categories
- [x] 2. Finish the highest-value derived boolean properties
- [x] 3. Add `Any` and `ASCII` if desired
- [x] 4. Decide on script support
- [x] 5. Only then revisit Unicode-aware shorthand semantics
  Current decision:
  - do not widen shorthand semantics in this plan
  - leave ASCII shorthand and ASCII word-boundary behavior unchanged

## Explicit Non-Goals

The following remain outside this plan:

- backtracking-only regex features
- fallback-engine work
- property execution inside the byte planner
- silent widening of ASCII shorthand behavior without an explicit compatibility
  decision
