# Native Unicode Regex Plan

This plan covers the next native-engine regex work after
`docs/plans/regex-surface-plan.md`.

It is intentionally limited to features that can still live inside
`zigrep`'s current Thompson NFA / DFA / Pike VM model.

The goal is:

- improve Unicode behavior without introducing a second regex engine
- keep lowering and execution coherent across UTF-8 and raw-byte paths
- make Unicode-data costs and semantic boundaries explicit before code lands

## Borrowed Inputs

- [x] Borrow Unicode data inputs from the local `zg` repository at
  `../zig-libs/zg/data/unicode` during generation time only.

- [x] Borrow the general data-generation approach from `zg`:
  - checked-in Unicode database files
  - generated compact Zig tables

- [x] Do not borrow `zg` as a runtime dependency.
  Boundary:
  - `zigrep` runtime code must import only checked-in generated files from this
    repo
  - `zigrep` source code must not depend on absolute filesystem paths to the
    `zg` checkout
  - the external `zg` path is allowed only for generator-time inputs

- [x] Record the contributor workflow in
  [docs/unicode-data-generation.md](../unicode-data-generation.md) instead of
  leaving it only in this plan.

## Scope

- [x] Keep this plan native-engine only.
- [x] Do not reopen the fallback-engine question here.
- [x] Focus on:
  - Unicode-aware character-class extensions
  - Unicode property classes only if they can be lowered cleanly

## Phase 1: Decide Unicode Semantics

- [x] Decide whether default shorthand classes remain ASCII-only permanently or
  whether Unicode-aware alternatives should be added separately.

  Decision:
  - keep `\d`, `\w`, and `\s` ASCII-only for compatibility
  - add Unicode-aware behavior only through explicit Unicode property syntax
  - do not silently widen existing shorthand semantics

- [x] Decide the target syntax surface for Unicode-aware classes:
  - property syntax like `\p{...}` / `\P{...}`
  - POSIX-like named classes are out unless they clearly fit the parser model
  - bracket-class Unicode property items such as `[\p{Greek}]` are optional and
    should be staged only after top-level property support works

  Decision:
  - first syntax target is top-level property escapes only:
    - `\p{Letter}`
    - `\P{Letter}`
  - do not add POSIX-style named classes
  - do not add bracket-class property items in the first implementation

- [x] Decide the semantic rule for raw-byte matching:
  - valid UTF-8 scalars participate in Unicode-aware class/property checks
  - invalid bytes remain non-scalar raw units and should not be treated as
    matching positive Unicode property predicates by accident

  Decision:
  - valid UTF-8 scalars participate in Unicode property checks
  - invalid raw bytes are non-scalar units
  - invalid raw bytes do not satisfy positive Unicode property predicates
  - invalid raw bytes do satisfy negated Unicode property predicates, which
    keeps negation behavior coherent with the current raw-byte model

- [x] Decide the first supported property set.
  Recommended starting scope:
  - `Letter`
  - `Number`
  - `Whitespace`
  - maybe `Alphabetic`

  Decision:
  - first property set is:
    - `Letter`
    - `Number`
    - `Whitespace`
  - defer `Alphabetic` until there is a clearer reason to distinguish it from
    `Letter` in the user-visible surface

## Phase 2: Choose A Unicode Data Strategy

- [x] Decide where Unicode category/property data will come from.
  Options to evaluate:
  - checked-in generated Zig tables
  - a small generated subset for only the supported properties
  - hand-maintained ranges only if the supported set stays very small

  Decision:
  - use checked-in generated Zig tables
  - generate only the subset needed for the supported property set
  - do not hand-maintain Unicode ranges in source once property support is real

- [x] Prefer generated static tables over ad hoc handwritten logic once the
  property surface grows beyond a tiny subset.

- [x] Decide the versioning rule for Unicode data:
  - pin a Unicode version in the repo
  - document it in `docs/supported-syntax.md`

  Decision:
  - pin a Unicode version in the repo when the generated tables are added
  - document that pinned version in `docs/supported-syntax.md`

- [x] Define size limits before implementation:
  - acceptable table size increase
  - acceptable compile-time cost
  - acceptable runtime lookup cost

  Decision:
  - keep the initial generated table set limited to the first three supported
    properties
  - prefer compact range tables over large dense maps
  - if the generated data becomes large enough to meaningfully slow builds or
    inflate the binary, stop and revisit the property scope before expanding it

## Phase 3: Add Unicode Property Syntax

- [x] Add lexer support for property escapes only if Phase 1 and 2 are settled.
  Candidate syntax:
  - `\p{Letter}`
  - `\P{Letter}`

- [x] Reject unsupported or malformed property names explicitly.

- [x] Lower supported property escapes into native-engine class/property nodes
  without introducing a second execution path.

- [x] Keep ASCII shorthand classes unchanged unless there is an explicit
  migration decision.

- [x] Add a Unicode property table generator scaffold for the initial supported
  subset so the eventual runtime implementation does not depend on handwritten
  ranges.

## Phase 4: Engine Integration

- [x] Extend HIR to represent Unicode property predicates cleanly.

- [x] Extend NFA compilation without changing the overall execution model.

- [x] Extend VM matching rules:
  - valid UTF-8 scalar => Unicode property lookup
  - invalid byte on raw-byte path => non-scalar behavior stays explicit

- [x] Decide whether DFA boolean-search fast paths need to opt out for Unicode
  property patterns at first, similar to the boundary decision, before any more
  aggressive optimization work.

## Phase 5: Character-Class Integration

- [x] Decide whether Unicode property items can appear inside bracket classes in
  the first implementation or only as top-level escapes.

  Decision:
  - keep the first implementation top-level only
  - do not allow property items inside bracket classes yet

- [ ] If bracket integration is included, support property items inside classes
  without creating ambiguous parser behavior.

- [x] Keep non-Unicode class behavior stable:
  - existing ASCII classes
  - negated classes
  - raw-byte matching semantics on invalid UTF-8 input

## Phase 6: Validation

- [x] Add parser tests for:
  - valid property syntax
  - malformed property syntax
  - unsupported property names

- [x] Add VM and search-layer tests for:
  - positive and negated property checks
  - UTF-8 scalar matching
  - invalid-byte raw-path behavior
  - interaction with multiline mode where relevant

- [x] Add end-to-end CLI tests for:
  - property matching in normal UTF-8 text
  - property matching in invalid-UTF-8 files through the raw-byte path
  - failure behavior for unsupported properties

- [x] Re-run planner-vs-general-VM equivalence coverage if any byte-path fast
  path is taught about Unicode properties.

  Result:
  - Unicode property patterns still stay off the byte planner
  - the general raw-byte VM remains the only byte-path execution route for
    property patterns in the current implementation

## Recommended Order

- [x] 1. Lock Unicode semantics first.
- [x] 2. Choose and pin the Unicode data source/version.
- [x] 3. Implement a very small property set with explicit errors for the rest.
- [x] 4. Validate UTF-8 and raw-byte behavior carefully before broadening the
  property surface.

## Explicit Non-Goals

- [ ] Do not change `\d`, `\w`, `\s` away from their current ASCII semantics in
  this plan unless there is a separate compatibility decision.
- [ ] Do not add look-around, backreferences, or any other backtracking-only
  feature.
- [ ] Do not add a fallback engine here.
- [ ] Do not promise full Unicode property coverage in the first implementation.
